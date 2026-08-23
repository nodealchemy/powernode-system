# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.federation_peer_data_residency`. Dispatched through
    # Ai::AutonomyGate from BOTH residency surfaces —
    # FederationPeersController#update (a PATCH that CHANGES data_residency)
    # and Ai::Tools::SdwanTool#set_data_residency.
    #
    # IMP-9bf58a693634. `data_residency` is a COMPLIANCE declaration, not a
    # label: Federation::ResidencyEnforcer compares it against this instance's
    # own POWERNODE_DATA_RESIDENCY to decide whether a record may cross a
    # regulatory boundary to this peer, and Sdwan::FederationGovernance raises
    # a finding on an active platform peer that has not declared one. Rewriting
    # it silently relaxes (or fabricates) a boundary.
    #
    # It therefore carries the treatment of its trust-boundary siblings —
    # propose / accept / revoke are all seeded require_approval — rather than a
    # lighter tier. `notify_and_proceed` would not have been a gate at all
    # here: Ai::AutonomyGate executes it inline exactly as auto_approve, so it
    # would have bought an audit row and no human decision.
    #
    # THE AUDIT ROW: the gate's own Ai::DeferredOperation is durable but is
    # keyed by action_category — it is not on the PEER's trail, which is what
    # Ai::Tools::SdwanTool#get_audit_log, Federation::AuditShipmentService
    # (WORM sealing) and FederationApi::AuditExcerptsController read, all three
    # filtering `federation.*` FleetEvents on payload->>'federation_peer_id'.
    # System::FederationPeer's own emitter only fires on saved_change_to_status?,
    # so a residency change emits nothing there. #perform emits it explicitly,
    # INSIDE the write transaction and non-best-effort (see #emit_audit_event!).
    class SetFederationPeerDataResidency < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.federation_peer_data_residency"

      # Raised when the compliance write could not be paired with its audit
      # event. A StandardError, so Ai::DeferredOperation#execute_now! fails the
      # row and the approver who authorised it sees the refusal rather than a
      # silent success (the reasoning ::System::Executors::Base::
      # ReplayBaselineError carries, for the same audience).
      class AuditEventNotRecorded < StandardError; end

      # The peer's audit-trail event kind. `federation.`-prefixed so the three
      # per-peer readers named above pick it up.
      EVENT_KIND = "federation.peer.data_residency_changed"

      # Attributes that ride in on the residency PATCH and are deliberately NOT
      # written here. `status` is the trust-boundary flip, which has its own two
      # gated categories (accept / revoke) and its own transition matrix — a
      # residency approval must not become a back door to it. The controller
      # already excepts it; excepted again here because params are replayed
      # verbatim from a stored row and this executor is reachable from any
      # surface that names it.
      IGNORED_RIDE_ALONG_KEYS = %i[status].freeze

      protected

      def perform
        peer = ::System::FederationPeer.find(params[:federation_peer_id])
        previous = peer.data_residency

        # The ride-along fields of the same request and the residency change are
        # ONE caller intent (the acceptance executor's rule, for the same
        # reason): applying half of them at request time and the rest at
        # approval leaves a PATCH that answered 202 partially committed.
        attributes = attrs.except(*IGNORED_RIDE_ALONG_KEYS)

        ::ActiveRecord::Base.transaction do
          peer.update!(attributes)
          emit_audit_event!(peer, previous)
        end

        { federation_peer_id: peer.id,
          data_residency: peer.data_residency,
          previous_data_residency: previous }
      end

      def summarize = "Set federation peer #{params[:federation_peer_id]} data residency to #{attrs[:data_residency].inspect}"
      def impact    = "Redeclares the peer's regulatory home — Federation::ResidencyEnforcer gates cross-boundary record homing on this tag"

      def named_attribute_keys = attrs.keys - IGNORED_RIDE_ALONG_KEYS

      private

      # System::Fleet::EventBroadcaster.emit! is best-effort by contract — it
      # swallows its own failures and returns nil, which is the right default
      # for liveness telemetry and the wrong one for a compliance mutation. A
      # residency change whose audit row did not persist is not an outcome
      # worth committing, so the nil is raised on and the enclosing transaction
      # takes the write back with it.
      def emit_audit_event!(peer, previous)
        event = ::System::Fleet::EventBroadcaster.emit!(
          account: peer.account,
          kind: EVENT_KIND,
          severity: "medium",
          source: "federation_peer",
          payload: {
            # federation_peer_id, NOT peer_id — the key every per-peer reader
            # matches on (System::FederationPeer#broadcast_peer_state! carries
            # the full note on why).
            federation_peer_id: peer.id,
            peer_kind: peer.peer_kind,
            status: peer.status,
            previous_data_residency: previous,
            data_residency: peer.data_residency,
            # The discriminator that separates the two writers of this event
            # kind. THIS side asserting where a remote peer's data lives is a
            # local compliance decision and is approval-gated; the heartbeat's
            # "remote_peer" is that peer declaring its own, ungated because an
            # inbound heartbeat has nowhere to park (the reasoning lives in
            # FederationApi::HeartbeatController#stamp_residency!). An auditor
            # reading the trail has to be able to tell them apart.
            declared_by: "local_decision",
            # BOTH principals, and the operation that authorised them. The
            # caller this gate exists to constrain is an agent — an MCP
            # instance principal carries no User at all — so recording only
            # requested_by would leave the audit row naming nobody for exactly
            # that caller. deferred_operation_id is what joins this peer-trail
            # row back to the approval that authorised it; without it the two
            # audit surfaces (the peer's trail and Ai::DeferredOperation) share
            # no key.
            changed_by_user_id: requesting_user&.id,
            changed_by_agent_id: deferred_operation&.ai_agent&.id,
            deferred_operation_id: deferred_operation&.id,
            action_category: ACTION_CATEGORY
          }
        )

        return event if event

        raise AuditEventNotRecorded,
              "data residency change for peer #{peer.id} left no audit event — refusing to commit an unaudited compliance write"
      end
    end
  end
end
