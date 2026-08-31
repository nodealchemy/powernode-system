# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# IMP-8c1a94b8e1d6 — a FAILING reconcile must land on the repository row, not
# only on the sync run. Three operator surfaces (serialize_repo REST,
# serialize_gitops_repository MCP, GitopsTab.tsx) render
# GitopsRepository#last_status / #last_error; before this spec, every failure
# exit of Reconciler#reconcile! returned without touching them, so the row kept
# reporting its last SUCCESS — or the "pending" column default forever, if it
# had never succeeded — while every sync underneath it failed.
#
# Both halves are covered deliberately: the failure must be RECORDED, and it
# must be CLEARED on the next success. A fix that only writes the error turns a
# transient failure into a permanent false alarm.
RSpec.describe System::Gitops::Reconciler, "repository status recording" do
  let(:account) { create(:account) }
  let(:repo) do
    System::GitopsRepository.create!(
      account: account, name: "fleet",
      repo_url: "https://example.com/fleet.git",
      branch: "main", path_prefix: "", enabled: true, auto_apply: false
    )
  end

  let(:work_tree) { Dir.mktmpdir("reconciler-status-spec") }
  let!(:gitops_agent) do
    create(:ai_agent, account: account, name: "gitops-reconciler",
                      slug: "gitops-reconciler-#{SecureRandom.hex(4)}")
  end

  before do
    allow(System::Gitops::RepoSyncService).to receive(:sync!).with(repo)
      .and_return(System::Gitops::RepoSyncService::Result.new(
                    ok?: true, work_tree_path: work_tree, commit_sha: "abc123def456"
                  ))

    # Account bootstrap seeds templates/modules; clear so the diff engine sees
    # a truly empty fleet (mirrors reconciler_spec.rb).
    ::System::NodeModuleAssignment
      .joins(:node)
      .where(system_nodes: { account_id: account.id })
      .destroy_all
    ::System::NodeTemplate.where(account: account).destroy_all
    ::System::NodeModule.where(account: account).update_all(current_version_id: nil)
    ::System::NodeModule.where(account: account).destroy_all

    File.write(File.join(work_tree, "fleet.yaml"), "templates: {}\n")
  end

  after { FileUtils.rm_rf(work_tree) }

  # Each context drives ONE failure exit of reconcile! so a fix that covers
  # some but not all of them is distinguishable from a fix that covers all.
  describe "failure exits" do
    context "step 1 — clone/pull fails (RepoSyncService not ok)" do
      before do
        allow(System::Gitops::RepoSyncService).to receive(:sync!).with(repo)
          .and_return(System::Gitops::RepoSyncService::Result.new(
                        ok?: false, error: "Network unreachable"
                      ))
      end

      it "records failed + the error on the repository row" do
        described_class.reconcile!(repository: repo)

        repo.reload
        expect(repo.last_status).to eq("failed")
        expect(repo.last_error).to include("Network unreachable")
      end
    end

    context "step 2 — desired-state parse fails" do
      before { FileUtils.rm_f(File.join(work_tree, "fleet.yaml")) }

      it "records failed + the error on the repository row" do
        described_class.reconcile!(repository: repo)

        repo.reload
        expect(repo.last_status).to eq("failed")
        expect(repo.last_error).to include("not found")
      end
    end

    context "step 3 — diff engine returns not ok" do
      before do
        allow(System::Gitops::DiffEngine).to receive(:diff!)
          .and_return(System::Gitops::DiffEngine::Result.new(
                        ok?: false, error: "diff engine exploded"
                      ))
      end

      it "records failed + the error on the repository row" do
        described_class.reconcile!(repository: repo)

        repo.reload
        expect(repo.last_status).to eq("failed")
        expect(repo.last_error).to include("diff engine exploded")
      end
    end

    context "rescue StandardError — a raise BEFORE the sync run exists" do
      # The method-level rescue is reachable with `sync_run` still nil (anything
      # raising at or before the `@repository.schedule_sync!` assignment). It
      # used to NoMethodError out of reconcile! on `nil.finalize!`, so this
      # failure produced neither a repository status nor the documented Result.
      before do
        allow(repo).to receive(:schedule_sync!).and_raise(ActiveRecord::RecordInvalid.new(repo))
      end

      it "still records failed on the repository row and returns a failed Result" do
        result = described_class.reconcile!(repository: repo)

        expect(result.ok?).to be false
        repo.reload
        expect(repo.last_status).to eq("failed")
        expect(repo.last_error).to include("ActiveRecord::RecordInvalid")
      end
    end

    context "rescue StandardError — an unexpected raise mid-reconcile" do
      before do
        allow(System::Gitops::DiffEngine).to receive(:diff!)
          .and_raise(ArgumentError, "boom from the diff engine")
      end

      it "records failed + the exception on the repository row" do
        result = described_class.reconcile!(repository: repo)

        expect(result.ok?).to be false
        repo.reload
        expect(repo.last_status).to eq("failed")
        expect(repo.last_error).to include("ArgumentError")
        expect(repo.last_error).to include("boom from the diff engine")
      end
    end
  end

  # The half that gets skipped. Writing the error but never clearing it makes
  # a transient failure permanent on all three operator surfaces.
  describe "recovery" do
    it "clears last_error and returns to success after a failing sync recovers" do
      repo.update!(last_status: "failed", last_error: "Network unreachable")

      result = described_class.reconcile!(repository: repo)

      expect(result.ok?).to be true
      repo.reload
      expect(repo.last_status).to eq("success")
      expect(repo.last_error).to be_nil
    end

    it "does not clobber last_synced_revision with a later failure" do
      described_class.reconcile!(repository: repo)
      expect(repo.reload.last_synced_revision).to eq("abc123def456")

      allow(System::Gitops::RepoSyncService).to receive(:sync!).with(repo)
        .and_return(System::Gitops::RepoSyncService::Result.new(
                      ok?: false, error: "Network unreachable"
                    ))
      described_class.reconcile!(repository: repo)

      repo.reload
      expect(repo.last_status).to eq("failed")
      # The last SUCCESSFUL sync's revision/timestamp stay intact — the row
      # says "failing now, last good was abc123def456", which is the whole
      # point of a status field separate from last_synced_revision.
      expect(repo.last_synced_revision).to eq("abc123def456")
      expect(repo.last_synced_at).to be_present
    end
  end

  # The status write must not silently degrade the outcome it is reporting.
  describe "when the repository row itself cannot be written" do
    it "re-raises on a SUCCESS outcome so the sync run reports failed, not a false success" do
      # Pre-existing semantics: the inline @repository.update! on the success
      # path raised into reconcile!'s rescue, and the run came back failed.
      # Swallowing here would let the run claim success over a stale row.
      allow(repo).to receive(:update!).and_raise(ActiveRecord::StatementInvalid, "PG went away")

      result = described_class.reconcile!(repository: repo)

      expect(result.ok?).to be false
      expect(result.error).to include("PG went away")
      expect(repo.sync_runs.last.status).to eq("failed")
    end

    it "swallows on a FAILED outcome so the reconcile still returns its failed Result" do
      allow(System::Gitops::RepoSyncService).to receive(:sync!).with(repo)
        .and_return(System::Gitops::RepoSyncService::Result.new(
                      ok?: false, error: "Network unreachable"
                    ))
      allow(repo).to receive(:update!).and_raise(ActiveRecord::StatementInvalid, "PG went away")

      expect { @result = described_class.reconcile!(repository: repo) }.not_to raise_error
      expect(@result.ok?).to be false
      expect(@result.error).to include("Network unreachable")
      expect(repo.sync_runs.last.status).to eq("failed")
    end
  end

  # Ordering: the repository row is written BEFORE the sync run, so a raise out
  # of the sync-run write does not cost the operator the status.
  describe "when the sync-run write raises" do
    it "has already recorded the failure on the repository row" do
      allow(System::Gitops::RepoSyncService).to receive(:sync!).with(repo)
        .and_return(System::Gitops::RepoSyncService::Result.new(
                      ok?: false, error: "Network unreachable"
                    ))
      allow_any_instance_of(System::GitopsSyncRun).to receive(:finalize!)
        .and_raise(ActiveRecord::StatementInvalid, "sync run write blew up")

      # The raise still escapes reconcile! — pre-existing, and out of scope
      # here. What must NOT happen is losing the repository status with it.
      expect { described_class.reconcile!(repository: repo) }
        .to raise_error(ActiveRecord::StatementInvalid)

      repo.reload
      expect(repo.last_status).to eq("failed")
      # Two passes reach the row: the clone-failure guard records "Network
      # unreachable", then the sync-run raise lands in reconcile!'s rescue,
      # which finalizes again and overwrites with the raise. The last writer
      # wins, and either way the row is NOT left stale at its previous value.
      expect(repo.last_error).to include("sync run write blew up")
    end
  end

  # last_error renders in GitopsTab and every REST/MCP repository read, so an
  # unbounded exception message must not land there whole.
  describe "last_error bounding" do
    it "truncates a huge error to 1000 chars on the row while the run keeps it whole" do
      huge = "x" * 5000
      allow(System::Gitops::RepoSyncService).to receive(:sync!).with(repo)
        .and_return(System::Gitops::RepoSyncService::Result.new(ok?: false, error: huge))

      described_class.reconcile!(repository: repo)

      expect(repo.reload.last_error.length).to eq(1000)
      expect(repo.sync_runs.last.error_message.length).to eq(5000)
    end
  end

  # The truncation message is written on the SUCCESS-ish path; a refactor that
  # centralises the status write must not clobber it with a bare nil error.
  describe "partial (per-tick cap) still carries its reason" do
    let(:platform) { create(:system_node_platform, account: account) }

    before do
      templates_yaml = (1..4).map do |i|
        "  template-#{i}:\n    name: template-#{i}\n    description: t\n    node_platform_id: #{platform.id}\n"
      end.join
      File.write(File.join(work_tree, "fleet.yaml"), "templates:\n#{templates_yaml}")
      stub_const("System::Gitops::Reconciler::MAX_PROPOSALS_PER_TICK", 2)
    end

    it "keeps status partial with the cap reason in last_error" do
      described_class.reconcile!(repository: repo)

      repo.reload
      expect(repo.last_status).to eq("partial")
      expect(repo.last_error).to include("MAX_PROPOSALS_PER_TICK")
    end
  end

  # Deliberate EXCLUSION, asserted so it cannot regress silently: the standby
  # plane performs no reconcile at all, and both planes share this row. Writing
  # any status from standby would overwrite the ACTIVE plane's real result.
  describe "standby control plane (deliberately does not write repository status)" do
    it "leaves last_status and last_error untouched" do
      repo.update!(last_status: "success", last_error: nil, last_synced_revision: "deadbeef")
      allow(::System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(false)

      described_class.reconcile!(repository: repo)

      repo.reload
      expect(repo.last_status).to eq("success")
      expect(repo.last_error).to be_nil
      expect(repo.last_synced_revision).to eq("deadbeef")
    end
  end
end
