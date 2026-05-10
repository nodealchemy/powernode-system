# frozen_string_literal: true

# Detects SDWAN MembershipCredentials approaching their `not_after`
# boundary. Two thresholds:
#
#   - 15 minutes → medium severity (advisory; the agent should refresh
#     on its next reconcile)
#   - 5  minutes → high severity (urgent; the controller should re-issue
#     proactively because the agent's refresh-before-expiry loop missed
#     its window)
#
# Also surfaces MCs whose refresh window has been crossed but no fresh
# row has been issued — that's the "refresh failed" signal the
# autonomy planner uses to decide between re-issue + escalation. We
# detect it heuristically: an MC is in the `expiring` state but no
# newer revision exists for the same (peer, network) pair.
#
# The expected response is a system.sdwan_credential_refresh action
# (re-issue via Sdwan::MembershipCredentialSigner.issue!). This sensor
# emits the signal; the DecisionEngine routes it to the appropriate
# executor (registered in N0 only as a stub — Phase N1+ wires the full
# autonomy executor).
#
# Phase N0 of the in-house encrypted mesh overlay roadmap.
module System
  module Fleet
    module Sensors
      class SdwanCredentialExpirySensor < BaseSensor
        ADVISORY_WINDOW = 15.minutes
        URGENT_WINDOW   = 5.minutes

        def sense
          return [] unless defined?(::Sdwan::MembershipCredential)

          now = Time.current
          signals = []

          # Window 1: live MCs nearing expiry.
          ::Sdwan::MembershipCredential
            .live
            .where(account_id: account.id)
            .expiring_within(ADVISORY_WINDOW, now: now)
            .find_each do |mc|
              age_to_exp = (mc.not_after - now).to_i
              severity = age_to_exp <= URGENT_WINDOW.to_i ? :high : :medium
              signals << signal(
                kind: "system.sdwan_credential_expiring",
                severity: severity,
                payload: {
                  membership_credential_id: mc.id,
                  peer_id: mc.sdwan_peer_id,
                  network_id: mc.sdwan_network_id,
                  revision: mc.revision,
                  not_after: mc.not_after.utc.iso8601,
                  seconds_to_expiry: [age_to_exp, 0].max,
                  remediation_action: "system.sdwan_credential_refresh"
                },
                fingerprint: "sdwan_credential_expiring:#{mc.id}"
              )
            end

          # Window 2: MCs whose refresh window passed but the controller
          # hasn't issued a newer revision. The healthy path replaces
          # the row with a higher-revision active MC; the failure path
          # leaves the original sitting in `expiring`. We dedupe per
          # (peer, network) so a stuck MC only emits once.
          stuck_keys = ::Sdwan::MembershipCredential
                         .where(account_id: account.id, status: "expiring")
                         .where("not_after > ?", now)
                         .select(:sdwan_peer_id, :sdwan_network_id, :id)
                         .group_by { |row| [row.sdwan_peer_id, row.sdwan_network_id] }

          stuck_keys.each do |(peer_id, network_id), rows|
            latest_rev = ::Sdwan::MembershipCredential
                           .where(sdwan_peer_id: peer_id, sdwan_network_id: network_id)
                           .maximum(:revision) || 0
            stuck_row = rows.find { |r| r.id }
            next if stuck_row.nil?

            stuck_record = ::Sdwan::MembershipCredential.find(stuck_row.id)
            # Only emit when no superseding revision exists (i.e., this
            # IS the most recent attempt). Otherwise the system already
            # rotated successfully and the `expiring` row is just history.
            next if stuck_record.revision < latest_rev

            signals << signal(
              kind: "system.sdwan_credential_refresh_stalled",
              severity: :high,
              payload: {
                membership_credential_id: stuck_record.id,
                peer_id: peer_id,
                network_id: network_id,
                revision: stuck_record.revision,
                refresh_after: stuck_record.refresh_after.utc.iso8601,
                not_after: stuck_record.not_after.utc.iso8601,
                seconds_overdue: [(now - stuck_record.refresh_after).to_i, 0].max,
                remediation_action: "system.sdwan_credential_refresh"
              },
              fingerprint: "sdwan_credential_refresh_stalled:#{peer_id}:#{network_id}"
            )
          end

          signals
        end
      end
    end
  end
end
