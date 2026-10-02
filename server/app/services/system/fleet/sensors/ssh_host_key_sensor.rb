# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # IMP-e744d96da817 — the two things IMP-190834701b0a (agent-reported SSH
      # host keys) left undone. Read-side only: it reads the FleetEvent trail
      # System::SshHostKeyWriter writes and the recorded keys, and writes nothing.
      #
      # ARM B — A CHANGE WITH NO BOOT BETWEEN.
      # A reimaged node legitimately gets new host keys, and the writer classes
      # that as a change ACROSS a boot (boot_id differs). The same boot_id on both
      # sides has no routine explanation: the impersonation or tamper shape. The
      # writer audits it and emits a high event, which reaches a feed; this lane
      # puts it in front of a person. `system.ssh_host_key_changed_in_boot` is
      # bound skill: nil under require_approval — there is no applier and can be
      # none: the only remedies (clear the recorded key, isolate the node) are
      # human acts. boot_id is self-reported by the same principal that reports
      # the key, so this separates accidents, not attackers; the signal says so by
      # existing only for the no-boot-between shape and never for the other.
      # One signal per event (fingerprint carries the event id), over a lookback
      # window, so a change is paged once and ages out.
      #
      # ARM A — COVERAGE.
      # "Verify coverage, then flip system.ssh.require_host_key" had no tool behind
      # it. Per account and per tick, over the running or starting instances:
      #   - one or more WITHOUT a recorded key, past a grace for a first heartbeat:
      #     system.ssh_host_key_uncovered, notify-only (notify_and_proceed, no
      #     applier: an operator finds out why that agent is not reporting);
      #   - none uncovered and none still inside the grace, with at least one
      #     instance: system.ssh_host_key_coverage_complete, a POSITIVE fact bound
      #     to system.observation (auto_approve: it files for dashboards and pages
      #     no one), so "zero uncovered" is a measured answer rather than the same
      #     silence a stalled sensor would produce;
      #   - a fleet with no instances says nothing: 0 of 0 is not coverage.
      # The sensor never flips the setting. `ready_to_enforce` and the current
      # `require_host_key` value ride in the payload; the decision stays with the
      # operator. WHAT "COVERED" MEANS, stated rather than implied: a valid key is
      # RECORDED for the instance. It does not say the key is current (a reimaged
      # node whose agent cannot heartbeat the new key still reads covered until its
      # next report) nor that the agent is alive (InstanceStatusSensor owns that),
      # and an instance that can never report one (a shared legacy mtls_subject is
      # never ingested) reads uncovered until it is fixed or retired. The
      # require_host_key flip is the operator's call with those caveats in hand.
      class SshHostKeySensor < BaseSensor
        CHANGED_KIND   = "system.ssh_host_key_changed_in_boot"
        UNCOVERED_KIND = "system.ssh_host_key_uncovered"
        COMPLETE_KIND  = "system.ssh_host_key_coverage_complete"

        COVERED_STATUSES = ::System::NodeInstance::HEARTBEAT_EXPECTED_STATUSES
        COMPLETE_BUCKET_SECONDS = 1800

        def self.default_thresholds
          {
            "change_lookback_seconds" => 3600, # how long a no-boot change stays a live signal
            "grace_seconds" => 1800,           # a new instance's time to send its first heartbeat
            "max_uncovered_ids" => 50          # ids named in the payload (the count is never capped)
          }
        end

        def sense
          change_signals + coverage_signals
        end

        private

        # ── arm b ───────────────────────────────────────────────────────
        def change_signals
          cutoff = Time.current - threshold("change_lookback_seconds").seconds

          ::System::FleetEvent
            .where(account: account, kind: ::System::SshHostKeyWriter::CHANGED_EVENT_KIND)
            .where("emitted_at >= ?", cutoff)
            .where("payload ->> 'boot_id_changed' = 'false'")
            .order(:emitted_at)
            .map { |event| change_signal(event) }
        end

        # Fingerprints only: no key blob is in the event, and none is read here.
        def change_signal(event)
          payload = event.payload.is_a?(Hash) ? event.payload : {}
          signal(
            kind: CHANGED_KIND,
            severity: :high,
            payload: {
              "instance_id" => event.node_instance_id || payload["instance_id"],
              "event_id" => event.id,
              "emitted_at" => event.emitted_at.iso8601,
              "previous_fingerprints" => Array(payload["previous_fingerprints"]),
              "fingerprints" => Array(payload["fingerprints"]),
              "key_types" => Array(payload["key_types"])
            },
            fingerprint: "ssh_host_key_changed_in_boot:#{event.id}"
          )
        end

        # ── arm a ───────────────────────────────────────────────────────
        def coverage_signals
          covered = []
          uncovered = []
          pending = []
          grace_cutoff = Time.current - threshold("grace_seconds").seconds

          running_instances.find_each do |instance|
            if ::System::SshHostKeys.recorded_for(instance).any?
              covered << instance.id
            elsif instance.created_at && instance.created_at > grace_cutoff
              pending << instance.id
            else
              uncovered << instance.id
            end
          end

          total = covered.size + uncovered.size + pending.size
          return [] if total.zero?

          counts = coverage_counts(covered, uncovered, pending, total)
          return [ uncovered_signal(uncovered, counts) ] if uncovered.any?
          return [] if pending.any? # still reporting in: neither a gap nor yet complete

          [ complete_signal(counts) ]
        end

        def running_instances
          ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { account_id: account.id })
            .where(status: COVERED_STATUSES)
        end

        def coverage_counts(covered, uncovered, pending, total)
          {
            "covered_count" => covered.size,
            "uncovered_count" => uncovered.size,
            "awaiting_first_report_count" => pending.size,
            "total" => total,
            "ready_to_enforce" => uncovered.empty? && pending.empty?,
            "require_host_key" => ::System::SshExecutionService.require_host_key?
          }
        end

        def uncovered_signal(uncovered, counts)
          named = uncovered.first(threshold("max_uncovered_ids"))
          signal(
            kind: UNCOVERED_KIND,
            severity: :medium,
            payload: counts.merge("uncovered_instance_ids" => named),
            # The set, not just the account: a changed set is reported again.
            fingerprint: "ssh_host_key_uncovered:#{account.id}:#{Digest::SHA256.hexdigest(uncovered.join(',')).first(16)}"
          )
        end

        # The fingerprint carries a time bucket on purpose. DecisionEngine ages a
        # fingerprint re-detected past SignalState's escalate_after_ticks with no
        # remediation on record into a "standing signal needs a decision" page, and a
        # good-news fact that stays true would earn that page every hour. A new bucket
        # is a new fingerprint, so the fact is restated about every half hour (well
        # inside the default 60-tick threshold) and never accumulates into a standing
        # condition. The uncovered arm is deliberately NOT bucketed: a gap that stands
        # IS an operator's problem.
        def complete_signal(counts)
          signal(
            kind: COMPLETE_KIND,
            severity: :low,
            payload: counts,
            fingerprint: "ssh_host_key_coverage_complete:#{account.id}:#{Time.current.to_i / COMPLETE_BUCKET_SECONDS}"
          )
        end
      end
    end
  end
end
