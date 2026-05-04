# frozen_string_literal: true

# Skill executor for system.sdwan_bgp_session_remediate. Invoked when
# SdwanBgpSessionHealthSensor flags an iBGP session that has been stuck
# in non-established state for too long.
#
# v1 strategy (PLANNING-ONLY — no auto-restart of FRR):
#   1. Locate the BgpSession and surrounding context (local peer, network,
#      neighbor address, last_error).
#   2. Compute a triage payload: likely cause, recommended next step,
#      and whether the operator should attempt a clear-and-restart
#      via the agent's vtysh `clear ip bgp <neighbor> soft` path.
#   3. Return the plan; the actual `systemctl restart frr` happens
#      out-of-band (operator runs it through the node SSH or agent
#      command channel — slice 9f.1 will add an in-band restart action).
#
# This planning-first stance matches SdwanFailoverExecutor: blast radius
# of "restart FRR on a hub" is high (every other peer's session goes idle
# for the duration). Auto-restart needs a dedup-cool-down sensor + human
# trust accumulation; both deferred.
#
# Slice 9f of the SDWAN plan.
module System
  module Ai
    module Skills
      class SdwanBgpSessionRemediateExecutor
        def self.descriptor
          {
            name: "sdwan_bgp_session_remediate",
            description: "Triage an unhealthy iBGP session; returns a plan with likely cause + recommended next step. v1 does NOT auto-restart FRR.",
            category: "sdwan",
            inputs: {
              bgp_session_id: { type: "string", required: false },
              peer_id:        { type: "string", required: false,
                                description: "Local peer (resolves session via peer_id + neighbor_address)" },
              neighbor_address: { type: "string", required: false },
              dry_run:        { type: "boolean", required: false, default: true }
            },
            outputs: {
              resolved: :boolean,
              session_id: :string,
              state: :string,
              likely_cause: :string,
              recommended_action: :string
            }
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(bgp_session_id: nil, peer_id: nil, neighbor_address: nil, dry_run: true)
          session = locate_session(bgp_session_id, peer_id, neighbor_address)
          return failure("BGP session not found in account scope") unless session

          unless dry_run
            return failure("auto-restart of FRR not implemented in v1; pass dry_run: true. " \
                           "Manual remediation: ssh into peer, `vtysh -c \"clear ip bgp #{session.neighbor_address}\"` " \
                           "or `systemctl restart frr` if soft-clear doesn't resolve.")
          end

          analysis = analyze(session)
          success(
            resolved: false,
            requires_operator_action: true,
            session_id: session.id,
            peer_id: session.sdwan_peer_id,
            network_id: session.sdwan_network_id,
            neighbor_address: session.neighbor_address,
            state: session.state,
            stuck_for_seconds: stuck_for(session),
            last_error: session.last_error,
            likely_cause: analysis[:cause],
            recommended_action: analysis[:action],
            recommended_command: analysis[:command]
          )
        rescue StandardError => e
          Rails.logger.error("[SdwanBgpSessionRemediateExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        private

        def locate_session(id, peer_id, neighbor_address)
          if id.present?
            return ::Sdwan::BgpSession
                     .joins(:network)
                     .where(sdwan_networks: { account_id: @account.id })
                     .find_by(id: id)
          end
          return nil if peer_id.blank? || neighbor_address.blank?

          ::Sdwan::BgpSession
            .joins(:network)
            .where(sdwan_networks: { account_id: @account.id })
            .find_by(sdwan_peer_id: peer_id, neighbor_address: neighbor_address)
        end

        # Heuristic triage from FRR's reset reason text.
        def analyze(session)
          reason = session.last_error.to_s.downcase
          case session.state
          when "active", "connect"
            {
              cause: "TCP connection to neighbor failed; likely WG tunnel down or peer agent silent",
              action: "verify the neighbor's WG handshake (Sdwan::Peer.last_handshake_at) and FRR daemon status",
              command: "vtysh -c \"clear ip bgp #{session.neighbor_address}\""
            }
          when "opensent", "openconfirm"
            {
              cause: "BGP OPEN exchange in flight or stuck; AS mismatch, capability negotiation failure, or hold-timer expiry",
              action: "verify both ends agree on AS number (sdwan.account_bgp.as_number) and that the WG MTU isn't fragmenting OPEN",
              command: "vtysh -c \"show bgp neighbors #{session.neighbor_address}\""
            }
          when "idle"
            cause = if reason.include?("hold")
                      "BGP hold timer expired — KEEPALIVE traffic isn't reaching the neighbor"
                    elsif reason.include?("authentication")
                      "BGP authentication failure"
                    else
                      "Session idle — check last_error or restart manually"
                    end
            {
              cause: cause,
              action: "soft-clear the session; if that fails, restart FRR on the local peer",
              command: "vtysh -c \"clear ip bgp #{session.neighbor_address} soft\""
            }
          else
            {
              cause: "non-standard state",
              action: "inspect FRR status manually",
              command: "vtysh -c \"show bgp summary\""
            }
          end
        end

        def stuck_for(session)
          return 0 if session.last_state_change_at.nil?
          (Time.current - session.last_state_change_at).to_i
        end

        def success(payload) = { success: true, data: payload }
        def failure(error) = { success: false, error: error.to_s }
      end
    end
  end
end
