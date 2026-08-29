# frozen_string_literal: true

# IMP-a8f9fa74284d — the CONSUMER half of the boot/LKG ARM oracle.
#
# System::BootLkgStateWriter has persisted a `boot_lkg` document — including a
# derived `arm_state` — onto System::NodeInstance#config on every heartbeat
# since IMP-b8d5cfa33b79, and Ai::Tools::SystemFleetTool exposes it over MCP.
# Nothing ASKED. The platform could answer "is this node armed with a valid
# last-known-good?" while the question an operator actually faces — before
# pulling a node's control plane — was still answered by the absence of an
# alarm. This sensor is what makes that answer reach a person.
#
# == THE ABSENCE RULE IS THE WHOLE FEATURE
#
# Every boot/LKG field on the agent's wire is Go `omitempty`, so a FALSE value
# is never transmitted at all: on the wire, "not armed" and "the agent never
# said" are the same bytes. Absence is therefore the NORMAL shape of an
# un-armed node, and the writer records it as `arm_state: "unreported"` —
# explicitly NOT as a measured false.
#
# So this sensor treats anything that is not an explicit "armed" as BLOCKING:
# no document at all, an "unreported" document, a document too stale to
# describe the node now, and an arm_state it does not recognise all alarm. A
# consumer that read any of those as "probably fine" would convert a
# decommission blocker into the decommission green light this whole lane exists
# to prevent — strictly worse than the status quo, where the operator at least
# knows the answer is missing.
#
# TWO kinds, one disposition (surface to a person, no auto-action):
#
#   system.node_lkg_unarmed — a live node the platform cannot say is armed.
#                             Reasons: `never_reported` (no document — a fleet
#                             still running a pre-#39 agent, or a node whose
#                             on-disk LKG was deleted, wiped by a re-provision,
#                             or corrupted), `unreported` (the document says
#                             so), `stale_report` (the document stopped being
#                             rewritten while heartbeats kept flowing), and
#                             `arm_state_unrecognized`.
#
#   system.node_lkg_stale   — a node that IS armed, whose LKG confirmation has
#                             aged past the window (`confirmation_aged`) or
#                             which never stated one (`unconfirmed`). Same
#                             doctrine one level down: absence is not freshness.
#
# NO APPLIER, by design and by necessity. Nothing the platform can dispatch
# re-arms a node — the LKG is frozen on the node's own disk by the agent at
# boot, and the repair is a person restoring or re-capturing it. The binding is
# therefore `skill: nil` with a notify-level action_category, and the category
# is listed in RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES: a
# fingerprint that stands until a human acts would otherwise score ineffective
# every settle window and manufacture a false fleet.remediation_stuck HIGH.
# DO NOT collapse the category to system.observation, which the fleet seed maps
# to auto_approve — that files the signal for a dashboard and reaches no
# operator, which would make this sensor as inert as the state it reads.
module System
  module Fleet
    module Sensors
      class BootLkgArmSensor < BaseSensor
        # How recent the stored document must be to still describe the node.
        # Once a document exists the writer REWRITES it on every heartbeat
        # (that is its stated rule), so beyond this the lane itself stopped —
        # and a frozen document must never be allowed to keep answering
        # "armed" for a node that stopped being armed.
        DEFAULT_REPORT_FRESH_SECONDS = 900   # 15 minutes

        # How recently the host must have heartbeated for us to claim anything
        # about it at all. Beyond this the node is SILENT, which is
        # InstanceStatusSensor's alarm — a second alarm here would be two
        # sensors firing on one cause. Deliberately SHORTER than the freshness
        # window above, so `stale_report` is reachable only when the agent
        # keeps heartbeating while the boot/LKG document stops moving.
        DEFAULT_LIVE_HEARTBEAT_SECONDS = 600 # 10 minutes

        # How old an armed node's LKG confirmation may be before it is worth an
        # operator's attention. Generous: a frozen LKG is not wrong, it is
        # merely unverified since, and the alarm for it is medium.
        DEFAULT_STALE_SECONDS = 30 * 24 * 60 * 60 # 30 days

        # Instances named individually in an aggregate payload.
        MAX_NAMED_INSTANCES = 20

        # Bound on the ACCUMULATORS, not just on what is named. The expected
        # initial state of a fleet is "every node runs an agent that predates
        # the boot/LKG block", so the un-armed set can be the whole account.
        # One past the cap is enough to know the sweep overflowed; the count
        # the signal reports is then explicitly a FLOOR, never a fabricated
        # total.
        MAX_TRACKED_PER_TICK = 500

        SETTING_PREFIX         = "system.boot_lkg"
        ACCOUNT_SETTING_PREFIX = "boot_lkg"

        def sense
          return [] unless defined?(::System::NodeInstance)

          unarmed = []
          stale   = []

          live_instances.find_each do |instance|
            break if unarmed.size >= MAX_TRACKED_PER_TICK && stale.size >= MAX_TRACKED_PER_TICK

            reason = unarmed_reason(instance)
            if reason
              unarmed << { instance: instance, reason: reason } if unarmed.size < MAX_TRACKED_PER_TICK
              next
            end

            reason = stale_reason(instance)
            stale << { instance: instance, reason: reason } if reason && stale.size < MAX_TRACKED_PER_TICK
          end

          [
            aggregate_signal(
              kind: "system.node_lkg_unarmed",
              severity: :high,
              entries: unarmed,
              fingerprint: "node_lkg_unarmed:#{account.id}",
              summary: ->(count, floor) {
                "#{floor}#{count} live node(s) cannot be shown to be armed with a valid " \
                "last-known-good composition — those nodes are UNVERIFIED, not safe to " \
                "decommission or to have their control plane pulled"
              }
            ),
            aggregate_signal(
              kind: "system.node_lkg_stale",
              severity: :medium,
              entries: stale,
              fingerprint: "node_lkg_stale:#{account.id}",
              summary: ->(count, floor) {
                "#{floor}#{count} armed node(s) have a last-known-good whose confirmation is " \
                "aged or absent — the composition they would fall back to has not been " \
                "confirmed recently"
              }
            )
          ].compact
        end

        private

        # The population the decommission question applies to: a RUNNING node
        # that is still talking to us. A silent or stopped node is a different
        # alarm with a different owner, and claiming "unarmed" about one we
        # cannot currently hear would be an assertion the fleet never made.
        def live_instances
          ::System::NodeInstance
            .where(account_id: account.id, status: "running")
            .where(last_heartbeat_at: live_heartbeat_seconds.seconds.ago..)
            .select(:id, :name, :node_id, :agent_version, :last_heartbeat_at, :config)
        end

        # nil when the node is demonstrably armed RIGHT NOW. Otherwise the
        # reason it is not — and every path that is not an explicit ARMED
        # returns one.
        def unarmed_reason(instance)
          document = boot_lkg(instance)
          return "never_reported" if document.nil?

          observed = parse_time(document["observed_at"])
          return "stale_report" if observed.nil? || observed < report_fresh_seconds.seconds.ago

          arm_state = document["arm_state"].to_s
          return nil if arm_state == ::System::BootLkgStateWriter::ARMED
          return "unreported" if arm_state == ::System::BootLkgStateWriter::UNREPORTED

          # Neither value this platform writes. A document from an older writer,
          # a hand-edited config, or a shape drift — none of which is evidence
          # of an arm, so it is treated exactly like the absence it resembles.
          "arm_state_unrecognized"
        end

        # Only ever asked of an instance that already answered ARMED, so the
        # two kinds partition the fleet rather than double-counting it.
        def stale_reason(instance)
          confirmed = parse_time(boot_lkg(instance)&.fetch("lkg_confirmed_at", nil))
          return "unconfirmed" if confirmed.nil?
          return "confirmation_aged" if confirmed < stale_seconds.seconds.ago

          nil
        end

        def boot_lkg(instance)
          document = instance.config.is_a?(Hash) ? instance.config[::System::BootLkgStateWriter::CONFIG_KEY] : nil
          document.is_a?(Hash) ? document : nil
        end

        # ONE signal per kind per account, deliberately. The expected initial
        # state of a fleet is that NO node reports this block, so a per-instance
        # fingerprint would be a rollout-sized storm of one fact. The count and
        # the named sample ride the payload, which changes freely without
        # changing the fingerprint — so the lane dedups as a standing condition
        # while still showing an operator the current extent.
        def aggregate_signal(kind:, severity:, entries:, fingerprint:, summary:)
          return nil if entries.empty?

          capped = entries.size >= MAX_TRACKED_PER_TICK

          signal(
            kind: kind,
            severity: severity,
            payload: {
              "instance_count" => entries.size,
              # Says so when the sweep stopped at the cap: reporting a total it
              # never finished counting would be the same fabrication the
              # absence rule exists to stop.
              "count_is_floor" => capped,
              "reasons"        => entries.group_by { |e| e[:reason] }.transform_values(&:size),
              "instances"      => named(entries),
              "truncated"      => entries.size > MAX_NAMED_INSTANCES,
              "summary"        => summary.call(entries.size, capped ? "at least " : ""),
              # There is no applier and can be none — nothing re-arms a node.
              # See the class doc.
              "remediation_action" => nil
            },
            fingerprint: fingerprint
          )
        end

        def named(entries)
          entries.first(MAX_NAMED_INSTANCES).map do |entry|
            instance = entry[:instance]
            {
              "instance_id"       => instance.id,
              "instance_name"     => instance.name,
              "node_id"           => instance.node_id,
              "agent_version"     => instance.agent_version,
              "last_heartbeat_at" => instance.last_heartbeat_at&.utc&.iso8601,
              "reason"            => entry[:reason]
            }
          end
        end

        def report_fresh_seconds
          @report_fresh_seconds ||= setting_seconds("report_fresh_seconds", DEFAULT_REPORT_FRESH_SECONDS)
        end

        def live_heartbeat_seconds
          @live_heartbeat_seconds ||= setting_seconds("live_heartbeat_seconds", DEFAULT_LIVE_HEARTBEAT_SECONDS)
        end

        def stale_seconds
          @stale_seconds ||= setting_seconds("stale_seconds", DEFAULT_STALE_SECONDS)
        end

        # Per-account first, then the deployment-wide SiteSetting, then the
        # constant — the same resolution order as ModuleVerifyFailedSensor. A
        # non-positive configured value is treated as unset rather than
        # collapsing the window to zero.
        def setting_seconds(suffix, fallback)
          raw = account.settings&.dig("#{ACCOUNT_SETTING_PREFIX}_#{suffix}").presence ||
                ::SiteSetting.get("#{SETTING_PREFIX}.#{suffix}")
          value = raw.to_i
          value.positive? ? value : fallback
        end

        def parse_time(raw)
          return nil if raw.blank?

          Time.parse(raw.to_s)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
