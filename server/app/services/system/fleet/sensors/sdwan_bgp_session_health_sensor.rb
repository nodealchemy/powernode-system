# frozen_string_literal: true

# Detects iBGP sessions that have been stuck in a non-established state
# for too long. A session in "active" or "connect" briefly is normal —
# FRR's TCP state machine is climbing toward "established". Lingering
# there for more than UNHEALTHY_WINDOW means real trouble: misconfigured
# AS, mTU mismatch on the WireGuard tunnel, or peer agent down.
#
# Also flags sessions that haven't been observed in STALE_WINDOW (5 min),
# which usually means the agent reporter is silent (FRR hung, vtysh
# missing, agent crashed) — distinct from a session that IS reporting
# but isn't established.
#
# Emits one signal per unhealthy session; the DecisionEngine routes them
# to system.sdwan_bgp_session_remediate (default policy notify_and_proceed —
# the executor restarts FRR via systemctl, low blast radius).
#
# Slice 9f of the SDWAN plan.
#
# IMP-2f34679b6b73 adds a third family: ATTRIBUTION. The two session-level
# families above both assume the rows they read describe the network they are
# filed under. On a host in two or more iBGP networks that assumption held
# only by accident — one host-wide FRR, one unscoped vtysh poll, replayed
# under every network id. Sdwan::BgpSessionWriter now refuses to file what it
# cannot attribute and records WHY on the local peer's
# bgp_session_state["observation"]; that refusal has to reach an operator, or
# the fix trades a wrong measurement for a silent absence. These signals are
# notify-only (skill: nil): nothing the fleet can execute repairs an
# unattributable observation — the host needs an agent that scopes its poll
# by VRF, which is a rollout, not a remediation.
module System
  module Fleet
    module Sensors
      class SdwanBgpSessionHealthSensor < BaseSensor
        UNHEALTHY_WINDOW = 5.minutes
        STALE_WINDOW     = 5.minutes
        SEVERE_DOWN      = 30.minutes

        def sense
          return [] unless defined?(::Sdwan::BgpSession)

          signals = []
          signals.concat(unhealthy_state_signals)
          signals.concat(stale_observation_signals)
          signals.concat(attribution_signals)
          signals
        end

        private

        # IMP-2f34679b6b73 — peers whose last BGP report could not be
        # attributed to their network, or which the agent disclaimed
        # outright. Both are absences of a measurement, and neither is
        # visible anywhere else: no BgpSession row is written for them, so
        # the two session-level families above are structurally blind here.
        def attribution_signals
          return [] unless ::Sdwan::Peer.column_names.include?("bgp_session_state")

          peers_with_unresolved_observations.filter_map do |peer|
            observation = peer.bgp_session_state["observation"]
            next unless observation.is_a?(Hash)
            next if observation_stale?(observation)

            attribution_signal(peer, observation)
          end
        end

        UNRESOLVED_STATUSES = %w[unattributable not_measured].freeze

        # The status test belongs in SQL, not in Ruby after `.to_a`: the
        # writer stamps an `observation` on EVERY tick, so a mere
        # key-existence predicate matches every actively-reporting iBGP peer
        # in the account and filters nothing. There is no GIN index on this
        # column, so the selective term has to do the work.
        def peers_with_unresolved_observations
          ::Sdwan::Peer
            .joins(:network)
            .where(system_sdwan_networks: { account_id: account.id, routing_protocol: "ibgp" })
            .where("system_sdwan_peers.bgp_session_state -> 'observation' ->> 'status' IN (?)",
                   UNRESOLVED_STATUSES)
            .to_a
        end

        # An observation block that stopped being refreshed describes an
        # agent that stopped reporting, which is the stale family's subject,
        # not this one. Ageing out here keeps one condition to one signal.
        def observation_stale?(observation)
          observed_at = observation["observed_at"]
          return true if observed_at.blank?

          parsed = Time.zone.parse(observed_at.to_s)
          parsed.nil? || parsed < STALE_WINDOW.ago
        rescue ArgumentError, TypeError
          true
        end

        # How long a standing misattribution has to have been standing before
        # it stops being "new" and becomes an operator emergency. The host has
        # been feeding another network's sessions to the remediate executor
        # for this entire window.
        MULTI_IBGP_ESCALATION_AGE = 24.hours

        def attribution_signal(peer, observation)
          unattributable = observation["status"].to_s == "unattributable"
          flag = ::Sdwan::MultiIbgpHostFlagger.flag_for(peer)

          signal(
            kind: unattributable ? "system.sdwan_bgp_observation_unattributable"
                                 : "system.sdwan_bgp_observation_not_measured",
            # An unattributable report has already been ACTED on in the old
            # shape (the remediate executor ran against another network's
            # sessions), so it outranks a self-declared absence.
            severity: attribution_severity(unattributable, flag),
            payload: {
              peer_id: peer.id,
              network_id: peer.sdwan_network_id,
              node_instance_id: peer.node_instance_id,
              status: observation["status"],
              reason: observation["reason"],
              observed_at: observation["observed_at"],
              sessions_accepted: observation["sessions_accepted"],
              sessions_rejected: observation["sessions_rejected"],
              rejected_neighbors: observation["rejected_neighbors"],
              # The rebuild boundary, per report: false means this host is
              # still running an agent that polls FRR without naming a VRF.
              agent_vrf_scoped: observation["agent_vrf_scoped"],
              multi_ibgp_network_ids: flag ? flag["network_ids"] : nil,
              # Provenance only the persisted flag carries: WHEN this host
              # entered the multi-iBGP shape. No live query can reconstruct
              # it, and it is what separates a fresh enrollment from a
              # misattribution that has been standing for days.
              multi_ibgp_since: flag ? flag["flagged_at"] : nil,
              recommended_action: observation["agent_vrf_scoped"] == false ? "roll_out_vrf_scoped_agent"
                                                                           : "inspect_frr_on_host"
            },
            # Per (peer, status) — a host stuck unattributable re-emits the
            # same fingerprint every tick and is squelched by the dedup TTL,
            # while a transition between the two statuses is a new fact.
            fingerprint: "sdwan_bgp_observation:#{peer.id}:#{observation['status']}"
          )
        end

        # The flag's one behavioural read: a misattribution standing since
        # before MULTI_IBGP_ESCALATION_AGE is critical, not merely high.
        def attribution_severity(unattributable, flag)
          return :medium unless unattributable

          # No stamp is the pre-existing-fleet case: the host is multi-iBGP
          # (the writer proved it from live rows) but was never flagged,
          # because it entered that shape before this change shipped. High,
          # not critical — we do not know how long it has been standing.
          flagged_at = flag.is_a?(Hash) ? flag["flagged_at"] : nil
          return :high if flagged_at.blank?

          parsed = Time.zone.parse(flagged_at.to_s)
          parsed && parsed < MULTI_IBGP_ESCALATION_AGE.ago ? :critical : :high
        rescue ArgumentError, TypeError
          :high
        end

        # Sessions reporting a non-established state for too long.
        def unhealthy_state_signals
          ::Sdwan::BgpSession
            .joins(:network)
            .where(system_sdwan_networks: { account_id: account.id })
            .where.not(state: "established")
            .where("last_state_change_at < ?", UNHEALTHY_WINDOW.ago)
            .where("last_observed_at >= ?", STALE_WINDOW.ago) # exclude stale; covered separately
            .find_each.map do |session|
              age = Time.current - session.last_state_change_at
              signal(
                kind: "system.sdwan_bgp_session_unhealthy",
                severity: severity_for(age),
                payload: {
                  bgp_session_id: session.id,
                  peer_id: session.sdwan_peer_id,
                  network_id: session.sdwan_network_id,
                  neighbor_peer_id: session.neighbor_peer_id,
                  neighbor_address: session.neighbor_address,
                  state: session.state,
                  stuck_for_seconds: age.to_i,
                  last_error: session.last_error,
                  remediation_action: "system.sdwan_bgp_session_remediate"
                },
                # Dedup on (local_peer, neighbor) — same flap re-emits
                # the same fingerprint so FleetAutonomyService squelches
                # duplicates within the dedup TTL window.
                fingerprint: "sdwan_bgp_session_unhealthy:#{session.sdwan_peer_id}:#{session.neighbor_address}"
              )
            end
        end

        # Sessions that haven't been observed at all recently. Distinct
        # signal — different remediation (restart agent? check FRR is
        # installed?) than "session reporting but down."
        def stale_observation_signals
          ::Sdwan::BgpSession
            .joins(:network)
            .where(system_sdwan_networks: { account_id: account.id })
            .where("last_observed_at < ?", STALE_WINDOW.ago)
            .find_each.map do |session|
              age = Time.current - session.last_observed_at
              signal(
                kind: "system.sdwan_bgp_session_stale",
                severity: :medium,
                payload: {
                  bgp_session_id: session.id,
                  peer_id: session.sdwan_peer_id,
                  network_id: session.sdwan_network_id,
                  neighbor_address: session.neighbor_address,
                  last_observed_at: session.last_observed_at.utc.iso8601,
                  stale_for_seconds: age.to_i,
                  recommended_action: "verify_agent_reporting"
                },
                fingerprint: "sdwan_bgp_session_stale:#{session.sdwan_peer_id}:#{session.neighbor_address}"
              )
            end
        end

        def severity_for(age_seconds)
          return :critical if age_seconds >= SEVERE_DOWN.to_i
          return :high     if age_seconds >= 15.minutes.to_i
          :medium
        end
      end
    end
  end
end
