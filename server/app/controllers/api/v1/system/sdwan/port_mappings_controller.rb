# frozen_string_literal: true

# Operator-facing CRUD for Sdwan::PortMapping. Hub peers publish
# overlay services to v4-only clients via DNAT entries declared here.
# The compiler (Sdwan::NatCompiler) renders these to nft rules in
# the per-network sdwan_nat_<8> chain on the next agent reconcile.
#
# Slice 7b of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class PortMappingsController < ::Api::V1::System::BaseController
          include ::System::GatedActions

          before_action :set_account
          before_action :set_network
          before_action :set_mapping, only: %i[show update destroy]

          def index
            require_permission("system.sdwan.port_mappings.read")
            scope = @network.port_mappings
            scope = scope.where(sdwan_peer_id: params[:hub_peer_id]) if params[:hub_peer_id].present?
            scope = scope.where(enabled: ActiveModel::Type::Boolean.new.cast(params[:enabled])) if params.key?(:enabled)
            mappings = scope.order(:listen_port, :protocol)
            render_success(port_mappings: mappings.map { |m| serialize(m) }, count: mappings.size)
          end

          def show
            require_permission("system.sdwan.port_mappings.read")
            render_success(port_mapping: serialize_full(@mapping))
          end

          # IMP-bf996c7abcb4: both writes route through Ai::AutonomyGate.
          # Sdwan::Executors::{Create,Update}PortMapping existed and were
          # tenancy-hardened but had no caller, so the seeded
          # sdwan.port_mapping_{create,update} policies matched nothing — while
          # DELETE on this same controller has been gated since slice 7b.
          # Publishing a DNAT entry to a hub's underlay interface is at least as
          # consequential as removing one.
          #
          # Response contract: on the gate's :pending branch the answer is 202
          # (deferred operation id) and the row appears at approval time; the
          # executor — not this controller — performs the write, because gate!
          # never calls on_proceed on :pending. 201/200 with the serialized row
          # is the answer on :proceed.
          #
          # Which branch an operator gets is a per-account policy question.
          # gate! passes no `agent:`, so Ai::InterventionPolicy#agent_matches?
          # admits only agent-less rows. db/seeds/system_sdwan_manager_agent.rb
          # seeds the recorded per-verb table twice — agent-scoped for the SDWAN
          # Manager, agent-less for the operator path (IMP-187124ca2984) — so a
          # seeded account resolves sdwan.port_mapping_{create,update} to
          # notify_and_proceed and lands on :proceed. An account with no operator
          # policy for the category falls through InterventionPolicyService to
          # its require_approval default and gets 202, exactly like the DELETE
          # below. Either way the executor owns the write.
          def create
            require_permission("system.sdwan.port_mappings.manage")
            attrs = mapping_params.to_h
            # Validated before the gate so an unsaveable payload keeps its
            # field-level errors instead of the gate's generic refusal, and so
            # no audit row is opened for an operation that could never run.
            # Never saved — the executor's create! stays the authority.
            candidate = @network.port_mappings.new(attrs.merge(account_id: @account.id))
            return render_validation_error(candidate) unless candidate.valid?

            gate!(
              action_category: "sdwan.port_mapping_create",
              executor_class: "Sdwan::Executors::CreatePortMapping",
              params: { network_id: @network.id, attributes: attrs },
              source_type: "Sdwan::Network",
              source_id: @network.id,
              description: "Add SDWAN port mapping #{candidate.name} on #{@network.name}",
              on_proceed: lambda { |result|
                created = @network.port_mappings.find(result.result&.dig(:data, :mapping_id))
                render_success({ port_mapping: serialize_full(created) }, status: :created)
              }
            )
          end

          def update
            require_permission("system.sdwan.port_mappings.manage")
            attrs = mapping_params.to_h
            @mapping.assign_attributes(attrs)
            return render_validation_error(@mapping) unless @mapping.valid?

            # Discard the un-gated in-memory changes: nothing may reach the row
            # except through the executor.
            @mapping.reload

            gate!(
              action_category: "sdwan.port_mapping_update",
              executor_class: "Sdwan::Executors::UpdatePortMapping",
              params: { mapping_id: @mapping.id, attributes: attrs },
              source_type: "Sdwan::PortMapping",
              source_id: @mapping.id,
              description: "Update SDWAN port mapping #{@mapping.name} on #{@network.name}",
              on_proceed: ->(_r) { render_success(port_mapping: serialize_full(@mapping.reload)) }
            )
          end

          def destroy
            require_permission("system.sdwan.port_mappings.manage")
            id = @mapping.id
            gate!(
              action_category: "sdwan.port_mapping_delete",
              executor_class: "Sdwan::Executors::DeletePortMapping",
              params: { mapping_id: id },
              source_type: "Sdwan::PortMapping",
              source_id: id,
              description: "Delete port mapping #{id}",
              on_proceed: ->(_r) { render_success(deleted: true, id: id) }
            )
          end

          private

          def set_network
            @network = ::Sdwan::Network.where(account_id: @account.id).find(params[:network_id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Network")
          end

          def set_mapping
            @mapping = @network.port_mappings.find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Port Mapping")
          end

          def mapping_params
            params.require(:port_mapping).permit(
              :name, :description, :sdwan_peer_id, :target_peer_id, :target_virtual_ip_id,
              :listen_port, :target_port, :protocol, :enabled, metadata: {}
            )
          end

          def serialize(m)
            {
              id: m.id,
              network_id: m.sdwan_network_id,
              hub_peer_id: m.sdwan_peer_id,
              target_peer_id: m.target_peer_id,
              target_virtual_ip_id: m.target_virtual_ip_id,
              name: m.name,
              listen_port: m.listen_port,
              target_port: m.target_port,
              effective_target_port: m.effective_target_port,
              protocol: m.protocol,
              enabled: m.enabled,
              last_compiled_at: m.last_compiled_at&.iso8601,
              created_at: m.created_at&.iso8601
            }
          end

          def serialize_full(m)
            serialize(m).merge(
              description: m.description,
              metadata: m.metadata,
              resolved_target_address: m.resolved_target_address
            )
          end
        end
      end
    end
  end
end
