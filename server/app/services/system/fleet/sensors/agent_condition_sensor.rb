# frozen_string_literal: true

require "digest"

# IMP-a6d61b01490d — the operator-visible half of the agent's standing
# conditions.
#
# The agent keeps two things OFF the failure path on purpose and used to say so
# only through cfg.OnError, i.e. stderr and the node journal, which the operator
# cannot read: a known-degraded unit (a run-once unit that was already failing
# before an in-place upgrade, which the upgrade therefore committed past), and a
# refused sudoers grant (an illegal or colliding drop-in name). Neither may become
# a convergence failure — that would fail every apply_config on the node forever —
# so they ride the heartbeat as ONE generic agent_conditions list
# {kind, subject, detail, first_seen}; System::BootLkgStateWriter persists it, and
# this sensor makes a live node's standing conditions reach a person.
#
# ABSENCE IS DELIVERED, not inferred: the writer stores nil for an agent that did
# not report (too old, or not measured yet) and [] for "measured, nothing wrong",
# so a node that cleared its condition goes quiet here because it said so, and an
# agent that cannot report is never mistaken for a clean one. Only a non-empty
# list raises a signal.
#
# NO APPLIER, and none is possible: the repair is configuring the missing
# credential, or fixing or removing the refused grant, both operator decisions.
# notify-only, declared non-remediating in RemediationValidator like its siblings.
module System
  module Fleet
    module Sensors
      class AgentConditionSensor < BaseSensor
        DEFAULT_LIVE_HEARTBEAT_SECONDS = 600 # 10 minutes

        MAX_NAMED_INSTANCES  = 20
        MAX_TRACKED_PER_TICK = 500

        SETTING_PREFIX         = "system.agent_condition"
        ACCOUNT_SETTING_PREFIX = "agent_condition"

        def sense
          return [] unless defined?(::System::NodeInstance)

          affected = []
          live_instances.find_each do |instance|
            break if affected.size >= MAX_TRACKED_PER_TICK

            conditions = ::System::BootLkgStateWriter.agent_conditions_for(instance)["conditions"]
            next if conditions.empty?

            affected << { instance: instance, conditions: conditions }
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

        # ONE signal per account, like its siblings. The fingerprint carries a
        # digest of WHICH (instance, kind, subject) conditions stand: an
        # unchanged standing set keeps one fingerprint and so does not re-raise
        # every tick, while a condition appearing on top of an existing one is a
        # new fingerprint and does.
        def aggregate_signal(affected)
          return nil if affected.empty?

          capped = affected.size >= MAX_TRACKED_PER_TICK

          signal(
            kind: "system.node_agent_condition",
            severity: :high,
            payload: {
              "instance_count"     => affected.size,
              "count_is_floor"     => capped,
              "instances"          => named(affected),
              "truncated"          => affected.size > MAX_NAMED_INSTANCES,
              "summary"            => "#{capped ? 'at least ' : ''}#{affected.size} live node(s) report a standing agent " \
                                      "condition the agent deliberately keeps off the failure path (a known-degraded unit, " \
                                      "or a refused sudoers grant). Each needs an operator: configure the missing " \
                                      "credential, or fix or remove the refused grant",
              "remediation_action" => nil
            },
            fingerprint: "node_agent_condition:#{account.id}:#{standing_digest(affected)}"
          )
        end

        def standing_digest(affected)
          keys = affected.flat_map do |entry|
            entry[:conditions].map { |c| [ entry[:instance].id, c["kind"], c["subject"] ].join("|") }
          end
          Digest::SHA256.hexdigest(keys.sort.join("\n"))[0, 16]
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
              "conditions"        => entry[:conditions].map do |c|
                { "kind" => c["kind"], "subject" => c["subject"], "detail" => c["detail"], "first_seen" => c["first_seen"] }
              end
            }
          end
        end

        def live_heartbeat_seconds
          @live_heartbeat_seconds ||= begin
            raw = account.settings&.dig("#{ACCOUNT_SETTING_PREFIX}_live_heartbeat_seconds").presence ||
                  ::SiteSetting.get("#{SETTING_PREFIX}.live_heartbeat_seconds")
            value = raw.to_i
            value.positive? ? value : DEFAULT_LIVE_HEARTBEAT_SECONDS
          end
        end
      end
    end
  end
end
