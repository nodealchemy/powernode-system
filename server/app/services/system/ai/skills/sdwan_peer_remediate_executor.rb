# frozen_string_literal: true

# Skill executor for system.sdwan_peer_remediate. Invoked by the
# DecisionEngine when an SdwanDriftSensor signal proceeds through the
# notify_and_proceed gate.
#
# Remediation strategy (idempotent):
#   1. Rotate the peer's keypair via Sdwan::KeyDistributor.rotate! —
#      generates a new keypair, marks the old one revoked. The chain
#      is preserved via rotated_from_id for audit.
#   2. Touch peer.last_compiled_at so the next agent reconcile pulls
#      the new config (new pubkey, new private key) and re-applies
#      the wg interface. The agent re-establishes the tunnel from
#      scratch — new keys mean a fresh handshake.
#
# This is "reset-the-tunnel" remediation, not "fix-the-network." If the
# underlying NAT/ISP issue persists, the next tick will fire again and
# (after the dedup TTL) a new ApprovalRequest will be queued — which is
# the correct escalation.
#
# Slice 5.5 of the SDWAN plan.
module System
  module Ai
    module Skills
      class SdwanPeerRemediateExecutor
        def self.descriptor
          {
            name: "sdwan_peer_remediate",
            description: "Rotate an SDWAN peer's keypair and force the agent to re-establish its tunnel on next reconcile",
            category: "sdwan",
            inputs: {
              peer_id: { type: "string", required: true,
                         description: "Sdwan::Peer to remediate" },
              dry_run: { type: "boolean", required: false, default: false,
                         description: "Plan-only mode — return what would happen without rotating keys" }
            },
            outputs: {
              resolved: :boolean,
              rotated_from_key_id: :string,
              new_key_id: :string,
              new_public_key: :string
            }
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(peer_id:, dry_run: false)
          peer = ::Sdwan::Peer.joins(:network)
                              .where(sdwan_networks: { account_id: @account.id })
                              .find_by(id: peer_id)
          return failure("peer not found in account") unless peer

          previous = peer.active_key

          if dry_run
            return success(
              resolved: false,
              dry_run: true,
              would_rotate_from: previous&.id,
              would_rotate_from_pubkey: previous&.public_key,
              peer_address: peer.assigned_address
            )
          end

          new_key = ::Sdwan::KeyDistributor.rotate!(peer: peer, reason: "fleet_autonomy_remediation")

          # Force the next agent reconcile to refetch + reapply.
          peer.update_columns(last_compiled_at: nil, status: "pending", updated_at: Time.current)

          # Audit trail in FleetEvent.
          if defined?(::System::Fleet::EventBroadcaster)
            ::System::Fleet::EventBroadcaster.emit!(
              account: @account,
              kind: "system.sdwan.peer_remediated",
              severity: :medium,
              payload: {
                peer_id: peer.id,
                network_id: peer.sdwan_network_id,
                rotated_from_key_id: previous&.id,
                new_key_id: new_key&.id
              },
              source: "sdwan_remediate_executor",
              correlation_id: nil
            )
          end

          success(
            resolved: true,
            rotated_from_key_id: previous&.id,
            new_key_id: new_key&.id,
            new_public_key: new_key&.public_key,
            peer_address: peer.assigned_address
          )
        rescue StandardError => e
          Rails.logger.error("[SdwanPeerRemediateExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        private

        def success(payload)
          { success: true, data: payload }
        end

        def failure(error)
          { success: false, error: error.to_s }
        end
      end
    end
  end
end
