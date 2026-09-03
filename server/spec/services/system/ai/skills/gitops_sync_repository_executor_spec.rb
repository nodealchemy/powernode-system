# frozen_string_literal: true

require "rails_helper"

# HIER-P2F — the GitOps Reconciler's sync skill: a thin executor over
# System::Gitops::Reconciler with the same run-minting and standby refusal the
# system_gitops_sync_repository MCP verb performs, gated on the agent's own
# `system.gitops_sync_repository` row (declared auto_approve — a sync is the
# read side: it refreshes the diff and opens proposals, it applies nothing).
RSpec.describe System::Ai::Skills::GitopsSyncRepositoryExecutor do
  let(:account) { create(:account) }
  let(:repo)    { create(:system_gitops_repository, account: account) }
  let(:exec)    { described_class.new(account: account) }

  def reconcile_result(**overrides)
    ::System::Gitops::Reconciler::Result.new(
      **{ ok?: true, diff_count: 2, proposal_ids: [ "p1", "p2" ], synced_revision: "abc123",
          diff_summary: { "create" => 2 }, error: nil }.merge(overrides)
    )
  end

  describe ".descriptor" do
    it "gates on the GitOps Reconciler's declared sync category and binds to that agent" do
      d = described_class.descriptor
      expect(d[:name]).to eq("gitops_sync_repository")
      expect(d[:category]).to eq("devops")
      expect(d[:requires_approval]).to be true
      expect(d[:inputs].keys).to eq([ :repository_id ])

      expect(described_class.action_category).to eq("system.gitops_sync_repository")
      expect(System::Governance::PolicyDeclarations::GITOPS_RECONCILER_POLICIES)
        .to have_key(described_class.action_category)

      reg = System::Ai::Skills::SkillBindings.all.find { |r| r[:executor] == described_class }
      expect(reg[:agents]).to eq([ "GitOps Reconciler" ])
    end
  end

  describe "#execute (policy auto-executes)" do
    before { auto_execute_skill_policy!(account, described_class) }

    it "mints a sync run, hands it to the reconciler and returns the finalized handle" do
      allow(::System::Gitops::Reconciler).to receive(:reconcile!).and_return(reconcile_result)

      r = exec.execute(repository_id: repo.id)

      expect(r[:success]).to be true
      run = ::System::GitopsSyncRun.where(gitops_repository_id: repo.id).last
      expect(run).to be_present
      expect(::System::Gitops::Reconciler).to have_received(:reconcile!).with(repository: repo, sync_run: run)
      expect(r.dig(:data, :sync_run_id)).to eq(run.id)
      expect(r.dig(:data, :repository_id)).to eq(repo.id)
      expect(r.dig(:data, :diff_count)).to eq(2)
      expect(r.dig(:data, :proposal_ids)).to eq([ "p1", "p2" ])
      expect(r.dig(:data, :synced_revision)).to eq("abc123")
    end

    it "returns a failure when the reconcile failed, keeping the run id for the operator" do
      allow(::System::Gitops::Reconciler).to receive(:reconcile!)
        .and_return(reconcile_result(ok?: false, error: "clone failed: auth", diff_count: 0, proposal_ids: []))

      r = exec.execute(repository_id: repo.id)

      expect(r[:success]).to be false
      expect(r[:error]).to eq("clone failed: auth")
      expect(r[:sync_run_id]).to eq(::System::GitopsSyncRun.where(gitops_repository_id: repo.id).last.id)
    end

    it "refuses on a standby control plane BEFORE any run exists" do
      allow(::System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(false)
      allow(::System::Gitops::Reconciler).to receive(:reconcile!)

      r = exec.execute(repository_id: repo.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/standby control plane/)
      expect(::System::GitopsSyncRun.where(gitops_repository_id: repo.id)).to be_empty
      expect(::System::Gitops::Reconciler).not_to have_received(:reconcile!)
    end

    it "refuses a repository that belongs to another account" do
      foreign = create(:system_gitops_repository)
      allow(::System::Gitops::Reconciler).to receive(:reconcile!)

      r = exec.execute(repository_id: foreign.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found/)
      expect(::System::Gitops::Reconciler).not_to have_received(:reconcile!)
    end
  end

  describe "the approval gate" do
    it "parks the sync (no run minted) when no policy auto-executes it" do
      allow(::System::Gitops::Reconciler).to receive(:reconcile!)

      r = exec.execute(repository_id: repo.id)

      expect(r[:pending]).to be true
      expect(::System::GitopsSyncRun.where(gitops_repository_id: repo.id)).to be_empty
      expect(::System::Gitops::Reconciler).not_to have_received(:reconcile!)
    end
  end

  # HIER-P2F review — admission runs BEFORE the approval gate (BaseSkillExecutor
  # validates first so a doomed call never parks an approval). No auto-execute
  # policy here. The STANDBY refusal deliberately stays inside #perform: which
  # plane is elected can change between parking and replay, so that one is not
  # an admission check.
  describe "admission before the approval gate" do
    it "refuses an unknown repository without parking an approval" do
      allow(::System::Gitops::Reconciler).to receive(:reconcile!)

      r = exec.execute(repository_id: SecureRandom.uuid)

      expect(r[:success]).to be false
      expect(r[:pending]).to be_falsey
      expect(r[:error]).to match(/not found/)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
      expect(::System::Gitops::Reconciler).not_to have_received(:reconcile!)
    end
  end

end
