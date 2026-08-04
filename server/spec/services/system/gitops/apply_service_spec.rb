# frozen_string_literal: true

require "rails_helper"

# ApplyService lands TemplateModule joins straight from an approved fleet.yaml
# diff, bypassing the assignment-path guard. GitOps apply is AUTHORING, not
# reproduction — fleet.yaml is the desired state and the operator approved this
# specific line — so an error-severity conflict is refused the same way a stale
# conflict is: a failed Result naming the problem, leaving the rest of the
# repository applied and the fix in fleet.yaml where it belongs.
RSpec.describe System::Gitops::ApplyService, "#apply! assignment composition guard" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:category) { create(:system_node_module_category, account: account, name: "cat-#{SecureRandom.hex(3)}") }
  let(:other_category) { create(:system_node_module_category, account: account, name: "other-#{SecureRandom.hex(3)}") }
  let(:agent) { create(:ai_agent, account: account, slug: "gitops-#{SecureRandom.hex(4)}") }

  def node_module(name, variety: "subscription", in_category: category)
    create(:system_node_module, account: account, node_platform: platform,
           category: in_category, variety: variety, name: "#{name}-#{SecureRandom.hex(3)}")
  end

  def preassign(mod)
    ::System::TemplateModule.create!(node_template: template, node_module: mod)
  end

  def assignment_proposal(mod)
    ::Ai::AgentProposal.create!(
      account: account, ai_agent_id: agent.id,
      title: "GitOps: create assignment", proposal_type: "configuration",
      status: "approved", priority: "medium",
      proposed_changes: {
        source: "gitops",
        diff: { kind: "assignment", change: "create",
                desired: { template: template.name, module: mod.name } }
      }
    )
  end

  it "applies an assignment that composes cleanly" do
    mod = node_module("clean")

    result = described_class.apply!(proposal: assignment_proposal(mod))

    expect(result.ok?).to be true
    expect(::System::TemplateModule.exists?(node_template: template, node_module: mod)).to be true
  end

  it "refuses an assignment that would introduce an error-severity conflict" do
    preassign(node_module("installed-inst", variety: "instance"))
    incoming = node_module("incoming-inst", variety: "instance")

    result = described_class.apply!(proposal: assignment_proposal(incoming))

    expect(result.ok?).to be false
    expect(result.error).to include(incoming.name)
    expect(::System::TemplateModule.exists?(node_template: template, node_module: incoming)).to be false
  end

  # Same reason the assignment path diffs: a template that already composes
  # badly must still accept the rest of fleet.yaml, or one bad line wedges the
  # whole repository.
  it "still applies an unrelated assignment onto an already-colliding template" do
    preassign(node_module("stuck-a", variety: "instance"))
    preassign(node_module("stuck-b", variety: "instance"))
    unrelated = node_module("unrelated", in_category: other_category)

    result = described_class.apply!(proposal: assignment_proposal(unrelated))

    expect(result.ok?).to be true
  end

  # find_or_create_by! is idempotent by design — re-applying a line that is
  # already live must stay a no-op even on a template that now collides.
  it "stays idempotent for a join that already exists" do
    installed = node_module("already-inst", variety: "instance")
    preassign(installed)
    preassign(node_module("collides-inst", variety: "instance"))

    result = described_class.apply!(proposal: assignment_proposal(installed))

    expect(result.ok?).to be true
  end

  it "passes a warning-severity overlap through" do
    claimer = node_module("claimer")
    claimer.update!(protected_spec: "/etc/shadow")
    preassign(claimer)
    broad = node_module("broad", in_category: other_category)
    broad.update!(file_spec: "/etc/**")

    result = described_class.apply!(proposal: assignment_proposal(broad))

    expect(result.ok?).to be true
  end
end
