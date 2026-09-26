# frozen_string_literal: true

# N4 (review round 11, IMP-caef5c00d63f) — the pending-upgrade-digest oracle.
# System::PendingModuleDigestsWriter has persisted the agent's
# PendingModuleDigests heartbeat lane (mount.Module.PendingDigest, M9 round
# 9) since this task's own round 11, and nothing consumed it: a module whose
# in-place upgrade attempt failed partway is auto-retried with backoff (N2)
# or reverted, but if it stays stuck — the same digest, retried and backed
# off, never committing and never reverting — that is exactly the kind of
# fact SecurityFailClosedSensor's own doc names: "answerable but never
# asked". Same shape as that sensor; same lane it extends.
#
# NO APPLIER, and none is possible here either: N2's own retry/backoff/revert
# machinery is already the agent's best automatic attempt, running on every
# reconcile tick without server involvement. A module still stuck past the
# threshold means the automatic recovery itself is not working — a manifest
# problem, a genuinely crash-looping binary, or a resource conflict N8's own
# minimal recovery could not resolve — all operator-diagnosed, not something
# a skill can dispatch. notify-only, declared non-remediating in
# RemediationValidator, same as system.node_security_fail_closed_investigate.
module System
  module Fleet
    module Sensors
      class PendingDigestStuckSensor < BaseSensor
        # Same freshness discipline as SecurityFailClosedSensor/BootLkgArmSensor:
        # only ask this of a node we can currently hear from. A silent node is
        # a different sensor's alarm.
        DEFAULT_LIVE_HEARTBEAT_SECONDS = 600 # 10 minutes

        # How long a module may hold the SAME pending digest (per
        # PendingModuleDigestsWriter's own first_seen_at, reset on a revert
        # or re-target) before this alerts. Comfortably past N2's own backoff
        # ceiling (10s, 20s, 40s... capped at 5 minutes) — several backed-off
        # retries are expected and not yet alarming; this fires only once the
        # agent's own automatic recovery has plainly not resolved it.
        DEFAULT_STUCK_AFTER_SECONDS = 900 # 15 minutes

        MAX_NAMED_INSTANCES  = 20
        MAX_TRACKED_PER_TICK = 500

        SETTING_PREFIX         = "system.pending_digest_stuck"
        ACCOUNT_SETTING_PREFIX = "pending_digest_stuck"

        def sense
          return [] unless defined?(::System::NodeInstance)

          affected = []
          live_instances.find_each do |instance|
            break if affected.size >= MAX_TRACKED_PER_TICK

            modules = stuck_modules(instance)
            next if modules.empty?

            affected << { instance: instance, modules: modules }
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

        # { module_id => { "digest" => ..., "first_seen_at" => ... } } for
        # every module whose first_seen_at is at or before the cutoff. A
        # missing/unparseable first_seen_at is NOT treated as stuck — an
        # unmeasured duration is not evidence of one past the threshold,
        # the same declining-over-guessing stance the agent side takes.
        def stuck_modules(instance)
          document = instance.config.is_a?(Hash) ? instance.config[::System::PendingModuleDigestsWriter::CONFIG_KEY] : nil
          modules = document.is_a?(Hash) ? document["modules"] : nil
          return {} unless modules.is_a?(Hash)

          cutoff = stuck_after_seconds.seconds.ago
          modules.select do |_module_id, entry|
            next false unless entry.is_a?(Hash)

            first_seen = parse_time(entry["first_seen_at"])
            !first_seen.nil? && first_seen <= cutoff
          end
        end

        # ONE signal per account, same reasoning as the two sibling sensors:
        # the expected steady state is NO node reporting this, so a
        # per-instance fingerprint would be a rollout-sized storm of one
        # fact.
        def aggregate_signal(affected)
          return nil if affected.empty?

          capped = affected.size >= MAX_TRACKED_PER_TICK

          signal(
            kind: "system.node_pending_digest_stuck",
            severity: :high,
            payload: {
              "instance_count"     => affected.size,
              "count_is_floor"     => capped,
              "instances"          => named(affected),
              "truncated"          => affected.size > MAX_NAMED_INSTANCES,
              "stuck_after_seconds" => stuck_after_seconds,
              "summary"            => "#{capped ? 'at least ' : ''}#{affected.size} live node(s) have held a module " \
                                       "upgrade at the same PendingDigest for more than #{stuck_after_seconds}s — " \
                                       "the agent's own retry/backoff/revert (N2) has not resolved it and this needs " \
                                       "an operator look",
              "remediation_action" => nil
            },
            fingerprint: "node_pending_digest_stuck:#{account.id}"
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
              "modules"           => entry[:modules].transform_values do |v|
                { "digest" => v["digest"], "first_seen_at" => v["first_seen_at"] }
              end
            }
          end
        end

        def parse_time(raw)
          return nil if raw.blank?

          Time.iso8601(raw.to_s)
        rescue ArgumentError, TypeError
          nil
        end

        def live_heartbeat_seconds
          @live_heartbeat_seconds ||= setting_seconds("live_heartbeat_seconds", DEFAULT_LIVE_HEARTBEAT_SECONDS)
        end

        def stuck_after_seconds
          @stuck_after_seconds ||= setting_seconds("stuck_after_seconds", DEFAULT_STUCK_AFTER_SECONDS)
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
