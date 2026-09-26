# frozen_string_literal: true

# IMP-caef5c00d63f phase 4 — F2 (round-3 review). System::BootLkgStateWriter
# has persisted pivot_security_fail_closed_units / runtime_security_fail_closed_units
# onto System::NodeInstance#config on every heartbeat since this task's own
# round 3, and nothing asked. A unit the agent REFUSED to (re)attach or start
# because a security drop-in write failed non-exempt is a real confinement
# gap on a real node — the agent never weakens a unit's confinement and
# starts it anyway (round 5 removed an earlier draft that stopped a running
# unit here, which was itself unrecoverable on a self-hosted node whose own
# rails/postgres it could stop). Same "answerable but never asked" shape
# BootLkgArmSensor closed for the LKG-armed question.
#
# ONE kind, both fields, because they share one disposition (reach an
# operator) and one root cause (a security drop-in write failed on this
# node): system.node_security_fail_closed. The payload distinguishes WHICH
# field(s) fired per instance so an operator can tell "at boot" from
# "mid-uptime" without needing two alarms to correlate.
#
# NO APPLIER, and none is possible here either: the fix is whatever made the
# write fail in the first place (usually node-wide ENOSPC/EROFS, per the
# agent-side review) or a manifest correction — both are operator actions, not
# something a skill can dispatch. notify-only, declared non-remediating in
# RemediationValidator, same as system.node_lkg_investigate.
module System
  module Fleet
    module Sensors
      class SecurityFailClosedSensor < BaseSensor
        # Same freshness discipline as BootLkgArmSensor: only ask this of a
        # node we can currently hear from. A silent node is a different
        # sensor's alarm.
        DEFAULT_LIVE_HEARTBEAT_SECONDS = 600 # 10 minutes

        MAX_NAMED_INSTANCES  = 20
        MAX_TRACKED_PER_TICK = 500

        SETTING_PREFIX         = "system.security_fail_closed"
        ACCOUNT_SETTING_PREFIX = "security_fail_closed"

        def sense
          return [] unless defined?(::System::NodeInstance)

          affected = []
          live_instances.find_each do |instance|
            break if affected.size >= MAX_TRACKED_PER_TICK

            units = fail_closed_units(instance)
            next if units.empty?

            affected << { instance: instance, units: units }
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

        # { "pivot" => [...], "runtime" => [...] } — only the non-empty halves,
        # so an instance reporting neither is skipped entirely rather than
        # named with two empty lists.
        def fail_closed_units(instance)
          document = instance.config.is_a?(Hash) ? instance.config[::System::BootLkgStateWriter::CONFIG_KEY] : nil
          return {} unless document.is_a?(Hash)

          {
            "pivot"   => Array(document["pivot_security_fail_closed_units"]),
            "runtime" => Array(document["runtime_security_fail_closed_units"])
          }.select { |_, units| units.present? }
        end

        # ONE signal per account, deliberately — same reasoning as
        # BootLkgArmSensor's aggregate_signal: the expected steady state is
        # NO node reporting this, so a per-instance fingerprint would be a
        # rollout-sized storm of one fact.
        def aggregate_signal(affected)
          return nil if affected.empty?

          capped = affected.size >= MAX_TRACKED_PER_TICK

          signal(
            kind: "system.node_security_fail_closed",
            severity: :high,
            payload: {
              "instance_count"      => affected.size,
              "count_is_floor"      => capped,
              "instances"           => named(affected),
              "truncated"           => affected.size > MAX_NAMED_INSTANCES,
              # NOT "running without confinement" (review G6): the agent
              # never weakens a unit's confinement and starts it anyway — a
              # non-exempt drop-in write failure makes it REFUSE to
              # (re)attach/start the unit at all. A first attach's unit is
              # genuinely NOT RUNNING; a re-attach's unit, if already
              # running, keeps running under whatever confinement it already
              # had (never a weaker one the agent just failed to apply).
              # "Refused" is the one word true in both cases.
              "summary"             => "#{capped ? 'at least ' : ''}#{affected.size} live node(s) report a unit the agent " \
                                        "REFUSED to (re)attach/start because a security drop-in write failed and was " \
                                        "not exempt — those units are NOT RUNNING with the agent's involvement",
              "remediation_action"  => nil
            },
            fingerprint: "node_security_fail_closed:#{account.id}"
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
              "units"             => entry[:units]
            }
          end
        end

        def live_heartbeat_seconds
          @live_heartbeat_seconds ||= setting_seconds("live_heartbeat_seconds", DEFAULT_LIVE_HEARTBEAT_SECONDS)
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
