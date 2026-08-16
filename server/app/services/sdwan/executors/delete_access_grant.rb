# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.access_grant_delete`, dispatched via Ai::AutonomyGate
    # from Api::V1::System::Sdwan::AccessGrantsController#destroy.
    #
    # Deliberately separate from Sdwan::Executors::RevokeAccessGrant, which
    # serves the softer POST :revoke. Revoking flips the grant to "revoked" and
    # soft-revokes its devices, keeping every row for the 90-day audit window;
    # deleting removes the grant, cascades through
    # `has_many :user_devices, dependent: :destroy` to every device, and takes
    # each device's WireGuard private key out of Vault with it (the
    # VaultCredential after_destroy hook). Keeping the two apart means an
    # operator approving a revoke can never get a delete, and gives each verb
    # its own intervention policy.
    #
    # The destroy happens HERE rather than in the controller's on_proceed lambda
    # because `sdwan.access_grant_delete` is seeded require_approval:
    # Ai::GatedActions#gate! renders the approval stub on its :pending branch and
    # never calls on_proceed, so a DELETE approved later would otherwise leave
    # the grant in place while the caller had already been told it was deleted.
    class DeleteAccessGrant < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.access_grant_delete"

      protected

      def perform
        grant        = scoped_grant
        grant_id     = grant.id
        network_id   = grant.sdwan_network_id
        device_count = grant.user_devices.count

        grant.destroy!

        { grant_id: grant_id, network_id: network_id, destroyed: true, devices_destroyed: device_count }
      end

      def summarize
        "Delete SDWAN access grant #{grant_label || params[:grant_id]}"
      end

      # Surfaced on the approval card — the only place an operator sees the
      # blast radius before saying yes, so the cascade is named explicitly.
      def impact
        count = device_count_for_preview
        return "Destroys the access grant and every VPN device beneath it" if count.nil?

        "Destroys the access grant and its #{count} #{'device'.pluralize(count)}, removing each device's " \
          "WireGuard key from Vault; unlike revoke, nothing is retained for the 90-day audit window"
      end

      private

      # A deferred operation runs long after the request that created it, so the
      # network/grant pairing recorded in params is re-validated against current
      # state: if the grant has moved to another network, or either row is gone,
      # this raises instead of destroying the wrong grant.
      #
      # This is NOT an authorization check — both ids come from the stored
      # params. Account ownership is enforced upstream by the controller's
      # set_network/set_grant guards, matching the convention the other SDWAN
      # trust-boundary executors follow.
      def scoped_grant
        ::Sdwan::Network.find(params[:network_id]).access_grants.find(params[:grant_id])
      end

      # The row the CARD names, resolved through Base#scoped_label_record
      # (IMP-8e4674f4d62d). scoped_grant is deliberately not reused here: it
      # anchors on the NETWORK named in the same params, which re-validates the
      # pairing but establishes nothing about ownership — so a caller that did
      # not pre-scope had another account's grant labelled on its approvers'
      # card, and this card's label is the grant holder's EMAIL ADDRESS. That
      # makes it a disclosure of personal data, not a mislabelled resource.
      #
      # Both guards, not one: the account anchor is the ownership check, and
      # the `sdwan_network_id` comparison keeps scoped_grant's pairing check —
      # a grant that has moved network since the operation was parked still
      # declines to be named. The comparison is against the params value
      # because that is what the approver's request was ABOUT; reaching the
      # network through the grant instead would make the pairing tautological.
      #
      # Nil is "render the id instead", per the seam's caller contract — never
      # "not found", which it also covers.
      def label_grant
        grant = scoped_label_record(::Sdwan::AccessGrant, params[:grant_id])
        return nil unless grant
        return nil unless grant.sdwan_network_id.to_s == params[:network_id].to_s

        grant
      end

      def grant_label
        label_grant&.user&.email
      end

      def device_count_for_preview
        label_grant&.user_devices&.count
      end
    end
  end
end
