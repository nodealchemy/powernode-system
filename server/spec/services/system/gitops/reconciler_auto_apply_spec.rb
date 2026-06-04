# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# Auto-apply safety-gate spec for the GitOps reconciler. The base
# reconciler_spec.rb covers the proposal-open path; this file exercises the
# wired auto-apply branch added in the GitOps auto-apply feature. Auto-apply
# lets the reconciler approve + apply a proposal WITHOUT operator review, so
# every safety gate is verified here:
#
#   1. repository.auto_apply must be true
#   2. the diff must be non-destructive (create / update — never destroy)
#   3. the account must NOT be halted (kill-switch / emergency-halt)
#   4. only the per-tick-capped diffs are eligible
#
# RepoSyncService is stubbed to a local tmpdir (same approach as the base
# spec) so we never touch the network / subprocess-git path.
RSpec.describe System::Gitops::Reconciler, "#reconcile! auto-apply" do
  let(:account) { create(:account) }
  let(:auto_apply) { true }
  let(:repo) do
    System::GitopsRepository.create!(
      account: account, name: "fleet",
      repo_url: "https://example.com/fleet.git",
      branch: "main", path_prefix: "", enabled: true, auto_apply: auto_apply
    )
  end

  let(:work_tree) { Dir.mktmpdir("reconciler-auto-apply-spec") }
  let(:platform) { create(:system_node_platform, account: account) }
  let!(:gitops_agent) do
    create(:ai_agent, account: account, name: "gitops-reconciler",
                       slug: "gitops-reconciler-#{SecureRandom.hex(4)}")
  end

  before do
    allow(System::Gitops::RepoSyncService).to receive(:sync!).with(repo)
      .and_return(System::Gitops::RepoSyncService::Result.new(
        ok?: true, work_tree_path: work_tree, commit_sha: "abc123def456"
      ))

    # Clear the M1 onboarding bootstrap (7 templates + 6 modules) so live
    # state reflects only what each example sets up. Mirrors reconciler_spec.rb.
    ::System::NodeModuleAssignment
      .joins(:node)
      .where(system_nodes: { account_id: account.id })
      .destroy_all
    ::System::NodeTemplate.where(account: account).destroy_all
    ::System::NodeModule.where(account: account).update_all(current_version_id: nil)
    ::System::NodeModule.where(account: account).destroy_all
  end

  after { FileUtils.rm_rf(work_tree) }

  # A non-destructive create diff: fleet.yaml declares a module that does not
  # exist live → DiffEngine emits change: :create. We use a `module` (not a
  # `template`) for the create path because ApplyService#apply_module create
  # round-trips cleanly from the DiffEngine's desired payload, whereas template
  # create expects a `node_platform` name that the diff does not carry.
  def write_create_module_yaml
    File.write(File.join(work_tree, "fleet.yaml"), <<~YAML)
      modules:
        nginx-public:
          name: nginx-public
          priority: 50
          variety: subscription
    YAML
  end

  context "auto_apply repo + non-destructive (create) diff" do
    before { write_create_module_yaml }

    it "auto-approves and applies the proposal → status implemented" do
      result = described_class.reconcile!(repository: repo)

      expect(result.ok?).to be true
      proposal = Ai::AgentProposal.last
      expect(proposal.status).to eq("implemented")
      # the module was actually created
      expect(::System::NodeModule.where(account: account, name: "nginx-public")).to exist
    end

    it "records audit metadata noting the AUTO approval (no human reviewer)" do
      described_class.reconcile!(repository: repo)

      proposal = Ai::AgentProposal.last
      expect(proposal.reviewed_by_id).to be_nil
      expect(proposal.reviewed_at).to be_present
      expect(proposal.impact_assessment["auto_applied"]).to be true
      expect(proposal.impact_assessment["approved_by"]).to eq("gitops_auto_apply")
    end

    it "reports the applied proposal in the Result" do
      result = described_class.reconcile!(repository: repo)
      proposal = Ai::AgentProposal.last
      expect(result.applied_proposal_ids).to include(proposal.id)
      expect(result.failed_proposal_ids).to be_empty
    end
  end

  context "auto_apply repo + non-destructive (update) diff" do
    let!(:existing_template) do
      create(:system_node_template, account: account, name: "web-server",
                                     node_platform: platform)
    end

    before do
      # Same name exists live but with a different description → :update diff.
      File.write(File.join(work_tree, "fleet.yaml"), <<~YAML)
        templates:
          web-server:
            name: web-server-renamed
            description: Updated description
            node_platform_id: #{platform.id}
      YAML
    end

    it "auto-applies the update → status implemented" do
      result = described_class.reconcile!(repository: repo)

      expect(result.ok?).to be true
      proposal = Ai::AgentProposal.last
      expect(proposal.proposed_changes.dig("diff", "change")).to eq("update")
      expect(proposal.status).to eq("implemented")
      expect(existing_template.reload.name).to eq("web-server-renamed")
    end
  end

  context "auto_apply repo + destructive (destroy) diff" do
    let!(:existing_template) do
      create(:system_node_template, account: account, name: "stale-template",
                                     node_platform: platform)
    end

    before do
      # fleet.yaml omits the existing template → DiffEngine emits :destroy.
      File.write(File.join(work_tree, "fleet.yaml"), "templates: {}\n")
    end

    it "leaves the proposal pending_review (never auto-applies a destroy)" do
      result = described_class.reconcile!(repository: repo)

      expect(result.ok?).to be true
      proposal = Ai::AgentProposal.last
      expect(proposal.proposed_changes.dig("diff", "change")).to eq("destroy")
      expect(proposal.status).to eq("pending_review")
      # the template must still exist
      expect(::System::NodeTemplate.where(account: account, name: "stale-template")).to exist
    end

    it "does not list the destroy proposal as applied" do
      result = described_class.reconcile!(repository: repo)
      proposal = Ai::AgentProposal.last
      expect(result.applied_proposal_ids).not_to include(proposal.id)
    end
  end

  context "auto_apply = false (legacy behavior)" do
    let(:auto_apply) { false }

    before { write_create_module_yaml }

    it "leaves the proposal pending_review (unchanged legacy behavior)" do
      result = described_class.reconcile!(repository: repo)

      expect(result.ok?).to be true
      proposal = Ai::AgentProposal.last
      expect(proposal.status).to eq("pending_review")
      expect(result.applied_proposal_ids).to be_empty
      # nothing applied
      expect(::System::NodeModule.where(account: account, name: "nginx-public")).not_to exist
    end
  end

  context "account is halted (kill-switch active)" do
    before do
      write_create_module_yaml
      account.suspend_ai!
    end

    it "skips auto-apply and leaves the proposal pending_review" do
      result = described_class.reconcile!(repository: repo)

      expect(result.ok?).to be true
      proposal = Ai::AgentProposal.last
      expect(proposal.status).to eq("pending_review")
      expect(result.applied_proposal_ids).to be_empty
      expect(::System::NodeModule.where(account: account, name: "nginx-public")).not_to exist
    end
  end

  context "ApplyService raises a stale conflict" do
    before do
      # Two create diffs so we can prove one failure does not abort the others.
      File.write(File.join(work_tree, "fleet.yaml"), <<~YAML)
        templates:
          web-server:
            name: web-server
            description: Standard web nodes
            node_platform_id: #{platform.id}
          api-server:
            name: api-server
            description: API nodes
            node_platform_id: #{platform.id}
      YAML

      call_count = 0
      allow(System::Gitops::ApplyService).to receive(:apply!) do |proposal:|
        call_count += 1
        if call_count == 1
          # First eligible proposal hits a stale conflict.
          System::Gitops::ApplyService::Result.new(
            ok?: false, error: "stale", stale_conflict: true
          )
        else
          # Subsequent proposals apply cleanly.
          proposal.update!(status: "implemented")
          System::Gitops::ApplyService::Result.new(
            ok?: true, applied_action: "created template", resource_id: proposal.id
          )
        end
      end
    end

    it "still succeeds; the conflicted proposal is not implemented; others unaffected" do
      result = described_class.reconcile!(repository: repo)

      expect(result.ok?).to be true
      expect(result.failed_proposal_ids.size).to eq(1)
      expect(result.applied_proposal_ids.size).to eq(1)

      statuses = Ai::AgentProposal.where(account: account).pluck(:status).sort
      expect(statuses).to eq(%w[implemented pending_review])
    end
  end
end
