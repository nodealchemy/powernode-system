# frozen_string_literal: true

module Ai
  module Tools
    # MCP surface for infrastructure blast-radius — the fleet-topology
    # counterpart to core's `code_blast_radius` (Ai::Tools::CodeAnalysisTool /
    # Ai::Codebase::BlastRadiusService). Given a fleet node identifier (a
    # System::Node name, a System::NodeInstance name, or a bare provider
    # cluster-node token like "dna"/"rna" embedded in NodeInstance
    # #cloud_instance_id), derives what currently depends on it: SDWAN peers/
    # host-bridges/VIPs/services/port-mappings, instance-pool membership,
    # direct + cross-node storage assignments, and the other
    # System::NodeInstance::CASCADE_DEPENDENTS categories.
    #
    # Read-only — this tool never mutates fleet state. Campaign 019f9250
    # (Resilient Control Plane v2), increment P0-d.
    class SystemBlastRadiusTool < BaseTool
      # Same floor as the rest of the read surface in SystemFleetTool — a
      # cross-cutting dependency query is a strict superset of "can read
      # nodes", and there's no dedicated finer-grained permission for it.
      REQUIRED_PERMISSION = "system.nodes.read"

      def self.definition
        {
          name: "system_blast_radius",
          description: "Infrastructure blast-radius: given a fleet node (System::Node name, " \
                       "System::NodeInstance name, or a bare provider cluster-node token like " \
                       "\"dna\"/\"rna\"), derive what currently depends on it — SDWAN peers/VIPs/" \
                       "services/port-mappings, instance-pool membership, direct + cross-node " \
                       "storage assignments, and other node_instance_id FK dependents.",
          parameters: {
            node: { type: "string", required: true,
                    description: "Fleet node identifier: a System::Node#name, a System::NodeInstance#name, " \
                                 "or a provider cluster-node token (e.g. \"dna\") embedded in cloud_instance_id" }
          }
        }
      end

      protected

      def call(params)
        node = params[:node].presence || params["node"]
        return error_result("node is required") if node.blank?

        service = ::System::BlastRadiusService.new(account: account)
        service.trace(node)
      rescue StandardError => e
        Rails.logger.error("[SystemBlastRadiusTool] #{e.class}: #{e.message}")
        error_result("blast-radius computation failed: #{e.class}: #{e.message}")
      end
    end
  end
end
