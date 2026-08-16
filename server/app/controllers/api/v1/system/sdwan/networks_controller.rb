# frozen_string_literal: true

# Operator-facing CRUD for Sdwan::Network. Mirrors the System::NodeInstancePeer
# controller's shape — set_account / require_permission / inline serializers.
#
# Slice 1 of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class NetworksController < ::Api::V1::System::BaseController
          include ::System::GatedActions

          before_action :set_account
          before_action :set_network, only: %i[show update destroy topology]

          def index
            require_permission("system.sdwan.networks.read")
            scope = ::Sdwan::Network.where(account_id: @account.id).includes(:peers).order(:name)
            scope = scope.where(status: params[:status]) if params[:status].present?
            networks = paginate(scope)
            render_success(networks: networks.map { |n| serialize_network(n) }, meta: pagination_meta)
          end

          def show
            require_permission("system.sdwan.networks.read")
            render_success(network: serialize_network_full(@network))
          end

          def create
            require_permission("system.sdwan.networks.manage")
            attrs = network_params

            network = ::Sdwan::Network.new(attrs.merge(account_id: @account.id))
            if network.save
              render_success({ network: serialize_network_full(network) }, status: :created)
            else
              render_validation_error(network)
            end
          end

          # IMP-c159cc6777b1: the update routes through Ai::AutonomyGate.
          # Sdwan::Executors::UpdateNetwork existed but had no caller, so the
          # seeded sdwan.network_update policy matched nothing — while DELETE
          # below has been gated since the destructive-ops slice. Flipping a
          # network's status / routing_protocol / advertise_overlay_subnet
          # rewrites BGP and AllowedIPs for every peer, so it is at least as
          # consequential as removing the network.
          #
          # Response contract mirrors DELETE: an operator carries no agent, and
          # (for accounts with no seeded operator rows) InterventionPolicyService
          # falls through to its require_approval default — 202, the change
          # applied only at approval time by the executor, since gate! never
          # calls on_proceed on its :pending branch. 200 with the row is the
          # :proceed branch.
          #
          # No re-parent anchor is needed here (unlike UpdatePortMapping):
          # Sdwan::Network is the top of the SDWAN tenancy tree — every child
          # points at it via sdwan_network_id and it carries no re-pointable
          # tenancy-bearing FK of its own. account_id is its only tenancy key —
          # Executors::Base#attrs strips it (so a mass-assigned account_id cannot
          # move the row) and resolve_scoped refuses any network_id outside the
          # operation's account.
          def update
            require_permission("system.sdwan.networks.manage")
            attrs = network_params.to_h
            # Validated before the gate so an unsaveable payload keeps its
            # field-level 422 and opens no audit row for an operation that could
            # never run. Never saved — UpdateNetwork's update! stays the only
            # writer, and it takes the account from the operation.
            @network.assign_attributes(attrs)
            return render_validation_error(@network) unless @network.valid?

            # Discard the un-gated in-memory changes: nothing may reach the row
            # except through the executor.
            @network.reload

            gate!(
              action_category: ::Sdwan::Executors::UpdateNetwork::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::UpdateNetwork",
              params: { network_id: @network.id, attributes: attrs },
              source_type: "Sdwan::Network",
              source_id: @network.id,
              description: "Update SDWAN network '#{@network.name}'",
              on_proceed: ->(_r) { render_success(network: serialize_network_full(@network.reload)) }
            )
          end

          def destroy
            require_permission("system.sdwan.networks.manage")
            id = @network.id
            name = @network.name
            gate!(
              action_category: ::Sdwan::Executors::DeleteNetwork::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::DeleteNetwork",
              params: { network_id: id },
              source_type: "Sdwan::Network",
              source_id: id,
              description: "Delete SDWAN network '#{name}'",
              on_proceed: ->(_r) { render_success(deleted: true, id: id) }
            )
          end

          # GET /api/v1/system/sdwan/networks/:id/topology
          # Returns the compiled per-peer view for every peer in the network.
          # Useful for operator visualization (slice 3) and external diagnostics.
          def topology
            require_permission("system.sdwan.peers.read")
            views = ::Sdwan::TopologyCompiler.compile_for_network(@network)
            render_success(
              network_id: @network.id,
              cidr_64: @network.cidr_64,
              peer_count: views.size,
              peers: views
            )
          end

          private

          def set_network
            @network = ::Sdwan::Network.where(account_id: @account.id).find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Network")
          end

          def network_params
            params.require(:network).permit(:name, :slug, :description, :status,
                                            # Slice 9a — per-network routing-layer knobs.
                                            :routing_protocol, :advertise_overlay_subnet,
                                            :route_reflector_redundancy,
                                            settings: {}, tags: [])
          end

          def serialize_network(n)
            {
              id: n.id,
              name: n.name,
              slug: n.slug,
              status: n.status,
              cidr_64: n.cidr_64,
              tags: n.tags,
              peer_count: n.peers.size,
              # Slice 9a — routing-layer summary.
              routing_protocol: n.routing_protocol,
              advertise_overlay_subnet: n.advertise_overlay_subnet,
              route_reflector_redundancy: n.route_reflector_redundancy,
              last_compiled_at: n.last_compiled_at&.iso8601,
              created_at: n.created_at.iso8601
            }
          end

          def serialize_network_full(n)
            serialize_network(n).merge(
              description: n.description,
              settings: n.settings,
              metadata: n.metadata,
              hub_count: n.peers.where(publicly_reachable: true).count,
              spoke_count: n.peers.where(publicly_reachable: false).count,
              advertised_prefix_count: n.subnet_advertisements.active.count
            )
          end
        end
      end
    end
  end
end
