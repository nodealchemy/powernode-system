# frozen_string_literal: true

module Sdwan
  # IMP-2e7816b5ee95 — the ONE author of a governed, IN-PLACE rotation of an
  # SDWAN peer's WireGuard keypair, and of its audit row.
  #
  # Reached by system_sdwan_rotate_peer_key (SdwanTool) on its :proceed branch
  # and on the approved DeferredToolCall replay, under sdwan.peer_key_rotate.
  # Before it, Sdwan::KeyDistributor.rotate! had no operator or MCP caller:
  # rotating a compromised key meant detach + re-attach (a new peer id, a new
  # overlay address, the tunnel down) or a console runner.
  #
  # IN PLACE: the peer row is never rewritten. Its id, overlay address, network
  # and endpoints stay as they were; only its Sdwan::PeerKey rows change (the
  # active one revoked, a new one chained to it via rotated_from_id).
  #
  # KEY MATERIAL: the new private half is generated server-side and written
  # straight to Vault by KeyDistributor#generate_and_store!. Nothing here reads
  # it, returns it, logs it or audits it — the audit row and the event carry
  # PUBLIC-key fingerprints (PeerKey#public_key_fingerprint) and key ids.
  #
  # CONVERGENCE (what the verb's description tells the operator):
  #   * the peer's own agent reads its new private key on its next SDWAN
  #     reconcile — the node API compile inlines it
  #     (TopologyCompiler include_private_key: true), and the agent reconciles
  #     on every heartbeat tick;
  #   * every other peer picks up the new PUBLIC key on its own next pull;
  #   * until both ends have pulled, handshakes between them fail — the tunnel
  #     goes down and re-handshakes;
  #   * a publicly-reachable peer's key is also rendered into every user-device
  #     config, which is rendered once and never re-pulled, so those devices
  #     stop handshaking until re-issued (PeerKey's `touch: true` is what lets
  #     SdwanUserDeviceConfigStalenessSensor see the re-key).
  #
  # The membership credential names the WireGuard public key (wg_pubkey, and
  # the peer handle derives from it), and MembershipCredentialSigner.ensure_fresh!
  # keeps serving a still-fresh credential for up to its refresh window — so
  # without a re-issue here the next pull would hand out a signed envelope
  # naming the REVOKED key. It is re-issued after the rotation commits,
  # best-effort: a signer failure must not undo a rotation made because a key
  # is compromised (the signer emits its own sdwan.credential_refresh_failed).
  #
  # A refusal is a MESSAGE (nil means "would proceed"), like
  # System::UnitRestartService#refusal, so the gate context can ask without
  # writing, and the replay asks again through #rotate!.
  class PeerKeyRotationService
    class Refused < StandardError; end

    # The autonomy category the verb gates on. Owned HERE, not by an
    # Sdwan::Executors class: the replay is the generic DeferredToolCall, which
    # owns no category, and this service is the act the category governs. Any
    # further door onto this rotation (a REST twin) reads this constant, so the
    # doors cannot fork on a rename (action_category_coherence_spec).
    ACTION_CATEGORY = "sdwan.peer_key_rotate"

    AUDIT_ACTION = "system.sdwan.peer.rotate_key"
    AUDITED_ACTIONS = [ AUDIT_ACTION ].freeze

    EVENT_KIND = "system.sdwan.peer_key_rotated"

    REASON_MAX_LENGTH = 500

    # What KeyDistributor stamps on the revoked key row. A fixed token, not the
    # caller's text: the free-text reason belongs on the audit row.
    REVOCATION_REASON = "operator_rotation"

    Result = Struct.new(:peer, :previous_key, :new_key, :membership_credential_reissued, keyword_init: true)

    # nil when the rotation would proceed; else the refusal text, authored for
    # the caller. Read-only.
    def refusal(reason:)
      text = reason.to_s.strip
      return "reason is required: say why this peer's key is being rotated" if text.blank?

      "reason must be at most #{REASON_MAX_LENGTH} characters" if text.length > REASON_MAX_LENGTH
    end

    # Re-checks, then rotates and writes the audit row in ONE transaction: a
    # rotation whose audit cannot be written does not happen. The peer row is
    # locked first so two approved rotations of one peer serialise instead of
    # both revoking the same "active" key.
    def rotate!(peer:, reason:, initiated_by: nil, agent_id: nil, deferred_operation_id: nil, call_origin: nil)
      reason = reason.to_s.strip
      message = refusal(reason: reason)
      raise Refused, message if message

      previous = nil
      new_key = ::ActiveRecord::Base.transaction do
        peer.lock!
        previous = peer.active_key
        key = ::Sdwan::KeyDistributor.rotate!(peer: peer, reason: REVOCATION_REASON)
        write_audit!(peer: peer, previous: previous, new_key: key, reason: reason, initiated_by: initiated_by,
                     agent_id: agent_id, deferred_operation_id: deferred_operation_id, call_origin: call_origin)
        key
      end

      # KeyDistributor inserts the new row without going through peer.keys, so
      # a collection loaded before the rotation still answers the OLD key.
      peer.keys.reset
      reissued = reissue_membership_credential(peer)
      emit_event(peer: peer, previous: previous, new_key: new_key, reissued: reissued)

      Result.new(peer: peer, previous_key: previous, new_key: new_key, membership_credential_reissued: reissued)
    end

    private

    def write_audit!(peer:, previous:, new_key:, reason:, initiated_by:, agent_id:, deferred_operation_id:, call_origin:)
      ::AuditLog.create!(
        account: peer.account,
        user: initiated_by,
        action: AUDIT_ACTION,
        resource_type: "Sdwan::Peer",
        resource_id: peer.id.to_s,
        source: "system",
        metadata: {
          reason: reason,
          network_id: peer.sdwan_network_id,
          previous_key_id: previous&.id,
          previous_public_key_fingerprint: previous&.public_key_fingerprint,
          new_key_id: new_key.id,
          new_public_key_fingerprint: new_key.public_key_fingerprint,
          agent_id: agent_id,
          deferred_operation_id: deferred_operation_id,
          call_origin: call_origin
        }.compact
      )
    end

    def reissue_membership_credential(peer)
      ::Sdwan::MembershipCredentialSigner.issue!(peer: peer)
      true
    rescue StandardError => e
      # The class only: a signer failure message can carry Vault detail, and
      # the signer has already emitted sdwan.credential_refresh_failed.
      Rails.logger.warn(
        "[Sdwan::PeerKeyRotationService] rotated the key of peer #{peer.id} but could not re-issue its " \
        "membership credential (#{e.class}); the next compile keeps serving the previous one until its refresh window"
      )
      false
    end

    # After commit, and never allowed to turn a completed rotation into a
    # reported failure: the audit row is the record, this is the dashboard.
    def emit_event(peer:, previous:, new_key:, reissued:)
      ::System::Fleet::EventBroadcaster.emit!(
        account: peer.account,
        kind: EVENT_KIND,
        severity: :medium,
        payload: {
          peer_id: peer.id,
          network_id: peer.sdwan_network_id,
          previous_key_id: previous&.id,
          previous_public_key_fingerprint: previous&.public_key_fingerprint,
          new_key_id: new_key.id,
          new_public_key_fingerprint: new_key.public_key_fingerprint,
          membership_credential_reissued: reissued
        },
        source: "sdwan_peer_key_rotation",
        correlation_id: nil
      )
    rescue StandardError => e
      Rails.logger.warn("[Sdwan::PeerKeyRotationService] could not emit #{EVENT_KIND} for peer #{peer.id} (#{e.class})")
    end
  end
end
