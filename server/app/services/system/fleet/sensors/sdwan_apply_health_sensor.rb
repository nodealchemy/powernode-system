# frozen_string_literal: true

# IMP-da1b772c2596 — the consumer half of the SDWAN apply oracle.
#
# Every other sdwan_* sensor scores the platform's own work: the compiler ran,
# the config was served, the peer handshook. NONE of them can say whether the
# node's kernel ACCEPTED the config it was handed. That answer exists only on
# the node, the agent has been reporting it on every heartbeat as
# `sdwan_state`, and until Sdwan::AgentApplyStateWriter landed nothing read
# it — so a host whose nftables/vrf/bridge apply failed on every single tick
# looked exactly like a host that applied cleanly. This sensor is what makes
# that failure reach an operator.
#
# TWO kinds, one disposition (surface to a person, no auto-action):
#
#   system.sdwan_apply_failed        — the AGENT reported a subsystem in
#                                      state "error" that its own later
#                                      success has not cleared. The oracle is
#                                      the agent's observation; server-side
#                                      compile success is explicitly NOT
#                                      evidence and is never consulted here.
#
#   system.sdwan_apply_not_measured  — the platform expects this host to be
#                                      applying SDWAN (it has a peer, it is
#                                      heartbeating) and has NO apply
#                                      observation for it. Absence is its own
#                                      state: never rendered as healthy,
#                                      never as a measured zero.
#
# WHY THE SECOND KIND EXISTS. Without it the "absence is not measured" rule is
# decorative — an unreported host would simply produce no signal, which reads
# to an operator exactly like a clean one. The reasons it separates have
# different owners: `no_subsystem_observation` is a fleet still running a
# pre-28460bbb agent (a ROLLOUT fact, not a node fault), `stale_reconcile` is
# a node whose reconcile loop has stopped running while its heartbeat loop
# has not, and `unrecognized_state` is a producer whose wire vocabulary this
# platform no longer understands.
#
# NO APPLIER, by design. A failed apply is a kernel-side refusal (a missing
# module, an unsupported device type, an nft ruleset the host rejects); the
# agent already retries it every tick, so there is nothing a server-side
# "remediation" could do that has not already been tried. Re-serving the same
# config is not a fix. The lane is therefore notify_and_proceed and is listed
# in RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES — DO NOT collapse
# it to system.observation, which the fleet seed maps to auto_approve and
# which would silently downgrade the gate so no operator is ever reached.
module System
  module Fleet
    module Sensors
      class SdwanApplyHealthSensor < BaseSensor
        # How recent an apply report must be to still describe the node's
        # current state. Heartbeats run every ~30s, so anything beyond this
        # means the agent stopped sending the block, not that it is quiet.
        DEFAULT_REPORT_FRESH_SECONDS = 900   # 15 minutes

        # How recently the host must have heartbeated for us to claim
        # anything about it at all. Beyond this the node is SILENT, which is
        # InstanceStatusSensor's alarm — a second alarm here would be two
        # sensors firing on one cause.
        #
        # Deliberately SHORTER than the freshness window above. The two are
        # not independent: a host inside this window has, by construction,
        # sent a report at most this long ago, so `stale_report` is reachable
        # only when the agent keeps heartbeating while OMITTING the block.
        # The staleness that matters day to day is `stale_reconcile`, which
        # is keyed on the agent's own clock and is unaffected by either.
        DEFAULT_LIVE_HEARTBEAT_SECONDS = 600 # 10 minutes

        # Failures arrive in HERDS: one bad agent build, or one image without
        # a kernel module tree, fails the same applier on every node at once.
        # Itemise a bounded number and summarise the rest — truncation that
        # says so is honest; an uncapped sweep is one notification per node
        # per dedup window. Mirrors SdwanServiceHealthSensor::MAX_ORPHANS_PER_TICK.
        MAX_FAILURES_PER_TICK = 50

        # Unmeasured instances named individually in the aggregate payload.
        MAX_NAMED_UNMEASURED = 20

        SETTING_PREFIX         = "system.sdwan.apply_health"
        ACCOUNT_SETTING_PREFIX = "sdwan_apply_health"

        def sense
          return [] unless defined?(::Sdwan::Peer) && defined?(::System::NodeInstance)

          failures   = {}
          unmeasured = []

          expected_instances.find_each do |instance|
            reason = not_measured_reason(instance)
            if reason
              unmeasured << { instance: instance, reason: reason }
              next
            end

            collect_failures(instance, failures)
            # ADDITIVE, not exclusive: an instance can both report a real
            # error and carry a state string this platform does not
            # recognize, and the two are different facts. Without this the
            # writer's "unknown, never ok" would be honest at rest and inert
            # at read — a producer that renamed its error constant would take
            # the whole fleet silently green on the next agent rollout.
            unmeasured << { instance: instance, reason: "unrecognized_state" } if unrecognized_state?(instance)
          end

          failure_signals(failures) + Array(not_measured_signal(unmeasured))
        end

        private

        # The hosts the platform has actually ASKED to run SDWAN — a peer row
        # is the request — and that are currently talking to us. An instance
        # with no peer is not silent about SDWAN, it was never given any.
        def expected_instances
          # A correlated subquery, not a pluck: this runs on every fleet tick
          # for every account, and materialising every SDWAN host id into
          # Ruby only to ship it straight back as an IN list is a round trip
          # whose size grows with the fleet.
          ::System::NodeInstance
            .where(account_id: account.id)
            .where(id: ::Sdwan::Peer.where(account_id: account.id).select(:node_instance_id))
            .where(last_heartbeat_at: live_heartbeat_seconds.seconds.ago..)
            .select(:id, :name, :node_id, :agent_version, :last_heartbeat_at, :config)
        end

        # nil when the instance HAS a usable apply observation. Otherwise the
        # reason it does not — each of which is a distinct absence, and none
        # of which may be rendered as health.
        def not_measured_reason(instance)
          state = instance.config.is_a?(Hash) ? instance.config[::Sdwan::AgentApplyStateWriter::CONFIG_KEY] : nil
          return "never_reported" unless state.is_a?(Hash)

          observed = parse_time(state["observed_at"])
          return "never_reported" if observed.nil?
          # When the REPORT last reached us. Necessary but nowhere near
          # sufficient — see the reconcile check below.
          return "stale_report"   if observed < report_fresh_seconds.seconds.ago

          networks = state["networks"]
          return "no_networks" unless networks.is_a?(Array) && networks.any?
          # A pre-28460bbb agent sends network entries with no applier
          # outcomes at all. An empty subsystem list is NOT "nothing failed".
          return "no_subsystem_observation" unless networks.any? { |n| n.is_a?(Hash) && n["subsystems_reported"] }

          # THE OBSERVATION'S OWN AGE, on the AGENT'S clock. Manager#Heartbeat
          # Statuses is a pure snapshot of stored state under a mutex — it
          # neither runs a reconcile nor requires one to have run — and the
          # heartbeat loop is a different loop from the reconcile it calls in
          # PostSend. So an agent whose reconcile has wedged keeps shipping
          # the SAME frozen block every 30s, and the server re-stamps
          # `observed_at` fresh each time. Keying freshness on the ingest
          # clock alone would launder a six-hour-dead reconciler as current,
          # and (if its last snapshot happened to be all-ok) as healthy —
          # which is the task's own false-green class, one level up.
          # `last_reconcile_at` is written only at the END of a completed
          # Reconcile pass, so it is the honest liveness oracle.
          reconciled = newest_reconcile_at(networks)
          return "stale_reconcile" if reconciled.nil? || reconciled < report_fresh_seconds.seconds.ago

          nil
        end

        def newest_reconcile_at(networks)
          networks.filter_map { |n| parse_time(n["last_reconcile_at"]) if n.is_a?(Hash) }.max
        end

        # TRUE when any reported subsystem carries a state this platform does
        # not recognize (the writer's "unknown" — never coerced to ok).
        def unrecognized_state?(instance)
          state = instance.config[::Sdwan::AgentApplyStateWriter::CONFIG_KEY]
          Array(state["networks"]).any? do |net|
            next false unless net.is_a?(Hash)

            Array(net["subsystems"]).any? do |sub|
              sub.is_a?(Hash) &&
                ![ ::Sdwan::AgentApplyStateWriter::OK,
                   ::Sdwan::AgentApplyStateWriter::ERROR ].include?(sub["state"])
            end
          end
        end

        # Accumulates into `failures`, keyed by (instance, subsystem, scope)
        # — the identity of ONE failing applier. A host-global subsystem
        # (empty scope) is replayed under every network in the payload, so
        # the same key is seen repeatedly and must collapse; the network ids
        # it was seen under are collected instead of multiplying the signal.
        def collect_failures(instance, failures)
          state = instance.config[::Sdwan::AgentApplyStateWriter::CONFIG_KEY]
          Array(state["networks"]).each do |net|
            next unless net.is_a?(Hash)

            Array(net["subsystems"]).each do |sub|
              next unless sub.is_a?(Hash)
              # ONLY an explicit "error" is a failure. "unknown" (an
              # unrecognized wire value) is an absence, not a fault, and is
              # deliberately not alarmed on here — it would fire on every
              # node the moment the producer added a third state.
              next unless sub["state"] == ::Sdwan::AgentApplyStateWriter::ERROR

              key = [ instance.id, sub["subsystem"].to_s, sub["scope"].to_s ]
              # Bound the ACCUMULATOR, not just the emission. MAX_NETWORKS x
              # MAX_SUBSYSTEMS_PER_NETWORK is 8k distinct keys per instance,
              # and this sweep spans every SDWAN host on the account — capping
              # only at emit time would still build the whole map first.
              # One past the cap is enough to know the sweep overflowed.
              next if !failures.key?(key) && failures.size > MAX_FAILURES_PER_TICK

              entry = failures[key] ||= {
                instance: instance, subsystem: sub["subsystem"].to_s,
                scope: sub["scope"].to_s, message: sub["message"],
                observed_at: sub["observed_at"], network_ids: [], interfaces: []
              }
              entry[:network_ids] |= [ net["network_id"] ].compact
              entry[:interfaces]  |= [ net["interface"] ].compact
            end
          end
        end

        def failure_signals(failures)
          entries    = failures.values
          overflowed = entries.size > MAX_FAILURES_PER_TICK
          emitted    = overflowed ? entries.first(MAX_FAILURES_PER_TICK) : entries

          signals = emitted.map { |entry| failure_signal(entry) }
          signals << failure_overflow_signal(emitted.size) if overflowed
          signals
        end

        def failure_signal(entry)
          instance = entry[:instance]
          signal(
            kind: "system.sdwan_apply_failed",
            severity: :high,
            payload: {
              "instance_id"       => instance.id,
              "instance_name"     => instance.name,
              "node_id"           => instance.node_id,
              "agent_version"     => instance.agent_version,
              "subsystem"         => entry[:subsystem],
              "scope"             => entry[:scope],
              "message"           => entry[:message],
              "observed_at"       => entry[:observed_at],
              "network_ids"       => entry[:network_ids].sort,
              "interfaces"        => entry[:interfaces].sort,
              # No automated remediation: the agent already retries this
              # apply every tick, so re-serving the same config is not a fix.
              "remediation_action" => nil
            },
            fingerprint: "sdwan_apply_failed:#{instance.id}:#{entry[:subsystem]}:#{entry[:scope]}"
          )
        end

        # Reports "more than N", never a total — the sweep stopped at the cap
        # and has not counted the remainder, so inventing one would be the
        # same fabrication this sensor exists to stop.
        def failure_overflow_signal(emitted_count)
          signal(
            kind: "system.sdwan_apply_failed",
            severity: :high,
            payload: {
              "overflow"       => true,
              "emitted_count"  => emitted_count,
              "summary"        => "more than #{emitted_count} SDWAN appliers are failing across this " \
                                  "account's fleet; only the first #{emitted_count} are itemised this tick",
              "remediation_action" => nil
            },
            fingerprint: "sdwan_apply_failed_overflow:#{account.id}"
          )
        end

        # ONE signal per account, deliberately. The expected initial state of
        # a fleet is "every node still runs a pre-28460bbb agent", so a
        # per-instance fingerprint would be a rollout-sized storm of one fact.
        # The count and the named sample ride the payload, which changes
        # freely without changing the fingerprint — so the lane dedups while
        # still showing an operator the current extent.
        def not_measured_signal(unmeasured)
          return nil if unmeasured.empty?

          named = unmeasured.first(MAX_NAMED_UNMEASURED).map do |u|
            {
              "instance_id"   => u[:instance].id,
              "instance_name" => u[:instance].name,
              "agent_version" => u[:instance].agent_version,
              "reason"        => u[:reason]
            }
          end

          signal(
            kind: "system.sdwan_apply_not_measured",
            severity: :medium,
            payload: {
              "instance_count" => unmeasured.size,
              "reasons"        => unmeasured.group_by { |u| u[:reason] }
                                            .transform_values(&:size),
              "instances"      => named,
              "truncated"      => unmeasured.size > MAX_NAMED_UNMEASURED,
              "summary"        => "#{unmeasured.size} SDWAN-configured instance(s) report no apply " \
                                  "observation — their apply state is UNKNOWN, not healthy",
              "remediation_action" => nil
            },
            fingerprint: "sdwan_apply_not_measured:#{account.id}"
          )
        end

        def report_fresh_seconds
          @report_fresh_seconds ||= setting_seconds("report_fresh_seconds",
                                                    DEFAULT_REPORT_FRESH_SECONDS)
        end

        def live_heartbeat_seconds
          @live_heartbeat_seconds ||= setting_seconds("live_heartbeat_seconds",
                                                      DEFAULT_LIVE_HEARTBEAT_SECONDS)
        end

        # Per-account first, then the deployment-wide SiteSetting, then the
        # constant — the same resolution order as SdwanServiceHealthSensor. A
        # non-positive configured value is treated as unset rather than
        # collapsing the window to zero (which would mark the whole fleet
        # unmeasured).
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
