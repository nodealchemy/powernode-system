# frozen_string_literal: true

# Detects VIPs whose primary holder is unreachable. Two conditions
# trigger a signal:
#
#  1. The holder peer's last_handshake_at is older than the
#     DEGRADED_HANDSHAKE_WINDOW (5 min) — the WG tunnel to the holder
#     hasn't rekeyed, so packets to the VIP have nowhere to go.
#
#  2. (Future / when iBGP) The BGP route for the VIP CIDR is missing
#     from the local RIB despite the VIP being marked active.
#
# For non-anycast VIPs with failover candidates, the executor can
# auto-promote the next candidate (via VipFailoverExecutor). For anycast
# VIPs the failover happens at the BGP layer — we just emit a
# notification signal so operators know one of the holders went silent.
#
# Slice 9f of the SDWAN plan.
module System
  module Fleet
    module Sensors
      class SdwanVipReachabilitySensor < BaseSensor
        UNREACHABLE_WINDOW = 5.minutes

        def sense
          return [] unless defined?(::Sdwan::VirtualIp)

          ::Sdwan::VirtualIp
            .where(account_id: account.id, state: "active")
            .find_each.flat_map do |vip|
              holder_ids = Array(vip.holder_peer_ids)
              next [] if holder_ids.empty?

              # For each holder, check WG reachability. Signal once per
              # unreachable holder.
              ::Sdwan::Peer.where(id: holder_ids).map do |holder|
                next nil if holder.last_handshake_at.nil?
                next nil if holder.last_handshake_at >= UNREACHABLE_WINDOW.ago

                age = Time.current - holder.last_handshake_at
                signal(
                  kind: "system.sdwan_vip_unreachable",
                  severity: severity_for(age, vip.anycast?),
                  payload: {
                    virtual_ip_id: vip.id,
                    cidr: vip.cidr,
                    network_id: vip.sdwan_network_id,
                    anycast: vip.anycast?,
                    holder_peer_id: holder.id,
                    holder_handshake_age_seconds: age.to_i,
                    has_failover_candidates: vip.failover_holder_peer_ids.any?,
                    remediation_action: vip.anycast? ? nil : "system.sdwan_vip_failover"
                  },
                  # Anycast VIPs aren't dedup'd on the *holder* — every
                  # silent holder is a separate signal — but single-
                  # holder VIPs dedup on the VIP id (one failover
                  # decision per VIP).
                  fingerprint: vip.anycast? \
                    ? "sdwan_vip_holder_silent:#{vip.id}:#{holder.id}" \
                    : "sdwan_vip_unreachable:#{vip.id}"
                )
              end.compact
            end
        end

        private

        # Anycast VIPs degrade gracefully (other holders absorb the load),
        # so a single silent holder is medium severity; for single-holder
        # VIPs it's high — there's no fallback until failover fires.
        def severity_for(age_seconds, anycast)
          return :critical if age_seconds >= 30.minutes.to_i
          return :high     if !anycast && age_seconds >= 10.minutes.to_i
          :medium
        end
      end
    end
  end
end
