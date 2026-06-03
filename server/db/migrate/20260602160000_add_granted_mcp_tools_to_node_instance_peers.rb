# frozen_string_literal: true

# AI/MCP workload substrate L2 — per-instance MCP tool grant. The glob patterns an
# instance-agent is authorized to invoke on the platform MCP (default-deny: empty
# = none). Read by core Mcp::Principal via the injected tool_grant_resolver.
class AddGrantedMcpToolsToNodeInstancePeers < ActiveRecord::Migration[8.1]
  def change
    add_column :system_node_instance_peers, :granted_mcp_tools, :jsonb, null: false, default: []
  end
end
