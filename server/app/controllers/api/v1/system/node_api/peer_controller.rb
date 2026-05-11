# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Instance-side endpoints for peer announcement and remote task
        # execution. mTLS-authenticated via the node_api BaseController's
        # certificate pinning.
        #
        # Reference: comprehensive stabilization sweep P6.
        class PeerController < BaseController
          # POST /api/v1/system/node_api/peer/announce
          # Body: { capabilities: {...}, skills: [...], addresses: [...] }
          # Idempotent — subsequent announces update the existing peer.
          # Always responds 200 with the peer's current state (or 422 on
          # validation failure).
          def announce
            return render_unauthorized("Instance authentication required") unless current_node_instance

            result = ::System::AgentPeeringService.announce!(
              node_instance: current_node_instance,
              capabilities: params[:capabilities] || {},
              skills: params[:skills] || [],
              addresses: params[:addresses] || []
            )

            if result.success?
              render_success(
                peer: serialize_peer(result.peer),
                created: result.created
              )
            else
              render_error(result.error, status: :unprocessable_entity)
            end
          end

          # POST /api/v1/system/node_api/peer/execute_result
          # Reports the result of a previously-delegated remote task.
          # Used by the Go agent to close the loop on a task descriptor it
          # received via the local mTLS channel.
          def execute_result
            return render_unauthorized("Instance authentication required") unless current_node_instance

            peer = ::System::NodeInstancePeer.find_by(node_instance: current_node_instance)
            return render_not_found("Peer") unless peer

            success = ActiveModel::Type::Boolean.new.cast(params[:success])
            peer.record_execution!(success: success)

            render_success(
              peer: serialize_peer(peer.reload),
              recorded: true
            )
          end

          private

          def serialize_peer(peer)
            {
              id: peer.id,
              handle: peer.handle,
              status: peer.status,
              enabled: peer.enabled,
              capabilities: peer.capabilities,
              declared_skills: peer.declared_skills,
              addresses: peer.addresses,
              trust_score: peer.trust_score.to_f,
              daily_decision_budget: peer.daily_decision_budget,
              daily_decision_used: peer.daily_decision_used,
              execution_count: peer.execution_count,
              first_announced_at: peer.first_announced_at,
              last_announced_at: peer.last_announced_at,
              last_executed_at: peer.last_executed_at
            }
          end
        end
      end
    end
  end
end
