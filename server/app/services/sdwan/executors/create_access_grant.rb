# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.access_grant_create` — entitles one user to attach
    # VPN clients to one SDWAN network.
    #
    # IMP-343163bf37a4: the category was seeded and registered from the start
    # but had no executor and no gate site, so both operator surfaces created
    # grants inline. That mattered more than a missing audit row, because
    # creation is not only additive here: AccessGrantsController#create and
    # SdwanTool#create_access_grant both `find_or_initialize_by(user_id:)`,
    # and the grant is unique per (network, user). A create naming a user
    # whose grant was REVOKED therefore reuses that row and forces it back to
    # active with revoked_at and revocation_reason cleared — the exact inverse
    # of `sdwan.access_grant_revoke`, which is seeded require_approval on both
    # surfaces. The state an operator approval was required to leave could be
    # re-entered with no gate at all.
    #
    # Revoked devices are deliberately NOT un-revoked. AccessGrant#revoke!
    # soft-revokes each device on its way out, and re-granting access is not
    # the same decision as handing back the keys that were on it: the operator
    # re-issues devices explicitly. That also keeps this executor's blast
    # radius strictly smaller than its inverse's.
    class CreateAccessGrant < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5) —
      # read by AccessGrantsController#create and by
      # Ai::Tools::SdwanTool#create_access_grant, and pinned to the seeded
      # policy row + engine registration by
      # spec/services/sdwan/executors/action_category_coherence_spec.rb.
      ACTION_CATEGORY = "sdwan.access_grant_create"

      protected

      def perform
        network = resolve_scoped(::Sdwan::Network, params[:network_id])
        # Scoped to the network's OWNER, never to an account the request names.
        # resolve_scoped has already refused a network outside the operation's
        # account, so this anchor is a row's own owner rather than a claim.
        user = ::User.where(account_id: network.account_id).find(params[:user_id])

        grant = network.access_grants.find_or_initialize_by(user_id: user.id)
        grant.assign_attributes(
          account_id: network.account_id,
          status: "active",
          # The operator who filed the request, not whoever approved it later.
          # Base#requesting_user is nil-safe across the duck-typed contexts and
          # is the right reader for a User-id column (#initiator falls back to
          # the ai_agent). Falls back to the existing value so an approval can
          # never blank a grant's provenance.
          granted_by_id: requesting_user&.id || grant.granted_by_id,
          granted_at: Time.current,
          revoked_at: nil,
          revocation_reason: nil
        )
        # Only when the caller said something about tags: both surfaces send
        # them optionally, and an omitted key must preserve what the row
        # already carries rather than clearing it on a re-grant.
        grant.tags = Array(params[:tags]) unless params[:tags].nil?
        grant.save!

        { grant_id: grant.id, network_id: network.id, user_id: user.id }
      end

      def summarize
        return "Grant SDWAN access to #{grant_label}" if grant_label.present?

        "Grant SDWAN access on network #{network_label}"
      end

      def impact
        "User may attach VPN clients to the network; a previously revoked grant is reinstated"
      end

      private

      # This card names a USER'S EMAIL ADDRESS, so the anchoring discipline
      # matters more here than for a card naming a resource: an unanchored
      # label is a cross-account disclosure of personal data, which is why
      # Sdwan::Executors::DeleteAccessGrant carries dedicated examples in
      # spec/services/system/executors/preview_account_anchor_spec.rb.
      #
      # Two anchors, in precedence order — CreatePeer#target_account_id argues
      # the same ladder at length:
      #
      #   1. the OPERATION's account. The gate opened the operation in it, so
      #      it is the one account on the request nobody supplied. This is the
      #      live path: Ai::DeferredOperation#preview always supplies it.
      #   2. otherwise the account of the network the request NAMES — a row's
      #      own owner rather than a claim — and only when the USER named by
      #      the SAME request corroborates it. Deriving the anchor from the
      #      network alone would be no anchor at all: the check
      #      `network.account_id == anchor` cannot fail when `anchor` was read
      #      off that same network, so every caller-supplied id would get its
      #      network named. One caller-supplied id is not corroboration for
      #      another, so when the two rows disagree the card names neither.
      def anchor_account_id
        return @anchor_account_id if defined?(@anchor_account_id)

        @anchor_account_id = account&.id || corroborated_account_id
      end

      def corroborated_account_id
        owner = named_network&.account_id
        return nil if owner.blank?
        return nil unless named_user&.account_id == owner

        owner
      end

      # Resolved by id ALONE: on the preview path these rows carry the anchor,
      # so they cannot themselves be scoped by one. Nothing is named off either
      # until `anchor_account_id` has settled and the row is checked against it.
      def named_network
        return @named_network if defined?(@named_network)

        @named_network =
          params[:network_id].present? ? ::Sdwan::Network.find_by(id: params[:network_id]) : nil
      end

      def named_user
        return @named_user if defined?(@named_user)

        @named_user = params[:user_id].present? ? ::User.find_by(id: params[:user_id]) : nil
      end

      def network_label
        anchor = anchor_account_id
        named  = named_network
        return params[:network_id] if anchor.blank? || named.nil? || named.account_id != anchor

        named.name.presence || named.id
      end

      def grant_label
        anchor = anchor_account_id
        return nil if anchor.blank?

        user = named_user
        return nil if user.nil? || user.account_id != anchor

        email = user.email.presence
        return nil if email.blank?

        "#{email} on #{network_label}"
      end
    end
  end
end
