# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.federation_peer_accept`. Dispatched through
    # Ai::AutonomyGate from BOTH acceptance surfaces —
    # FederationPeersController#update (a PATCH whose status transitions to
    # "accepted") and Ai::Tools::SdwanTool#accept_federation_peer.
    #
    # Accepting is the inverse of revoking and carries the same weight: it
    # completes the handshake that starts mutual route advertisement with a
    # remote instance. Revocation is gated on two endpoints, so forming the
    # link is gated to match.
    #
    # The acceptance happens HERE rather than in a controller on_proceed lambda
    # because `sdwan.federation_peer_accept` resolves to require_approval — it
    # is seeded that way on the SDWAN Manager, and require_approval is also
    # Ai::InterventionPolicyService's default when no policy row matches (an
    # operator-initiated request carries no agent, so an agent-scoped row does
    # not match it). Ai::GatedActions#gate! renders the approval stub on its
    # :pending branch and never calls on_proceed (IMP-322999495307), so an
    # approved PATCH would otherwise leave the peer proposed.
    class AcceptFederationPeer < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.federation_peer_accept"

      # Attributes that ride in on the acceptance PATCH and are deliberately NOT
      # written by #perform: :status is the flip accept! performs, and
      # :signed_at is stamped by accept! with the moment of acceptance. Shared
      # by #perform and #named_attribute_keys so the write and the approval
      # card's claim about it cannot drift apart (IMP-35bc8eda71ad).
      IGNORED_RIDE_ALONG_KEYS = %i[status signed_at].freeze

      protected

      def perform
        peer = ::System::FederationPeer.find(params[:federation_peer_id])

        # One transaction: the ride-along fields and the acceptance are a single
        # operator intent, and accept! can still refuse below (a peer revoked
        # during the approval window, a bad token). Without this the refusal
        # would commit the field edits and leave the peer proposed — an
        # unapproved edit smuggled in on a rejected acceptance.
        ::ActiveRecord::Base.transaction do
          # The controller's PATCH permits other mutable fields in the same
          # request as the status flip, so they ride along under
          # params[:attributes]. Applied BEFORE accept!, which merges the
          # accepted_by_user_id audit key into metadata — writing that stamp
          # last keeps a caller-supplied metadata hash from clobbering it.
          #
          # signed_at is excluded rather than applied-then-overwritten: accept!
          # stamps it with the moment of acceptance, which is what the column
          # means, so a value supplied in the same PATCH cannot win and should
          # not look like it might.
          ride_along = attrs.except(*IGNORED_RIDE_ALONG_KEYS)
          peer.update!(ride_along) if ride_along.any?

          # accept! is the only path that verifies the Phase 11b single-use
          # acceptance token and records who accepted; it returns false rather
          # than raising on a rejected transition or a bad token. That false has
          # to be converted here — the previous implementation dropped it and
          # reported success over a peer that never left "proposed".
          #
          # This runs long after the request that queued it, so the transition
          # is re-checked against current state: a peer revoked during the
          # approval window must not be quietly accepted afterwards.
          #
          # The accepting operator comes from the gate's own record of who asked
          # (current_user at request time), never from params — params are
          # replayed from a stored row and must not be able to name someone else.
          unless peer.accept!(accepted_by_user: deferred_operation&.requested_by,
                              acceptance_token: params[:acceptance_token])
            raise ArgumentError, "federation peer #{peer.id} was not accepted: #{acceptance_failure(peer)}"
          end
        end

        { federation_peer_id: peer.id, accepted: true }
      end

      def summarize = "Accept federation peer #{params[:federation_peer_id]}"
      def impact    = "Completes federation handshake; mutual route advertisement begins"

      # The card names what #perform WRITES, so the two keys it drops are not
      # announced (IMP-35bc8eda71ad). Without this the PATCH that supplies
      # signed_at renders "Sets fields: signed_at" on a card for an operation
      # that discards it — the exact "should not look like it might" #perform
      # excludes it to avoid.
      def named_attribute_keys = attrs.keys - IGNORED_RIDE_ALONG_KEYS

      private

      # accept! records its reason on the model for the token legs and returns a
      # bare false for a rejected transition; name the status in that case so an
      # operator reading the failed deferred operation can tell the two apart.
      def acceptance_failure(peer)
        peer.errors.full_messages.presence&.join("; ") ||
          "status=#{peer.status.inspect} cannot transition to accepted"
      end
    end
  end
end
