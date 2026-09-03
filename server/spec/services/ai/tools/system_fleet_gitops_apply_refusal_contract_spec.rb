# frozen_string_literal: true

require "rails_helper"

# IMP-4a3a45df69bc — the caller-visible contract of system_gitops_apply_proposal
# on a refusal.
#
# THE FINDING. The action description promises "Errors with stale_conflict if
# reality drifted post-proposal", but the executor built the refusal with
# `success_result(applied: false, error: ..., stale_conflict: true)` — i.e.
# `success: true` (BaseTool#success_result). The conflict detail WAS in the
# payload; the one field a program branches on said the opposite. A human
# reading the body might notice `applied: false`; an agent branching on
# `success` structurally cannot, and a stale conflict is exactly the case where
# an autonomous caller must STOP rather than proceed as though the fleet now
# matches the repository.
#
# WHY THE RETURN AND NOT THE DESCRIPTION. The comment that defended the old
# shape ("so the operator can read the conflict reason without it looking like
# an error") is answerable: `error` carries the reason on the failure shape too,
# so nothing is lost but the label. And a refusal reported as an error is this
# tool's own dominant convention, not a deviation from it.
#
# BOTH HALVES ARE ORACLES. A response that says "failed" while the write landed
# is the same defect pointing the other way, so every refusal example asserts
# the TARGET ROW as well as the response: the resource was not created/renamed
# and the proposal did not move to "implemented".
#
# The success path is asserted in its own examples. A fix that turned every
# outcome into an error would be no fix, and one mutant that reddens both arms
# would prove neither.
RSpec.describe Ai::Tools::SystemFleetTool, "GitOps apply refusal contract (IMP-4a3a45df69bc)" do
  let(:account) { create(:account) }
  let(:operator) { create(:user, account: account, permissions: [ "system.modules.update" ]) }
  let(:agent) { create(:ai_agent, account: account) }
  let(:platform) { create(:system_node_platform, account: account) }

  let!(:gitops_repo) do
    ::System::GitopsRepository.create!(
      account: account, name: "apply-contract",
      repo_url: "https://git.example.test/fleet.git", branch: "main"
    )
  end

  def make_proposal(diff:, status: "approved", source: "gitops")
    ::Ai::AgentProposal.create!(
      account: account,
      ai_agent_id: agent.id,
      title: "GitOps: #{diff[:change]} #{diff[:kind]}",
      description: "apply contract spec",
      proposal_type: "configuration",
      status: status,
      priority: "medium",
      proposed_changes: {
        diff: diff, source: source,
        repository_id: gitops_repo.id, commit_sha: "abc123"
      }
    )
  end

  def apply(proposal)
    described_class.new(account: account, user: operator)
                   .execute(params: { action: "system_gitops_apply_proposal", proposal_id: proposal.id })
  end

  # ---------------------------------------------------------------------------
  # The stale conflict — a template that existed when the proposal was opened
  # and was destroyed before the operator approved the apply. This is the drift
  # the description names, raised as ApplyService::StaleConflictError.
  # ---------------------------------------------------------------------------
  describe "a genuine stale conflict" do
    let(:doomed_template) { create(:system_node_template, account: account, node_platform: platform, name: "edge-old") }

    let(:proposal) do
      resource_id = doomed_template.id
      p = make_proposal(diff: {
        kind: "template", change: "update", name: "edge-old",
        resource_id: resource_id, current: { name: "edge-old" },
        desired: { name: "edge-renamed" }
      })
      # Reality drifts AFTER the proposal is opened.
      doomed_template.destroy!
      p
    end

    it "reports failure on the field a program branches on" do
      r = apply(proposal)

      expect(r[:success]).to be false
    end

    it "names the conflict in the payload" do
      r = apply(proposal)

      # The message names the drifted id (IMP-54f9a053ad27): ApplyService reads
      # the string key of the JSONB-reloaded diff, so the operator is told WHAT
      # drifted, not just that something did.
      expect(r[:error]).to include("no longer exists")
      expect(r[:error]).to include(doomed_template.id)
      expect(r.dig(:data, :stale_conflict)).to be true
      expect(r.dig(:data, :applied)).to be false
      expect(r.dig(:data, :proposal_id)).to eq(proposal.id)
    end

    # The other half: the response must not merely SAY it refused.
    it "leaves the target row untouched — nothing was renamed into existence" do
      apply(proposal)

      expect(::System::NodeTemplate.where(account_id: account.id, name: "edge-renamed")).not_to exist
    end

    it "leaves the proposal unimplemented so a re-sync can supersede it" do
      apply(proposal)

      expect(proposal.reload.status).to eq("approved")
      expect(proposal.impact_assessment.to_h).not_to have_key("applied_at")
    end
  end

  # ---------------------------------------------------------------------------
  # Refusals that are NOT stale conflicts still fail, and are distinguishable:
  # the marker is not stamped on every refusal. It is NOT drift-exclusive
  # either — ApplyService raises StaleConflictError for an unresolvable
  # node_platform NAME on a create too (apply_service.rb:109), which is a
  # fleet.yaml authoring error rather than post-proposal drift. What these
  # examples pin is the weaker, true property: a refusal that carries no
  # conflict claim must not acquire one. Asserted separately so a mutant that
  # hardcodes the marker is caught here rather than masked by the conflict
  # examples.
  # ---------------------------------------------------------------------------
  describe "a non-drift refusal" do
    it "refuses a proposal that is not approved, without claiming a conflict" do
      proposal = make_proposal(
        diff: { kind: "template", change: "create", name: "never-applied",
                desired: { name: "never-applied", node_platform: platform.name } },
        status: "pending_review"
      )

      r = apply(proposal)

      expect(r[:success]).to be false
      expect(r[:error]).to include("only 'approved'")
      expect(r.dig(:data, :applied)).to be false
      expect(r.dig(:data, :stale_conflict)).to be_nil
      expect(::System::NodeTemplate.where(account_id: account.id, name: "never-applied")).not_to exist
      expect(proposal.reload.status).to eq("pending_review")
    end

    it "refuses an unsupported destroy diff, without claiming a conflict" do
      tmpl = create(:system_node_template, account: account, node_platform: platform, name: "keep-me")
      proposal = make_proposal(diff: {
        kind: "template", change: "destroy", name: "keep-me",
        resource_id: tmpl.id, current: { name: "keep-me" }, desired: nil
      })

      r = apply(proposal)

      expect(r[:success]).to be false
      expect(r[:error]).to include("not yet implemented")
      expect(r.dig(:data, :stale_conflict)).to be_nil
      expect(::System::NodeTemplate.where(id: tmpl.id)).to exist
      expect(proposal.reload.status).to eq("approved")
    end
  end

  # ---------------------------------------------------------------------------
  # The success path is unchanged — the fix must not turn every outcome into an
  # error. Separate examples, separate mutant.
  # ---------------------------------------------------------------------------
  describe "an applicable proposal" do
    it "still reports success and writes the row" do
      proposal = make_proposal(diff: {
        kind: "template", change: "create", name: "edge-applied",
        resource_id: nil, current: nil,
        desired: { name: "edge-applied", node_platform: platform.name }
      })

      r = apply(proposal)

      expect(r[:success]).to be true
      expect(r.dig(:data, :applied)).to be true
      expect(r.dig(:data, :applied_action)).to include("created template")
      expect(::System::NodeTemplate.where(account_id: account.id, name: "edge-applied")).to exist
      expect(proposal.reload.status).to eq("implemented")
    end
  end
end
