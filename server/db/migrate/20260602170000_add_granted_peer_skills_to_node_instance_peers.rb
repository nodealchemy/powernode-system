# frozen_string_literal: true

# AI/MCP workload substrate L2.5 (A2A) — the skill-name glob patterns an
# instance-agent may invoke on OTHER peers via agent-to-agent MCP (default-deny).
class AddGrantedPeerSkillsToNodeInstancePeers < ActiveRecord::Migration[8.1]
  def change
    add_column :system_node_instance_peers, :granted_peer_skills, :jsonb, null: false, default: []
  end
end
