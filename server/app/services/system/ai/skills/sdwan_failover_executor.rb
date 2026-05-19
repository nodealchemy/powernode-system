# frozen_string_literal: true

# Skill executor for system.sdwan_failover. Invoked AFTER an operator
# approves the ApprovalRequest queued by the SdwanReachabilitySensor.
#
# v1 strategy (planning-only — auto-promote NOT enabled):
#   1. Find candidate spoke peers in the network that have a public
#      endpoint on file (i.e., could be promoted to hub).
#   2. Return a plan listing the candidates with their last_handshake_at
#      so the operator can pick which spoke to promote.
#   3. The actual promotion (flipping publicly_reachable) is a manual
#      operator action — too risky to auto-flip in v1, since promoting
#      the wrong spoke would route all traffic through a node that
#      operators didn't intend to expose.
#
# Slice 5.5 ships the planning side; slice 6+ may add an `auto: true`
# parameter that performs the flip if exactly one candidate exists AND
# the original hub has been unreachable for >2x the reachability window.
#
# Slice 5.5 of the SDWAN plan.
module System
  module Ai
    module Skills
      class SdwanFailoverExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "sdwan_failover",
          description: "Plan an SDWAN hub failover for an unreachable network; identifies promotion candidates without auto-flipping",
          category: "sdwan",
          inputs: {
            network_id: { type: "string", required: true },
            dry_run: { type: "boolean", required: false, default: true,
                       description: "v1 only supports dry_run=true — auto-promotion deferred" }
          },
          outputs: {
            resolved: :boolean,
            network_id: :string,
            current_hub_count: :integer,
            candidates: { peer_id: :string, endpoint_host: :string, endpoint_port: :integer, last_handshake_at: :string }
          }
        )

        binds_to "SDWAN Manager"

        protected

        def perform(network_id:, dry_run: true)
          network = ::Sdwan::Network.where(account_id: @account.id).find_by(id: network_id)
          return failure("network not found in account") unless network

          # Promotion candidates: spokes that have endpoint info pre-configured
          # (operator already supplied host/port even though publicly_reachable
          # is false). These can be promoted without any further input.
          candidates = network.peers.where(publicly_reachable: false)
                                    .where.not(endpoint_host: nil)
                                    .where.not(endpoint_port: nil)
                                    .order(last_handshake_at: :desc)

          candidate_payload = candidates.map do |c|
            {
              peer_id: c.id,
              node_instance_id: c.node_instance_id,
              endpoint_host: c.endpoint_host,
              endpoint_port: c.endpoint_port,
              last_handshake_at: c.last_handshake_at&.utc&.iso8601
            }
          end

          unless dry_run
            return failure("auto-promotion not implemented in v1; pass dry_run: true and have an operator manually flip publicly_reachable")
          end

          success(
            resolved: false, # planning only — operator must act
            requires_operator_action: true,
            network_id: network.id,
            current_hub_count: network.peers.where(publicly_reachable: true).count,
            candidate_count: candidate_payload.size,
            candidates: candidate_payload,
            note: "Operator must promote the chosen candidate by PATCHing /sdwan/networks/<id>/peers/<peer_id> with publicly_reachable=true."
          )
        end
      end
    end
  end
end
