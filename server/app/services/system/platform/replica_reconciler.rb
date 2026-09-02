# frozen_string_literal: true

module System
  module Platform
    # Converges the LIVE replica count of a System::PlatformDeployment toward
    # its declared `target_replicas`.
    #
    # IMP-8c0f0fe9a8cf (APO-3b). `target_replicas` used to be a write with no
    # reader that could act on it: the Scaling panel PATCH, the GitOps bridge
    # and the platform_resilience `scale` branch all stored the number, and the
    # only consumers were display (deployments_controller#serialize), diffing
    # (Gitops::DiffEngine) and peer preference (Powernode::Bootstrap). Nothing
    # created or removed an instance to match it, so "scaled to 3" meant a
    # column said 3 while the fleet stayed at 1.
    #
    # WHAT COUNTS AS A REPLICA. The same rail the Scaling panel reports on —
    # NodeInstance rows in `active` status whose Node carries the deployment's
    # node_template_id. Deliberately NOT NodeInstance::LIVE_REPLICA_STATUSES:
    # this service must converge the number an operator SEES in the panel, and
    # the panel's count is the narrower `active` scope
    # (deployments_controller#compute_actual_replicas). Two different numbers
    # for one deployment is how a reconciler ends up fighting its own display.
    #
    # WHAT IT REFUSES. A deployment whose template is the template of THIS
    # control plane's own hosting node (System::Autonomy::SelfManagementFence,
    # SiteSetting `self_hosting_node_id`). Readiness §7 / INV-1: the control
    # plane must never autonomously remediate its own hosting stack — every
    # hard failure the RCP campaign traces back to "ops-hub is its own control
    # plane". The fence is inert until an operator configures the setting, so
    # on a plane that has not declared its own host NOTHING is refused; that is
    # the documented default of the fence, not a gap this service invents.
    #
    # WHO MAY ACTUATE. Both directions check the permission that governs the
    # PRIMITIVE, not the one that governs the caller's entry point:
    # `system.instances.create` to provision, `system.instances.control` to
    # terminate. The MCP door onto this service maps to `system.platform.scale`,
    # which was the right grant while the scale branch only moved a column and
    # is too coarse now that it moves instances. Only an explicit in-process
    # caller (`internal: true`) is exempt.
    #
    # THE TWO DIRECTIONS ARE NOT SYMMETRIC, on purpose:
    #
    #   scale OUT provisions through System::ProvisioningService. Additive and
    #   reversible, so beyond the provision permission and the per-pass clamp it
    #   runs on the caller's authority.
    #
    #   scale IN terminates, which is irreversible, so it resolves TWO
    #   intervention policies first and takes the stricter: the platform's one
    #   declared terminate category (`system.task.terminate` — the same row
    #   System::Executors::TerminateInstance and the MCP `declare_action`
    #   resolve) and the narrower `system.platform.scale_in`. It actuates only
    #   when BOTH auto-execute. Absence of a row resolves to require_approval
    #   (Ai::InterventionPolicyService#default_policy), so the default install
    #   removes nothing and names the excess instances instead. The scale_in
    #   category is declared in System::Governance::PolicyDeclarations, so it is
    #   retunable in the Autonomy modal rather than being a verdict with no
    #   control behind it.
    #
    #   The terminate itself goes through System::ProvisioningService, NOT
    #   InstanceControlService: System::Executors::TerminateInstance documents
    #   the four controls that live only in ProvisioningService (the INV-1
    #   fence, the SDWAN peer detach, the dev-cell deploy-key revoke, and the
    #   "terminated" meter event), and a second destroy door must not be the
    #   one that drops them.
    class ReplicaReconciler
      include ::System::Autonomy::SelfManagementFence

      # Per-pass ceiling on how many instances one reconcile may create or
      # destroy. An unclamped pass turns a fat-fingered `target_replicas` into
      # a fleet-sized event. FIVE, not ten: CLAUDE.md's bulk-operation rule
      # puts the confirm-first threshold at "more than 5 items", and a
      # scale-out runs unattended on the caller's authority with no approval
      # row behind it, so the per-pass ceiling has to sit at that threshold
      # rather than at twice it. Re-running the same scale converges the rest
      # (a reconcile is idempotent against the live count), and the operator
      # can raise the ceiling deliberately via the SiteSetting.
      DEFAULT_MAX_DELTA = 5
      MAX_DELTA_SETTING_KEY = "system.platform.replica_reconcile_max_delta"

      SCALE_IN_ACTION_CATEGORY = "system.platform.scale_in"

      # The platform's ONE declared terminate category
      # (System::Executors::TerminateInstance::ACTION_CATEGORY, and the literal
      # on system_fleet_tool's `declare_action "system_terminate_instance"`).
      # Resolved IN ADDITION to SCALE_IN_ACTION_CATEGORY, stricter-of-the-two:
      # a second destroy door that consults only its own new category would let
      # an operator who set system.task.terminate to `block` be bypassed by
      # spelling the same destroy "scale in". (IMP-8c0f0fe9a8cf review.)
      TERMINATE_ACTION_CATEGORY = "system.task.terminate"

      # Permissions the two directions actuate under. The MCP surface maps
      # `system_platform_resilience` to `system.platform.scale`
      # (system_fleet_tool.rb PERMISSION_MAP), while every other door onto
      # these primitives requires `system.instances.create` (provision) or
      # `system.instances.control` (stop/terminate). Before this service
      # existed the scale branch only moved a column, so the coarser grant cost
      # nothing; now that it provisions and terminates, the grant that governs
      # the primitive has to be checked here or the skill becomes a privilege
      # escalation onto the fleet.
      PROVISION_PERMISSION = "system.instances.create"
      TERMINATE_PERMISSION = "system.instances.control"

      # Mirrors System::Ai::Skills::BaseSkillExecutor::AUTO_EXECUTE_POLICIES —
      # the verdicts that mean "run it now, without a durable approval row".
      AUTO_EXECUTE_POLICIES = %w[auto_approve notify_and_proceed].freeze

      HUB_REFUSAL_MESSAGE =
        "Refusing to reconcile replicas for %<name>s: its template hosts this control " \
        "plane itself. The control plane must never autonomously remediate its own " \
        "hosting stack (INV-1 / readiness §7) — management authority has to come from " \
        "the consensus group, never the node being managed. Scale this deployment from " \
        "another plane, or by hand."

      Result = Struct.new(
        :ok, :refused_reason, :message, :deployment_id, :target_replicas,
        :actual_before, :actual_after, :provisioned_instance_ids,
        :terminated_instance_ids, :pending_removal_instance_ids, :failures,
        keyword_init: true
      ) do
        def ok?
          ok
        end
      end

      def self.reconcile!(deployment:, account:, user: nil, agent: nil, internal: false)
        new(account: account, user: user, agent: agent, internal: internal).reconcile!(deployment)
      end

      # `internal` is the caller's own answer to BaseSkillExecutor#
      # internal_caller? — true only for a trusted in-process caller (the
      # autonomy reconcilers build executors with user: nil and mean it).
      # It defaults to FALSE so that every other shape — an MCP instance
      # principal, which also arrives with no User — is checked, not waved
      # through on the nil.
      def initialize(account:, user: nil, agent: nil, internal: false)
        @account = account
        @user = user
        @agent = agent
        @internal = internal
      end

      # True when `deployment` is the one hosting this control plane. Keyed on
      # the TEMPLATE rather than on an instance id because that is the rail the
      # deployment↔instance mapping already uses everywhere else (the panel's
      # replica count, the GitOps bridge); an instance-keyed answer would go
      # stale the first time the hub's VM is rebuilt, which has happened.
      def hub_deployment?(deployment)
        self_id = self_hosting_node_id
        return false if self_id.blank?
        return false if deployment.node_template_id.blank?

        ::System::Node.where(id: self_id).pick(:node_template_id) == deployment.node_template_id
      end

      def reconcile!(deployment)
        if hub_deployment?(deployment)
          return refusal(deployment, :control_plane_self_remediation,
                         format(HUB_REFUSAL_MESSAGE, name: deployment.name))
        end

        target = deployment.target_replicas.to_i
        before = live_scope(deployment).count
        delta  = clamp_delta(target - before)

        return scale_out(deployment, delta, before, target) if delta.positive?
        return scale_in(deployment, -delta, before, target) if delta.negative?

        empty_result(deployment, before, target,
                     "Already at #{target} live replica(s) — nothing to reconcile.")
      end

      private

      def scale_out(deployment, count, before, target)
        unless authorized_for?(PROVISION_PERMISSION)
          return refusal(
            deployment, :insufficient_permission,
            "Cannot scale #{deployment.name} out: provisioning an instance requires the " \
            "#{PROVISION_PERMISSION} permission, which this caller does not hold. " \
            "target_replicas was not converged.",
            actual_before: before, target: target
          )
        end

        node = provisioning_node(deployment)
        unless node
          return refusal(
            deployment, :no_provisioning_node,
            "Cannot scale #{deployment.name} out: no System::Node in this account carries the " \
            "deployment's template, so there is nothing to provision onto. Create the node (or " \
            "deploy the platform) first.",
            actual_before: before, target: target
          )
        end

        region_id, instance_type_id = provisioning_shape(deployment)
        unless region_id && instance_type_id
          return refusal(
            deployment, :no_provisioning_shape,
            "Cannot scale #{deployment.name} out: no provider region / instance type resolves for " \
            "node #{node.name}. Bind a provider region and instance type, then retry.",
            actual_before: before, target: target
          )
        end

        created = []
        failures = []
        count.times do |i|
          result = ::System::ProvisioningService.provision_instance(
            node: node,
            provider_region_id: region_id,
            provider_instance_type_id: instance_type_id,
            options: { name: "#{deployment.name}-replica-#{before + i + 1}" }
          )
          if result.respond_to?(:success?) && result.success?
            instance = result.data[:instance] || result.data["instance"]
            created << instance&.id
          else
            failures << { instance_id: nil,
                          error: (result.respond_to?(:error) ? result.error.to_s : "provisioning failed") }
          end
        rescue StandardError => e
          failures << { instance_id: nil, error: "#{e.class}: #{e.message}" }
        end

        Result.new(
          ok: true, deployment_id: deployment.id, target_replicas: target,
          actual_before: before, actual_after: live_scope(deployment).count,
          provisioned_instance_ids: created.compact,
          terminated_instance_ids: [], pending_removal_instance_ids: [],
          failures: failures,
          message: "Provisioned #{created.compact.size} of #{count} requested replica(s)."
        )
      end

      def scale_in(deployment, count, before, target)
        victims = live_scope(deployment).order(created_at: :desc, id: :desc).limit(count).to_a

        unless authorized_for?(TERMINATE_PERMISSION)
          return refusal(
            deployment, :insufficient_permission,
            "Cannot scale #{deployment.name} in: terminating an instance requires the " \
            "#{TERMINATE_PERMISSION} permission, which this caller does not hold. " \
            "target_replicas was not converged.",
            actual_before: before, target: target
          )
        end

        blocking = non_auto_execute_categories
        if blocking.any?
          return Result.new(
            ok: true, deployment_id: deployment.id, target_replicas: target,
            actual_before: before, actual_after: before,
            provisioned_instance_ids: [], terminated_instance_ids: [],
            pending_removal_instance_ids: victims.map(&:id), failures: [],
            message: "#{victims.size} replica(s) above target were NOT removed: the " \
                     "#{blocking.join(' and ')} policy does not auto-execute. Terminating an " \
                     "instance is irreversible — approve or retune that policy, or terminate " \
                     "these by hand."
          )
        end

        terminated = []
        failures = []
        victims.each do |instance|
          result = ::System::ProvisioningService.terminate_instance(instance: instance)
          if result.respond_to?(:success?) && result.success?
            terminated << instance.id
          else
            failures << { instance_id: instance.id,
                          error: (result.respond_to?(:error) ? result.error.to_s : "terminate failed") }
          end
        rescue StandardError => e
          failures << { instance_id: instance.id, error: "#{e.class}: #{e.message}" }
        end

        Result.new(
          ok: true, deployment_id: deployment.id, target_replicas: target,
          actual_before: before, actual_after: live_scope(deployment).count,
          provisioned_instance_ids: [], terminated_instance_ids: terminated,
          pending_removal_instance_ids: [], failures: failures,
          message: "Terminated #{terminated.size} of #{count} replica(s) above target."
        )
      end

      # STRICTER OF THE TWO. `system.task.terminate` is the platform's one
      # declared terminate category — System::Executors::TerminateInstance
      # resolves it, and system_fleet_tool's `declare_action` names it, with a
      # tripwire whose own comment says reaching the terminate body without a
      # policy evaluation is a fail-loudly bug. A scale-in is a terminate, so
      # it consults that row too; `system.platform.scale_in` narrows the
      # operator's control, it does not replace it. Both must auto-execute.
      #
      # Returns the categories that did NOT clear, so the caller can name them.
      def non_auto_execute_categories
        [ SCALE_IN_ACTION_CATEGORY, TERMINATE_ACTION_CATEGORY ].reject do |category|
          AUTO_EXECUTE_POLICIES.include?(resolved_policy_for(category))
        end
      end

      # FAIL CLOSED, the same way BaseSkillExecutor#resolved_policy does: an
      # unresolvable policy is not permission to destroy an instance.
      def resolved_policy_for(category)
        ::Ai::InterventionPolicyService
          .new(account: @account)
          .resolve(action_category: category, agent: @agent, user: @user)[:policy].to_s
      rescue StandardError => e
        Rails.logger.error("[ReplicaReconciler] #{category} policy resolution failed, refusing: #{e.class}: #{e.message}")
        "require_approval"
      end

      # Fail closed on the nil user: only an explicit in-process caller is
      # exempt. An instance principal arrives with @user nil AND @internal
      # false, and is refused here.
      def authorized_for?(permission)
        return true if @internal

        @user.present? && @user.has_permission?(permission)
      rescue StandardError => e
        Rails.logger.error("[ReplicaReconciler] permission check for #{permission} failed, refusing: #{e.class}: #{e.message}")
        false
      end

      def live_scope(deployment)
        ::System::NodeInstance
          .joins(:node)
          .where(system_nodes: { node_template_id: deployment.node_template_id,
                                 account_id: @account.id })
          .active
      end

      def provisioning_node(deployment)
        ::System::Node
          .where(account_id: @account.id, node_template_id: deployment.node_template_id)
          .order(:created_at).first
      end

      # Prefer the shape the deployment's own newest replica already runs —
      # a scale-out should widen the existing fleet, not silently introduce a
      # different region or instance type.
      #
      # FALLBACK, stated honestly: the account's OLDEST System::Provider, which
      # is arbitrary on a multi-provider account. System::Node has no `provider`
      # association to fall back to — `command grep -n "provider"
      # app/models/system/node.rb` returns zero association hits; its belongs_to
      # list is account / node_template / worker — so the "falls back to the
      # node's provider" this was copied from
      # (platform_deployment_orchestrator.rb) describes a branch that can never
      # be taken, in that file as much as in this one.
      def provisioning_shape(deployment)
        sibling = live_scope(deployment).order(created_at: :desc, id: :desc).first
        if sibling&.provider_region_id.present? && sibling.provider_instance_type_id.present?
          return [ sibling.provider_region_id, sibling.provider_instance_type_id ]
        end

        provider = ::System::Provider.where(account_id: @account.id).order(:created_at).first
        return [ nil, nil ] unless provider

        region = ::System::ProviderRegion.where(provider_id: provider.id).order(:created_at).first
        type   = ::System::ProviderInstanceType.where(provider_id: provider.id).order(:created_at).first
        [ region&.id, type&.id ]
      end

      def clamp_delta(delta)
        max = max_delta
        delta.clamp(-max, max)
      end

      def max_delta
        value = (::SiteSetting.get(MAX_DELTA_SETTING_KEY).presence || DEFAULT_MAX_DELTA).to_i
        value.positive? ? value : DEFAULT_MAX_DELTA
      rescue StandardError
        DEFAULT_MAX_DELTA
      end

      def refusal(deployment, reason, message, actual_before: nil, target: nil)
        Result.new(
          ok: false, refused_reason: reason, message: message,
          deployment_id: deployment.id,
          target_replicas: target || deployment.target_replicas.to_i,
          actual_before: actual_before, actual_after: actual_before,
          provisioned_instance_ids: [], terminated_instance_ids: [],
          pending_removal_instance_ids: [], failures: []
        )
      end

      def empty_result(deployment, before, target, message)
        Result.new(
          ok: true, deployment_id: deployment.id, target_replicas: target,
          actual_before: before, actual_after: before,
          provisioned_instance_ids: [], terminated_instance_ids: [],
          pending_removal_instance_ids: [], failures: [], message: message
        )
      end
    end
  end
end
