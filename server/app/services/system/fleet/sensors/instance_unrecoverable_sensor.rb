# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # IMP-e2f53e87d090 (APO-2b) — the sense arm for "a reboot cannot bring
      # this instance back".
      #
      # WHY IT IS A SEPARATE SENSOR AND A SEPARATE SIGNAL
      #
      # InstanceStatusSensor emits system.instance_silent for ANY running /
      # starting instance with a stale heartbeat, and DecisionEngine's applier
      # #reboot_silent_instance answers every one of them with a provider-side
      # reboot (or a start, from a not-running row). Three materially different
      # conditions collapsed into that one signal and that one remediation:
      #
      #   1. the VM is GONE — the provider reports terminated/error, so there
      #      is nothing left to reboot;
      #   2. the HOST is unreachable — the platform's own control path to that
      #      provider is in error and no usable connection remains, so the
      #      reboot cannot be dispatched at all;
      #   3. the reboot has ALREADY been tried and the validate arc scored the
      #      outcomes ineffective — re-running a proven-futile action.
      #
      # Disaster recovery's answer to all three is REPLACE, and a replace needs
      # its own operator-tunable policy row. So this sensor emits a distinct
      # kind (system.instance_unrecoverable) on a distinct action_category
      # (system.instance_replace, seeded require_approval).
      #
      # A FOURTH CONDITION JOINED THEM (campaign 01a07025 / app-2): an
      # ephemeral POOL MEMBER sitting in status `error` past a grace window.
      # It reaches the same lane for the same reason — a reboot cannot bring it
      # back and the pool's own lifecycle_class says nothing on it is worth
      # preserving — but it is classified from the platform's own rows rather
      # than from a provider read, so it is written and documented separately
      # (see #ephemeral_pool_error) instead of being folded into the three
      # below.
      #
      # UNKNOWN IS NOT UNRECOVERABLE. A missing adapter, a blank
      # cloud_instance_id, a failed sync_status read, a provider carrying no
      # connection rows, and a provider whose connections are merely `pending`
      # (the schema default — never tested) are all ABSENCE of provider state,
      # and absence keeps the instance on the existing instance_silent lane
      # rather than escalating it to a replace proposal. Every predicate below
      # fails CLOSED (returns "not unrecoverable") on anything it cannot read.
      #
      # THE ACTUATOR ARRIVED IN APO-4 (IMP-555db48d41f1). This paragraph read
      # "NOT AN ACTUATOR. There is no replace applier: this increment delivers
      # detection plus the distinct policy row", which was true of APO-2b and
      # is not true now: the binding names
      # System::Ai::Skills::ReplaceInstanceExecutor, and
      # system.instance_replace has come out of
      # RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES because a lane
      # that actuates must be scored rather than exempted.
      #
      # What this sensor does is unchanged — it still only DETECTS, and the
      # payload it emits (instance_id + the classified reason) is what the
      # executor's input_mapper reads. Its fingerprint matters more than it
      # used to: the binding passes it as the executor's `operation_id`, so a
      # re-emitted IDENTICAL signal replays a replace already in progress
      # rather than claiming a second warm member.
      #
      # THE FINGERPRINT IS NOT STABLE ACROSS A RECLASSIFICATION, and no reader
      # of it should assume otherwise. #unrecoverable_reason re-derives the
      # reason on every tick from a live provider read, so the same dead
      # instance emits "…:host_unreachable" while its provider connection is
      # down and "…:provider_terminal" once that connection recovers — two
      # fingerprints, one failure. The replace executor closes that with
      # #adopted_acquisition (an acquire is matched on the FAILED INSTANCE as
      # well as the operation_id); the alternative, making the fingerprint
      # reason-free, would collapse genuinely distinct classifications into one
      # signal and cost the operator the reason on the card.
      class InstanceUnrecoverableSensor < BaseSensor
        # The same fence InstanceStatusSensor carries over the same population:
        # never speak for an instance another control plane owns.
        include ::System::Autonomy::ControlPlaneFence

        SIGNAL_KIND = "system.instance_unrecoverable"

        # The DecisionEngine's presumed-dead reaper flips a silent `running`
        # instance to `error` at PRESUMED_DEAD_SILENCE_SECONDS (30 min) and
        # emits this kind. A reaped instance is the CANONICAL disaster-recovery
        # case — the model row was retired on a timer while the provider's own
        # state may only settle to `terminated` later — so the candidate set
        # below re-admits exactly the rows that reaper marked, and no other
        # `error` row (a failed provision is a different problem with a
        # different owner).
        PRESUMED_DEAD_KIND = "system.instance_presumed_dead"

        # Bounds the per-tick provider reads (one sync_status subprocess each,
        # like InstanceStateDriftSensor::MAX_PER_TICK). Applied AFTER the
        # emit-window exclusion below, so instances already carrying a live
        # replace proposal never consume a slot.
        # IMP-ca485128072e (APO-2e) — the constant is the FALLBACK; the
        # effective value resolves through BaseSensor.resolved_threshold. It
        # used to read ENV["FLEET_UNRECOVERABLE_MAX_PER_TICK"], which is not
        # operator configuration on this platform: the reconciler runs inside a
        # module-composed systemd unit, so changing it meant a unit edit and a
        # redeploy on every node, and no operator surface listed the name.
        MAX_PER_TICK = 25

        # Emit-once-per-window. An unrecoverable instance STAYS unrecoverable —
        # the condition clears when a person replaces it, not inside any tick
        # interval — so re-emitting each 60s tick would bleed one FleetEvent
        # and one operator-facing decision per minute, indefinitely. The
        # suppression reads the durable FleetEvent the DecisionEngine mints for
        # the signal, so it needs no sensor-side state and survives restarts.
        # It is enforced IN SQL, before MAX_PER_TICK (see #candidates).
        # Fallback; overridable per account as "emit_window_seconds".
        EMIT_WINDOW_SECONDS = 3600

        # Consecutive ineffective instance_silent remediations before the
        # reboot lane is called exhausted. Deliberately BELOW
        # DecisionEngine::STUCK_STREAK_THRESHOLD (3): the generic stuck
        # escalation says "this remediation is not working" without saying
        # what to do instead, and this signal is the what-to-do-instead.
        # Fallback; overridable per account as "reboot_attempt_threshold".
        REBOOT_ATTEMPT_THRESHOLD = 2

        # Campaign 01a07025 / app-2 — how long an ERRORED ephemeral pool member
        # must have been quiet before it counts as unrecoverable.
        #
        # THE LIVE POPULATION THIS EXISTS FOR: 12 NodeInstances sat in status
        # `error` on ops-hub, 9 of them ephemeral `ci-native-builders-*` pool
        # members dating to 2026-08-09. Not one was reachable by any
        # classification above. They are not running/starting, so
        # InstanceStatusSensor never saw them; no presumed-dead FleetEvent was
        # ever minted for them, so #in_scope_status_sql's `error` arm excluded
        # them; and with no instance_silent lane ever having run, their
        # ineffective streak is 0, so #reboot_exhausted would decline them even
        # if they were in scope. They were invisible for four weeks.
        #
        # 24h, not minutes: a pool member that errors during provisioning is a
        # provisioning failure with its own owner and its own retry, and this
        # lane must not race it. Fallback; overridable per account as
        # "ephemeral_error_grace_seconds".
        EPHEMERAL_ERROR_GRACE_SECONDS = 86_400

        # The pool lifecycle_class this lane admits.
        #
        # `spot` is the OTHER member of System::InstancePool::LIFECYCLE_CLASSES
        # and is deliberately NOT here. A spot member in `error` may be a
        # provider reclaim, which is a different condition with a different
        # answer (re-bid, or fall back to on-demand) and no ruling behind it
        # yet. Widening this list is a decision, not a typo fix.
        REAPABLE_LIFECYCLE_CLASSES = %w[ephemeral].freeze

        # Provider-reported states from which a reboot cannot recover. A
        # `stopped` VM is deliberately NOT here — start is the legal, correct
        # remediation for it, and instance_state_drifted already converges the
        # model.
        TERMINAL_PROVIDER_STATES = %w[terminated error].freeze

        # The tunable surface. silent_threshold_seconds is deliberately NOT
        # here — see #silent_threshold_seconds below.
        def self.default_thresholds
          {
            "max_per_tick" => MAX_PER_TICK,
            "emit_window_seconds" => EMIT_WINDOW_SECONDS,
            "reboot_attempt_threshold" => REBOOT_ATTEMPT_THRESHOLD,
            # Campaign 01a07025 / app-2 — registered HERE, in the seam
            # `platform.system_get_sensor_config` reads, and not as a constant
            # an operator would need a redeploy to change. This sensor is one
            # of the four already on that seam; the increment adds a key to it
            # rather than a fifth registration mechanism.
            "ephemeral_error_grace_seconds" => EPHEMERAL_ERROR_GRACE_SECONDS
          }
        end

        def sense
          fence_to_control_plane(candidates)
            # No per-sensor attempt stamp exists to rotate on, and any fixed
            # ordering key would let permanently-silent-but-RECOVERABLE
            # instances (never-enrolled rows the provider still reports
            # running) pin the front of the window forever and starve the rest
            # — the defect IMP-bcadb1ecd52d fixed in InstanceStateDriftSensor.
            # A random draw reaches every candidate within a bounded number of
            # ticks without one.
            .order(Arel.sql("random()"))
            .limit(threshold("max_per_tick"))
            .filter_map { |inst| signal_for(inst) }
        end

        private

        # IMP-ca485128072e — resolved from the INSTANCE_STATUS sensor's key,
        # not this sensor's own, and replacing a
        # `SILENT_THRESHOLD = InstanceStatusSensor::SILENT_THRESHOLD` alias
        # that existed for the same reason: the two sensors must not disagree
        # about which instances are silent, because this one exists to CLASSIFY
        # that exact population. A second, separately tunable copy would
        # reintroduce precisely that disagreement — so an operator who widens
        # the silent window widens it for the classifier too, in one write.
        def silent_threshold_seconds
          @silent_threshold_seconds ||=
            InstanceStatusSensor.resolved_threshold("silent_threshold_seconds", account: account)
        end

        # The candidate population, narrowed IN SQL so MAX_PER_TICK bounds only
        # work that is still to be done. Both exclusions below MUST precede the
        # limit: filtering after it lets a fixed set of already-classified rows
        # consume the whole window every tick while the rest of a mass failure
        # is never looked at.
        def candidates
          ::System::NodeInstance
            # instance_pool alongside provider_region: #ephemeral_pool_error reads
            # the pool for every candidate it reaches, and a per-row lookup there is
            # the N+1 the eager-loading convention exists to stop.
            .includes(:provider_region, :instance_pool)
            .joins(:node)
            .where(system_nodes: { account_id: account.id })
            .where(
              "system_node_instances.last_heartbeat_at < ? OR system_node_instances.last_heartbeat_at IS NULL",
              Time.current - silent_threshold_seconds.seconds
            )
            .where(
              in_scope_status_sql,
              account_id: account.id,
              presumed_dead: PRESUMED_DEAD_KIND,
              reapable_classes: REAPABLE_LIFECYCLE_CLASSES,
              ephemeral_grace_cutoff: Time.current - threshold("ephemeral_error_grace_seconds").seconds
            )
            .where(
              outside_emit_window_sql,
              account_id: account.id, kind: SIGNAL_KIND,
              since: Time.current - threshold("emit_window_seconds").seconds
            )
        end

        # running/starting (InstanceStatusSensor's own population) PLUS the
        # rows the presumed-dead reaper retired out of it PLUS, since campaign
        # 01a07025 / app-2, errored EPHEMERAL POOL MEMBERS past the grace
        # window.
        #
        # THE THIRD ARM IS NOT A WIDENING OF THE SECOND. The presumed-dead arm
        # re-admits rows THIS PLATFORM retired on a timer, and is deliberately
        # narrow about it ("no other `error` row — a failed provision is a
        # different problem with a different owner"). That reasoning still
        # holds and is untouched: a persistent instance in `error` is still out
        # of scope here. What the third arm adds is a population where the
        # owner question has a settled answer — a pool member whose pool
        # declares it EPHEMERAL is disposable by construction, the pool
        # replenishes, and there is nothing to preserve. Nine such rows
        # (`ci-native-builders-*`, errored since 2026-08-09) sat unreachable by
        # every lane for four weeks.
        #
        # The grace clause reads COALESCE(last_heartbeat_at, created_at): a
        # member that never enrolled has no heartbeat to age, and its row age
        # is the only honest measure available. It is NOT `updated_at`, which
        # any unrelated write bumps.
        def in_scope_status_sql
          <<~SQL.squish
            (
              system_node_instances.status IN ('running', 'starting')
              OR (
                system_node_instances.status = 'error'
                AND EXISTS (
                  SELECT 1 FROM system_fleet_events reaped
                  WHERE reaped.node_instance_id = system_node_instances.id
                    AND reaped.account_id = :account_id
                    AND reaped.kind = :presumed_dead
                )
              )
              OR (
                system_node_instances.status = 'error'
                AND system_node_instances.instance_pool_id IS NOT NULL
                AND COALESCE(
                      system_node_instances.last_heartbeat_at,
                      system_node_instances.created_at
                    ) < :ephemeral_grace_cutoff
                AND EXISTS (
                  SELECT 1 FROM system_instance_pools pool
                  WHERE pool.id = system_node_instances.instance_pool_id
                    AND pool.account_id = :account_id
                    AND pool.lifecycle_class IN (:reapable_classes)
                )
              )
            )
          SQL
        end

        # Per-INSTANCE, not per-account: a host failure takes down many
        # instances at once and each still needs its own replace decision.
        def outside_emit_window_sql
          <<~SQL.squish
            NOT EXISTS (
              SELECT 1 FROM system_fleet_events emitted
              WHERE emitted.node_instance_id = system_node_instances.id
                AND emitted.account_id = :account_id
                AND emitted.kind = :kind
                AND emitted.emitted_at > :since
            )
          SQL
        end

        def signal_for(instance)
          reason, detail = unrecoverable_reason(instance)
          return nil unless reason

          signal(
            kind: SIGNAL_KIND,
            severity: :critical,
            payload: {
              instance_id: instance.id,
              node_id: instance.node_id,
              reason: reason,
              last_heartbeat_at: instance.last_heartbeat_at&.iso8601,
              silent_threshold_seconds: silent_threshold_seconds
            }.merge(detail),
            fingerprint: "#{SIGNAL_KIND.delete_prefix('system.')}:#{instance.id}:#{reason}"
          )
        end

        # The four classifications, most definitive first. Returns
        # [reason, extra_payload] or nil.
        #
        # host_unreachable is an INFERENCE about the control path, so a
        # successful provider read disproves it: if the adapter answered at
        # all, the path is up and the only question left is whether the reboot
        # lane is spent. reboot_exhausted is independent evidence (the validate
        # arc's own scoring) and survives a healthy read — a VM the provider
        # calls `running` whose agent stayed silent through N ineffective
        # reboots is exactly the case a replace answers.
        def unrecoverable_reason(instance)
          state, detail = provider_probe(instance)
          return [ "provider_terminal", detail ] if state == :terminal

          host = state == :unknown ? host_unreachable(instance) : nil
          host || reboot_exhausted(instance) || ephemeral_pool_error(instance)
        end

        # 4. Campaign 01a07025 / app-2 — an errored EPHEMERAL pool member.
        #
        # LAST ON PURPOSE, so this arm is strictly additive: it can only
        # classify a row that provider_terminal, host_unreachable and
        # reboot_exhausted all declined, and it therefore changes the reason
        # (and so the fingerprint) of no instance that was already classified.
        #
        # It is also the ONE arm that does not read the provider, and that is
        # not a relaxation of this sensor's "unknown is not unrecoverable"
        # rule. The other three infer a machine's fate from provider state,
        # where absence of evidence must stay absence. Here the evidence is the
        # platform's OWN two rows: this instance is in `error`, and its pool
        # declares it ephemeral. Neither is an inference, and the conclusion
        # ("this member is disposable and the pool will replenish") is the
        # pool's definition rather than a guess about a host.
        #
        # Still only DETECTION. The binding routes this to
        # ReplaceInstanceExecutor under system.instance_replace (seeded
        # require_approval), whose additive half is all an approved replace
        # applies; the terminate is a SECOND approval on system.instance_reap
        # replaying ReapInstanceExecutor. Nothing here shortens that path —
        # per the ratified rule in
        # docs/operations/autonomous-infrastructure-readiness-2026-08-12.md §7,
        # removals never auto-apply.
        def ephemeral_pool_error(instance)
          return nil unless instance.status == "error"
          return nil if instance.instance_pool_id.blank?

          # Through the association so the #candidates preload is used; the
          # account check stays because a preloaded row is not a scoped one.
          pool = instance.instance_pool
          return nil unless pool && pool.account_id == account.id
          return nil unless REAPABLE_LIFECYCLE_CLASSES.include?(pool.lifecycle_class)

          [ "ephemeral_pool_error",
            { instance_pool_id: pool.id,
              instance_pool_name: pool.name,
              pool_lifecycle_class: pool.lifecycle_class,
              pool_state: instance.pool_state } ]
        rescue StandardError => e
          Rails.logger.warn(
            "[InstanceUnrecoverableSensor] pool read failed for #{instance.id}: #{e.class}: #{e.message}"
          )
          nil
        end

        # 1. Read the provider the same way InstanceStateDriftSensor does.
        # Returns :terminal (the VM is gone), :reachable (the provider answered
        # with a non-terminal state), or :unknown. EVERY absence path is
        # :unknown: no adapter, no cloud id, an unsuccessful read, a blank
        # status, or a raise.
        def provider_probe(instance)
          adapter = ::System::Providers::Registry.for_instance(instance)
          return [ :unknown, nil ] unless adapter.respond_to?(:sync_status)

          cloud_id = instance.config&.dig("cloud_instance_id")
          return [ :unknown, nil ] if cloud_id.blank?

          result = adapter.sync_status(cloud_id)
          return [ :unknown, nil ] unless result.is_a?(Hash) && result[:success]

          provider_status = result[:status].to_s
          return [ :unknown, nil ] if provider_status.blank?
          return [ :reachable, nil ] unless TERMINAL_PROVIDER_STATES.include?(provider_status)

          [ :terminal, { provider_status: provider_status } ]
        rescue StandardError => e
          Rails.logger.warn(
            "[InstanceUnrecoverableSensor] provider read failed for #{instance.id}: #{e.class}: #{e.message}"
          )
          [ :unknown, nil ]
        end

        # 2. The host is unreachable. Only a POSITIVELY OBSERVED failure
        # counts: at least one connection to that provider is in `error` (the
        # state ProviderConnection#mark_error! writes when a connection test
        # fails) AND none is still usable.
        #
        # `pending` — the schema default, i.e. never tested — is deliberately
        # NOT a failure, and neither is a provider with no connection rows at
        # all: both are configuration ABSENCE, and escalating absence to a
        # replace proposal is exactly the inference this sensor refuses.
        def host_unreachable(instance)
          region = instance.provider_region
          return nil unless region

          connections = ::System::ProviderConnection
                          .where(provider_id: region.provider_id, account_id: account.id)
          return nil unless connections.where(status: "error").exists?

          # `enabled` as well as `status`: Registry#find_connection_for_region
          # filters on status alone, so a connection an operator switched off
          # still reads "connected" there while nothing can be dispatched
          # through it — it is not a usable path out of the error state.
          return nil if connections.where(status: "connected", enabled: true).exists?

          [ "host_unreachable", { provider_id: region.provider_id } ]
        rescue StandardError => e
          Rails.logger.warn(
            "[InstanceUnrecoverableSensor] connection read failed for #{instance.id}: #{e.class}: #{e.message}"
          )
          nil
        end

        # 3. The reboot lane is spent. Reuses the validate arc's own measure
        # (RemediationOutcome.ineffective_streak — consecutive ineffective
        # outcomes newest-first, reset by the first `effective` row) against
        # the fingerprint InstanceStatusSensor mints, rather than counting
        # reboots from a second source that could drift from it.
        def reboot_exhausted(instance)
          streak = ::System::Fleet::RemediationOutcome.ineffective_streak(
            account: account, fingerprint: "instance_silent:#{instance.id}"
          )
          return nil if streak < threshold("reboot_attempt_threshold")

          [ "reboot_exhausted", { ineffective_streak: streak } ]
        rescue StandardError => e
          Rails.logger.warn(
            "[InstanceUnrecoverableSensor] streak read failed for #{instance.id}: #{e.class}: #{e.message}"
          )
          nil
        end
      end
    end
  end
end
