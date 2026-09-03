# frozen_string_literal: true

require "rails_helper"

# IMP-54f9a053ad27 — the stale-conflict message must NAME the resource that
# drifted.
#
# THE FINDING. `diff` is `proposal.proposed_changes["diff"]`, reloaded from a
# JSONB column, so it is STRING-keyed. The template and module update arms
# looked the row up with `diff["resource_id"] || diff[:resource_id]` (correct)
# but built the StaleConflictError message from the bare symbol
# `diff[:resource_id]`, which is always nil on the reloaded hash. The operator
# read "template  no longer exists" — two spaces, id absent — and was told to
# re-sync without being told what drifted. `error` is the top-level field an
# autonomous caller reads (IMP-4a3a45df69bc), so it identified nothing.
#
# The proposal is RELOADED before apply in every example: an in-memory
# `proposed_changes` keeps the symbol keys it was assigned with, and a spec
# that skipped the round-trip would pass on the defective code.
RSpec.describe System::Gitops::ApplyService, "stale-conflict message names the resource (IMP-54f9a053ad27)" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, name: "cat-#{SecureRandom.hex(3)}") }
  let(:agent)    { create(:ai_agent, account: account, slug: "gitops-#{SecureRandom.hex(4)}") }

  def update_proposal(kind:, resource_id:, name:)
    ::Ai::AgentProposal.create!(
      account: account, ai_agent_id: agent.id,
      title: "GitOps: update #{kind}", proposal_type: "configuration",
      status: "approved", priority: "medium",
      proposed_changes: {
        source: "gitops",
        diff: { kind: kind, change: "update", name: name, resource_id: resource_id,
                current: { name: name }, desired: { name: "#{name}-renamed" } }
      }
    ).reload
  end

  it "names the template id when the template drifted away after the proposal opened" do
    doomed = create(:system_node_template, account: account, node_platform: platform, name: "edge-old")
    proposal = update_proposal(kind: "template", resource_id: doomed.id, name: doomed.name)
    doomed.destroy!

    result = described_class.apply!(proposal: proposal)

    expect(result.ok?).to be false
    expect(result.stale_conflict).to be true
    expect(result.error).to eq("template \"#{doomed.id}\" no longer exists")
  end

  it "names the module id when the module drifted away after the proposal opened" do
    doomed = create(:system_node_module, account: account, node_platform: platform,
                    category: category, name: "mod-old-#{SecureRandom.hex(3)}")
    proposal = update_proposal(kind: "module", resource_id: doomed.id, name: doomed.name)
    doomed.destroy!

    result = described_class.apply!(proposal: proposal)

    expect(result.ok?).to be false
    expect(result.stale_conflict).to be true
    expect(result.error).to eq("module \"#{doomed.id}\" no longer exists")
  end
end
