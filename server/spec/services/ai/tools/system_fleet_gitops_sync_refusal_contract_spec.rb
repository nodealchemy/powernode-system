# frozen_string_literal: true

require "rails_helper"

# IMP-8ce4d88499a0 — the caller-visible contract of system_gitops_sync_repository
# when the reconcile did NOT happen or did NOT succeed.
#
# THE FINDING. The executor ended unconditionally in
# `success_result(ok: result.ok?, ..., error: result.error)` — so a reconcile
# whose clone was refused, whose fleet.yaml did not parse, or whose diff blew up
# came back `success: true` with the reason nested at data.error and `ok: false`
# beside it. `success` is the one field a program branches on (and the field the
# MCP transport derives isError from); it said the sync succeeded when it did
# not. Sibling of IMP-4a3a45df69bc (the apply verb), and the stronger case:
# sync PRECEDES apply, so a caller that reads a failed sync as a success
# concludes the fleet matches the repository and never opens the proposals it
# should have.
#
# THE STANDBY SKIP. Worse than the failed arm: on a standby control plane the
# reconciler performs nothing and returns ok?: true, diff_count 0, no error —
# and the action DESCRIPTION had been amended to admit exactly that ("CAUTION:
# ... indistinguishable from a repository that is fully in sync. Check
# diff_summary for a skipped marker"). A silent PASS with a prose caveat is not
# a contract. The verb now refuses on a standby plane, before any run row is
# created, with a refusal_code a program can branch on.
#
# BOTH HALVES ARE ORACLES. A response that says "failed" while a success ran
# is the same defect pointing the other way, so the success and partial arms
# are asserted in their own examples, and the standby refusal asserts the
# absence of a sync run as well as the response shape.
RSpec.describe Ai::Tools::SystemFleetTool, "GitOps sync refusal contract (IMP-8ce4d88499a0)" do
  let(:account) { create(:account) }
  let(:tool) { described_class.new(account: account, internal: true) }

  let!(:repo) do
    ::System::GitopsRepository.create!(
      account: account, name: "sync-contract",
      repo_url: "https://git.example.test/fleet.git", branch: "main"
    )
  end

  def sync(id = repo.id)
    tool.execute(params: { action: "system_gitops_sync_repository", id: id })
  end

  def reconciler_result(**overrides)
    ::System::Gitops::Reconciler::Result.new(
      **{ ok?: true, diff_count: 0, proposal_ids: [], synced_revision: "abc123",
          diff_summary: { "templates" => 0 }, error: nil,
          applied_proposal_ids: [], failed_proposal_ids: [] }.merge(overrides)
    )
  end

  # ---------------------------------------------------------------------------
  # A FAILED reconcile — the reconciler's own `failed` arm, reached here through
  # its first guard (clone/pull refused). Runs the real reconciler so the sync
  # run row is finalized exactly as production would.
  # ---------------------------------------------------------------------------
  describe "a reconcile whose clone was refused" do
    before do
      allow(::System::Gitops::RepoSyncService).to receive(:sync!)
        .and_return(double(ok?: false, work_tree_path: nil, commit_sha: nil, error: "clone refused: bad deploy key"))
    end

    it "reports failure on the field a program branches on" do
      r = sync

      expect(r[:success]).to be false
    end

    it "carries the reconcile's failure as the top-level error, where error_result puts it" do
      r = sync

      expect(r[:error]).to eq("clone refused: bad deploy key")
    end

    it "keeps the distinguishing fields at their dig paths under data" do
      r = sync

      expect(r.dig(:data, :ok)).to be false
      expect(r.dig(:data, :repository_id)).to eq(repo.id)
      expect(r.dig(:data, :diff_count)).to eq(0)
      expect(r.dig(:data, :proposal_ids)).to eq([])
    end

    # The sync_run_id promise (IMP-d4923c10977e) must survive the refusal —
    # the FAILURE path is the one the description sells it for.
    it "still hands back a resolvable sync_run_id whose row is terminal and failed" do
      r = sync

      run = ::System::GitopsSyncRun.find(r.dig(:data, :sync_run_id))
      expect(run.gitops_repository_id).to eq(repo.id)
      expect(run.status).to eq("failed")
      expect(run.completed_at).to be_present
      expect(run.error_message).to eq("clone refused: bad deploy key")
    end
  end

  # The reconciler's OTHER failure route — its method-level rescue, which
  # produces a failed Result rather than propagating. Same contract.
  describe "a reconcile that raised mid-pass" do
    before do
      allow(::System::Gitops::RepoSyncService).to receive(:sync!).and_raise(RuntimeError, "git clone failed: exit 128")
    end

    it "reports failure with the rescued reason" do
      r = sync

      expect(r[:success]).to be false
      expect(r[:error]).to eq("RuntimeError: git clone failed: exit 128")
      expect(r.dig(:data, :ok)).to be false
    end
  end

  # A Result that is not ok but carries no message must not turn into
  # `error: nil` on a failure envelope.
  describe "a failed Result with no message" do
    it "names the failure anyway" do
      allow(::System::Gitops::Reconciler).to receive(:reconcile!)
        .and_return(reconciler_result(ok?: false, synced_revision: nil, error: nil))

      r = sync

      expect(r[:success]).to be false
      expect(r[:error]).to be_present
    end
  end

  # ---------------------------------------------------------------------------
  # The standby control plane. Before this fix the reconciler was invoked, did
  # nothing, finalized the caller-created run as "success" with a
  # `skipped` note in diff_summary, and the verb returned success: true,
  # ok: true, diff_count: 0 — the shape of a fully in-sync repository.
  # ---------------------------------------------------------------------------
  describe "on a standby control plane" do
    before do
      allow(::System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(false)
    end

    it "refuses, with a refusal_code a program can branch on" do
      r = sync

      expect(r[:success]).to be false
      expect(r[:refusal_code]).to eq("standby_control_plane")
      expect(r[:retryable]).to be false
      expect(r[:error]).to include("standby")
      expect(r.dig(:data, :repository_id)).to eq(repo.id)
    end

    # `active?` is false for :standby AND :gate_error (control_plane_role.rb
    # #status) — and :gate_error knows nothing about who IS active. Refusing is
    # right in both; asserting that an active peer owns the reconcile is a
    # guess in the second, which is the same class of defect this task fixed.
    it "does not claim an active peer exists — active? is false for :gate_error too" do
      r = sync

      expect(r[:error]).not_to match(/active (control )?plane owns/i)
    end

    it "does not invoke the reconciler at all" do
      expect(::System::Gitops::Reconciler).not_to receive(:reconcile!)

      sync
    end

    # The other half: a refusal must not leave a "success" run on the timeline
    # for a reconcile that never happened.
    it "creates no sync run" do
      expect { sync }.not_to change { ::System::GitopsSyncRun.where(gitops_repository_id: repo.id).count }
    end

    it "does not write a status onto the repository row — the active plane owns it" do
      repo.update!(last_status: "success", last_error: nil)

      sync

      expect(repo.reload.last_status).to eq("success")
      expect(repo.last_error).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # The success arm is unchanged — the fix must not turn every outcome into an
  # error. Separate examples, separate mutant.
  # ---------------------------------------------------------------------------
  describe "a reconcile that succeeded" do
    it "still reports success with a nil error" do
      allow(::System::Gitops::Reconciler).to receive(:reconcile!)
        .and_return(reconciler_result(diff_count: 2, proposal_ids: %w[p1 p2]))

      r = sync

      expect(r[:success]).to be true
      expect(r[:error]).to be_nil
      expect(r.dig(:data, :ok)).to be true
      expect(r.dig(:data, :diff_count)).to eq(2)
      expect(r.dig(:data, :proposal_ids)).to eq(%w[p1 p2])
      expect(r.dig(:data, :synced_revision)).to eq("abc123")
      expect(r.dig(:data, :error)).to be_nil
    end
  end

  # A `partial` run is the reconciler's ok?: true WITH a message: the per-tick
  # proposal cap truncated the proposal set. It is the one case where a
  # success response carries a non-nil data.error, and the description says so.
  describe "a partial reconcile (per-tick proposal cap hit)" do
    it "reports success and surfaces the truncation note under data.error" do
      allow(::System::Gitops::Reconciler).to receive(:reconcile!)
        .and_return(reconciler_result(diff_count: 30, proposal_ids: (1..25).map { |i| "p#{i}" },
                                      error: "diff count exceeded MAX_PROPOSALS_PER_TICK=25"))

      r = sync

      expect(r[:success]).to be true
      expect(r[:error]).to be_nil
      expect(r.dig(:data, :ok)).to be true
      expect(r.dig(:data, :error)).to eq("diff count exceeded MAX_PROPOSALS_PER_TICK=25")
    end
  end

  # ---------------------------------------------------------------------------
  # The description. It had been amended to DOCUMENT the silent pass rather
  # than fix the return — the resolution the operator forbade for the apply
  # verb. An honest description names the failure contract and no longer
  # tells the caller to sniff diff_summary for a marker.
  # ---------------------------------------------------------------------------
  describe "the action description" do
    let(:description) { described_class.action_definitions.fetch("system_gitops_sync_repository")[:description] }

    it "no longer documents a standby skip that returns ok:true" do
      expect(description).not_to match(/still returns ok:\s*true/i)
      expect(description).not_to match(/indistinguishable/i)
      expect(description).not_to match(/skipped.? marker/i)
    end

    it "names the failure contract and the standby refusal" do
      expect(description).to include("success: false")
      expect(description).to include("standby_control_plane")
    end

    # The refusal promise is scoped to what this verb does (it refuses before
    # starting, and mints no run); it must not assert an active peer, because
    # `active?` is equally false when the quorum gate itself errored.
    it "does not assert an active peer owns the reconcile" do
      expect(description).not_to match(/active (control )?plane owns/i)
    end
  end
end
