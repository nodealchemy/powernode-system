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
      #   - "drain_instance"  → cordon + drain a specific NodeInstance
      #                          (mirrors system_drain_instance MCP action;
      #                          marks config.drain_* keys, emits FleetEvent)
      #   - "scale"           → mutate target_replicas on a deployment
      #                          (increment / decrement / set)
      #   - "failover_check"  → surface peers + instances showing stress
      #                          (stale heartbeats, errored instances,
      #                          unreachable endpoints). Returns an
      #                          operator-facing triage list — NO
      #                          automatic failover in v1.
      #
      # Plan reference: chat-driven platform deployment + resilience
      # (D2-ext.2).
      class PlatformResilienceExecutor < BaseSkillExecutor
        ACTIONS = %w[drain_instance scale failover_check].freeze
        SCALE_DIRECTIONS = %w[set increment decrement].freeze

        skill_descriptor(
          name: "platform_resilience",
          description: "Platform incident response — drain an instance, scale a deployment up/down, or triage peer/instance health. Use this skill when the operator describes a stress event (instance misbehaving, capacity pressure, peer heartbeats stale) or asks 'what should I do about X'.",
          category: "devops",
          inputs: {
            action: { type: "string", required: true,
                      description: "One of: drain_instance, scale, failover_check" },
            instance_id: { type: "string", required: false,
                           description: "NodeInstance id (required for drain_instance)" },
            timeout_seconds: { type: "integer", required: false, default: 600,
                               description: "Drain timeout for in-flight work (drain_instance only)" },
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
        # Marks the instance for drain via config keys. The worker
        # runtime (agent on-node) reads these keys and stops accepting
        # new work. Operator can follow up with terminate once the
        # in-flight work has bled off.
        def drain_instance(params)
          instance_id = params[:instance_id]
          return failure("instance_id is required") if instance_id.blank?

          instance = ::System::NodeInstance
                       .joins(:node)
                       .where(system_nodes: { account_id: @account.id })
                       .find_by(id: instance_id)
          return failure("Instance not found: #{instance_id}") unless instance

          timeout = (params[:timeout_seconds] || 600).to_i
          initiated_at = Time.current.iso8601

          instance.config ||= {}
          instance.config["drain_initiated_at"] = initiated_at
          instance.config["drain_timeout_seconds"] = timeout
          instance.config["drain_initiated_by_user_id"] = @user&.id
          instance.save!

          emit_event!(
            kind: "platform.resilience.drain_started",
            payload: {
              instance_id: instance.id, timeout_seconds: timeout, by_user: @user&.id
            },
            instance_id: instance.id
          )

          success(
            action: "drain_instance",
            data: {
              instance_id: instance.id,
              instance_name: instance.name,
              drain_initiated_at: initiated_at,
              drain_timeout_seconds: timeout
            },
            recommendations: [
              "Instance marked for drain. The on-node agent will stop accepting new work and bleed off in-flight load within #{timeout}s.",
              "After drain completes, call system_terminate_instance to remove the row OR system_destroy_instance to release the cloud resource."
            ]
          )
        end

        # ── scale ────────────────────────────────────────────────────────
        # Increment / decrement / set target_replicas on a deployment.
        # The actual provisioning sync (creating new NodeInstances to
        # match target) is queued for a follow-up — this records intent
        # via the existing Scaling-panel PATCH path.
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

          if new_target == previous_target
            return success(
              action: "scale",
              data: {
                deployment_id: deployment.id,
                deployment_name: deployment.name,
                target_replicas: new_target,
                no_op: true
              },
              recommendations: [ "Already at the requested replica count — no change." ]
            )
          end

          deployment.update!(target_replicas: new_target)
          emit_event!(
            kind: "platform.resilience.scale_intent",
            payload: {
              deployment_id: deployment.id,
              previous_target: previous_target,
              new_target: new_target,
              direction: direction
            }
          )

          success(
            action: "scale",
            data: {
              deployment_id: deployment.id,
              deployment_name: deployment.name,
              previous_target: previous_target,
              target_replicas: new_target,
              direction: direction
            },
            recommendations: [
              "target_replicas updated #{previous_target} → #{new_target}. Provisioning sync to create/drain instances to match is queued for a follow-up slice; for now monitor in /app/system/compute/platform/scaling."
            ]
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

        def emit_event!(kind:, payload:, instance_id: nil)
          return unless defined?(::System::FleetEvent)
          ::System::FleetEvent.create!(
            account_id: @account.id,
            kind: kind,
            severity: "info",
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
