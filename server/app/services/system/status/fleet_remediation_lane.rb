# frozen_string_literal: true

module System
  module Status
    # THE FLEET'S REMEDIATION LANE (design §5.1, B4).
    #
    # One instance, registered against every signal kind in
    # DecisionEngine::SIGNAL_BINDINGS by RemediationWiring. It is a generic
    # adapter keyed by kind rather than fifty-odd classes, because nothing
    # about describing or proceeding differs per kind except what the BINDING
    # already says: its action category, its owner, and whether it is advisory.
    #
    # ── #describe ASKS THE GATE; IT DOES NOT RE-IMPLEMENT IT ────────────────
    # The decision (routed-lane refusal, consent budget, plane resolution,
    # intervention policy) comes from FleetAutonomyService#preview_gate, the
    # write-free twin of #gate_action!, so the lane cannot drift from the gate
    # it reports on. Nothing is consumed: no consent unit, no approval, no
    # notification, and the owner agent is looked up with `mint: false`.
    #
    # ── THE INV-1 FENCE RUNS FIRST ──────────────────────────────────────────
    # The DecisionEngine's appliers refuse to act on this control plane's own
    # hosting node (SelfManagementFence). The lane asks the same fence before
    # anything else, and its refusal reaches the screen in the fence's own
    # words. A proceed on a fenced target never reaches the gate, so it
    # consumes nothing either.
    #
    # ── WHAT "AUTO IN PROGRESS" PROMISES ────────────────────────────────────
    # Only a kind with a REMEDIATION_APPLIERS entry can act. An observation or
    # plan-only binding may well gate to :proceed, but nothing is then applied,
    # so reporting auto_in_progress for it would tell the operator the fleet is
    # fixing something it is not. Those report not_actuatable, with the gate's
    # own answer still carried in `gate` and `policy`.
    #
    # ── #proceed! IS THE LANE'S OWN ACTUATOR ────────────────────────────────
    # Core never calls it (Platform::Remediation::Lane). It runs the fence, then
    # the fleet gate — the same #gate_action! the autonomy tick uses — and
    # returns the gate's result. Applying a remediation needs the signal's
    # payload, which only the tick holds, so the applier stays the tick's.
    class FleetRemediationLane < ::Platform::Remediation::Lane
      KEY = "system.fleet"

      NO_BINDING = "NoFleetBinding"
      NO_ACCOUNT = "SharedComponent"
      NO_AGENT   = "NoGateAgent"
      NO_APPLIER = "NoRemediationApplier"

      # Registry keys of the component kinds the target derivation reads.
      # A kind's key is data (it lands in component rows), not a class name.
      NODE_INSTANCE      = "node_instance"
      NODE               = "node"
      NODE_MODULE        = "node_module"
      PLATFORM_SUBSYSTEM = "platform_subsystem"

      PLATFORM_SUBSYSTEM_REASON =
        "platform_subsystem components are this control plane's own; no fleet lane may act on them " \
        "(INV-1: no self-management). Management authority must come from the consensus group, " \
        "never the node itself."

      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      # A fresh fence per question: the module memoizes the self-hosting id
      # for the life of the including object, and this lane lives for the
      # life of the process.
      class Fence
        include ::System::Autonomy::SelfManagementFence
      end

      Target = Struct.new(:instance, :node_id, :module_id, keyword_init: true) do
        # The gate's metadata shape: the keys #gate_environment and the consent
        # budget read, exactly as a signal payload carries them.
        def metadata
          { "instance_id" => instance&.id, "node_id" => node_id, "module_id" => module_id }.compact
        end
      end

      def key
        KEY
      end

      def signal_kinds
        bindings.keys
      end

      def describe(component_status, signal_kind, account: nil)
        kind = signal_kind.to_s
        binding = bindings[kind]
        return refused(NO_BINDING) unless binding
        return refused(NO_ACCOUNT) if account.nil?

        target = target_for(component_status, account)
        fenced = fence_refusal(component_status, target)
        return refused(fenced) if fenced

        gate = gate_for(account, binding, mint: false)
        return refused("#{NO_AGENT}: no #{engine.owner_for(binding)} agent in this account") unless gate

        preview = gate.preview_gate(binding[:action_category], metadata: target.metadata,
                                                              advisory: advisory?(binding))
        report(preview, kind, target, account)
      end

      def proceed!(component_status, signal_kind, account: nil, **_options)
        kind = signal_kind.to_s
        binding = bindings[kind]
        return { decision: :denied, reason: NO_BINDING } unless binding
        return { decision: :denied, reason: NO_ACCOUNT } if account.nil?

        target = target_for(component_status, account)
        fenced = fence_refusal(component_status, target)
        return { decision: :denied, reason: fenced } if fenced

        gate = gate_for(account, binding, mint: true)
        return { decision: :denied, reason: NO_AGENT } unless gate

        gate.gate_action!(
          binding[:action_category],
          metadata: target.metadata.merge(
            "signal_kind" => kind,
            "component_kind" => component_status.component_kind,
            "component_ref" => component_status.component_ref
          ),
          reasoning: { summary: "Remediation lane proceed: #{kind} on " \
                                "#{component_status.component_kind}/#{component_status.component_ref}" },
          advisory: advisory?(binding)
        )
      end

      private

      def engine
        ::System::Fleet::DecisionEngine
      end

      def bindings
        engine::SIGNAL_BINDINGS
      end

      def advisory?(binding)
        binding[:advisory] == true
      end

      def report(preview, kind, target, account)
        state, can_proceed, reason = rung_for(preview)
        unless engine::REMEDIATION_APPLIERS.key?(kind)
          state = ::Platform::ComponentStatus::REMEDIATION_NOT_ACTUATABLE
          can_proceed = false
          reason = "#{NO_APPLIER}: #{kind} has no remediation applier; the fleet gate can only notify or plan"
        end

        {
          state: state,
          lane_key: KEY,
          policy: preview[:policy] || preview[:gate],
          consent: consent_report(preview[:consent]),
          # gate_action! applies no disruption budget; a skill plan may carry
          # a disruption_pct, but nothing gates on it.
          disruption: { applied_by_gate: false },
          environment_ceiling: ceiling_report(preview),
          blast_radius: blast_radius_for(target, account),
          can_proceed: can_proceed,
          reason: reason,
          gate: preview[:gate]
        }
      end

      # The gate's decision words mapped onto the row's rungs, per the Lane
      # contract: proceed -> auto_in_progress, pending -> awaiting_operator,
      # anything else -> not_actuatable, with the gate's own reason verbatim.
      def rung_for(preview)
        cs = ::Platform::ComponentStatus
        case preview[:decision]
        when :proceed then [ cs::REMEDIATION_AUTO_IN_PROGRESS, true, nil ]
        when :pending then [ cs::REMEDIATION_AWAITING_OPERATOR, false, preview[:reason].presence || preview[:gate].to_s ]
        else [ cs::REMEDIATION_NOT_ACTUATABLE, false, preview[:reason].presence || preview[:gate].to_s ]
        end
      end

      def refused(reason)
        {
          state: ::Platform::ComponentStatus::REMEDIATION_NOT_ACTUATABLE,
          lane_key: KEY,
          policy: nil,
          consent: { remaining: nil, budget: nil },
          disruption: { applied_by_gate: false },
          environment_ceiling: nil,
          blast_radius: nil,
          can_proceed: false,
          reason: reason
        }
      end

      def consent_report(headroom)
        return { remaining: nil, budget: nil } unless headroom

        { remaining: headroom.remaining, budget: headroom.budget, used: headroom.used }
      end

      def ceiling_report(preview)
        environment = preview[:environment]
        escalation = preview[:environment_escalation]
        return nil if environment.nil? && escalation.nil?

        { environment: environment&.slug, max_blast_radius: environment&.max_blast_radius,
          escalation: escalation }.compact
      end

      def blast_radius_for(target, account)
        node = target.instance&.node ||
               (target.node_id && ::System::Node.where(account_id: account.id).find_by(id: target.node_id))
        return nil unless node

        traced = ::System::BlastRadiusService.new(account: account).trace(node.name)
        return { error: traced[:error] } unless traced[:success]

        { node: node.name, instance_count: traced.dig(:target, :instance_count),
          total_dependents: traced[:total_dependents] }
      rescue StandardError => e
        { error: "#{e.class}: #{e.message}" }
      end

      # What the component would be acted ON. The component's own ref when its
      # kind is the resource, otherwise the dependency edges its contributor
      # already declared (dependencies_for), so no kind needs a special case.
      def target_for(component_status, account)
        deps = Array(component_status.dependencies)
        kind = component_status.component_kind.to_s
        ref = component_status.component_ref.to_s

        instance = find_instance(account, kind == NODE_INSTANCE ? ref : dependency_ref(deps, NODE_INSTANCE))
        node_id = kind == NODE ? ref : (instance&.node_id || dependency_ref(deps, NODE))
        Target.new(instance: instance, node_id: node_id.presence, module_id: (kind == NODE_MODULE ? ref : nil))
      end

      def find_instance(account, id)
        return nil unless id.to_s.match?(UUID)

        ::System::NodeInstance.where(account_id: account.id).find_by(id: id)
      end

      def dependency_ref(deps, kind)
        edge = deps.find { |dep| dep.is_a?(Hash) && (dep["kind"] || dep[:kind]).to_s == kind }
        edge && (edge["ref"] || edge[:ref]).to_s.presence
      end

      # nil when the fence has no objection; otherwise the refusal, in the
      # fence's own words. A component with no host to fence is not fenced —
      # except the control plane's own subsystems, which have no instance to
      # point at and are refused outright rather than assumed safe.
      def fence_refusal(component_status, target)
        subject = target.instance || target.node_id
        if subject.nil?
          return component_status.component_kind.to_s == PLATFORM_SUBSYSTEM ? PLATFORM_SUBSYSTEM_REASON : nil
        end

        Fence.new.assert_not_self_managed!(subject, action: "remediate")
        nil
      rescue ::System::Autonomy::SelfManagementFence::SelfManagementViolation => e
        e.message
      end

      # The gate the tick would decide this binding under: the binding's owner,
      # falling back to the tick's own agent when the owner is not seeded
      # (FleetAutonomyService#for_owner does the same, but also EMITS a warning
      # event, which a describe must not).
      def gate_for(account, binding, mint:)
        [ engine.owner_for(binding), ::System::Fleet::FleetAutonomyService::DEFAULT_OWNER ].uniq.each do |key|
          agent = ::System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: key, mint: mint)
          next unless agent

          agent.resolving_account = account if agent.respond_to?(:resolving_account=)
          return ::System::Fleet::FleetAutonomyService.new(account: account, agent: agent, owner_key: key)
        end
        nil
      end
    end
  end
end
