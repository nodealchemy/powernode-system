# frozen_string_literal: true

# IMP-3855ff9908f2 — the CONSUMER half of the `verify:` probe oracle.
#
# Every other module sensor scores the platform's own bookkeeping: the artifact
# was published (ModulePromotionSensor), the node's digests match what it was
# assigned (ModuleDriftSensor), the template's closure was applied
# (TemplateClosureDriftSensor). NONE of them can say whether the capability the
# module exists to provide is reachable on the node afterwards. That answer
# lives on the node; the agent computes it from the manifest's `verify:` block
# and ships it on every heartbeat; System::ModuleVerifyStateWriter persists it.
# This sensor is what makes a failed probe reach an operator.
#
# TWO kinds, one disposition (surface to a person, no auto-action):
#
#   system.module_verify_failed        — a probe RESOLVED to something other
#                                        than the path its manifest declared,
#                                        in at least one shell. This is the
#                                        shadowed-binary class: the name
#                                        answered, so every existence check on
#                                        the node passed, and the wrong file
#                                        was behind it.
#
#   system.module_verify_not_measured  — the platform assigned this node a
#                                        module that DECLARES probes, and has
#                                        no usable verdict for it. Absence is
#                                        its own state: never rendered as
#                                        healthy, never as a measured pass.
#
# WHY THE SECOND KIND EXISTS. Without it the "absence is not measured" rule is
# decorative — an unreported node would produce no signal, which reads to an
# operator exactly like a clean one. Its reasons have different owners:
# `never_reported` / `no_module_report` is a fleet still running an agent that
# predates the probe runner (a ROLLOUT fact); `stale_report` is a node whose
# heartbeat kept flowing while the block stopped; `stale_probe` is a probe loop
# that wedged while the heartbeat loop did not; `partial_report` is an agent
# that ran fewer probes than the module declared; and `shells_not_covered` is
# the one this whole feature was specified around — a probe that ran ONE shell.
# A one-shell probe is NOT a weaker pass. The VM-9000 bug WAS the divergence
# between login and non-login PATH resolution, so a report covering one of them
# has not tested the thing that broke, and is recorded as unmeasured.
#
# NO APPLIER, by design. A failed probe means the node's filesystem or PATH is
# not what the manifest says it should be — a wrong artifact, a shadowing
# package, a profile script reordering PATH. Re-serving the same module does
# not fix any of those (the gitleaks v4 incident is the proof: the artifact the
# platform would re-serve is the empty one). The repair is a person changing an
# artifact or an image. The lane is therefore notify_and_proceed and is listed
# in RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES — DO NOT collapse
# it to system.observation, which the fleet seed maps to auto_approve and which
# would silently downgrade the gate so no operator is ever reached.
module System
  module Fleet
    module Sensors
      class ModuleVerifyFailedSensor < BaseSensor
        # How recent a verify report must be to still describe the node.
        # Heartbeats run every ~30s, so beyond this the agent stopped sending
        # the block rather than merely being quiet.
        DEFAULT_REPORT_FRESH_SECONDS = 900   # 15 minutes

        # How recently the host must have heartbeated for us to claim anything
        # about it at all. Beyond this the node is SILENT, which is
        # InstanceStatusSensor's alarm — a second alarm here would be two
        # sensors firing on one cause. Deliberately SHORTER than the freshness
        # window, so `stale_report` is reachable only when the agent keeps
        # heartbeating while OMITTING the block.
        DEFAULT_LIVE_HEARTBEAT_SECONDS = 600 # 10 minutes

        # Failures arrive in HERDS: one bad publish fails the same probe on
        # every node carrying the module at once. Itemise a bounded number and
        # say so; an uncapped sweep is one notification per node per window.
        MAX_FAILURES_PER_TICK = 50

        # Unmeasured observations named individually in the aggregate payload.
        MAX_NAMED_UNMEASURED = 20

        # Bound on the unmeasured ACCUMULATOR, not just on what is named.
        # Entries arrive at two granularities — one per instance for a
        # document-level absence, one per probe for a probe-level one — so on
        # a large fleet the array would otherwise grow as instances x probes
        # before being reduced to MAX_NAMED_UNMEASURED. The count the signal
        # reports is then explicitly a FLOOR, never a fabricated total.
        MAX_UNMEASURED_PER_TICK = 500

        SETTING_PREFIX         = "system.module_verify"
        ACCOUNT_SETTING_PREFIX = "module_verify"

        def sense
          return [] unless defined?(::System::NodeInstance)

          failures   = {}
          unmeasured = []

          expected_instances.each do |instance, expected_modules|
            break if unmeasured.size >= MAX_UNMEASURED_PER_TICK

            report = verify_state(instance)
            reason = report_level_reason(report)
            if reason
              unmeasured << { instance: instance, reason: reason,
                              module_names: expected_modules.values.sort }
              next
            end

            by_module = index_modules(report)
            expected_modules.each do |module_id, module_name|
              module_report = by_module[module_id.to_s]
              collect(instance, module_id, module_name, module_report, failures, unmeasured)
            end
          end

          failure_signals(failures) + Array(not_measured_signal(unmeasured))
        end

        private

        # Instances the platform has actually ASKED to provide something
        # probeable — their node carries at least one module whose manifest
        # declares a `verify:` block — and that are currently talking to us.
        # An instance with no probe-declaring module is not silent about
        # verification; it was never given anything to verify.
        #
        # Returns [instance, {module_id => module_name}] pairs. The probe
        # declarations are parsed from NodeModule#config in Ruby (there is no
        # queryable column), so the module set is loaded ONCE per account and
        # reused across instances rather than re-parsed per node.
        def expected_instances
          modules = probe_declaring_modules
          return [] if modules.empty?

          by_node = modules_by_node(modules)
          return [] if by_node.empty?

          ::System::NodeInstance
            .where(account_id: account.id, node_id: by_node.keys)
            .where(last_heartbeat_at: live_heartbeat_seconds.seconds.ago..)
            .select(:id, :name, :node_id, :agent_version, :last_heartbeat_at, :config)
            .filter_map do |instance|
              declared = by_node[instance.node_id]
              [ instance, declared ] if declared.present?
            end
        end

        # {node_id => {module_id => module_name}} — "which node carries this
        # module", resolved the way the fleet actually attaches modules.
        #
        # THIS IS THE LINK THAT MUST NOT BE GUESSED. `System::NodeModule#node_id`
        # is NOT it: that column is the DEPENDANT-CHILD FK (see the `for_node`
        # note on NodeModule, where an earlier direct-column `where(node_id:)`
        # was removed as shadowed dead code in IMP-843c223063cf), and
        # ManifestImportService never writes it. A base module imported from a
        # manifest — which is every module that can carry a `verify:` block —
        # has node_id NULL, so keying on it matches no live instance and the
        # entire lane is inert while every unit spec stays green. That is
        # exactly the "producer exists, consumer never sees it" shape this
        # sensor was built to end, and it is why the spec attaches modules
        # through a real NodeModuleAssignment.
        #
        # Both production pathways, mirroring NodeApi::ModulesController
        # #node_modules — the agent's own resolver:
        #
        #   1. Base modules: an enabled System::NodeModuleAssignment row.
        #   2. Dependant children (NodeModuleAssignment#create_dependant!):
        #      parent_module_id + node_id set directly, NO assignment row.
        def modules_by_node(modules)
          by_node = Hash.new { |h, k| h[k] = {} }

          ::System::NodeModuleAssignment
            .where(node_module_id: modules.keys, enabled: true)
            .pluck(:node_id, :node_module_id)
            .each { |node_id, mid| by_node[node_id][mid] = modules[mid] if node_id }

          ::System::NodeModule
            .where(id: modules.keys, enabled: true)
            .where.not(parent_module_id: nil)
            .where.not(node_id: nil)
            .pluck(:node_id, :id)
            .each { |node_id, mid| by_node[node_id][mid] = modules[mid] }

          by_node
        end

        # {module_id => module_name} for every module on this account whose
        # manifest declares at least one probe. `config` is jsonb, so the
        # candidate set is narrowed in SQL (the key must be present at all —
        # served by index_system_node_modules_on_config) before ModuleVerify
        # parses each one. The literal `?` survives to Postgres as the jsonb
        # key-exists operator because the bind is NAMED: Rails only treats `?`
        # as a placeholder on the positional branch.
        def probe_declaring_modules
          ::System::NodeModule
            .where(account_id: account.id)
            .where("config ? :key", key: ::System::ModuleVerify::DECLARATION_KEY)
            .select(:id, :name, :config)
            .each_with_object({}) do |mod, acc|
              acc[mod.id] = mod.name if ::System::ModuleVerify.declared?(mod)
            end
        end

        def verify_state(instance)
          state = instance.config.is_a?(Hash) ? instance.config[::System::ModuleVerifyStateWriter::CONFIG_KEY] : nil
          state.is_a?(Hash) ? state : nil
        end

        # nil when the DOCUMENT is usable. Otherwise the reason it is not —
        # a whole-instance absence, reported once rather than per module.
        def report_level_reason(report)
          return "never_reported" if report.nil?

          observed = parse_time(report["observed_at"])
          return "never_reported" if observed.nil?
          return "stale_report"   if observed < report_fresh_seconds.seconds.ago

          nil
        end

        def index_modules(report)
          Array(report["modules"]).each_with_object({}) do |m, acc|
            acc[m["module_id"].to_s] = m if m.is_a?(Hash)
          end
        end

        def collect(instance, module_id, module_name, module_report, failures, unmeasured)
          if module_report.nil?
            unmeasured << { instance: instance, reason: "no_module_report",
                            module_names: [ module_name ] }
            return
          end

          # The agent's OWN clock for this module's last probe pass. The
          # document's `observed_at` only says when the report reached us, and
          # a wedged probe loop keeps re-shipping a frozen snapshot the server
          # would otherwise re-stamp as fresh on every tick — laundering a
          # long-dead verdict as current, and (if it was green) as healthy.
          probed_at = parse_time(module_report["observed_at"])
          if probed_at.nil? || probed_at < report_fresh_seconds.seconds.ago
            unmeasured << { instance: instance, reason: "stale_probe",
                            module_names: [ module_name ] }
            return
          end

          declared = module_report["declared_count"].to_i
          reported = module_report["reported_count"].to_i

          # ZERO probes reported is its own absence, and it must be stated.
          # Without this the module produces neither a failure nor an
          # unmeasured entry, and reads exactly like a verified-clean node.
          # It is also what a producer-side type drift produces: a
          # `declared_count` in a shape integer_or_nil rejects (a float, say)
          # becomes nil, nil.to_i is 0, and the partial_report guard below
          # silently disables itself.
          if reported.zero?
            unmeasured << { instance: instance, reason: "no_probes_reported",
                            module_names: [ module_name ] }
            return
          end

          if declared.positive? && reported < declared
            unmeasured << { instance: instance, reason: "partial_report",
                            module_names: [ module_name ] }
          end

          Array(module_report["probes"]).each do |probe|
            next unless probe.is_a?(Hash)

            case probe["status"]
            when ::System::ModuleVerifyStateWriter::FAIL
              record_failure(instance, module_id, module_name, probe, failures)
            when ::System::ModuleVerifyStateWriter::PASS
              next
            else
              # UNKNOWN / ERROR. Split on WHY, because "the agent only ran one
              # shell" and "the probe blew up" have different owners, and the
              # first is the exact half-measure this feature was specified to
              # make impossible.
              reason = probe["shells_covered"] ? "probe_error" : "shells_not_covered"
              unmeasured << { instance: instance, reason: reason,
                              module_names: [ module_name ] }
            end
          end
        end

        def record_failure(instance, module_id, module_name, probe, failures)
          key = [ instance.id, module_id, probe["name"].to_s ]
          # Bound the ACCUMULATOR, not just the emission: this sweep spans
          # every probe-carrying host on the account. One past the cap is
          # enough to know the sweep overflowed.
          return if !failures.key?(key) && failures.size > MAX_FAILURES_PER_TICK

          failing = Array(probe["shells"]).select do |s|
            s.is_a?(Hash) && s["status"] == ::System::ModuleVerifyStateWriter::FAIL
          end

          failures[key] ||= {
            instance: instance, module_id: module_id, module_name: module_name,
            probe: probe["name"].to_s, command: probe["command"].to_s,
            expected: probe["expected"].to_s,
            # The load-bearing payload. `resolved` is what the node's shell
            # ACTUALLY answered with — the difference between it and
            # `expected` IS the finding, and naming the shell is what tells an
            # operator whether they are chasing a profile script or a package.
            failing_shells: failing.map do |s|
              { "shell" => s["shell"], "resolved" => s["resolved"], "message" => s["message"] }
            end,
            shells_covered: probe["shells_covered"] ? true : false
          }
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
          shadowed = entry[:failing_shells].any? { |s| s["resolved"].present? }
          signal(
            kind: "system.module_verify_failed",
            severity: :high,
            payload: {
              "instance_id"    => instance.id,
              "instance_name"  => instance.name,
              "node_id"        => instance.node_id,
              "agent_version"  => instance.agent_version,
              "module_id"      => entry[:module_id],
              "module_name"    => entry[:module_name],
              "probe"          => entry[:probe],
              "command"        => entry[:command],
              "expected_path"  => entry[:expected],
              "failing_shells" => entry[:failing_shells],
              "shells_covered" => entry[:shells_covered],
              # TRUE when the name resolved to SOMETHING other than the
              # declared path — the shadowing case. FALSE means it resolved to
              # nothing (the binary is simply absent, e.g. the gitleaks v4
              # empty-artifact whiteout). Both are failures; they send an
              # operator to different places.
              "shadowed"       => shadowed,
              "summary"        => failure_summary(entry, shadowed),
              # No automated remediation: re-serving the same module cannot
              # change what the node resolved. See the class doc.
              "remediation_action" => nil
            },
            fingerprint: "module_verify_failed:#{instance.id}:#{entry[:module_id]}:#{entry[:probe]}"
          )
        end

        def failure_summary(entry, shadowed)
          shells = entry[:failing_shells].map do |s|
            "#{s['shell']}=#{s['resolved'].presence || '<unresolved>'}"
          end.join(", ")
          if shadowed
            "#{entry[:module_name]} probe #{entry[:probe]}: `#{entry[:command]}` resolves to a " \
            "DIFFERENT path than the manifest declares (#{entry[:expected]}) — #{shells}"
          else
            "#{entry[:module_name]} probe #{entry[:probe]}: `#{entry[:command]}` does not resolve at " \
            "all where the manifest declares #{entry[:expected]} — #{shells}"
          end
        end

        # Reports "more than N", never a total — the sweep stopped at the cap
        # and has not counted the remainder, so inventing one would be the
        # same fabrication this sensor exists to stop.
        def failure_overflow_signal(emitted_count)
          signal(
            kind: "system.module_verify_failed",
            severity: :high,
            payload: {
              "overflow"      => true,
              "emitted_count" => emitted_count,
              "summary"       => "more than #{emitted_count} module verify probes are failing across " \
                                 "this account's fleet; only the first #{emitted_count} are itemised this tick",
              "remediation_action" => nil
            },
            fingerprint: "module_verify_failed_overflow:#{account.id}"
          )
        end

        # ONE signal per account, deliberately. The expected initial state of a
        # fleet is "every node still runs an agent with no probe runner", so a
        # per-instance fingerprint would be a rollout-sized storm of one fact.
        # The count and the named sample ride the payload, which changes freely
        # without changing the fingerprint — so the lane dedups while still
        # showing an operator the current extent.
        def not_measured_signal(unmeasured)
          return nil if unmeasured.empty?

          capped = unmeasured.size >= MAX_UNMEASURED_PER_TICK
          named  = unmeasured.first(MAX_NAMED_UNMEASURED).map do |u|
            {
              "instance_id"   => u[:instance].id,
              "instance_name" => u[:instance].name,
              "agent_version" => u[:instance].agent_version,
              "modules"       => Array(u[:module_names]),
              "reason"        => u[:reason]
            }
          end

          signal(
            kind: "system.module_verify_not_measured",
            severity: :medium,
            payload: {
              # A count of OBSERVATIONS (instance-level absences plus
              # probe-level ones), not of instances — the two are different
              # granularities and calling it an instance count would
              # overstate. `count_is_floor` says so when the sweep stopped at
              # the cap: reporting a total it never finished counting would be
              # the same fabrication this sensor exists to stop.
              "observation_count" => unmeasured.size,
              "count_is_floor"    => capped,
              "reasons"           => unmeasured.group_by { |u| u[:reason] }.transform_values(&:size),
              "instances"         => named,
              "truncated"         => unmeasured.size > MAX_NAMED_UNMEASURED,
              "summary"           => "#{capped ? 'at least ' : ''}#{unmeasured.size} module verify " \
                                     "observation(s) are missing or incomplete — those modules are " \
                                     "UNVERIFIED, not healthy",
              "remediation_action" => nil
            },
            fingerprint: "module_verify_not_measured:#{account.id}"
          )
        end

        def report_fresh_seconds
          @report_fresh_seconds ||= setting_seconds("report_fresh_seconds", DEFAULT_REPORT_FRESH_SECONDS)
        end

        def live_heartbeat_seconds
          @live_heartbeat_seconds ||= setting_seconds("live_heartbeat_seconds", DEFAULT_LIVE_HEARTBEAT_SECONDS)
        end

        # Per-account first, then the deployment-wide SiteSetting, then the
        # constant — the same resolution order as SdwanApplyHealthSensor. A
        # non-positive configured value is treated as unset rather than
        # collapsing the window to zero (which would mark the fleet unmeasured).
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
