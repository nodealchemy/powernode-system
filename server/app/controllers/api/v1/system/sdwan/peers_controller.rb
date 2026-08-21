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
          include ::System::GatedActions

          before_action :set_account
          before_action :set_network
          before_action :set_peer, only: %i[show update destroy]

          def index
            require_permission("system.sdwan.peers.read")
            peers = @network.peers.includes(:node_instance, :keys, :subnet_advertisements).order(:created_at)
            render_success(peers: peers.map { |p| serialize_peer(p) }, count: peers.size)
          end

          def show
            require_permission("system.sdwan.peers.read")
            render_success(peer: serialize_peer_full(@peer))
          end

          # IMP-cf285f21f3a9: routed through Ai::AutonomyGate. The seeded
          # sdwan.peer_create policy matched NO gate call site — this surface
          # and the MCP attach_peer twin both went straight to
          # Sdwan::PeerEnroller — so the operator's configured policy for
          # joining a node to an overlay was decorative on both. Attaching a
          # peer is a fabric-membership change at least as consequential as a
          # firewall rule, which has been gated since ac2a92d5.
          #
          # DELETE on this same controller has been gated (sdwan.peer_delete)
          # since slice 1, so until now a peer could be added without a policy
          # check and only removing it consulted one.
          #
          # Internal composition is deliberately NOT routed here: provisioning,
          # federation acceptance, storage auto-enroll and the compose skills
          # keep calling Sdwan::PeerEnroller directly. Gating those would put an
          # operator policy in the middle of automated provisioning.
          def create
            require_permission("system.sdwan.peers.manage")
            attrs = peer_params

            node_instance = ::System::NodeInstance.joins(:node)
                                                  .where(system_nodes: { account_id: @account.id })
                                                  .find(attrs[:node_instance_id])

            # Never saved — Sdwan::Executors::CreatePeer (via PeerEnroller)
            # stays the authority. gate_create! validates this candidate BEFORE
            # the gate so an unsaveable payload keeps its field-level 422 and
            # opens no audit row.
            candidate = @network.peers.new(account_id: @account.id)
            candidate.assign_attributes(enroll_attributes(attrs).merge(node_instance: node_instance))

            gate_create!(
              candidate: candidate,
              scope: @network.peers,
              result_key: :peer_id,
              response_key: :peer,
              serializer: ->(p) { serialize_peer_full(p) },
              action_category: ::Sdwan::Executors::CreatePeer::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::CreatePeer",
              params: { network_id: @network.id,
                        attributes: enroll_attributes(attrs).merge(node_instance_id: node_instance.id) },
              source_type: "Sdwan::Network",
              source_id: @network.id,
              # Matches Sdwan::Executors::CreatePeer#summarize so the request
              # and the approval card speak one sentence.
              description: "Add SDWAN peer #{::Sdwan::Peer.operator_label_for(
                node_instance: node_instance,
                network_name: @network.name,
                endpoint_display: nil,
                fallback: node_instance.id
              )}"
            )
          rescue ActiveRecord::RecordNotFound
            render_not_found("NodeInstance")
          rescue ActiveRecord::RecordInvalid => e
            render_validation_error(e.record)
          rescue ::Sdwan::PeerEnroller::CrossAccountError => e
            render_error(e.message, status: :unprocessable_content)
          end

          # IMP-c159cc6777b1: routes through Ai::AutonomyGate. Sdwan::Executors::
          # UpdatePeer existed and was tenancy-hardened but had no caller, so the
          # seeded sdwan.peer_update policy matched no gate call — while DELETE on
          # this same controller has been gated (sdwan.peer_delete) since slice 1.
          # Changing a peer's endpoint / lan_subnets / publicly_reachable rewrites
          # AllowedIPs and BGP for every session it participates in, so it is at
          # least as consequential as removing the peer.
          #
          # Response contract mirrors DELETE: an operator request carries no agent
          # and (for an account with no agent-less policy row) falls through
          # InterventionPolicyService to its require_approval default — 202, the
          # change applied only at approval time by the executor, which is the sole
          # writer since gate! never calls on_proceed on its :pending branch. 200
          # with the serialized row is the :proceed branch.
          def update
            require_permission("system.sdwan.peers.manage")
            attrs = peer_update_params.to_h
            # Validated before the gate so an unsaveable payload keeps its
            # field-level 422 and opens no audit row for an operation that could
            # never run. Never saved — UpdatePeer's update! stays the only writer.
            @peer.assign_attributes(attrs)
            return render_validation_error(@peer) unless @peer.valid?

            # Discard the un-gated in-memory changes: nothing may reach the row
            # except through the executor.
            @peer.reload

            gate!(
              action_category: ::Sdwan::Executors::UpdatePeer::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::UpdatePeer",
              params: { peer_id: @peer.id, attributes: attrs },
              source_type: "Sdwan::Peer",
              source_id: @peer.id,
              description: "Update SDWAN peer #{@peer.operator_label}",
              on_proceed: ->(_r) { render_success(peer: serialize_peer_full(@peer.reload)) }
            )
          end

          # Gated through Ai::AutonomyGate — sdwan.peer_delete defaults to
          # require_approval (see system_sdwan_manager_agent.rb). Operators
          # without auto-approve get 202 + a notification with inline approve;
          # the executor (Sdwan::Executors::DeletePeer) handles the destroy
          # when the chain completes.
          def destroy
            require_permission("system.sdwan.peers.manage")

            gate_result = ::Ai::AutonomyGate.evaluate(
              action_category: ::Sdwan::Executors::DeletePeer::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::DeletePeer",
              params: { peer_id: @peer.id, network_id: @network.id },
              account: current_account,
              requested_by: current_user,
              source_type: "Sdwan::Peer",
              source_id: @peer.id,
              # IMP-ee57d0fbe859: this is the string the APPROVALS LIST renders —
              # AutonomyGate copies it onto Ai::ApprovalRequest#description, which
              # both approval serializers emit. It read `@peer.try(:endpoint)`,
              # and Sdwan::Peer has no `endpoint` method or column, so the card
              # always degraded to the bare UUID. Same labeler as the executor's
              # summarize (the notification body) so the two cannot drift again.
              description: "Delete SDWAN peer #{@peer.operator_label}"
            )

            case gate_result.decision
            when :proceed
              render_success(deleted: true, id: @peer.id)
            when :pending
              render_pending_approval(gate_result.deferred_operation,
                                      message: "Approval required to delete peer")
            when :blocked
              render_error(gate_result.error || "Action blocked by policy",
                           status: :unprocessable_content)
            end
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

          # The subset Sdwan::PeerEnroller accepts, in the shape
          # Sdwan::Executors::CreatePeer replays. Kept to
          # CreatePeer::ENROLL_KEYS so the parked params and the executor agree;
          # `tags` is permitted by peer_params but deliberately omitted, because
          # the pre-gate create never passed it to the enroller either and
          # adding it here would be a silent behaviour change riding on a
          # gating task.
          def enroll_attributes(attrs)
            attrs.to_h.symbolize_keys
                 .slice(*::Sdwan::Executors::CreatePeer::ENROLL_KEYS)
                 .compact
          end

          def peer_params
            params.require(:peer).permit(:node_instance_id, :publicly_reachable,
                                         :endpoint_host, :endpoint_host_v6, :endpoint_host_v4,
                                         :endpoint_port,
                                         :listen_port,
                                         # Slice 9a — declarative external prefixes the peer can route to
                                         :bgp_route_reflector_client,
                                         lan_subnets: [],
                                         # D8 — firewall tag labels
                                         tags: [],
                                         capabilities: {})
          end

          # IMP-4ed94eef2971 — the literal list moved to Sdwan::Peer so the MCP
          # twin (Ai::Tools::SdwanTool#update_peer, gating the same category
          # through the same executor) cannot drift from it. The permitted SET
          # is unchanged; only its home moved.
          def peer_update_params
            params.require(:peer).permit(
              *::Sdwan::Peer::UPDATE_SCALAR_ATTRIBUTES,
              **::Sdwan::Peer::UPDATE_ARRAY_ATTRIBUTES.index_with { [] },
              **::Sdwan::Peer::UPDATE_HASH_ATTRIBUTES.index_with { {} }
            )
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
              effective_endpoint: primary && ::Sdwan::Peer.format_host_port(primary[:host], primary[:port]),
              effective_endpoint_family: primary && primary[:family].to_s,
              fallback_endpoint: fallback && "#{fallback[:host]}:#{fallback[:port]}",
              listen_port: p.listen_port,
              status: p.status,
              last_handshake_at: p.last_handshake_at&.iso8601,
              public_key: p.active_key&.public_key,
              # Slice 9a: routing-layer fields.
              lan_subnets: Array(p.lan_subnets),
              # D8: firewall tag labels.
              tags: Array(p.tags),
              bgp_route_reflector_client: p.bgp_route_reflector_client,
              bgp_router_id_override: p.bgp_router_id_override,
              advertised_prefix_count: p.subnet_advertisements.count(&:active?)
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
