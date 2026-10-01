# frozen_string_literal: true

module System
  # Records the blast radius of a change to a template's module set: the
  # TemplateApprovalPolicy classification plus a durable `system.template_mutation`
  # FleetEvent, filed under one correlation_id per template so
  # system_inspect_correlation reads the template's mutation history in order.
  #
  # Returns the radius hash, or nil when the template carries no live fleet
  # (nothing to record). `extra` is merged into both the radius and the event
  # payload — the unassign path's purge count and node ids. `source` names the
  # door the change came through.
  #
  # Moved out of SystemFleetTool (IMP-5fa3c8d0e2f7) so the REST DELETE door
  # records exactly what the MCP verb records, through
  # System::TemplateModuleUnassignService, rather than the tool holding a
  # private copy only its own callers could reach.
  class TemplateMutationRecorder
    def self.record!(account:, template:, node_module:, change:, initiated_by:, source: "system_fleet_tool", extra: {})
      classification = ::System::Ai::Skills::TemplateApprovalPolicy.for(template: template)
      return nil unless classification.requires_approval?

      radius = {
        requires_approval: true,
        provisioned_node_count: classification.provisioned_node_count,
        reason: classification.reason
      }.merge(extra)

      ::System::Fleet::EventBroadcaster.emit!(
        account: account,
        kind: "system.template_mutation",
        severity: :medium,
        source: source,
        correlation_id: "template_mutation:#{template.id}",
        node_module_id: node_module.id,
        payload: radius.merge(
          change: change,
          template_id: template.id,
          template_name: template.name,
          node_module_name: node_module.name,
          initiated_by: initiated_by || "system"
        )
      )

      radius
    end
  end
end
