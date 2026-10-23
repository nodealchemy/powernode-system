# frozen_string_literal: true

# Skill executor behind the system.sdwan_peer_drift lane: DIAGNOSIS ONLY.
#
# IMP-01a0ed52. This used to rotate the peer's WireGuard keypair
# (Sdwan::KeyDistributor.rotate!, which revokes the old key) whenever a drift
# signal cleared the notify_and_proceed gate of system.sdwan_peer_remediate. A
# handshake that merely went stale is no evidence the key is bad, and rotating
# a peer that has not polled yet drops a WORKING tunnel — a key-safety bug and
# an availability bug, with no person involved.
#
# It now only reports the plan (the key a rotation would revoke). The rotation
# is a governed act: the DecisionEngine files ONE approval request under
# sdwan.peer_key_rotate carrying this plan and the drift evidence, and on
# approval DecisionEngine#rotate_drifted_peer_key calls
# Sdwan::PeerKeyRotationService — the same path as system_sdwan_rotate_peer_key.
#
# SAFETY LIVES HERE, IN CODE, NOT IN A POLICY ROW. A system.sdwan_peer_remediate
# row seeded notify_and_proceed or auto_approve on a running install is not
# rewritten by a declaration change, so this executor refuses to rotate whatever
# any row says: outside dry_run it returns a failure and writes nothing.
#
# Results expose ids and PUBLIC keys only.
module System
  module Ai
    module Skills
      class SdwanPeerRemediateExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "sdwan_peer_remediate",
          description: "Diagnose a drifted SDWAN peer and report the key a rotation would revoke; never rotates a key (rotation is the approval-gated system_sdwan_rotate_peer_key)",
          category: "sdwan",
          inputs: {
            peer_id: { type: "string", required: true,
                       description: "Sdwan::Peer to diagnose" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan-only mode — the only mode; a non-dry run refuses and points at the governed rotation" }
          },
          outputs: {
            resolved: :boolean,
            would_rotate_from: :string,
            would_rotate_from_pubkey: :string
          }
        )

        binds_to "SDWAN Manager"

        protected

        def perform(peer_id:, dry_run: false)
          peer = ::Sdwan::Peer.joins(:network)
                              .where(system_sdwan_networks: { account_id: @account.id })
                              .find_by(id: peer_id)
          return failure("peer not found in account") unless peer

          unless dry_run
            return failure(
              "this skill never rotates a peer key: a rotation revokes the working key and drops the tunnel until " \
              "both ends re-pull, so it needs an approved sdwan.peer_key_rotate request " \
              "(system_sdwan_rotate_peer_key, or approve the request the drift lane filed)"
            )
          end

          previous = peer.active_key
          success(
            resolved: false,
            dry_run: true,
            would_rotate_from: previous&.id,
            would_rotate_from_pubkey: previous&.public_key,
            peer_address: peer.assigned_address
          )
        end
      end
    end
  end
end
