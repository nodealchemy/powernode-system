# frozen_string_literal: true

module System
  module Fleet
    # Autonomy reconciler for the System extension fleet. Follows the
    # platform's standard overseer-autonomy shape — same gate_action!, same
    # dedup, same TTL, same ApprovalRequest shape — so the operator approval
    # UI surfaces fleet decisions identically to every other domain's.
    #
    # Reference: Golden Eclipse plan M7. The cross-cutting design property is
    # that nothing in this service hardcodes "fleet" semantics; only the
    # ADVANCEMENT_ACTIONS set, the source_type, and the chain lookup are
    # domain-specific. Everything else follows the shared pattern row-for-row.
    class FleetAutonomyService
      # Emergency kill-switch is authoritative across every reconciler — a halt
      # must stop the fleet reconcile loop, not just the AI execution jobs.
      include ::System::Autonomy::KillSwitchGuard
      include ::System::Autonomy::ControlPlaneGuard
      # Supplies the shared unpermitted-action refusal (and GATE_POLICY_MISSING)
      # that tells a routed-but-unseeded lane from an ordinary refusal.
      include ::System::Autonomy::RoutedLaneGuard

      attr_reader :account, :agent, :role

      # Actions that represent fleet-wide advancement (live promotion,
      # fleet upgrade roll, region expansion). These get the longer TTL
      # (4h) so operators have meaningful review time.
      ADVANCEMENT_ACTIONS = %w[
        system.module_promote_to_live
        system.fleet_rolling_upgrade
        system.node_boot_image_drift
        system.region_expansion
        system.package_module.create
        system.package_module.refresh
      ].freeze

      SOURCE_TYPE = "system_fleet"

      def initialize(account:, agent:, role: nil)
        @account = account
        @agent = agent
        @role = role
        @policy_service = ::Ai::InterventionPolicyService.new(account: account)
      end

      # Class-level entry point for the periodic reconcile tick. Finds the
      # fleet autonomy agent for the account, runs every sensor, routes
      # signals through the DecisionEngine, and records outcomes via the
      # LearningExtractor. Returns a structured tick summary.
      def self.tick!(account:, control_plane_reading: nil)
        agent = ::Ai::Agent.resolve_for(account.id, name: "Fleet Autonomy", agent_type: "monitor")&.tap { |a| a.resolving_account = account }
        return { ok: false, reason: "Fleet Autonomy agent not seeded for account" } unless agent

        service = new(account: account, agent: agent)
        service.tick!(control_plane_reading: control_plane_reading)
      end

      def tick!(control_plane_reading: nil)
        # Authoritative kill-switch check FIRST — an engaged emergency halt
        # no-ops the entire reconcile (no sensing, deciding, reaping, or task
        # dispatch) before any state is touched.
        return halted_tick_result if kill_switch_engaged?

        # Dual-plane fence SECOND: on the standby plane the tick must do
        # nothing — the active plane owns actuation (ControlPlaneRole is the
        # split-brain gate; inert unless the coordinator SiteSetting arms it).
        # A caller-carried pass-scoped reading is honored; freshness is still
        # enforced on it inside active?.
        return standby_tick_result unless control_plane_active?(reading: control_plane_reading)

        # Sweep BEFORE sensing: expired pending approvals must transition
        # (timeout_action) so the rejected-cooldown — not a fresh duplicate
        # request — absorbs any still-firing signal in this same tick.
        expire_stale_approvals!

        tick_correlation = "tick:#{SecureRandom.hex(8)}"
        ::System::Fleet::EventBroadcaster.emit!(
          account: account, kind: "fleet.tick_started", severity: :low,
          payload: { agent_id: agent.id }, source: "fleet_autonomy", correlation_id: tick_correlation
        )

        # Sample fresh project metrics for every active infrastructure
        # mission BEFORE the sensor pass so ProjectSloSensor sees a current
        # snapshot. Per-mission rescue keeps one bad collection from
        # breaking the entire tick.
        collect_project_metrics!(correlation_id: tick_correlation)

        signals, failed_sensors = collect_signals

        # Self-improvement Phase 0 — the validate step. Score the PREVIOUS tick's
        # remediations against THIS fresh sense pass before deciding anew: a prior
        # action whose triggering signal fingerprint is gone was effective; still
        # present means it didn't stick. Closes sense -> act -> VALIDATE. Best-
        # effort — a validator hiccup must never break the autonomy tick.
        # F3-11(a): failed sensors are passed through so the validator never
        # scores a crashed sensor's missing fingerprints as "effective".
        validator = ::System::Fleet::RemediationValidator.new(account: account, agent: agent)
        validation = safe_validate(validator, signals, failed_sensors)

        engine = DecisionEngine.new(autonomy_service: self)

        # F3-01: consume the approved lane BEFORE deciding anew — an operator
        # approval from a prior tick executes here (pull model), so the
        # require_approval gate is no longer a dead end.
        approved_executed = execute_approved_actions!(engine, validator: validator,
                                                              correlation_id: tick_correlation)

        decisions = engine.decide_all(signals)
        LearningExtractor.record_tick!(account: account, decisions: decisions)

        # Snapshot newly-PROCEEDED remediations so a later tick can validate them.
        recorded = safe_record(validator, decisions, signals, tick_correlation)

        # After decisions land, emit fleet-side stigmergic signals so trading
        # + other subsystems can perceive the current pressure state. Best-effort.
        ::System::Fleet::PressureEmitter.emit_for_account!(account: account) if defined?(::System::Fleet::PressureEmitter)

        ::System::Fleet::EventBroadcaster.emit!(
          account: account, kind: "fleet.tick_complete", severity: :low,
          payload: {
            signal_count: signals.size,
            decision_count: decisions.size,
            by_decision: decisions.group_by { |d| d[:decision] }.transform_values(&:size),
            validated: validation,
            remediations_recorded: recorded,
            approved_executed: approved_executed.size
          },
          source: "fleet_autonomy", correlation_id: tick_correlation
        )

        {
          ok: true,
          signal_count: signals.size,
          decision_count: decisions.size,
          by_kind: decisions.group_by { |d| d[:signal_kind] }.transform_values(&:size),
          by_decision: decisions.group_by { |d| d[:decision] }.transform_values(&:size),
          validated: validation,
          remediations_recorded: recorded,
          approved_executed: approved_executed.size,
          correlation_id: tick_correlation
        }
      end

      # Returns [signals, failed_sensor_names]. F3-11(a): the per-sensor rescue
      # keeps one bad sensor from breaking the tick, but it also removes that
      # sensor's fingerprints from the pass — so the failures must be REPORTED,
      # not just logged, or the validator scores the absence as "effective".
      def collect_signals
        signals = []
        failed = []
        SENSORS.each do |sensor_class|
          signals.concat(sensor_class.new(account: account).sense)
        rescue StandardError => e
          failed << sensor_class.name.demodulize
          Rails.logger.error("[FleetAutonomy] sensor #{sensor_class.name} failed: #{e.message}")
        end
        [ signals, failed ]
      end

      # Best-effort wrappers — a self-improvement validator hiccup must never
      # break the core autonomy tick (sense + decide must always run).
      def safe_validate(validator, signals, failed_sensors = [])
        validator.validate_due!(current_signals: signals, failed_sensors: failed_sensors)
      rescue StandardError => e
        Rails.logger.error("[FleetAutonomy] remediation validation failed: #{e.class}: #{e.message}")
        { effective: 0, ineffective: 0, inconclusive: 0 }
      end

      def safe_record(validator, decisions, signals, correlation_id)
        validator.record_proceeded!(decisions: decisions, signals: signals, correlation_id: correlation_id)
      rescue StandardError => e
        Rails.logger.error("[FleetAutonomy] remediation recording failed: #{e.class}: #{e.message}")
        0
      end

      # Pre-sensor metrics sampling. Walks active infrastructure missions
      # and writes a fresh batch of `System::ProjectMetric` rows so that
      # `ProjectSloSensor.sense` reads current observations from the DB
      # rather than the legacy `mission.configuration["latest_observations"]`
      # test seam. Each mission's collection is rescued individually so a
      # single bad mission can't crash the tick.
      def collect_project_metrics!(correlation_id:)
        return unless defined?(::System::ProjectMetricsCollector)

        ::Ai::Mission
          .where(account_id: account.id, mission_type: "infrastructure", status: "active")
          .find_each do |mission|
            ::System::ProjectMetricsCollector.collect!(
              mission: mission,
              correlation_id: correlation_id
            )
          rescue StandardError => e
            Rails.logger.warn(
              "[FleetAutonomy] project metrics collection failed for mission=#{mission.id}: " \
              "#{e.class}: #{e.message}"
            )
          end
      rescue StandardError => e
        Rails.logger.error("[FleetAutonomy] project metrics tick failed: #{e.class}: #{e.message}")
      end

      SENSORS = [
        # The OUTCOME oracle for the task janitor. Reads the property the
        # reaper maintains, never the reaper's own self-report — see the
        # sensor for why five weeks of green "0 reaped, success" logs proved
        # nothing.
        ::System::Fleet::Sensors::StuckTaskBacklogSensor,
        ::System::Fleet::Sensors::InstanceStatusSensor,
        # IMP-e2f53e87d090 (APO-2b) — the DR classifier for the population
        # InstanceStatusSensor watches. A silent instance whose VM the provider
        # calls terminated/error, whose host has no usable connection, or whose
        # reboots the validate arc already scored ineffective cannot be
        # rebooted back; it emits system.instance_unrecoverable on the distinct
        # system.instance_replace lane instead of another reboot proposal.
        ::System::Fleet::Sensors::InstanceUnrecoverableSensor,
        # Provider-side state drift (e.g. libvirt domstate=shut-off while
        # the model says status=running). Complementary to InstanceStatusSensor
        # which watches heartbeat staleness. Together they distinguish
        # agent-crashed-but-VM-up vs VM-itself-stopped.
        ::System::Fleet::Sensors::InstanceStateDriftSensor,
        ::System::Fleet::Sensors::ModuleDriftSensor,
        # Campaign 019f6084 §2.4.3 — ModuleDriftSensor only diffs a running
        # instance's digests against its ALREADY-ASSIGNED modules; it never
        # re-resolves the template, so a template mutation (a new
        # TemplateModule, or a new `requires` edge on an existing one)
        # never reaches an already-provisioned instance. This sensor closes
        # that gap → system.template_closure_apply gate.
        ::System::Fleet::Sensors::TemplateClosureDriftSensor,
        # Boot-image drift: a running node booted a stale disk image (its
        # reported booted_image_git_sha != the platform's promoted
        # disk_image_git_sha). Campaign 019f505f increment 1 — observation-only
        # (no remediation outcome); increment 4 routes it to the rollout executor.
        ::System::Fleet::Sensors::BootImageDriftSensor,
        ::System::Fleet::Sensors::CertificateExpirySensor,
        # Platform ACME (Traefik-terminated) cert expiry — distinct store +
        # remediation path from CertificateExpirySensor (node identity certs).
        # Emits system.acme_cert_expiring → platform_maintenance cert_rotate.
        ::System::Fleet::Sensors::CertExpirySensor,
        ::System::Fleet::Sensors::ModulePromotionSensor,
        # Asserts that what a module has BUILT and what the fleet RUNS have
        # converged, and alarms when they have not. Deliberately keyed on
        # NodeModule#current_version_id (the only thing agents materialize) and
        # NOT on promotion_state, and deliberately derived from STATE rather
        # than from the absence of a withheld event — the 2026-08-25 stall
        # emitted refusals, stopped emitting them, and still never promoted, so
        # an event-absence detector would have stayed silent throughout.
        # Notify-level: emits system.module_promotion_stalled, bound to
        # system.module_promotion_investigate (skill: nil) so the stall gets a
        # separately tunable, operator-facing policy row rather than the silent
        # auto-approved bucket. (notify_and_proceed's extra step is
        # #notify_action below — a Rails.logger line, not an operator page.)
        # No applier by design — see the binding's comment.
        ::System::Fleet::Sensors::ModulePromotionBacklogSensor,
        # `capability:<tag>` requirements no module on the account provides.
        # Advisory only — closing a gap means authoring a module, which must
        # pass the human reuse gate (see the sensor's own doc).
        ::System::Fleet::Sensors::CapabilityGapSensor,
        ::System::Fleet::Sensors::ConfigDriftSensor,
        ::System::Fleet::Sensors::SloViolationSensor,
        ::System::Fleet::Sensors::HoneypotAccessSensor,
        ::System::Fleet::Sensors::TradingPressureSensor,
        # Slice 5 of the SDWAN plan.
        ::System::Fleet::Sensors::SdwanDriftSensor,
        ::System::Fleet::Sensors::SdwanReachabilitySensor,
        # Slice 9f of the SDWAN plan: routing observability + autonomy.
        ::System::Fleet::Sensors::SdwanBgpSessionHealthSensor,
        ::System::Fleet::Sensors::SdwanVipReachabilitySensor,
        # Phase 6c — GitOps drift detection
        ::System::Fleet::Sensors::GitopsDriftSensor,
        # M2 of the AI-driven provisioning conversation — adaptive evolution.
        # Watches active infrastructure missions for SLO violations, brief
        # drift, and cost breaches. Emits project.* signals.
        ::System::Fleet::Sensors::ProjectSloSensor,
        # Phase 3c — federation peer liveness (stale heartbeat + cert expiry).
        # Emits system.federation_peer_liveness → federation_peer_remediate.
        ::System::Fleet::Sensors::FederationPeerLivenessSensor,
        # Audit F3-07 — written but never registered until now:
        # upstream package version drift → package_repository.sync gate.
        ::System::Fleet::Sensors::PackageDriftSensor,
        # SDWAN membership-credential expiry + stalled-refresh watch
        # → sdwan_credential_refresh gate / observation.
        ::System::Fleet::Sensors::SdwanCredentialExpirySensor,
        # Storage assignments stuck pending/degraded/failed
        # → storage_assignment_reconcile gate.
        ::System::Fleet::Sensors::StorageAssignmentDriftSensor,
        # DK3 of the disk-image-CI restoration — a platform whose last N
        # publications all failed. Pragmatic placement: this is disk-image
        # domain (normally Disk Image Manager's queue), but it fires here
        # because Fleet Autonomy's SENSORS array is the only sensor tick
        # that runs today; a dedicated DiskImageOps tick is a noted
        # follow-up if/when Disk Image Manager grows its own sense pass.
        # Mirrors the GitopsDriftSensor precedent (surfaced signal without
        # owning the tick it runs in) → system.disk_image_publication_investigate
        # gate, which is seeded on THIS agent (fleet_autonomy_agent.rb) for
        # the same reason federation_peer_remediate/sdwan_* live there.
        ::System::Fleet::Sensors::DiskImagePublicationFailureStreakSensor,
        # IMP-c7d663f24a0b — the first SERVICE-level SDWAN sensor. The other
        # five sdwan_* sensors answer "is the pipe up?"; this one correlates
        # already-ingested IPFIX FlowSamples against each active service's
        # backend VIP+port to answer "is the thing at the end serving?", and
        # flags enabled DNAT rules whose target no longer resolves. Emits
        # system.sdwan_service_silent / system.sdwan_portmap_orphaned →
        # system.sdwan_service_health_investigate (notify-level; no
        # auto-remediation until the signal quality is proven).
        ::System::Fleet::Sensors::SdwanServiceHealthSensor,
        # IMP-57e9a90598ee — visibility for the OVN activation lane. The
        # DeploymentReconciler transitions Sdwan::OvnDeployment at heartbeat
        # ingest (where the observations are); this sensor surfaces the
        # resulting degraded / stalled states on the tick. Notify-only →
        # system.sdwan_ovn_deployment_investigate (no applier by design:
        # the failing component is OVN control infrastructure the platform
        # does not provision).
        ::System::Fleet::Sensors::SdwanOvnDeploymentHealthSensor,
        # IMP-da1b772c2596 — the SDWAN APPLY oracle. Every other sdwan_*
        # sensor scores the platform's own work (compiled, served,
        # handshook); this one reads the agent's observed per-subsystem
        # APPLY outcome, which nothing on the server consumed until now — a
        # node whose nftables/vrf/bridge apply failed on every tick was
        # indistinguishable from one that applied cleanly. Emits
        # system.sdwan_apply_failed / system.sdwan_apply_not_measured →
        # system.sdwan_apply_investigate (notify-level; no applier exists,
        # because the agent already retries the apply every tick).
        ::System::Fleet::Sensors::SdwanApplyHealthSensor,
        # IMP-7034199a5a19 — the POST-ISSUE half of user-device config
        # correctness. WgConfigRenderer gets AllowedIPs right at download
        # time; a user device never re-pulls, so every VIP / lan_subnet /
        # federation prefix added afterwards is absent from every config
        # already in the field. Emits system.sdwan_user_device_config_stale →
        # system.sdwan_user_device_config_investigate (notify-only; the
        # drifted file lives on a laptop the platform cannot reach).
        ::System::Fleet::Sensors::SdwanUserDeviceConfigStalenessSensor,
        # IMP-3855ff9908f2 — the `verify:` probe oracle. ModuleDriftSensor
        # scores digests and ModulePromotionSensor scores publication; neither
        # can say whether the capability a module exists to provide is
        # REACHABLE on the node afterwards. The agent answers that from the
        # manifest's verify: block on every heartbeat. Emits
        # system.module_verify_failed / system.module_verify_not_measured ->
        # system.module_verify_investigate (notify-only; no applier exists,
        # because re-serving the same artifact cannot change what the node
        # resolved — the gitleaks v4 empty-artifact incident is the proof).
        ::System::Fleet::Sensors::ModuleVerifyFailedSensor,
        # IMP-a8f9fa74284d — the boot/LKG ARM oracle. BootLkgStateWriter has
        # derived `arm_state` from the agent's heartbeat since IMP-b8d5cfa33b79
        # and nothing consumed it, so "is this node armed with a valid
        # last-known-good?" was answerable but never asked — leaving the
        # question an operator faces before pulling a control plane answered by
        # the absence of an alarm. Emits system.node_lkg_unarmed /
        # system.node_lkg_stale -> system.node_lkg_investigate (notify-only; no
        # applier exists and none can, because the LKG is frozen on the node's
        # own disk). Runs HERE because this tick gates as the Fleet Autonomy
        # agent, which is the agent its policy is declared on.
        ::System::Fleet::Sensors::BootLkgArmSensor
      ].freeze

      # Scoped to THIS account. The fleet agents are seeded global (account_id
      # nil, one shared row), so every account's policy rows hang off the same
      # ai_agent_id — without the account filter this pre-gate answered from
      # every tenant's rows at once. That is not merely an over-broad list: the
      # pre-gate is the block/no-block discriminator, so a foreign row turned
      # this account's GATE_POLICY_MISSING refusal into a live approval
      # request. `.all_fleet_actions` below has always filtered by account;
      # this is the same scope.
      def permitted_actions
        @permitted_actions ||= ::Ai::InterventionPolicy
          .where(account: account, ai_agent_id: agent.id, scope: "agent", is_active: true)
          .pluck(:action_category)
      end

      def self.all_fleet_actions(account)
        ::Ai::InterventionPolicy
          .where(account: account, scope: "agent", is_active: true)
          .where("action_category LIKE 'system.%' OR action_category LIKE 'project.%'")
          .distinct
          .pluck(:action_category)
      end

      # force_policy (F3-11): the DecisionEngine's stuck-remediation consumer
      # overrides the resolved policy (e.g. forcing "require_approval" after N
      # consecutive ineffective outcomes) — mirroring the consent-budget
      # precedent where a feedback signal outranks the configured policy.
      # F3-01 — the act arm of the require_approval lane. Polls approved
      # system_fleet requests that have not been executed yet (no
      # request_data["execution"] stamp), replays each through the engine
      # (execute_approved!), and stamps the result so a request executes
      # exactly once. Per-request rescue: one failure never starves the
      # rest, and a failed execution is stamped (not retried forever).
      def execute_approved_actions!(engine, validator: nil, correlation_id: nil)
        return [] unless defined?(::Ai::ApprovalRequest)

        executed = []
        ::Ai::ApprovalRequest
          .approved
          .where(account: @account, source_type: SOURCE_TYPE)
          .where("request_data->'execution' IS NULL")
          .find_each do |request|
            result = engine.execute_approved!(request)
            stamp_execution!(request, result)
            # IMP-31f1e5f9b365 — the VALIDATE arm of this lane. Deliberately
            # NOT in the rescue below: a raised replay actuated nothing.
            record_approved_outcome!(validator, engine, request, result, correlation_id)
            executed << { request_id: request.id, applied: result[:applied] == true }
          rescue StandardError => e
            Rails.logger.error("[FleetAutonomy] approved execution failed for ApprovalRequest #{request.id}: #{e.class}: #{e.message}")
            stamp_execution!(request, { applied: false, error: "#{e.class}: #{e.message}" })
            executed << { request_id: request.id, applied: false, error: e.message }
          end
        executed
      end

      # IMP-31f1e5f9b365: the `gate` stamped on a RemediationOutcome minted by
      # the approved lane, distinguishing it on the row from a proceed-lane
      # outcome (whose gate is the resolved policy). Provenance for a dashboard
      # or an operator reading the validate arc; nothing branches on it.
      GATE_APPROVED_EXECUTION = "require_approval_executed"

      # `advisory` marks a decision that surfaces a condition without ever
      # actuating (DecisionEngine bindings tagged advisory: true — no skill,
      # no REMEDIATION_APPLIERS entry). Two gate behaviors change for them,
      # both because an advisory condition STANDS for as long as it takes a
      # human to act, rather than resolving on a fleet tick's timescale: the
      # per-module consent budget is not consumed (below), and an operator's
      # decision on the request is durable (create_pending_approval).
      # DECLARED SUPPRESSION CAUSES (IMP-fec9abb225c6).
      #
      # #create_pending_approval returns nil down four different paths, and from
      # the outside every one of them looks identical: decision: :pending with no
      # decision_record. A caller that has to ACT on the difference — the
      # adaptation lane raises an operator alarm on it — was left inferring, and
      # inferred wrong: it reported an operator's own rejection as a missing
      # policy. The cause is now stated rather than guessed.
      SUPPRESSION_REJECTION_COOLDOWN = "rejection_cooldown"
      SUPPRESSION_SETTLED_ADVISORY   = "settled_advisory"
      SUPPRESSION_NO_REQUEST_STORE   = "no_chain_or_request_store"

      def gate_action!(action_category, metadata: {}, reasoning: {}, temporal_context: {},
                       force_policy: nil, advisory: false)
        @suppression = nil

        # The whole unpermitted arm lives in System::Autonomy::RoutedLaneGuard —
        # it distinguishes a routed-but-unseeded lane (a deploy defect, blocked
        # LOUDLY as GATE_POLICY_MISSING) from an ordinary refusal, and it is
        # shared with every other gate_action! so the distinction cannot reach
        # one gate and miss another (IMP-b400ec1a2df8: it did exactly that).
        unless permitted_actions.include?(action_category)
          return refuse_unpermitted_action(action_category)
        end

        # Per-module consent budget check — applied before policy resolution.
        # When the budget is exhausted, the action is forced through
        # require_approval regardless of policy. Module-less actions skip.
        #
        # IMP-4019664a524b: advisory decisions consume NOTHING. The budget is
        # the operator's ceiling on autonomous ACTIONS taken against a module;
        # an advisory takes none, but it re-decides every dedup TTL for as long
        # as the condition stands (144x/day at 600s), which drained the whole
        # 24h ceiling and pushed that module's real remediations down the
        # budget-exhausted branch below.
        unless advisory
          consent_module_id = metadata&.dig("module_id") || metadata&.dig(:module_id) ||
                              metadata&.dig("payload", "module_id") || metadata&.dig(:payload, :module_id)
          consent = ::System::Fleet::ConsentBudgetService.check_and_consume!(module_id: consent_module_id)
          unless consent.allowed
            Rails.logger.info("[FleetAutonomy] Consent budget exhausted for #{action_category}: #{consent.reason}")
            # Force into require_approval pathway — operator must explicitly
            # extend the budget via Module Detail UI or by approving the request.
            request = create_pending_approval(
              action_category: action_category,
              metadata: metadata.merge("budget_exhaustion" => consent.reason),
              reasoning: reasoning,
              temporal_context: temporal_context
            )
            return { decision: :pending, gate: "consent_budget_exhausted",
                     decision_record: request, budget_reason: consent.reason,
                     suppression: @suppression }
          end
        end

        result = if force_policy
          { policy: force_policy, source: "decision_engine_override" }
        else
          @policy_service.resolve(action_category: action_category, agent: @agent)
        end

        case result[:policy]
        when "auto_approve"
          { decision: :proceed, gate: "auto_approve" }
        when "notify_and_proceed"
          notify_action(action_category, metadata: metadata, reasoning: reasoning)
          { decision: :proceed, gate: "notify_and_proceed" }
        when "require_approval"
          request = create_pending_approval(
            action_category: action_category,
            metadata: metadata,
            reasoning: reasoning,
            temporal_context: temporal_context,
            advisory: advisory
          )
          # `suppression` is nil whenever a request was actually minted; it names
          # WHY not when one wasn't.
          { decision: :pending, gate: "require_approval", decision_record: request,
            suppression: @suppression }
        when "block", "silent"
          { decision: :blocked, gate: result[:policy] }
        else
          { decision: :blocked, gate: "unknown_policy" }
        end
      end

      # IMP-01a025b3: is there already a live operator obligation for exactly
      # the request #gate_action! would mint for this (action_category, metadata)?
      #
      # "Open" means "re-gating would produce no NEW operator-facing artifact",
      # and it mirrors #create_pending_approval's three suppression arms
      # one-for-one, read straight off the DATABASE (never Rails.cache — the hub
      # runs CACHE_STORE=memory_store, which is per-Puma-process and flushes on
      # restart, so the cache can only ever be an optimization here, never the
      # correctness mechanism):
      #
      #   1. a PENDING request on the same dedup key — the gate would find that
      #      row and merely update it in place;
      #   2. a request on that key REJECTED inside #decision_ttl_for's cooldown;
      #   3. ANY request in the same action_category rejected inside that
      #      cooldown — the gate's action-level fallback, which suppresses
      #      regardless of dedup key. Omitting this arm left the caller
      #      escalating (and consuming consent budget) into a window where the
      #      gate mints nothing, which is the exact drain this exists to stop.
      #
      # Everything else is NOT open, deliberately: approved, expired, cancelled,
      # and rejected-past-cooldown all re-mint, so a caller that suppresses on
      # this predicate re-alerts the next time the condition is seen. The
      # failure mode being avoided in that direction is a lane that alerts once
      # and then goes silent forever, which is worse than the noise.
      #
      # An unattended PENDING request is normally self-limiting: it carries
      # expires_at (the chain's timeout_hours — 4h on the seeded fleet chain),
      # and #expire_stale_approvals! at tick start fires timeout_action
      # ("reject"), moving it into arm 2 and then out of it. That is a property
      # of the CHAIN, not of the schema: timeout_hours is nullable with no
      # default, and Ai::ApprovalChain#create_request! leaves expires_at NULL
      # when it is blank. Both expiry sweeps filter on `expires_at < ?`, which
      # NULL never satisfies, so a fleet chain configured without a timeout
      # suppresses this lane for as long as the request sits unanswered.
      #
      # Resolution is via #dedup_key_for so the row inspected here is EXACTLY
      # the row the gate would act on — a divergent key would silence on one
      # identity while minting on another. Two known divergences, both
      # unreachable today and both stated rather than assumed: the advisory
      # settled-request arm (#settled_advisory_request) is not modeled — no
      # advisory binding can reach a stuck streak, since advisory outcomes are
      # never recorded — and the dedup key is COARSER than a fingerprint for
      # actions keyed on module/template identity, so one open request stands
      # for every fingerprint sharing that key.
      #
      # Fails OPEN (false) on any error: a broken query must never be able to
      # suppress an operator alert. Logged at error level because that
      # fail-open silently restores the incident this predicate prevents.
      def open_operator_request?(action_category, metadata: {})
        return false unless defined?(::Ai::ApprovalRequest)

        if (key = dedup_key_for(action_category, metadata))
          name, value = key
          return true if pending_fleet_approvals
            .where("request_data->>'action_category' = ?", action_category)
            .where("request_data->'payload'->>? = ?", name, value)
            .exists?

          return true if recently_rejected_approval?(action_category,
              [ "request_data->>'action_category' = ? AND request_data->'payload'->>? = ?",
               action_category, name, value ])
        end

        recently_rejected_approval?(action_category,
          [ "request_data->>'action_category' = ?", action_category ])
      rescue StandardError => e
        Rails.logger.error("[FleetAutonomy] open-request check failed for #{action_category} " \
                           "(failing open — escalation will re-fire): #{e.class}: #{e.message}")
        false
      end

      def policy_for(action_category)
        @policy_service.resolve(action_category: action_category, agent: @agent)
      end

      def all_policies
        permitted_actions.each_with_object({}) do |action, hash|
          hash[action] = policy_for(action)
        end
      end

      private

      def notify_action(action_category, metadata:, reasoning:)
        Rails.logger.info("[FleetAutonomy] Auto-execute: #{action_category} — #{reasoning[:summary]&.truncate(120)}")
      end

      def decision_ttl_for(action_category)
        ADVANCEMENT_ACTIONS.include?(action_category) ? 4.hours : 1.hour
      end

      # Dedup key resolution. Different fleet actions key off different
      # metadata fields — instance_id for instance-class actions, template_id
      # for template-class actions, module_id for promotion. Returns
      # ["request_data->'payload'->>'KEY' = ?", value] pairs to merge into
      # the WHERE clause.
      def dedup_key_for(action_category, metadata)
        natural_key = case action_category
        when "system.instance_reprovision", "system.instance_reboot",
             # IMP-e2f53e87d090 — the DR replace lane is per-instance too, so
             # a re-emitted unrecoverable signal updates the one open approval
             # rather than queueing another.
             "system.instance_replace",
             "system.cert_rotate", "system.cert_revoke",
             # Observation signals never create remediation outcomes
             # (see RemediationValidator#record_proceeded!), so they should not
             # reach require_approval on the normal path — but dedup per instance
             # defensively so a future escalation can't mint one approval per tick
             # (boot-image drift carries instance_id in its payload).
             "system.observation"
          key_value(metadata, "instance_id")
        # Honeypot quarantine (F3-08): the access signal may carry no
        # instance when nothing currently hosts the canary module — fall
        # back to per-module dedup so repeated canary probes update one
        # approval instead of minting one per access event.
        when "system.instance_terminate"
          key_value(metadata, "instance_id") || key_value(metadata, "module_id")
        when "system.module_promote_to_live", "system.module_assign"
          key_value(metadata, "module_id") || key_value(metadata, "module_version_id")
        # Platform ACME cert rotation — per-cert dedup so the expiry sensor
        # re-firing each tick doesn't queue duplicate approvals/notifications.
        when "system.acme_cert_rotate"
          key_value(metadata, "certificate_id")
        when "system.fleet_rolling_upgrade", "system.region_expansion",
             "system.capacity_resize"
          key_value(metadata, "template_id")
        # Boot-image drift rollout (campaign 019f505f inc 4): the sensor emits one
        # signal per drifted instance, but the rollout is per-platform — dedup on
        # platform_id (carried TOP-LEVEL in the sensor's signal payload, so it
        # survives into the decision metadata and the execute_approved! replay) so
        # a fleet-wide drift collapses to ONE approval instead of one per node.
        when "system.node_boot_image_drift"
          key_value(metadata, "platform_id") || key_value(metadata, "instance_id")
        when "system.cve_remediate"
          key_value(metadata, "cve_id")
        # Federation peer remediation — per-peer dedup so a peer flapping in and
        # out of staleness (heartbeat or cert) doesn't queue a duplicate
        # ApprovalRequest every 60s tick. Mirrors system.sdwan_peer_remediate;
        # the sensor stamps federation_peer_id onto the signal payload.
        when "system.federation_peer_remediate"
          key_value(metadata, "federation_peer_id")
        # Slice 5 of the SDWAN plan: per-peer dedup for remediation/rotation/
        # failover — and (IMP-df40782d3f4d) credential refresh, whose sensor
        # re-fires each tick while an MC sits in the expiry window; per-device
        # for revocation. Without these, repeat sensor firings would queue
        # duplicate ApprovalRequests every tick.
        when "system.sdwan_peer_remediate",
             "system.sdwan_key_rotate",
             "system.sdwan_credential_refresh",
             "system.sdwan_failover"
          key_value(metadata, "peer_id") || key_value(metadata, "network_id")
        when "system.sdwan_user_device_revoke"
          key_value(metadata, "user_device_id")
        # Slice 9f — iBGP session remediation dedup'd on (peer, neighbor)
        # pair so a flapping single session doesn't create N approvals
        # per tick. VIP failover dedup'd on the VIP id.
        when "system.sdwan_bgp_session_remediate"
          key_value(metadata, "neighbor_address") || key_value(metadata, "peer_id")
        when "system.sdwan_vip_failover"
          key_value(metadata, "virtual_ip_id")
        # M2 of the AI-driven provisioning conversation. Project-scoped
        # actions dedup on `mission_id` (the project identifier) so that
        # repeat sensor firings for the same breaching mission collapse
        # into a single ApprovalRequest per tick window.
        when "project.adapt", "project.cost_control", "project.scale_horizontal",
             "project.relocate", "project.schema_change", "project.security_change"
          key_value(metadata, "mission_id")
        # Package repository ingestion — dedup at the natural granularity:
        # per-repo for syncs, per (repo, package) for create, per-link for refresh.
        when "system.package_repository.sync"
          key_value(metadata, "package_repository_id")
        when "system.package_module.create"
          repo = metadata&.dig("package_repository_id") || metadata&.dig(:package_repository_id)
          pkg  = metadata&.dig("package_name") || metadata&.dig(:package_name)
          repo.present? && pkg.present? ? [ "package_create_key", "#{repo}:#{pkg}" ] : nil
        when "system.package_module.refresh"
          key_value(metadata, "package_module_link_id")
        # Storage assignment re-reconciliation — per-assignment dedup.
        when "system.storage_assignment_reconcile"
          key_value(metadata, "storage_assignment_id")
        end

        # Universal fallback: every fleet signal stamps signal_fingerprint into
        # its payload (DecisionEngine#skill_metadata_payload). When an action has
        # no natural key — or the routed signal didn't carry it (e.g. an
        # instance-wide system.module_drift routes to system.module_assign, whose
        # module_id/module_version_id keys are both absent) — dedup on the
        # fingerprint so a persistent signal collapses to ONE open ApprovalRequest
        # instead of minting a fresh one every escalation tick (the operator-
        # approval flood; regression of imps 019f3cdc-efc9/d0a8). Operator-
        # initiated (non-signal) actions carry no signal_fingerprint, so this is
        # nil for them and the action-level cooldown still applies.
        natural_key || key_value(metadata, "signal_fingerprint")
      end

      def key_value(metadata, name)
        v = metadata&.dig(name) || metadata&.dig(name.to_sym)
        return nil if v.blank?
        [ name, v.to_s ]
      end

      def create_pending_approval(action_category:, metadata:, reasoning:, temporal_context:, advisory: false)
        @suppression = nil

        unless defined?(::Ai::ApprovalRequest)
          @suppression = SUPPRESSION_NO_REQUEST_STORE
          return nil
        end

        request_data = {
          "action_category" => action_category,
          "payload" => metadata.deep_stringify_keys,
          "reasoning" => reasoning.deep_stringify_keys,
          "temporal_context" => temporal_context.deep_stringify_keys,
          "agent_role" => @role
        }

        # Specific dedup based on the action's natural key (instance/template/module/cve).
        if (key = dedup_key_for(action_category, metadata))
          name, value = key

          # IMP-4019664a524b: an advisory decision is DURABLE. Both dedup paths
          # below assume the underlying condition resolves — pending matching
          # ends the moment a request settles, and the rejected cooldown is
          # time-boxed — so an APPROVED advisory matched nothing and the next
          # sense pass past the decide-cache minted a fresh request, forever.
          # Approval is the operator acknowledging a standing condition and
          # rejection is dismissing it; neither expires, because the condition
          # itself outlives any window. A genuinely different condition carries
          # a different fingerprint and still mints.
          if advisory && (settled = settled_advisory_request(action_category, name, value))
            Rails.logger.info("[FleetAutonomy] Skipped advisory #{action_category} for #{name}=#{value} — " \
                              "already #{settled.status} (durable operator decision)")
            @suppression = SUPPRESSION_SETTLED_ADVISORY
            return nil
          end

          existing = pending_fleet_approvals
            .where("request_data->>'action_category' = ?", action_category)
            .where("request_data->'payload'->>? = ?", name, value)
            .first
          if existing
            existing.update!(request_data: request_data,
                             description: reasoning[:summary] || reasoning["summary"])
            return existing
          end

          if recently_rejected_approval?(action_category,
              [ "request_data->>'action_category' = ? AND request_data->'payload'->>? = ?",
               action_category, name, value ])
            Rails.logger.info("[FleetAutonomy] Skipped #{action_category} for #{name}=#{value} — rejected within cooldown")
            @suppression = SUPPRESSION_REJECTION_COOLDOWN
            return nil
          end
        end

        # Fallback: action-level cooldown for actions without natural dedup keys.
        if recently_rejected_approval?(action_category,
            [ "request_data->>'action_category' = ?", action_category ])
          Rails.logger.info("[FleetAutonomy] Skipped #{action_category} — rejected within cooldown")
          @suppression = SUPPRESSION_REJECTION_COOLDOWN
          return nil
        end

        chain = fleet_approval_chain
        unless chain
          @suppression = SUPPRESSION_NO_REQUEST_STORE
          return nil
        end

        request = chain.create_request!(
          source_type: SOURCE_TYPE,
          source_id: action_category,
          description: (reasoning[:summary] || reasoning["summary"] || action_category).to_s.truncate(500),
          request_data: request_data
        )

        # An advisory request gets NO deadline. create_request! derives
        # expires_at from the chain's timeout_hours (4h on the fleet chain,
        # timeout_action "reject"), which for a condition only a human can
        # clear means an unattended gap is auto-rejected overnight by a clock —
        # and, since a settled request stops surfacing, silently buried. nil is
        # a first-class value here: ApprovalRequest#expired? is false for it,
        # `scope :active` explicitly admits it, and BOTH sweeps that could
        # settle this row filter on expires_at — ours (#expire_stale_approvals!)
        # and core's account-wide Ai::Autonomy::ApprovalWorkflowService
        # #expire_overdue!, driven by the AiApprovalExpiryJob cron. Clearing
        # the column is therefore the whole fix, with no core change and no
        # extension-specific knowledge pushed into core.
        request.update_columns(expires_at: nil) if advisory && request&.expires_at
        request
      rescue StandardError => e
        Rails.logger.error("[FleetAutonomy] Failed to create approval request: #{e.message}")
        nil
      end

      # IMP-4019664a524b: the settled counterpart to pending_fleet_approvals,
      # for advisory dedup only. Unbounded in age — an operator's answer about
      # a standing condition does not go stale the way the rejected-cooldown
      # assumes — but NOT unbounded in provenance: the `joins(:decisions)`
      # inner join requires an actual Ai::ApprovalDecision row, which only
      # #record_decision! writes. ApprovalRequest#check_expiration! transitions
      # a request straight to rejected/approved with no decision row, so a
      # CLOCK can never masquerade as a durable operator decision and bury the
      # gap; a timeout-rejected advisory falls through to the ordinary
      # rejection cooldown and re-mints, staying visible. That is belt and
      # braces with the nil expires_at above, which stops the timeout firing at
      # all. Non-advisory actions never consult this, so recurrence still
      # re-mints for them.
      #
      # Status is only excluded for "pending" — approved and rejected are the
      # reachable settled states here; "expired"/"cancelled" require a chain
      # timeout_action or an admin action neither of which this chain uses
      # today, and both are safe to treat as durable if they ever appear
      # (each implies a deliberate human/administrative disposition).
      def settled_advisory_request(action_category, name, value)
        ::Ai::ApprovalRequest
          .joins(:decisions)
          .where(account: @account, source_type: SOURCE_TYPE)
          .where.not(status: "pending")
          .where("request_data->>'action_category' = ?", action_category)
          .where("request_data->'payload'->>? = ?", name, value)
          .distinct
          .first
      end

      def pending_fleet_approvals
        # Deliberately no expires_at filter: an expired-but-still-pending
        # request must keep dedup-matching until the tick-start sweep
        # transitions it, otherwise each persisting signal re-mints a
        # duplicate request per TTL window.
        ::Ai::ApprovalRequest
          .pending
          .where(account: @account, source_type: SOURCE_TYPE)
      end

      # Expired pending requests don't transition on their own —
      # ApprovalRequest#check_expiration! only acts when invoked. Sweeping at
      # tick start fires the chain's timeout_action (typically reject), whose
      # rejected-cooldown then suppresses re-mints of the same signal.
      # Best-effort per row: one bad record must not break the autonomy tick.
      def expire_stale_approvals!
        return unless defined?(::Ai::ApprovalRequest)

        ::Ai::ApprovalRequest
          .pending
          .where(account: @account, source_type: SOURCE_TYPE)
          .where("expires_at < ?", Time.current)
          .find_each do |request|
            request.check_expiration!
          rescue StandardError => e
            Rails.logger.error("[FleetAutonomy] expiry sweep failed for ApprovalRequest #{request.id}: #{e.message}")
          end
      end

      # IMP-31f1e5f9b365 — score the require_approval lane.
      #
      # F3-01 gave this lane an ACT arm but no VALIDATE arm. #decide gates the
      # decision at :pending, and RemediationValidator#record_proceeded! only
      # ever saw #decide_all's decisions — so every remediation an operator
      # approved and this poller then EXECUTED produced no RemediationOutcome:
      # no effectiveness score, no ineffective_streak, no F3-11 escalation. The
      # only lane in the loop that a human had explicitly authorised was the one
      # lane nothing measured.
      #
      # THREE things this must get right, each of which is a defect if wrong:
      #
      # 1. REUSE record_proceeded!, do not re-derive. A second recorder would
      #    share none of its guards — the pending-per-fingerprint dedup, the
      #    NON_REMEDIATING_ACTION_CATEGORIES exemption, the :proposal skip, the
      #    fingerprint_self_clearing skip, and the convergence_deferred
      #    declaration. Every one of those exists because its absence
      #    manufactured a false score. The decision hash below is synthesised
      #    so that all five apply here unchanged.
      #
      # 2. The row is for an EXECUTION, not an approval. See
      #    #executed_remediation? — an approval that never ran, or ran
      #    applied:false, mints nothing, or the pending row scores ineffective
      #    every settle window and the streak escalates a lane that never acted.
      #
      # 3. The fingerprint is the sensor's own, read from the STAMPED
      #    signal_fingerprint. #validate_due! scores by matching this string
      #    against the fingerprints of a later tick's sense pass, so any other
      #    value — notably execute_approved!'s "approved:<request id>"
      #    replay fallback — is absent from every pass and would score
      #    EFFECTIVE unconditionally at the first due tick: a fabricated
      #    success, worse than no row. A request without one mints nothing.
      #
      #    THE STAMPED VALUE IS NECESSARY, NOT SUFFICIENT, and the doc used to
      #    overclaim here. "The sensor re-emits it" holds for the per-resource
      #    fingerprints (module_drift:<instance_id>, instance_silent:<id>,
      #    boot_image_drift:<id>); it does NOT hold for the event- and
      #    bucket-scoped ones — honeypot_access:<event_id> (whose sensor has a
      #    15-minute LOOKBACK, shorter than the 1h approval TTL),
      #    trading_pressure:<minute bucket>, gitops_drift:...:<synced_revision>.
      #    Those score `effective` on absence alone. That is not a FALSE
      #    success — only applied:true mints, so the terminate/apply really did
      #    land — but it is an uninformative 1.0 in the LEARN step's ground
      #    truth. A fingerprint whose disappearance is caused by the APPLIER
      #    rather than merely uncorrelated with it is a different and worse
      #    problem, and is declared away: see fingerprint_self_clearing on
      #    DecisionEngine#apply_template_closure_drift.
      #
      # Nothing is passed for acted_at/settle_until: record_proceeded! stamps
      # Time.current, and calling it HERE — from the execution — is what makes
      # the settle window run from the moment the work landed rather than from
      # the decision an operator may have approved hours earlier.
      #
      # ORDERING NOTE. tick! runs validate_due! -> execute_approved_actions! ->
      # decide_all -> record_proceeded!, so this call claims the
      # one-pending-row-per-fingerprint slot BEFORE the proceed lane can. If
      # the same fingerprint is both live in the sense pass and carried by an
      # approved request, the row describes the APPROVED execution and the
      # proceed lane's is deduped away. That is the right way round — the
      # approved execution is the one a human authorised — but it is an
      # ordering dependency, so do not reorder tick! without re-reading this.
      def record_approved_outcome!(validator, engine, request, result, correlation_id)
        return unless validator
        return unless executed_remediation?(result)

        data = request.request_data.is_a?(Hash) ? request.request_data : {}
        fingerprint = data.dig("payload", "signal_fingerprint").to_s
        return if fingerprint.blank?

        signal = engine.signal_from_approval(request)
        return unless signal

        validator.record_proceeded!(
          decisions: [ {
            decision: :proceed,
            gate: GATE_APPROVED_EXECUTION,
            signal_kind: signal.kind,
            fingerprint: fingerprint,
            action_category: data["action_category"],
            # The applier's own return hash, passed through verbatim so the
            # :proposal and :convergence_deferred DECLARATIONS reach the
            # validator exactly as they do on the proceed lane.
            remediation: result
          } ],
          signals: [ signal ],
          correlation_id: correlation_id
        )
      rescue StandardError => e
        # Same best-effort contract as #safe_record: a validator hiccup must
        # never break the approved-execution poller.
        Rails.logger.error("[FleetAutonomy] approved outcome recording failed for " \
                           "ApprovalRequest #{request.id}: #{e.class}: #{e.message}")
      end

      # Did the replay actually ACTUATE something worth scoring?
      #
      # applied:true is the ordinary yes. The second arm is the applier's
      # DECLARED convergence_deferred (IMP-848c7e953e2d): it did the part it
      # could and states the fleet cannot converge until the node reboots.
      # That shape is applied:false yet is still an execution, and the proceed
      # lane records it, so dropping it here would silently give the approved
      # lane different semantics from the proceed lane for a byte-identical
      # applier result.
      #
      # BE PRECISE ABOUT WHY THAT ARM IS SAFE — it is NOT that it reaches no
      # escalation. #validate_due! settles the row `inconclusive`, which
      # ineffective_streak's `status IN (effective, ineffective)` filter
      # excludes, so it cannot feed the STREAK. It does feed
      # RemediationOutcome.deferred_convergence?, which DecisionEngine#decide
      # reads pre-gate and routes into escalate_stuck_remediation! — the SAME
      # HIGH fleet.remediation_stuck event and the same forced
      # require_approval. What makes it acceptable is that the escalation is
      # then DECLARED rather than inferred (an applier said it could not
      # converge), and that the block is time-bounded by
      # RemediationOutcome::DEFERRED_BLOCK_WINDOW, which lapses on the clock
      # and so does not need a fresh :proceed to lift — the thing that would
      # otherwise strand a require_approval-only lane forever.
      #
      # Everything else is applied:false and mints NOTHING: "no applier for
      # <kind>", a control-plane fence skip, apply_remediation!'s rescue, the
      # unreplayable pre-F3-01 request, and the poller's own rescue above.
      #
      # KNOWN CONSERVATIVE GAP, stated rather than papered over. A binding
      # whose skill IS the actuation and which has no REMEDIATION_APPLIERS
      # entry — system.boot_image_drift is the live one; execute_approved!'s
      # own comment names it — really does actuate on approval (the executor
      # creates the upgrade_boot_image tasks) and then returns
      # applied:false/"no applier", so it still mints nothing and is still
      # unmeasured. Admitting it would mean INFERRING actuation from the
      # presence of skill_data, which is exactly the inference this file
      # refuses everywhere else; the declared fix is for those bindings to
      # return an actuation marker of their own, which is not this change.
      # Erring toward no row is the safe direction: a missing score is a gap,
      # a wrong score is ground truth the LEARN step believes.
      def executed_remediation?(result)
        return false unless result.is_a?(Hash)
        return true if result[:applied] == true

        result[:convergence_deferred].present?
      end

      def stamp_execution!(request, result)
        stamp = result.deep_stringify_keys.merge("executed_at" => Time.current.iso8601)
        request.update!(request_data: request.request_data.merge("execution" => stamp))
      rescue StandardError => e
        Rails.logger.error("[FleetAutonomy] could not stamp execution on ApprovalRequest #{request.id}: #{e.message}")
      end

      def recently_rejected_approval?(action_category, match_conditions)
        cooldown = decision_ttl_for(action_category)

        ::Ai::ApprovalRequest
          .rejected
          .where(account: @account, source_type: SOURCE_TYPE)
          .where("completed_at > ?", cooldown.ago)
          .where(match_conditions)
          .exists?
      end

      def fleet_approval_chain
        # Ai::ApprovalChain is a business-extension model; in core mode there's
        # no chain to resolve, so callers fall through to auto-proceed
        # semantics (matches AutonomyGate#require_approval_or_proceed).
        return nil unless defined?(::Ai::ApprovalChain)
        @fleet_approval_chain ||= ::Ai::ApprovalChain
          .where(account: @account, trigger_type: "autonomy_action", status: "active")
          .find_by("name ILIKE ?", "%fleet%") ||
          ::Ai::ApprovalChain.where(account: @account, trigger_type: "autonomy_action",
                                    status: "active").first
      end
    end
  end
end
