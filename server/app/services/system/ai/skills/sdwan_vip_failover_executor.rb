# frozen_string_literal: true

# Skill executor for system.sdwan_vip_failover. Invoked when
# SdwanVipReachabilitySensor flags a VIP whose primary holder has gone
# silent (last_handshake_at exceeded the unreachable window).
#
# Single-holder VIPs with `failover_holder_peer_ids` get auto-failover
# (low blast radius — the next candidate just promotes to head). Anycast
# VIPs are *informational* — the BGP layer handles re-convergence
# automatically; we just notify operators that one of the holders is
# silent so they can investigate.
#
# Idempotent: re-running with the same VIP that has already failed over
# returns success without re-firing. The VIP's failover! method itself
# is transactional and resists concurrent invocations.
#
# Slice 9f of the SDWAN plan.
module System
  module Ai
    module Skills
      class SdwanVipFailoverExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "sdwan_vip_failover",
          description: "Promote the next failover candidate of a silent-holder Sdwan::VirtualIp. Anycast VIPs return informational only.",
          category: "sdwan",
          inputs: {
            virtual_ip_id: { type: "string", required: true },
            dry_run:       { type: "boolean", required: false, default: false }
          },
          outputs: {
            resolved: :boolean,
            virtual_ip_id: :string,
            previous_holder_peer_id: :string,
            new_holder_peer_id: :string,
            anycast: :boolean
          }
        )

        binds_to "SDWAN Manager"

        protected

        def perform(virtual_ip_id:, dry_run: false)
          vip = ::Sdwan::VirtualIp.where(account_id: @account.id).find_by(id: virtual_ip_id)
          return failure("VIP not found in account scope") unless vip

          if vip.anycast?
            return success(
              resolved: false,
              note: "anycast VIP — failover handled by BGP withdrawal. No action taken.",
              virtual_ip_id: vip.id,
              cidr: vip.cidr,
              anycast: true,
              holder_count: Array(vip.holder_peer_ids).size
            )
          end

          if Array(vip.failover_holder_peer_ids).empty?
            return failure("VIP has no failover candidates configured. Edit the VIP and add at least one peer to failover_holder_peer_ids.")
          end

          previous_holder = Array(vip.holder_peer_ids).first

          if dry_run
            next_candidate = Array(vip.failover_holder_peer_ids).first
            return success(
              resolved: false,
              dry_run: true,
              virtual_ip_id: vip.id,
              cidr: vip.cidr,
              previous_holder_peer_id: previous_holder,
              would_promote_peer_id: next_candidate
            )
          end

          begin
            vip.failover!(reason: "sensor_failover", triggered_by_user: @user)
          rescue ::Sdwan::VirtualIp::StateError => e
            return failure(e.message)
          end
          vip.reload

          success(
            resolved: true,
            virtual_ip_id: vip.id,
            cidr: vip.cidr,
            previous_holder_peer_id: previous_holder,
            new_holder_peer_id: Array(vip.holder_peer_ids).first,
            anycast: false
          )
        end
      end
    end
  end
end
