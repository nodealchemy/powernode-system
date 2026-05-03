# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# Comprehensive stabilization sweep P5 — integration spec for the GitOps
# reconciler. Exercises the full pipeline: RepoSyncService (stubbed to a
# local tmpdir) → DesiredStateParser → DiffEngine → Reconciler. Verifies
# Ai::AgentProposal rows are opened with the right shape + per-tick cap
# enforcement.
RSpec.describe System::Gitops::Reconciler do
  let(:account) { create(:account) }
  let(:repo) do
    create(:account) # ensure the account fixture is available
    System::GitopsRepository.create!(
      account: account, name: "fleet",
      repo_url: "https://example.com/fleet.git",
      branch: "main", path_prefix: "", enabled: true, auto_apply: false
    )
  end

  let(:work_tree) { Dir.mktmpdir("reconciler-spec") }
  let(:gitops_agent) do
    create(:ai_agent, account: account, name: "gitops-reconciler",
                       slug: "gitops-reconciler-#{SecureRandom.hex(4)}")
  end

  before do
    # Stub RepoSyncService to a local tmpdir — avoid the network /
    # subprocess-git path, which is covered by the service's own spec.
    allow(System::Gitops::RepoSyncService).to receive(:sync!).with(repo)
      .and_return(System::Gitops::RepoSyncService::Result.new(
        ok?: true, work_tree_path: work_tree, commit_sha: "abc123def456"
      ))

    # Make Reconciler find our agent so proposals can be created
    allow(Ai::Agent).to receive(:where).and_call_original
    gitops_agent # eager
  end

  after { FileUtils.rm_rf(work_tree) }

  describe ".reconcile!" do
    context "first reconciliation against an empty fleet" do
      let(:platform) { create(:system_node_platform, account: account) }

      before do
        File.write(File.join(work_tree, "fleet.yaml"), <<~YAML)
          templates:
            web-server:
              name: web-server
              description: Standard web nodes
              node_platform_id: #{platform.id}
        YAML
      end

      it "opens an Ai::AgentProposal for the create diff" do
        expect {
          result = described_class.reconcile!(repository: repo)
          expect(result.ok?).to be true
          expect(result.diff_count).to eq(1)
          expect(result.proposal_ids.size).to eq(1)
        }.to change { Ai::AgentProposal.count }.by(1)
      end

      it "marks the proposal as gitops_reconcile in proposed_changes" do
        described_class.reconcile!(repository: repo)

        proposal = Ai::AgentProposal.last
        expect(proposal.proposed_changes["source"]).to eq("gitops")
        expect(proposal.proposed_changes["repository_id"]).to eq(repo.id)
        expect(proposal.proposed_changes["commit_sha"]).to eq("abc123def456")
      end

      it "uses configuration proposal_type" do
        described_class.reconcile!(repository: repo)
        expect(Ai::AgentProposal.last.proposal_type).to eq("configuration")
      end

      it "stores the diff_summary on the GitopsSyncRun" do
        result = described_class.reconcile!(repository: repo)
        run = repo.sync_runs.last
        expect(run.diff_summary["template"]).to eq(1)
        expect(run.status).to eq("success")
      end

      it "advances repository.last_synced_at + last_synced_revision" do
        described_class.reconcile!(repository: repo)

        repo.reload
        expect(repo.last_synced_at).to be_within(5.seconds).of(Time.current)
        expect(repo.last_synced_revision).to eq("abc123def456")
        expect(repo.last_status).to eq("success")
      end
    end

    context "when fleet.yaml is missing" do
      it "returns ok:false with an error message + records failed sync_run" do
        # Don't create fleet.yaml in work_tree
        result = described_class.reconcile!(repository: repo)

        expect(result.ok?).to be false
        expect(result.error).to include("not found")
        expect(repo.sync_runs.last.status).to eq("failed")
      end
    end

    context "when RepoSyncService fails (network down)" do
      before do
        allow(System::Gitops::RepoSyncService).to receive(:sync!).with(repo)
          .and_return(System::Gitops::RepoSyncService::Result.new(
            ok?: false, error: "Network unreachable"
          ))
      end

      it "records a failed sync_run without parsing or diffing" do
        expect(System::Gitops::DesiredStateParser).not_to receive(:parse!)
        expect(System::Gitops::DiffEngine).not_to receive(:diff!)

        result = described_class.reconcile!(repository: repo)

        expect(result.ok?).to be false
        expect(result.error).to include("Network")
        expect(repo.sync_runs.last.status).to eq("failed")
      end
    end

    context "per-tick proposal cap" do
      let(:platform) { create(:system_node_platform, account: account) }

      before do
        # Build a fleet.yaml with more diffs than the cap (default 25)
        templates_yaml = (1..30).map do |i|
          "  template-#{i}:\n    name: template-#{i}\n    description: t\n    node_platform_id: #{platform.id}\n"
        end.join
        File.write(File.join(work_tree, "fleet.yaml"), "templates:\n#{templates_yaml}")
        stub_const("System::Gitops::Reconciler::MAX_PROPOSALS_PER_TICK", 5)
      end

      it "caps proposals at MAX_PROPOSALS_PER_TICK + marks status partial" do
        result = described_class.reconcile!(repository: repo)

        expect(result.diff_count).to eq(30) # all detected
        expect(result.proposal_ids.size).to eq(5) # but only 5 opened
        expect(repo.reload.last_status).to eq("partial")
        expect(repo.last_error).to include("MAX_PROPOSALS_PER_TICK")
      end
    end

    context "destroy diffs get :high priority" do
      let!(:existing_template) { create(:system_node_template, account: account, name: "stale-template") }

      before do
        # fleet.yaml is missing the existing template, so the engine
        # will emit a :destroy diff for it.
        File.write(File.join(work_tree, "fleet.yaml"), "templates: {}\n")
      end

      it "opens a destroy proposal at high priority" do
        described_class.reconcile!(repository: repo)

        proposal = Ai::AgentProposal.last
        expect(proposal.priority).to eq("high")
        expect(proposal.title).to include("destroy")
        expect(proposal.proposed_changes.dig("diff", "name")).to eq("stale-template")
      end
    end
  end
end
