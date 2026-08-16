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

          # IMP-d952c791e264 — was a hand-written copy of the model's
          # candidate-less guard, whose wording had already drifted from it.
          # Sdwan::VirtualIp#failover_blocker is now the one source, so this
          # path also refuses a standby that is no longer a live peer of the
          # VIP's network instead of reaching ::Sdwan::Peer.find inside
          # failover!'s transaction. Resolved AFTER the anycast branch above,
          # which is informational here (BGP re-converges on its own) rather
          # than a failure.
          blocker         = vip.failover_blocker
          previous_holder = Array(vip.holder_peer_ids).first

          # A dry run is a PREVIEW, and System::Fleet::DecisionEngine invokes
          # it for exactly one purpose: to stamp `skill_plan` on the approval
          # request it is about to park (skill_metadata_payload keys on
          # `skill_result[:data]`, which #failure does not carry). Answering
          # a blocked preview with #failure would therefore park a card that
          # says nothing at all — so the preview stays a preview and reports
          # the refusal IN the plan, the same shape the anycast branch above
          # already uses for "this VIP cannot fail over, here is why". What it
          # must NOT do is what it did before IMP-d952c791e264: name a
          # would_promote_peer_id pointing at a peer that cannot be promoted.
          if dry_run
            return success(
              resolved: false,
              dry_run: true,
              blocked: blocker.present?,
              note: blocker,
              virtual_ip_id: vip.id,
              cidr: vip.cidr,
              previous_holder_peer_id: previous_holder,
              would_promote_peer_id: blocker ? nil : vip.failover_target_peer_id
            )
          end

          return failure(blocker) if blocker

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
