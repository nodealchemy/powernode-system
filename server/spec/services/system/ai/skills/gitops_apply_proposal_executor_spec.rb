# frozen_string_literal: true

require "rails_helper"

# HIER-P2F — the GitOps Reconciler's apply skill: a thin executor over
# System::Gitops::ApplyService, gated on the agent's own
# `system.gitops_apply_proposal` row — the SAME category the
# system_gitops_apply_proposal MCP verb parks under (IMP-0b4f18ae4384), so the
# skill door and the MCP door are one operator control.
#
# The oracle is the ROW (the IMP-ce5d320d3e4e lesson): every example reads the
# would-be template back rather than trusting the envelope alone.
RSpec.describe System::Ai::Skills::GitopsApplyProposalExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:author)   { create(:ai_agent, account: account) }
  let(:repo)     { create(:system_gitops_repository, account: account) }
  let(:exec)     { described_class.new(account: account) }

  def make_proposal(status: "approved", name: "edge-skill", account_record: account)
    ::Ai::AgentProposal.create!(
      account: account_record,
      ai_agent_id: author.id,
      title: "GitOps: create template #{name}",
      description: "skill spec",
      proposal_type: "configuration",
      status: status,
      priority: "medium",
      proposed_changes: {
        diff: { kind: "template", change: "create", name: name,
                resource_id: nil, current: nil,
                desired: { name: name, node_platform: platform.name } },
        source: "gitops", repository_id: repo.id, commit_sha: "abc123"
      }
    )
  end

  def template_applied?(name = "edge-skill")
    ::System::NodeTemplate.where(account_id: account.id, name: name).exists?
  end

  describe ".descriptor" do
    it "gates on the GitOps Reconciler's declared apply category and binds to that agent" do
      d = described_class.descriptor
      expect(d[:name]).to eq("gitops_apply_proposal")
      expect(d[:requires_approval]).to be true
      expect(d[:inputs].keys).to eq([ :proposal_id ])

      expect(described_class.action_category).to eq("system.gitops_apply_proposal")
      expect(described_class.action_category).to eq(Ai::Tools::SystemFleetTool::GITOPS_APPLY_PROPOSAL_CATEGORY)
      expect(System::Governance::PolicyDeclarations::GITOPS_RECONCILER_POLICIES)
        .to have_key(described_class.action_category)

      reg = System::Ai::Skills::SkillBindings.all.find { |r| r[:executor] == described_class }
      expect(reg[:agents]).to eq([ "GitOps Reconciler" ])
    end
  end

  describe "#execute (policy auto-executes)" do
    before { auto_execute_skill_policy!(account, described_class) }

    it "applies an approved gitops proposal to live fleet state and marks it implemented" do
      proposal = make_proposal

      r = exec.execute(proposal_id: proposal.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :applied)).to be true
      expect(r.dig(:data, :proposal_id)).to eq(proposal.id)
      expect(r.dig(:data, :applied_action)).to be_present
      expect(template_applied?).to be true
      expect(r.dig(:data, :proposal_status)).to eq(proposal.reload.status)
      expect(proposal.status).to eq("implemented")
    end

    it "returns the apply refusal as a failure (a proposal that is not approved applies nothing)" do
      proposal = make_proposal(status: "pending_review")

      r = exec.execute(proposal_id: proposal.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/only 'approved' proposals/)
      expect(r[:applied]).to be false
      expect(template_applied?).to be false
      expect(proposal.reload.status).to eq("pending_review")
    end

    it "flags a stale conflict on the failure envelope" do
      proposal = make_proposal
      allow(::System::Gitops::ApplyService).to receive(:apply!)
        .and_return(::System::Gitops::ApplyService::Result.new(ok?: false, error: "template moved", stale_conflict: true))

      r = exec.execute(proposal_id: proposal.id)

      expect(r[:success]).to be false
      expect(r[:error]).to eq("template moved")
      expect(r[:stale_conflict]).to be true
    end

    it "refuses a proposal that belongs to another account" do
      other_account = create(:account)
      proposal = make_proposal(account_record: other_account)

      r = exec.execute(proposal_id: proposal.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found/)
      expect(template_applied?).to be false
      expect(::System::NodeTemplate.where(account_id: other_account.id, name: "edge-skill")).to be_empty
    end
  end

  describe "the approval gate" do
    it "parks the apply (nothing written) when no policy auto-executes it" do
      proposal = make_proposal

      r = exec.execute(proposal_id: proposal.id)

      expect(r[:pending]).to be true
      expect(template_applied?).to be false
      expect(proposal.reload.status).to eq("approved")
    end
  end

  # HIER-P2F review — admission runs BEFORE the approval gate: a proposal that
  # is not in this account can only fail, so it must not park an approval an
  # operator then has to dispose of. No auto-execute policy here.
  describe "admission before the approval gate" do
    it "refuses a foreign proposal without parking an approval" do
      other_account = create(:account)
      proposal = make_proposal(account_record: other_account)

      r = exec.execute(proposal_id: proposal.id)

      expect(r[:success]).to be false
      expect(r[:pending]).to be_falsey
      expect(r[:error]).to match(/not found/)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
      expect(template_applied?).to be false
    end
  end

end
