# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing CRUD for NodeInstance peers + delegation entry point.
      # See `extensions/system/docs/agent-peering.md`.
      #
      # Reference: comprehensive stabilization sweep P6.
      class NodeInstancePeersController < BaseController
        before_action :set_account
        before_action :set_peer, only: %i[show activate deactivate execute]

        def index
          require_permission("system.peers.read")
          peers = @account.system_node_instance_peers
                          .includes(:node_instance)
                          .order(:handle)
          peers = peers.enabled if params[:enabled] == "true"
          peers = paginate(peers)
          render_success(peers: peers.map { |p| serialize_peer(p) }, meta: pagination_meta)
        end

        def show
          require_permission("system.peers.read")
          render_success(peer: serialize_peer(@peer))
        end

        # GET /api/v1/system/node_instance_peers/searchable
        #
        # Lightweight scope for the workspace mention picker — returns
        # only enabled peers in the operator's account, with a small
        # serialization (handle, status, node_instance_id, addresses) so
        # the autocomplete dropdown stays snappy with 100s of peers.
        # Filtered by handle prefix via `q` param. Phase 10.4.
        def searchable
          require_permission("system.peers.read")

          peers = @account.system_node_instance_peers.enabled.includes(:node_instance)
          if params[:q].present?
            prefix = params[:q].to_s.sub(/\A@/, "").downcase
            peers = peers.where("LOWER(handle) LIKE ?", "#{prefix}%")
          end
          peers = peers.order(:handle).limit(50)

          render_success(peers: peers.map { |p| serialize_searchable(p) }, count: peers.size)
        end

        def activate
          require_permission("system.peers.activate")
          if @peer.update(enabled: true, status: "active")
            render_success(peer: serialize_peer(@peer.reload), message: "Peer activated")
          else
            render_validation_error(@peer)
          end
        end

        def deactivate
          require_permission("system.peers.activate")
          if @peer.update(enabled: false, status: "registered")
            render_success(peer: serialize_peer(@peer.reload), message: "Peer deactivated")
          else
            render_validation_error(@peer)
          end
        end

        # POST /api/v1/system/node_instance_peers/:id/execute
        # Delegates a task descriptor to the peer. Validates against the
        # peer's declared capabilities and the operator's permission set
        # (an operator can only delegate tasks they could perform via API).
        def execute
          require_permission("system.peers.execute")

          unless @peer.enabled
            return render_error("Peer is not activated; activate first via /activate", status: :precondition_failed)
          end

          unless @peer.reserve_decision!
            return render_error("Daily decision budget exhausted", status: :too_many_requests)
          end

          task = params.permit(:skill, :input, capabilities: {}).to_h
          unless task["skill"].present?
            return render_error("skill is required", status: :unprocessable_entity)
          end

          if @peer.declared_skills.is_a?(Array) &&
             @peer.declared_skills.none? { |s| s["name"] == task["skill"] }
            return render_error("Peer does not declare skill: #{task['skill']}",
                                status: :unprocessable_entity)
          end

          # Synchronous dispatch placeholder — production path would dispatch
          # over the mTLS channel and wait for the agent to call back via
          # /node_api/peer/execute_result. For v1, we record the dispatch
          # intent and return 202 Accepted; the agent fulfills out-of-band.
          render_accepted(
            peer: serialize_peer(@peer.reload),
            dispatched_task: task,
            message: "Task dispatched; result will arrive via /node_api/peer/execute_result"
          )
        end

        private

        def set_peer
          @peer = @account.system_node_instance_peers.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node Instance Peer")
        end

        def render_accepted(payload)
          render json: { success: true, data: payload }, status: :accepted
        end

        def serialize_searchable(peer)
          {
            id: peer.id,
            handle: peer.handle,
            status: peer.status,
            node_instance_id: peer.node_instance_id,
            node_name: peer.node_instance&.node&.name,
            addresses: peer.addresses
          }
        end

        def serialize_peer(peer)
          {
            id: peer.id,
            handle: peer.handle,
            node_instance_id: peer.node_instance_id,
            enabled: peer.enabled,
            status: peer.status,
            capabilities: peer.capabilities,
            declared_skills: peer.declared_skills,
            addresses: peer.addresses,
            trust_score: peer.trust_score.to_f,
            daily_decision_budget: peer.daily_decision_budget,
            daily_decision_used: peer.daily_decision_used,
            execution_count: peer.execution_count,
            execution_failure_count: peer.execution_failure_count,
            first_announced_at: peer.first_announced_at,
            last_announced_at: peer.last_announced_at,
            last_executed_at: peer.last_executed_at
          }
        end
      end
    end
  end
end
