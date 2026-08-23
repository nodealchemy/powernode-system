# frozen_string_literal: true

# Operator-facing API for Sdwan::HostBridge. #index and #show inspect rows,
# #create allocates one, #activate makes it visible to the topology compiler,
# and #destroy releases it.
#
# Allocation itself always happens through Sdwan::HostBridgeAllocator (the
# source-of-truth atomic allocator), which is also invoked by the on-node
# agent during reconcile and by the SdwanHostBridgeComposeExecutor AI skill
# for batch composition.
#
# IMP-53a5c597ec8c changed three things here.
#
# #create and #activate are NEW. Both verbs existed only on the AI surfaces,
# so a console operator could see bridges and delete them but could neither
# stand one up nor make one take effect — and `activate` is not bookkeeping:
# `compilable` emits active|draining only, so a bridge left in `pending` is
# INVISIBLE to the compiler and does nothing on the node. This is
# API-surface parity, not yet an operator-experience fix: no console form
# posts to either route yet.
#
# #destroy is now GATED, and its FORCE DEFAULT CHANGED. That is the residual
# IMP-97c7b4123d8f recorded when it gated the MCP half of this family
# (db/seeds/system_sdwan_manager_agent.rb) and assigned to "the per-family
# parity tasks that own those controllers" — this is that task. Both halves
# matter:
#
#   * GATED. Leaving the write inline made the whole regime decorative: an
#     operator who hardens sdwan.host_bridge_delete to require_approval got
#     no protection at all, because the same JWT carrying
#     system.sdwan.host_bridges.manage performed the identical release one
#     route over, outside Ai::AutonomyGate. A gate a caller can walk around
#     is not a gate. The console already speaks the gated shape —
#     sdwanApi.deleteHostBridge returns Gated<Deleted> through extractGated
#     — so this costs the operator UI nothing.
#
#   * DRAIN BY DEFAULT. This route used to call release!(force: true)
#     unconditionally while its MCP twin defaulted to draining, so an
#     operator delete SKIPPED a grace window an agent release honored. A
#     bare DELETE now drains. The hard release stays reachable as an
#     explicit opt-in (?force=true or {"force": true}), and the flag rides
#     into the parked operation so an approver sees which one they are
#     authorizing. The default, its coercion and the reasoning live on
#     Sdwan::Executors::ReleaseHostBridge — one declaration site, every
#     surface.
#
# Response contract for the gated verbs, the same one every gated SDWAN
# write carries: on :proceed the answer is the success body (201 for
# #create, 200 for #activate/#destroy); on :pending it is 202 with a
# deferred_operation_id and nothing is written, because gate! never calls
# on_proceed on :pending. Which branch an operator gets is a per-account
# policy question — gate! passes no `agent:`, and
# db/seeds/system_sdwan_manager_agent.rb seeds the per-verb table onto
# agent-less rows too (IMP-187124ca2984), so a seeded account resolves
# host_bridge_create/update to notify_and_proceed and host_bridge_delete to
# require_approval.
#
# Phase O6 of the OVS+OVN dual-profile networking roadmap.
module Api
  module V1
    module System
      module Sdwan
        class HostBridgesController < ::Api::V1::System::BaseController
          include ::System::GatedActions

          before_action :set_account
          before_action :set_bridge, only: %i[show activate destroy]

          def index
            require_permission("system.sdwan.host_bridges.read")

            scope = ::Sdwan::HostBridge
                      .where(account_id: @account.id)
                      .includes(:node_instance)

            scope = scope.where(node_instance_id: params[:node_instance_id]) if params[:node_instance_id].present?
            scope = scope.where(state: params[:state])                        if params[:state].present?
            scope = scope.where(kind:  params[:kind])                         if params[:kind].present?

            bridges = scope.order(:node_instance_id, :short_id).to_a

            render_success(
              host_bridges: bridges.map { |b| serialize_bridge(b) },
              count: bridges.size,
              filters: {
                node_instance_id: params[:node_instance_id],
                state: params[:state],
                kind:  params[:kind]
              }.compact
            )
          end

          def show
            require_permission("system.sdwan.host_bridges.read")
            render_success(host_bridge: serialize_bridge_full(@bridge))
          end

          # Gated through Sdwan::Executors::CreateHostBridge, the executor the
          # MCP twin already uses. gate_create! is the WRONG helper here: it
          # needs a caller-built unsaved candidate to validate, and a
          # HostBridge cannot be built without the short_id the allocator
          # mints under a per-host row lock — so there is no candidate to
          # validate that the executor would not immediately discard. What a
          # caller CAN be checked on (a host in this account, a kind the model
          # accepts) is checked first, and the allocation goes through a bare
          # gate!.
          #
          # `kind` is deliberately left nil-able rather than defaulted here:
          # the allocator resolves it from the host's network_profile
          # (heavyweight → ovs, lightweight → linux), and duplicating that
          # mapping in the controller is exactly how two surfaces start
          # answering one payload differently.
          def create
            require_permission("system.sdwan.host_bridges.manage")

            host = host_in_account(params[:node_instance_id])
            return render_not_found("Node Instance") unless host

            kind = params[:kind].presence
            if kind && !::Sdwan::HostBridge::KINDS.include?(kind.to_s)
              return render_error("kind must be one of #{::Sdwan::HostBridge::KINDS.join(', ')}",
                                  status: :unprocessable_content)
            end

            gate!(
              action_category: ::Sdwan::Executors::CreateHostBridge::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::CreateHostBridge",
              params: { node_instance_id: host.id, kind: kind },
              source_type: "System::NodeInstance",
              source_id: host.id,
              description: "Allocate SDWAN host bridge on #{host.name.presence || host.id}",
              on_proceed: lambda { |result|
                bridge = ::Sdwan::HostBridge.where(account_id: @account.id)
                                            .find(result.result&.dig(:data, :host_bridge_id))
                render_success({ host_bridge: serialize_bridge_full(bridge) }, status: :created)
              }
            )
          end

          # Shaped on IpfixCollectorsController#update and
          # VirtualIpsController#failover, the family's other gated state
          # transitions: refuse an impossible request FIRST, then hand the
          # transition itself to the executor through a bare gate!.
          # gate_update! is the wrong helper — it exists to
          # assign-validate-reload caller ATTRIBUTES, and this fires an AASM
          # event.
          #
          # Refusing before the gate is the contract the MCP twin keeps: an
          # impossible request must fail now, not sit in an operator's queue
          # until they approve it and watch it fail. `may_mark_active?` reads
          # the state machine without writing, and the refusal wording is
          # shared verbatim with Ai::Tools::SdwanTool#activate_host_bridge so
          # the two surfaces naming one operation cannot disagree.
          def activate
            require_permission("system.sdwan.host_bridges.manage")

            unless @bridge.may_mark_active?
              hint = @bridge.state == "removed" ? " — use readopt to revive a removed bridge" : ""
              return render_error("cannot activate a #{@bridge.state} host bridge#{hint}",
                                  status: :unprocessable_content)
            end

            gate!(
              action_category: ::Sdwan::Executors::ActivateHostBridge::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::ActivateHostBridge",
              params: { host_bridge_id: @bridge.id },
              source_type: "Sdwan::HostBridge",
              source_id: @bridge.id,
              description: "Activate SDWAN host bridge #{@bridge.bridge_name.presence || @bridge.id}",
              on_proceed: ->(_r) { render_success(host_bridge: serialize_bridge_full(@bridge.reload)) }
            )
          end

          # DRAINS by default; force is an explicit opt-in. See the class
          # comment — this is a deliberate change to what a bare DELETE does
          # on this route, and `forced` is echoed in the success body so a
          # caller can see which arm ran rather than inferring it.
          def destroy
            require_permission("system.sdwan.host_bridges.manage")

            forced = ::Sdwan::Executors::ReleaseHostBridge.force?(params[:force])

            gate!(
              action_category: ::Sdwan::Executors::ReleaseHostBridge::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::ReleaseHostBridge",
              params: { host_bridge_id: @bridge.id, force: forced },
              source_type: "Sdwan::HostBridge",
              source_id: @bridge.id,
              description: "Release SDWAN host bridge #{@bridge.bridge_name.presence || @bridge.id}" \
                           "#{forced ? ' (forced)' : ''}",
              on_proceed: lambda { |_r|
                render_success(deleted: true, id: @bridge.id, forced: forced,
                               host_bridge: serialize_bridge_full(@bridge.reload))
              }
            )
          end

          private

          def set_bridge
            @bridge = ::Sdwan::HostBridge.where(account_id: @account.id)
                                         .includes(:node_instance)
                                         .find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Host Bridge")
          end

          # Scoped the way Ai::Tools::SdwanTool#create_host_bridge and the
          # compose skill both scope it — through the instance's NODE. The
          # instance carries its own account_id too, so this join is a
          # consistency choice rather than the only route: every surface that
          # resolves a host for a bridge asks the same question the same way,
          # and a divergence between them is exactly the class of bug this
          # task exists to remove. Returns nil rather than raising so #create
          # can answer 404 without opening a deferred operation for a host the
          # caller cannot reach.
          def host_in_account(id)
            return nil if id.blank?

            ::System::NodeInstance.joins(:node)
                                  .where(system_nodes: { account_id: @account.id })
                                  .find_by(id: id)
          end

          def serialize_bridge(b)
            instance = b.node_instance
            {
              id: b.id,
              node_instance_id: b.node_instance_id,
              node_instance_name: instance&.name,
              network_profile: instance&.network_profile,
              short_id: b.short_id,
              bridge_name: b.bridge_name,
              kind: b.kind,
              state: b.state
            }
          end

          def serialize_bridge_full(b)
            serialize_bridge(b).merge(
              applied_at:  b.applied_at&.iso8601,
              draining_at: b.draining_at&.iso8601,
              removed_at:  b.removed_at&.iso8601,
              created_at:  b.created_at.iso8601,
              updated_at:  b.updated_at.iso8601
            )
          end
        end
      end
    end
  end
end
