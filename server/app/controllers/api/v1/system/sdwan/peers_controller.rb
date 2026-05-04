# frozen_string_literal: true

# Operator-facing peer management nested under an Sdwan::Network. Create
# attaches a node-instance to the network (delegates to Sdwan::PeerEnroller);
# destroy removes it. Update is intentionally narrow — only endpoint
# host/port and publicly_reachable can change post-creation; the address
# itself is derived from peer.id and is therefore immutable.
#
# Slice 1 of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class PeersController < ::Api::V1::System::BaseController
          before_action :set_account
          before_action :set_network
          before_action :set_peer, only: %i[show update destroy]

          def index
            require_permission("sdwan.peers.read")
            peers = @network.peers.includes(:node_instance, :keys).order(:created_at)
            render_success(peers: peers.map { |p| serialize_peer(p) }, count: peers.size)
          end

          def show
            require_permission("sdwan.peers.read")
            render_success(peer: serialize_peer_full(@peer))
          end

          def create
            require_permission("sdwan.peers.manage")
            attrs = peer_params

            node_instance = ::System::NodeInstance.joins(:node)
                                                  .where(system_nodes: { account_id: @account.id })
                                                  .find(attrs[:node_instance_id])

            peer = ::Sdwan::PeerEnroller.call(
              network: @network,
              node_instance: node_instance,
              publicly_reachable: attrs[:publicly_reachable] || false,
              endpoint_host: attrs[:endpoint_host],
              endpoint_host_v6: attrs[:endpoint_host_v6],
              endpoint_host_v4: attrs[:endpoint_host_v4],
              endpoint_port: attrs[:endpoint_port],
              listen_port: attrs[:listen_port] || 51820,
              capabilities: attrs[:capabilities] || {},
              lan_subnets: Array(attrs[:lan_subnets]),
              bgp_route_reflector_client: attrs[:bgp_route_reflector_client] || false
            )

            render_success({ peer: serialize_peer_full(peer) }, status: :created)
          rescue ActiveRecord::RecordNotFound
            render_not_found("NodeInstance")
          rescue ActiveRecord::RecordInvalid => e
            render_validation_error(e.record)
          rescue ::Sdwan::PeerEnroller::CrossAccountError => e
            render_error(e.message, status: :unprocessable_entity)
          end

          def update
            require_permission("sdwan.peers.manage")
            if @peer.update(peer_update_params)
              render_success(peer: serialize_peer_full(@peer.reload))
            else
              render_validation_error(@peer)
            end
          end

          def destroy
            require_permission("sdwan.peers.manage")
            @peer.destroy!
            render_success(deleted: true, id: @peer.id)
          end

          private

          def set_network
            @network = ::Sdwan::Network.where(account_id: @account.id).find(params[:network_id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Network")
          end

          def set_peer
            @peer = @network.peers.find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Peer")
          end

          def peer_params
            params.require(:peer).permit(:node_instance_id, :publicly_reachable,
                                         :endpoint_host, :endpoint_host_v6, :endpoint_host_v4,
                                         :endpoint_port,
                                         :listen_port,
                                         # Slice 9a — declarative external prefixes the peer can route to
                                         :bgp_route_reflector_client,
                                         lan_subnets: [],
                                         capabilities: {})
          end

          def peer_update_params
            params.require(:peer).permit(:publicly_reachable, :endpoint_host,
                                         :endpoint_host_v6, :endpoint_host_v4,
                                         :endpoint_port, :listen_port,
                                         :bgp_route_reflector_client,
                                         lan_subnets: [],
                                         capabilities: {})
          end

          def serialize_peer(p)
            primary = p.primary_endpoint
            fallback = p.fallback_endpoint
            {
              id: p.id,
              network_id: p.sdwan_network_id,
              node_instance_id: p.node_instance_id,
              assigned_address: p.assigned_address,
              publicly_reachable: p.publicly_reachable,
              endpoint_host: p.endpoint_host,
              endpoint_host_v6: p.endpoint_host_v6,
              endpoint_host_v4: p.endpoint_host_v4,
              endpoint_port: p.endpoint_port,
              # Slice 7a: derived view of which endpoint the compiler will use
              # (primary) and which it ships as fallback to the agent.
              effective_endpoint: primary && "#{primary[:host]}:#{primary[:port]}",
              effective_endpoint_family: primary && primary[:family].to_s,
              fallback_endpoint: fallback && "#{fallback[:host]}:#{fallback[:port]}",
              listen_port: p.listen_port,
              status: p.status,
              last_handshake_at: p.last_handshake_at&.iso8601,
              public_key: p.active_key&.public_key,
              # Slice 9a: routing-layer fields.
              lan_subnets: Array(p.lan_subnets),
              bgp_route_reflector_client: p.bgp_route_reflector_client,
              bgp_router_id_override: p.bgp_router_id_override,
              advertised_prefix_count: p.subnet_advertisements.active.count
            }
          end

          def serialize_peer_full(p)
            serialize_peer(p).merge(
              capabilities: p.capabilities,
              metadata: p.metadata,
              created_at: p.created_at.iso8601,
              last_compiled_at: p.last_compiled_at&.iso8601
            )
          end
        end
      end
    end
  end
end
