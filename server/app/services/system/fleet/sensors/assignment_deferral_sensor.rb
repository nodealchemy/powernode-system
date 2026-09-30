# frozen_string_literal: true

# IMP-9f4e162d9ed1 — the operator-visible half of the agent's fail-closed
# assignment rules.
#
# The agent KEEPS modules it would otherwise detach when the platform's
# assignment list names no data-bearing module (IMP-1023e79cc82d), and SKIPS the
# /etc/passwd + sudoers + egress render when an attached module's manifest cannot
# be resolved. Both are the safe choice and both are silent: a node stuck in
# either is running a composition that no longer matches what the platform
# assigned, and nothing said so. The agent reports each live condition on its
# heartbeat as assignment_deferral {reason, module_ids, persisted_seconds}
# (persisted_seconds is a DURATION on the agent's own clock, so this never
# compares two machines' wall clocks); System::BootLkgStateWriter persists it, and
# this sensor makes a PERSISTENT one reach an operator.
#
# NO APPLIER, and none is possible: the repair is either a recorded unassignment
# (a confirmed_unassigned clearance the platform never issued for a removal it did
# not make through a server action) or a manifest the platform can serve again, and
# both are operator decisions. notify-only, declared non-remediating in
# RemediationValidator like its siblings.
module System
  module Fleet
    module Sensors
      class AssignmentDeferralSensor < BaseSensor
        DEFAULT_LIVE_HEARTBEAT_SECONDS = 600 # 10 minutes

        # A deferral younger than this is a blip (a fetch that failed once, the
        # platform restarting). The agent ticks every ~60s, so 15 minutes is
        # fifteen consecutive ticks of the same untrusted answer.
        DEFAULT_PERSISTED_AFTER_SECONDS = 900

        MAX_NAMED_INSTANCES  = 20
        MAX_TRACKED_PER_TICK = 500

        SETTING_PREFIX         = "system.assignment_deferral"
        ACCOUNT_SETTING_PREFIX = "assignment_deferral"

        def sense
          return [] unless defined?(::System::NodeInstance)

          affected = []
          live_instances.find_each do |instance|
            break if affected.size >= MAX_TRACKED_PER_TICK

            deferrals = persistent_deferrals(instance)
            next if deferrals.empty?

            affected << { instance: instance, deferrals: deferrals }
          end

          [ aggregate_signal(affected) ].compact
        end

        private

        def live_instances
          ::System::NodeInstance
            .where(account_id: account.id, status: "running")
            .where(last_heartbeat_at: live_heartbeat_seconds.seconds.ago..)
            .select(:id, :name, :node_id, :agent_version, :last_heartbeat_at, :config)
        end

        # Entries whose unbroken run has lasted at least the threshold. A
        # missing or non-integer duration is unmeasured, and an unmeasured
        # duration is not evidence of a long one.
        def persistent_deferrals(instance)
          document = instance.config.is_a?(Hash) ? instance.config[::System::BootLkgStateWriter::CONFIG_KEY] : nil
          entries = document.is_a?(Hash) ? document["assignment_deferral"] : nil
          return [] unless entries.is_a?(Array)

          entries.select do |entry|
            entry.is_a?(Hash) && entry["persisted_seconds"].is_a?(Integer) &&
              entry["persisted_seconds"] >= persisted_after_seconds
          end
        end

        # ONE signal per account, like its siblings: the expected steady state is
        # NO node reporting this, so a per-instance fingerprint would be a
        # rollout-sized storm of one fact.
        def aggregate_signal(affected)
          return nil if affected.empty?

          capped = affected.size >= MAX_TRACKED_PER_TICK

          signal(
            kind: "system.node_assignment_deferred",
            severity: :high,
            payload: {
              "instance_count"           => affected.size,
              "count_is_floor"           => capped,
              "instances"                => named(affected),
              "truncated"                => affected.size > MAX_NAMED_INSTANCES,
              "persisted_after_seconds"  => persisted_after_seconds,
              "summary"                  => "#{capped ? 'at least ' : ''}#{affected.size} live node(s) have been keeping " \
                                            "modules the platform's assignment no longer names, or skipping the identity " \
                                            "render, for more than #{persisted_after_seconds}s because the platform's answer " \
                                            "could not be trusted. Each is running a composition that does not match its " \
                                            "assignment; an operator has to unassign a module deliberately or fix the manifest",
              "remediation_action"       => nil
            },
            fingerprint: "node_assignment_deferred:#{account.id}"
          )
        end

        def named(affected)
          affected.first(MAX_NAMED_INSTANCES).map do |entry|
            instance = entry[:instance]
            {
              "instance_id"       => instance.id,
              "instance_name"     => instance.name,
              "node_id"           => instance.node_id,
              "agent_version"     => instance.agent_version,
              "last_heartbeat_at" => instance.last_heartbeat_at&.utc&.iso8601,
              "deferrals"         => entry[:deferrals].map do |d|
                { "reason" => d["reason"], "module_ids" => d["module_ids"], "persisted_seconds" => d["persisted_seconds"] }
              end
            }
          end
        end

        def live_heartbeat_seconds
          @live_heartbeat_seconds ||= setting_seconds("live_heartbeat_seconds", DEFAULT_LIVE_HEARTBEAT_SECONDS)
        end

        def persisted_after_seconds
          @persisted_after_seconds ||= setting_seconds("persisted_after_seconds", DEFAULT_PERSISTED_AFTER_SECONDS)
        end

        def setting_seconds(suffix, fallback)
          raw = account.settings&.dig("#{ACCOUNT_SETTING_PREFIX}_#{suffix}").presence ||
                ::SiteSetting.get("#{SETTING_PREFIX}.#{suffix}")
          value = raw.to_i
          value.positive? ? value : fallback
        end
      end
    end
  end
end
