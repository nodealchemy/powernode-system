# frozen_string_literal: true

# Operator-facing CRUD + failover for Sdwan::VirtualIp. Slice 9b ships
# the static-mode lifecycle (single-holder + ordered failover candidates).
# Slice 9c lights up anycast mode by inviting FRR to advertise the same
# /32 from every holder simultaneously.
#
# Slice 9b of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class VirtualIpsController < ::Api::V1::System::BaseController
          include ::System::GatedActions

          before_action :set_account
          before_action :set_network
          before_action :set_vip, only: %i[show update destroy failover]

          def index
            require_permission("system.sdwan.vips.read")
            vips = @network.virtual_ips.order(:name)
            vips = vips.where(state: params[:state]) if params[:state].present?
            vips = vips.to_a
            @primary_holders = preload_primary_holders(vips)
            render_success(virtual_ips: vips.map { |v| serialize_vip(v) }, count: vips.size)
          end

          def show
            require_permission("system.sdwan.vips.read")
            render_success(virtual_ip: serialize_vip_full(@vip))
          end

          # IMP-6c482005db87: routed through Ai::AutonomyGate.
          # Sdwan::Executors::CreateVirtualIp existed, tenancy-hardened and
          # card-labeled, but had no caller — this wrote the VIP inline behind
          # the permission check, so the seeded sdwan.virtual_ip_create policy
          # matched nothing an operator did, while DELETE and failover below
          # have been gated since slice 9b.
          #
          # Same response contract as PortMappingsController#create
          # (IMP-bf996c7abcb4): validated before the gate so an unsaveable
          # payload keeps its field-level 422 and opens no audit row; 202 with
          # the deferred-operation id on :pending; 201 with the serialized row
          # on :proceed. The slice-9b create ceremony (activation + initial
          # assignment row) moved INTO the executor — gate! never calls
          # on_proceed on :pending, so ceremony left here would silently not
          # happen on every approved create.
          def create
            require_permission("system.sdwan.vips.manage")
            attrs = vip_params.to_h

            # Never saved — the executor's save! stays the authority. The
            # candidate mirrors the executor's build (including activation,
            # via the model's one activate_if_held symbol) so validation sees
            # exactly the row that would be written.
            candidate = @network.virtual_ips.new(attrs.merge(account_id: @account.id))
            candidate.activate_if_held
            return render_validation_error(candidate) unless candidate.valid?

            gate!(
              action_category: "sdwan.virtual_ip_create",
              executor_class: "Sdwan::Executors::CreateVirtualIp",
              # IMP-4a5094b22df0: account_id no longer rides along. It existed
              # ONLY to give the approval card an account to scope its network
              # label by, back when Base.preview ran with deferred_operation:
              # nil; the card now anchors on the operation's own account. The
              # `candidate` above still merges it, because that one is a
              # validation probe rather than gate-replayed params.
              params: { network_id: @network.id, attributes: attrs },
              source_type: "Sdwan::Network",
              source_id: @network.id,
              # Matches CreateVirtualIp#summarize so both surfaces of the
              # approval speak one sentence (IMP-3a563becb7d7).
              description: "Allocate SDWAN VIP '#{candidate.name}' on network #{@network.name}",
              on_proceed: lambda { |result|
                created = @network.virtual_ips.find(result.result&.dig(:data, :vip_id))
                render_success({ virtual_ip: serialize_vip_full(created) }, status: :created)
              }
            )
          end

          # IMP-0e44cf2fc80b: routed through Ai::AutonomyGate, matching the
          # gated update verbs (network/peer/route_policy/port_mapping). This
          # verb was NOT a clean drop-in wiring: the holder audit trail
          # (sync_assignments_after_holder_change!) ran inline here, and gate!
          # never calls on_proceed on :pending — the executor is the sole
          # writer there — so the sync migrated INTO UpdateVirtualIp#perform
          # first. Wiring it naively would have applied an operator-APPROVED
          # holder change while silently dropping the assignment sync.
          def update
            require_permission("system.sdwan.vips.manage")
            attrs = vip_params.to_h
            # Validated before the gate so an unsaveable payload keeps its
            # field-level 422 and opens no audit row. Never saved —
            # UpdateVirtualIp's update! stays the only writer.
            @vip.assign_attributes(attrs)
            return render_validation_error(@vip) unless @vip.valid?

            # Discard the un-gated in-memory changes: nothing may reach the row
            # except through the executor. restore_attributes is the zero-query
            # equivalent of reload here (ActiveModel::Dirty).
            @vip.restore_attributes

            gate!(
              action_category: "sdwan.virtual_ip_update",
              executor_class: "Sdwan::Executors::UpdateVirtualIp",
              params: { vip_id: @vip.id, attributes: attrs },
              source_type: "Sdwan::VirtualIp",
              source_id: @vip.id,
              description: "Update SDWAN VIP '#{@vip.name}' on network #{@network.name}",
              on_proceed: ->(_r) { render_success(virtual_ip: serialize_vip_full(@vip.reload)) }
            )
          end

          def destroy
            require_permission("system.sdwan.vips.manage")
            id = @vip.id
            address = @vip.try(:cidr)
            gate!(
              action_category: "sdwan.virtual_ip_delete",
              executor_class: "Sdwan::Executors::DeleteVirtualIp",
              params: { vip_id: id },
              source_type: "Sdwan::VirtualIp",
              source_id: id,
              description: "Delete VIP #{address || id}",
              on_proceed: ->(_r) {
                # Executor handled the destroy + assignment cleanup; double-check
                # any lingering assignments rows. Idempotent.
                ::Sdwan::VipAssignment
                  .where(virtual_ip_id: id, released_at: nil)
                  .update_all(released_at: Time.current, updated_at: Time.current)
                render_success(deleted: true, id: id)
              }
            )
          end

          # POST /virtual_ips/:id/failover — manual failover for non-anycast VIPs.
          def failover
            require_permission("system.sdwan.vips.manage")
            id = @vip.id
            gate!(
              action_category: "system.sdwan_vip_failover",
              executor_class: "Sdwan::Executors::FailoverVirtualIp",
              params: { vip_id: id, target_peer_id: params[:target_peer_id] },
              source_type: "Sdwan::VirtualIp",
              source_id: id,
              description: "Manual failover of VIP #{@vip.try(:cidr) || id}",
              on_proceed: ->(_r) { render_success(virtual_ip: serialize_vip_full(@vip.reload), failed_over: true) }
            )
          end

          private

          def set_network
            @network = ::Sdwan::Network.where(account_id: @account.id).find(params[:network_id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Network")
          end

          def set_vip
            @vip = @network.virtual_ips.find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Virtual IP")
          end

          def vip_params
            params.require(:virtual_ip).permit(
              :name, :cidr, :description, :anycast,
              :advertised_med, :advertised_local_pref, :state,
              tags: [], holder_peer_ids: [], failover_holder_peer_ids: [], metadata: {}
            )
          end

          # Resolve a VIP's primary holder from the per-request preloaded map
          # (index path) or fall back to the model lookup (single-record paths
          # where no map was built).
          def primary_holder_for(v)
            holder_id = Array(v.holder_peer_ids).first
            if @primary_holders
              @primary_holders[holder_id]
            else
              v.primary_holder
            end
          end

          # One batched Sdwan::Peer load for the whole page instead of a
          # per-VIP find_by inside VirtualIp#primary_holder.
          def preload_primary_holders(vips)
            ids = vips.filter_map { |v| Array(v.holder_peer_ids).first }.uniq
            return {} if ids.empty?

            ::Sdwan::Peer.where(id: ids).index_by(&:id)
          end

          def serialize_vip(v)
            primary = primary_holder_for(v)
            {
              id: v.id,
              network_id: v.sdwan_network_id,
              name: v.name,
              cidr: v.cidr,
              anycast: v.anycast?,
              state: v.state,
              holder_peer_ids: Array(v.holder_peer_ids),
              failover_holder_peer_ids: Array(v.failover_holder_peer_ids),
              primary_holder_peer_id: primary&.id,
              primary_holder_address: primary&.assigned_address,
              advertised_med: v.advertised_med,
              advertised_local_pref: v.advertised_local_pref,
              tags: Array(v.tags),
              created_at: v.created_at&.iso8601
            }
          end

          def serialize_vip_full(v)
            serialize_vip(v).merge(
              description: v.description,
              metadata: v.metadata,
              assignments: v.assignments.order(assumed_at: :desc).limit(20).map do |a|
                {
                  id: a.id,
                  peer_id: a.sdwan_peer_id,
                  assumed_at: a.assumed_at.iso8601,
                  released_at: a.released_at&.iso8601,
                  reason: a.reason,
                  triggered_by_user_id: a.triggered_by_user_id,
                  active: a.active?
                }
              end
            )
          end
        end
      end
    end
  end
end
