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
            require_permission("sdwan.vips.read")
            vips = @network.virtual_ips.order(:name)
            vips = vips.where(state: params[:state]) if params[:state].present?
            render_success(virtual_ips: vips.map { |v| serialize_vip(v) }, count: vips.size)
          end

          def show
            require_permission("sdwan.vips.read")
            render_success(virtual_ip: serialize_vip_full(@vip))
          end

          def create
            require_permission("sdwan.vips.manage")
            attrs = vip_params

            ::Sdwan::VirtualIp.transaction do
              vip = @network.virtual_ips.new(attrs.merge(account_id: @account.id))
              vip.state = "active" if Array(vip.holder_peer_ids).any?
              vip.save!

              # Slice 9b — initial assignment row for the primary holder
              # (or every holder if anycast). Builds the audit trail from
              # row 0 — no "phantom" current state without a history row.
              create_initial_assignments!(vip)
              render_success({ virtual_ip: serialize_vip_full(vip.reload) }, status: :created)
            end
          rescue ActiveRecord::RecordInvalid => e
            render_validation_error(e.record)
          end

          def update
            require_permission("sdwan.vips.manage")
            ::Sdwan::VirtualIp.transaction do
              previous_holders = Array(@vip.holder_peer_ids).dup
              if @vip.update(vip_params)
                sync_assignments_after_holder_change!(@vip, previous_holders)
                render_success(virtual_ip: serialize_vip_full(@vip.reload))
              else
                render_validation_error(@vip)
              end
            end
          end

          def destroy
            require_permission("sdwan.vips.manage")
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
            require_permission("sdwan.vips.manage")
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

          def create_initial_assignments!(vip)
            holders = vip.anycast? ? Array(vip.holder_peer_ids) : Array(vip.holder_peer_ids).first(1)
            holders.compact.each do |peer_id|
              vip.assignments.create!(
                peer: ::Sdwan::Peer.find(peer_id),
                assumed_at: Time.current,
                reason: "initial",
                triggered_by_user_id: current_user&.id
              )
            end
          end

          # When holder_peer_ids changes via update, close out assignments
          # for departed holders and open new ones for newcomers. Reason is
          # "holder_changed" — distinct from "manual_failover" to keep the
          # audit trail honest about what action was taken.
          def sync_assignments_after_holder_change!(vip, previous_holders)
            current = vip.anycast? ? Array(vip.holder_peer_ids) : Array(vip.holder_peer_ids).first(1)
            current = current.compact

            departed = previous_holders - current
            arrived  = current - previous_holders
            return if departed.empty? && arrived.empty?

            now = Time.current
            departed.each do |peer_id|
              vip.assignments.where(sdwan_peer_id: peer_id, released_at: nil)
                 .update_all(released_at: now, updated_at: now)
            end
            arrived.each do |peer_id|
              vip.assignments.create!(
                peer: ::Sdwan::Peer.find(peer_id),
                assumed_at: now,
                reason: "holder_changed",
                triggered_by_user_id: current_user&.id
              )
            end
          end

          def serialize_vip(v)
            primary = v.primary_holder
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
