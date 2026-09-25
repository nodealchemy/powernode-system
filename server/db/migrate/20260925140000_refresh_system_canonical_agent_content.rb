# frozen_string_literal: true

require_relative "../seeds/content/canonical_agent_content"

# Carries the text in db/seeds/content/canonical_agent_content.rb (the "Use
# when" routing sentences of five system agents) to installs that already have
# the rows; seeds run only on an install's first boot. A field an operator
# edited is kept and logged (core's Ai::Agents::CanonicalContentRefresh); down
# restores what each write replaced.
class RefreshSystemCanonicalAgentContent < ActiveRecord::Migration[8.1]
  # Table-only model: no Ai::Agent callbacks (version bumps, audits) run.
  class AgentRow < ActiveRecord::Base
    self.table_name = "ai_agents"
  end

  def up
    AgentRow.reset_column_information
    System::Seeds::CanonicalAgentContent.refresh_catalog!(AgentRow)
  end

  def down
    AgentRow.reset_column_information
    System::Seeds::CanonicalAgentContent.revert_catalog!(AgentRow)
  end
end
