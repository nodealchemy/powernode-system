# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects provisioned instances whose TEMPLATE's current resolved
      # module closure (TemplateExpansionService) has grown past what is
      # actually assigned to the node (NodeModuleAssignment).
      #
      # ModuleDriftSensor can never see this: it only diffs a RUNNING
      # instance's reported digests against its ALREADY-ASSIGNED modules —
      # it never re-resolves the template. So a template mutation after
      # provisioning (a new TemplateModule, or a new `requires` edge on an
      # existing one — e.g. inc1's os.userland) is invisible to the fleet
      # forever unless something re-walks the closure. That's this sensor.
      #
      # Campaign 019f6084 §2.4.3.
      #
      # Pure read-side per the BaseSensor contract: computes + diffs only,
      # never mutates. Remediation (TemplateApplyService#apply! + a
      # sync_modules task, or a rolling-reprovision flag for pivot-booted
      # instances whose composed union is boot-time-fixed) is
      # DecisionEngine's job, gated by TemplateApprovalPolicy — see
      # DecisionEngine::SIGNAL_BINDINGS["system.template_closure_drift"] and
      # #apply_template_closure_drift.
      class TemplateClosureDriftSensor < BaseSensor
        def sense
          ::System::NodeInstance
            .joins(node: :node_template)
            .where(system_nodes: { account_id: account.id })
            .where(status: live_statuses)
            .includes(node: [ :node_template, :node_module_assignments ])
            .find_each.filter_map { |inst| sense_instance(inst) }
        end

        private

        def sense_instance(inst)
          node = inst.node
          template = node&.node_template
          return nil unless template

          closure_ids = closure_module_ids(template)
          return nil if closure_ids.empty?

          assigned_ids = node.node_module_assignments.map(&:node_module_id).to_set
          missing_ids = closure_ids - assigned_ids
          return nil if missing_ids.empty?

          classification = ::System::Ai::Skills::TemplateApprovalPolicy.for(template: template)

          signal(
            kind: "system.template_closure_drift",
            severity: :medium,
            payload: {
              instance_id: inst.id,
              node_id: node.id,
              template_id: template.id,
              missing_module_ids: missing_ids.to_a,
              missing_count: missing_ids.size,
              pivot_boot: inst.pivot_boot?,
              requires_approval: classification.requires_approval?,
              blast_radius_reason: classification.reason
            },
            fingerprint: "template_closure_drift:#{inst.id}"
          )
        end

        # "Provisioned" mirrors TemplateApprovalPolicy's own definition of
        # blast radius (LIVE_INSTANCE_SCOPE) rather than re-deriving a
        # status list here — the sensor and the gate must agree on what
        # counts as live fleet, or the sensor could fire for an instance the
        # policy itself would call "nothing provisioned."
        def live_statuses
          ::System::Ai::Skills::TemplateApprovalPolicy::LIVE_INSTANCE_SCOPE[:system_node_instances][:status]
        end

        # Memoized per sense pass — many instances share one template, and
        # TemplateExpansionService walks the full dependency graph, so
        # recomputing it per-instance would be O(instances) instead of
        # O(templates).
        def closure_module_ids(template)
          @closure_cache ||= {}
          @closure_cache[template.id] ||= ::System::TemplateExpansionService.new(
            template_modules: template.template_modules
          ).expand.modules.map(&:id).to_set
        end
      end
    end
  end
end
