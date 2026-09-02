# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill: platform resilience / incident response.
      #
      # Action-discriminated executor for actions the operator (or
      # autonomous agent) takes when something is misbehaving. Each
      # branch is a thin wrapper over an existing primitive so the
      # skill composes naturally with platform_maintenance and
      # platform_deploy.
      #
      # Sub-actions:
      #
      #   - "drain_instance"  → CORDON + STOP a NodeInstance. Removes a pool
      #                          member from the allocator (pool_state
      #                          "draining", which InstancePoolService#acquire
      #                          reads) and stops the instance through
      #                          System::InstanceControlService, the single
      #                          lifecycle choke point. See the branch below.
      #   - "scale"           → set target_replicas on a deployment
      #                          (increment / decrement / set) AND reconcile
      #                          the live replica count to match, via
      #                          System::Platform::ReplicaReconciler.
      #   - "failover_check"  → surface peers + instances showing stress
      #                          (stale heartbeats, errored instances,
      #                          unreachable endpoints). Returns an
      #                          operator-facing triage list — NO
      #                          automatic failover in v1.
      #
      # Plan reference: chat-driven platform deployment + resilience
      # (D2-ext.2).
      class PlatformResilienceExecutor < BaseSkillExecutor
        # INV-1 (no self-management) applies to both mutating branches: drain
        # refuses an instance on this plane's own hosting node, scale refuses
        # the deployment that hosts it. Inert until an operator configures
        # SiteSetting `self_hosting_node_id`.
        include ::System::Autonomy::SelfManagementFence

        ACTIONS = %w[drain_instance scale failover_check].freeze
        SCALE_DIRECTIONS = %w[set increment decrement].freeze

        skill_descriptor(
          name: "platform_resilience",
          description: "Platform incident response — cordon and stop an instance, scale a deployment up/down (THIS action reconciles the live replica count after writing target_replicas; the Scaling panel and the GitOps bridge still only record it), or triage peer/instance health. Use this skill when the operator describes a stress event (instance misbehaving, capacity pressure, peer heartbeats stale) or asks 'what should I do about X'.",
          category: "devops",
          inputs: {
            action: { type: "string", required: true,
                      description: "One of: drain_instance, scale, failover_check" },
            instance_id: { type: "string", required: false,
                           description: "NodeInstance id (required for drain_instance)" },
            deployment_id: { type: "string", required: false,
                             description: "PlatformDeployment id (required for scale)" },
            direction: { type: "string", required: false,
                         description: "scale direction: set | increment | decrement (defaults to increment)" },
            target_replicas: { type: "integer", required: false,
                               description: "When direction=set, the new target_replicas value" }
          },
          outputs: {
            action: :string,
            data: :object,
            recommendations: [ :string ]
          }
        )

        binds_to "System Concierge"

        protected

        def perform(action:, **params)
          unless ACTIONS.include?(action.to_s)
            return failure("Unknown action: #{action.inspect}; allowed: #{ACTIONS.inspect}")
          end

          case action.to_s
          when "drain_instance"  then drain_instance(params)
          when "scale"           then scale(params)
          when "failover_check"  then failover_check
          end
        end

        private

        # ── drain_instance ────────────────────────────────────────────────
        # A REAL drain: cordon, then stop.
        #
        # IMP-8c0f0fe9a8cf (APO-3b). This branch used to write three
        # `config.drain_*` keys, emit a FleetEvent, and say so in its own
        # recommendations — "Nothing was stopped or cordoned … Nothing reads
        # these markers". It was advertised to agents as platform incident
        # response while transitioning no state and enforcing no timeout, so an
        # operator who asked an agent to drain a misbehaving node got a row
        # update and a still-serving instance.
        #
        # The two halves are now the platform's own primitives:
        #
        #   CORDON — for a READY pool member, pool_state "draining". That is
        #     read: InstancePoolService#acquire! only ever picks pool_state
        #     "ready", so a drained member stops being handed out. Three states
        #     are deliberately NOT flipped — a non-pool instance (no allocator
        #     to cordon against), one already "draining", and a CLAIMED member,
        #     which is already un-acquirable and whose two release paths both
        #     guard on `pool_state == "claimed"`. See cordon_pool_member! for
        #     why flipping that last one would strand it. A cordon that RAISES
        #     aborts the drain before the stop.
        #
        #   STOP — System::InstanceControlService, the single lifecycle choke
        #     point. It honours an operator ops hold (its own comment: "the
        #     single choke point for instance lifecycle, which is why the check
        #     lives here"), drives the AASM transition, and dispatches to the
        #     provider — `provider_adapter.stop_instance` for cloud/dynamic,
        #     `shutdown -h now` over SSH for physical. A refused or failed stop
        #     is returned as a FAILURE — the one thing worse than a drain that
        #     does nothing is a drain that does nothing and reports success.
        #
        #   PRIVILEGE — the stop is gated on `system.instances.control`, the
        #     grant `system_stop_instance` itself requires, not on this skill's
        #     coarser `system.platform.scale` entry point.
        #
        # `timeout_seconds` is gone from the descriptor with the markers. It
        # named an in-flight-work grace period no code ever enforced, and the
        # stop path has no knob to map it onto.
        #
        # INV-1 applies here as much as to the reconciler: refuse outright when
        # the target is this control plane's own hosting node.
        def drain_instance(params)
          instance_id = params[:instance_id]
          return failure("instance_id is required") if instance_id.blank?

          instance = ::System::NodeInstance
                       .joins(:node)
                       .where(system_nodes: { account_id: @account.id })
                       .find_by(id: instance_id)
          return failure("Instance not found: #{instance_id}") unless instance

          # PRIVILEGE. The MCP door onto this skill maps to
          # `system.platform.scale` (system_fleet_tool PERMISSION_MAP), which
          # was the right grant while this branch only wrote config markers.
          # It now stops a fleet node through the same choke point
          # `system_stop_instance` uses, and that verb requires
          # `system.instances.control`. Check the permission that governs the
          # PRIMITIVE, or the coarser grant silently becomes a stop grant.
          # Fail closed on a nil user: only an explicit in-process caller
          # (`internal_caller?` — the autonomy reconcilers, user: nil and
          # meaning it) is exempt. An MCP instance principal also has no User
          # and is refused here, one layer under the deny overlay.
          unless internal_caller? || @user&.has_permission?("system.instances.control")
            return failure(
              "Draining #{instance_id} stops the instance, which requires the " \
              "system.instances.control permission — the same grant " \
              "system_stop_instance requires. This caller holds only the " \
              "skill's own system.platform.scale grant."
            )
          end

          if self_managed_target?(instance)
            return failure(
              "Refusing to drain #{instance.name}: it runs on this control plane's own hosting " \
              "node (INV-1: no self-management). Stopping it would take the plane issuing the " \
              "order offline, and management authority has to come from the consensus group."
            )
          end

          cordon = cordon_pool_member!(instance)
          if cordon == :cordon_failed
            emit_event!(
              kind: "platform.resilience.drain_failed",
              payload: { instance_id: instance.id, cordoned: false, error: "cordon failed" },
              severity: "medium",
              instance_id: instance.id
            )
            return failure(
              "Drain of #{instance.name} failed at the cordon step: it IS a pool member but its " \
              "pool_state could not be written, so stopping it now would leave a stopped VM the " \
              "allocator still considers ready. Nothing was stopped."
            )
          end

          cordoned = cordon == :cordoned

          result = ::System::InstanceControlService.execute(instance: instance, action: :stop)
          unless result.respond_to?(:success?) && result.success?
            reason = result.respond_to?(:error) ? result.error.to_s : "stop failed"
            emit_event!(
              kind: "platform.resilience.drain_failed",
              payload: { instance_id: instance.id, cordoned: cordoned, error: reason },
              severity: "medium",
              instance_id: instance.id
            )
            return failure("Drain of #{instance.name} failed at the stop step: #{reason}")
          end

          emit_event!(
            kind: "platform.resilience.drain_started",
            payload: { instance_id: instance.id, cordoned: cordoned, by_user: @user&.id },
            instance_id: instance.id
          )

          recs = []
          recs << case cordon
          when :cordoned
            "#{instance.name} was cordoned out of its pool (pool_state=draining) — the allocator " \
            "will not hand it out again — and then stopped."
          when :claimed
            "#{instance.name} was stopped. It is a pool member currently CLAIMED by a consumer, so " \
            "it was deliberately NOT flipped to pool_state=draining: both release paths " \
            "(system_return_pooled_instance, AgentFleetMissionService#reap_member!) refuse anything " \
            "that is not 'claimed', so the flip would strand it. It is already un-acquirable while " \
            "claimed. Return it with system_return_pooled_instance when its consumer is done."
          else
            "#{instance.name} was stopped. It is not a pool member, so there was no allocator to " \
            "cordon it out of."
          end
          recs << "Disk and registry row are retained: system_start_instance brings it back. " \
                  "Nothing migrated in-flight work off it first, so re-check anything that was " \
                  "mid-flight."
          recs << "To reclaim the cloud resource once you are done: system_terminate_instance " \
                  "(approval-gated), or system_destroy_instance for a row whose cloud resource is " \
                  "already gone."

          success(
            action: "drain_instance",
            data: {
              instance_id: instance.id,
              instance_name: instance.name,
              cordoned: cordoned,
              cordon_state: cordon,
              stopped: true,
              status: instance.reload.status
            },
            recommendations: recs
          )
        end

        # Removes a pool member from the allocator. TRI-STATE, not a boolean:
        # a boolean collapsed "there was nothing to cordon" and "the cordon
        # blew up" into one false, and the caller rendered that false as the
        # claim "it is not a pool member" — a fabricated statement about a real
        # pool member whose write had failed, made while stopping it anyway.
        #
        #   :not_pooled     — no pool, no allocator, nothing to do.
        #   :claimed        — a pool member a consumer currently holds. NOT
        #                     flipped: `InstancePoolService#acquire!` only ever
        #                     picks pool_state "ready", so a claimed member is
        #                     already un-acquirable and the cordon buys nothing
        #                     — while both release paths guard on
        #                     `pool_state == "claimed"`
        #                     (system_fleet_tool#return_pooled_instance,
        #                     AgentFleetMissionService#reap_member!), so
        #                     flipping it to "draining" makes the member
        #                     permanently unreturnable and unrecyclable, and
        #                     the mission reaper reports that leak as
        #                     "already_returned".
        #   :cordoned       — flipped (or already) "draining".
        #   :cordon_failed  — it IS cordonable and the write raised. The caller
        #                     must NOT proceed to the stop: a stopped VM the
        #                     allocator still calls "ready" is worse than a
        #                     refused drain.
        def cordon_pool_member!(instance)
          return :not_pooled unless instance.respond_to?(:in_pool?) && instance.in_pool?
          return :cordoned if instance.pool_state == "draining"
          return :claimed if instance.pool_state == "claimed"

          instance.update!(pool_state: "draining")
          :cordoned
        rescue StandardError => e
          Rails.logger.warn("[PlatformResilienceExecutor] pool cordon failed for #{instance.id}: #{e.message}")
          :cordon_failed
        end

        # ── scale ────────────────────────────────────────────────────────
        # Set target_replicas on a deployment AND converge the live replica
        # count to match it.
        #
        # IMP-8c0f0fe9a8cf (APO-3b). This branch used to end with "Provisioning
        # sync to create/drain instances to match is queued for a follow-up
        # slice" — and nothing was ever queued. target_replicas had three
        # readers (the Scaling panel's display, the GitOps diff, the bootstrap
        # peer preference) and no actuator, so the column moved and the fleet
        # did not.
        #
        # System::Platform::ReplicaReconciler is that actuator. Its two
        # directions are deliberately asymmetric — scale-out provisions on the
        # caller's authority, scale-in resolves system.platform.scale_in and
        # removes nothing unless the verdict auto-executes — and it REFUSES the
        # deployment that hosts this control plane. That refusal is checked
        # here, BEFORE the write: a hub scale must not leave a target_replicas
        # nothing will ever converge, which is the exact defect this task is
        # about.
        def scale(params)
          deployment_id = params[:deployment_id]
          return failure("deployment_id is required") if deployment_id.blank?

          deployment = ::System::PlatformDeployment.find_by(
            id: deployment_id, account: @account
          )
          return failure("Deployment not found: #{deployment_id}") unless deployment

          direction = (params[:direction] || "increment").to_s
          unless SCALE_DIRECTIONS.include?(direction)
            return failure("Invalid direction: #{direction.inspect}; allowed: #{SCALE_DIRECTIONS.inspect}")
          end

          # `internal:` is this executor's own answer to internal_caller? — the
          # reconciler checks system.instances.create / .control and must be
          # able to tell a trusted in-process caller (user: nil AND not an
          # instance principal) from an MCP instance principal, which also
          # arrives with no User.
          reconciler = ::System::Platform::ReplicaReconciler.new(
            account: @account, user: @user, agent: @agent, internal: internal_caller?
          )
          if reconciler.hub_deployment?(deployment)
            return failure(
              format(::System::Platform::ReplicaReconciler::HUB_REFUSAL_MESSAGE, name: deployment.name)
            )
          end

          previous_target = deployment.target_replicas.to_i
          new_target =
            case direction
            when "set"
              raise ArgumentError, "target_replicas required when direction=set" if params[:target_replicas].blank?
              params[:target_replicas].to_i
            when "increment" then previous_target + 1
            when "decrement" then [ previous_target - 1, 0 ].max
            end

          return failure("target_replicas cannot be negative") if new_target.negative?

          # RECONCILE UNCONDITIONALLY. An earlier revision returned "already at
          # the requested replica count" here whenever the requested target
          # equalled the stored one — which is the state EVERY deployment whose
          # target was last written by the Scaling panel or the GitOps bridge is
          # already in, and the state a clamped pass leaves behind. It reported
          # a matching column as a matching fleet and skipped the actuator: the
          # exact defect this task is filed against, reintroduced one layer up.
          # Only the WRITE is conditional; the convergence never is.
          deployment.update!(target_replicas: new_target) unless new_target == previous_target
          outcome = reconciler.reconcile!(deployment)

          emit_event!(
            kind: "platform.resilience.scale_intent",
            payload: {
              deployment_id: deployment.id,
              previous_target: previous_target,
              new_target: new_target,
              direction: direction,
              reconciled: outcome.ok?,
              provisioned: outcome.provisioned_instance_ids&.size.to_i,
              terminated: outcome.terminated_instance_ids&.size.to_i
            }
          )

          # A REFUSED reconcile is a FAILURE, not a success carrying a nested
          # ok:false. `success:` is the documented stop signal — SkillCompositionRunner
          # keys a composition halt on `success == false` — so returning true
          # here would tell a runner that a scale which provisioned nothing had
          # worked, with target_replicas already moved. That is the task's
          # original read one refusal-reason away.
          unless outcome.ok?
            return failure(
              outcome.message,
              data: {
                deployment_id: deployment.id,
                deployment_name: deployment.name,
                previous_target: previous_target,
                target_replicas: deployment.reload.target_replicas,
                direction: direction,
                reconciled: { ok: false, refused_reason: outcome.refused_reason }
              }
            )
          end

          success(
            action: "scale",
            data: {
              deployment_id: deployment.id,
              deployment_name: deployment.name,
              previous_target: previous_target,
              target_replicas: new_target,
              direction: direction,
              no_op: new_target == previous_target,
              reconciled: {
                ok: outcome.ok?,
                refused_reason: outcome.refused_reason,
                actual_before: outcome.actual_before,
                actual_after: outcome.actual_after,
                provisioned_instance_ids: outcome.provisioned_instance_ids,
                terminated_instance_ids: outcome.terminated_instance_ids,
                pending_removal_instance_ids: outcome.pending_removal_instance_ids,
                failures: outcome.failures
              }
            },
            recommendations: [
              "target_replicas updated #{previous_target} → #{new_target}.",
              outcome.message,
              "Live count is now #{outcome.actual_after.inspect} — the Scaling panel at " \
              "/app/system/compute/platform/scaling reads the same rail."
            ].compact
          )
        rescue ArgumentError => e
          failure(e.message)
        end

        # ── failover_check ───────────────────────────────────────────────
        # Read-only triage: surface peers + instances showing stress.
        # The operator decides what to do — this skill never auto-fails
        # over because the right response is context-dependent (drain,
        # restart, revoke, scale, etc.).
        def failover_check
          stale_peers   = stale_federation_peers
          degraded_peers = degraded_federation_peers
          errored_instances = errored_instances_for_account

          findings = stale_peers.size + degraded_peers.size + errored_instances.size
          recs = []
          if stale_peers.any?
            recs << "#{stale_peers.size} federation peer(s) with stale heartbeat — investigate connectivity or call platform_resilience again with action=drain_instance on the affected platform component."
          end
          if degraded_peers.any?
            recs << "#{degraded_peers.size} federation peer(s) in degraded state — review the topology view at /app/system/sdwan/topology."
          end
          if errored_instances.any?
            recs << "#{errored_instances.size} NodeInstance(s) in error status — terminate + replace, or check container_logs for the failure cause."
          end
          recs << "No platform stress detected — all peers reachable, no errored instances." if findings.zero?

          success(
            action: "failover_check",
            data: {
              total_findings: findings,
              stale_peers: stale_peers,
              degraded_peers: degraded_peers,
              errored_instances: errored_instances,
              generated_at: Time.current.iso8601
            },
            recommendations: recs
          )
        end

        def stale_federation_peers
          return [] unless defined?(::System::FederationPeer)
          ::System::FederationPeer
            .where(account: @account, peer_kind: "platform")
            .heartbeat_stale
            .map { |p| { id: p.id, url: p.remote_instance_url, last_heartbeat_at: p.last_heartbeat_at&.iso8601 } }
        rescue StandardError
          []
        end

        def degraded_federation_peers
          return [] unless defined?(::System::FederationPeer)
          ::System::FederationPeer
            .where(account: @account, peer_kind: "platform", status: "degraded")
            .map { |p| { id: p.id, url: p.remote_instance_url, status: p.status } }
        rescue StandardError
          []
        end

        def errored_instances_for_account
          ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { account_id: @account.id })
            .where(status: "error")
            .map { |i| { id: i.id, name: i.name, node_id: i.node_id } }
        rescue StandardError
          []
        end

        # IMP-8c0f0fe9a8cf: severity was "info", which is NOT in
        # System::FleetEvent::SEVERITIES (low/medium/high/critical) — every
        # create! raised RecordInvalid straight into the rescue below, so this
        # skill has never emitted a single event despite three call sites and a
        # class comment that says it does. "low" is the routine-operator-action
        # rung; a drain that FAILS is emitted at "medium" by its own call site.
        def emit_event!(kind:, payload:, severity: "low", instance_id: nil)
          return unless defined?(::System::FleetEvent)
          ::System::FleetEvent.create!(
            account_id: @account.id,
            kind: kind,
            severity: severity,
            payload: payload,
            node_instance_id: instance_id,
            emitted_at: Time.current
          )
        rescue StandardError
          # opportunistic — never block on event emission
        end
      end
    end
  end
end
