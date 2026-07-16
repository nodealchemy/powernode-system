# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc3 — CiRunnerLeaseSweepService.run!. Per-lease
# reconciliation (leased->registered correlation, terminal-run release,
# busy-runner flag-not-kill on expiry) plus orphan Gitea runner reaping.
RSpec.describe System::CiRunnerLeaseSweepService do
  let(:account)  { create(:account) }
  let(:instance) { create(:system_node_instance, :running, account: account) }

  let(:gitea_provider)   { create(:git_provider, :gitea, account: account) }
  let!(:gitea_credential) { create(:git_provider_credential, :gitea, account: account, provider: gitea_provider) }

  let(:fake_gitea_client) { instance_double("Devops::Git::GiteaApiClient") }

  before do
    allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake_gitea_client)
    allow(fake_gitea_client).to receive(:supports_runners?).and_return(true)
  end

  def build_lease(status:, node_instance: instance, **attrs)
    System::CiRunnerLease.create!(account: account, node_instance: node_instance, status: status, **attrs)
  end

  describe "leased -> registered correlation" do
    it "advances a leased lease to registered when a matching GitRunner is found" do
      lease = build_lease(status: "leased", runner_name: ::System::CiRunnerRegistrationResolver.runner_name(instance))
      runner = create(:git_runner, account: account, name: lease.runner_name)

      summary = described_class.run!(account: account)

      expect(lease.reload).to be_registered
      expect(lease.git_runner_id).to eq(runner.id)
      expect(summary[:advanced]).to eq(1)
    end

    it "leaves the lease in :leased when no runner has surfaced yet (no network call retried indefinitely)" do
      lease = build_lease(status: "leased", runner_name: "fleet-neverregisters00")
      allow(fake_gitea_client).to receive(:list_runners).and_return([])

      summary = described_class.run!(account: account)

      expect(lease.reload).to be_leased
      expect(summary[:advanced]).to eq(0)
    end
  end

  describe "registered + terminal run -> released" do
    it "releases a generic-purpose lease once its workflow run reaches a terminal status" do
      lease = build_lease(status: "registered", purpose: "generic",
                           workflow_run_id: 123, workflow_run_repo: "powernode/powernode-platform",
                           registered_at: 1.hour.ago)
      allow(fake_gitea_client).to receive(:get_workflow_run)
        .with("powernode", "powernode-platform", 123)
        .and_return("status" => "completed", "conclusion" => "success")

      summary = described_class.run!(account: account)

      expect(lease.reload).to be_released
      expect(lease.released_at).to be_present
      expect(summary[:released]).to eq(1)
    end

    it "marks a registered lease busy when its run is still in_progress (does not release)" do
      lease = build_lease(status: "registered", purpose: "generic",
                           workflow_run_id: 456, workflow_run_repo: "powernode/powernode-platform",
                           registered_at: 1.hour.ago)
      allow(fake_gitea_client).to receive(:get_workflow_run)
        .with("powernode", "powernode-platform", 456)
        .and_return("status" => "in_progress", "conclusion" => nil)

      summary = described_class.run!(account: account)

      expect(lease.reload).to be_busy
      expect(lease.busy_at).to be_present
      expect(summary[:advanced]).to eq(1)
      expect(summary[:released]).to eq(0)
    end

    it "holds release for a disk_image_build run until a DiskImagePublication has landed (soft publish gate)" do
      node_platform = create(:system_node_platform, account: account)
      lease = build_lease(status: "registered", purpose: "disk_image_build",
                           workflow_run_id: 789, workflow_run_repo: "powernode/powernode-platform",
                           registered_at: 1.hour.ago, leased_at: 1.hour.ago)
      allow(fake_gitea_client).to receive(:get_workflow_run)
        .with("powernode", "powernode-platform", 789)
        .and_return("status" => "completed", "conclusion" => "success")

      summary = described_class.run!(account: account)
      expect(lease.reload).to be_registered # not released yet — no publication has landed
      expect(summary[:released]).to eq(0)

      create(:system_disk_image_publication, :published, account: account, node_platform: node_platform)

      described_class.run!(account: account)
      expect(lease.reload).to be_released
    end
  end

  describe "expiry — flag, never kill, a busy runner" do
    it "flags (does not release) an expired lease whose GitRunner is currently busy" do
      busy_runner = create(:git_runner, :busy, account: account)
      lease = build_lease(status: "busy", purpose: "generic",
                           git_runner_id: busy_runner.id, registered_at: 2.hours.ago, busy_at: 1.hour.ago,
                           expires_at: 1.hour.ago)

      summary = described_class.run!(account: account)

      lease.reload
      expect(lease).to be_busy # unchanged — never torn down while busy
      expect(lease.metadata["stale_flagged_at"]).to be_present
      expect(lease.metadata["stale_reason"]).to include("runner busy")
      expect(summary[:flagged]).to eq(1)
      expect(summary[:released]).to eq(0)
    end

    it "releases an expired lease once its GitRunner is no longer busy" do
      idle_runner = create(:git_runner, :online, account: account)
      lease = build_lease(status: "registered", purpose: "generic",
                           git_runner_id: idle_runner.id, registered_at: 2.hours.ago,
                           expires_at: 1.hour.ago)
      allow(fake_gitea_client).to receive(:delete_runner).and_return(success: true)
      allow(::System::ProvisioningService).to receive(:terminate_instance)

      summary = described_class.run!(account: account)

      expect(lease.reload).to be_released
      expect(summary[:released]).to eq(1)
      expect(summary[:flagged]).to eq(0)
    end
  end

  describe "orphan reap" do
    it "deregisters an offline fleet-* runner unreferenced by any active lease" do
      orphan = create(:git_runner, :offline, account: account, name: "fleet-orphan0000001")
      allow(fake_gitea_client).to receive(:delete_runner).and_return(success: true)

      summary = described_class.run!(account: account)

      expect(::Devops::GitRunner.exists?(orphan.id)).to be false
      expect(summary[:orphans_reaped]).to eq(1)
    end

    it "does not reap a fleet-* runner still referenced by an active lease" do
      lease = build_lease(status: "registered", purpose: "generic", runner_name: "fleet-stillowned0001")
      referenced = create(:git_runner, :offline, account: account, name: lease.runner_name)

      described_class.run!(account: account)

      expect(::Devops::GitRunner.exists?(referenced.id)).to be true
    end

    it "does not reap a runner seen within the last 5 minutes even if offline" do
      recent = create(:git_runner, account: account, name: "fleet-recentlyseen001",
                                    status: "offline", last_seen_at: 1.minute.ago)

      described_class.run!(account: account)

      expect(::Devops::GitRunner.exists?(recent.id)).to be true
    end

    it "does not touch a non-fleet-prefixed offline runner" do
      other = create(:git_runner, :offline, account: account, name: "some-other-runner")

      described_class.run!(account: account)

      expect(::Devops::GitRunner.exists?(other.id)).to be true
    end
  end

  describe "summary shape" do
    it "returns the full counters hash even with nothing to do" do
      summary = described_class.run!(account: account)
      expect(summary).to eq(advanced: 0, released: 0, flagged: 0, errored: 0, orphans_reaped: 0, redispatched: 0)
    end

    it "isolates one lease's advance failure (fail!s it) from the rest of the sweep" do
      broken = build_lease(status: "registered", purpose: "generic",
                            workflow_run_id: 999, workflow_run_repo: "powernode/powernode-platform")
      # fetch_run's own StandardError handling swallows API failures to nil, so
      # force the surrounding advance() to blow up directly — exercises the
      # per-lease rescue in run! (one bad lease must not abort the sweep).
      allow_any_instance_of(described_class).to receive(:advance_running).and_raise(StandardError.new("advance boom"))

      other = build_lease(status: "leased", runner_name: ::System::CiRunnerRegistrationResolver.runner_name(instance))
      create(:git_runner, account: account, name: other.runner_name)

      summary = described_class.run!(account: account)

      expect(broken.reload).to be_errored
      expect(broken.error_message).to include("advance boom")
      expect(other.reload).to be_registered # unaffected by the other lease's failure
      expect(summary[:errored]).to eq(1)
      expect(summary[:advanced]).to eq(1)
    end
  end

  describe "module_build purpose-aware correlation (inc9 Part B)" do
    let!(:task) do
      create(:system_task, account: account, operable: instance, command: "ci.module_build", status: "pending",
                            options: { "module" => "mod-x", "sha" => "abc", "oci_ref" => "abc1234", "batch_id" => "batch-1" })
    end

    def build_module_build_lease(task:, status: "registered")
      build_lease(status: status, purpose: "module_build", build_task_id: task.id)
    end

    it "never attempts Gitea correlation for a module_build lease (it has no GitRunner to find)" do
      lease = build_module_build_lease(task: task)
      expect(fake_gitea_client).not_to receive(:list_runners)
      expect(fake_gitea_client).not_to receive(:get_workflow_run)

      described_class.run!(account: account)

      expect(lease.reload).to be_registered
    end

    it "marks the lease busy once the task is acknowledged (task -> running)" do
      lease = build_module_build_lease(task: task)
      task.update!(status: "running", started_at: Time.current)

      summary = described_class.run!(account: account)

      expect(lease.reload).to be_busy
      expect(summary[:advanced]).to eq(1)
    end

    it "does not mark a leased (not-yet-registered) module_build lease busy even if its task is running" do
      lease = build_module_build_lease(task: task, status: "leased")
      task.update!(status: "running", started_at: Time.current)

      described_class.run!(account: account)

      expect(lease.reload).to be_leased
    end

    it "triggers the orchestrator's advance_for_task! once the task is terminal, and releases via its outcome" do
      lease = build_module_build_lease(task: task, status: "busy")
      task.update!(status: "complete", completed_at: Time.current)
      allow(::System::NativeModuleBuildOrchestrator).to receive(:task_batch_id).and_return("batch-1")
      expect(::System::NativeModuleBuildOrchestrator).to receive(:advance_for_task!).with(task) do
        # Simulate the orchestrator releasing the lease itself (its real job).
        lease.update!(status: "released", released_at: Time.current)
      end

      summary = described_class.run!(account: account)

      expect(lease.reload).to be_released
      expect(summary[:released]).to eq(0) # released by the orchestrator, not the sweep's own backstop path
    end

    it "falls back to releasing the lease itself when the orchestrator does not (never strand a finished task's lease)" do
      lease = build_module_build_lease(task: task, status: "busy")
      task.update!(status: "failed", completed_at: Time.current, error_message: "boom")
      allow(::System::NativeModuleBuildOrchestrator).to receive(:task_batch_id).and_return("batch-1")
      allow(::System::NativeModuleBuildOrchestrator).to receive(:advance_for_task!) # no-op: doesn't release

      summary = described_class.run!(account: account)

      expect(lease.reload).to be_released
      expect(summary[:released]).to eq(1) # the sweep's own backstop path did it
    end

    it "is a no-op (never raises) when a module_build lease's task can no longer be found" do
      lease = build_lease(status: "registered", purpose: "module_build", build_task_id: SecureRandom.uuid)

      summary = described_class.run!(account: account)

      expect(summary[:errored]).to eq(0)
      expect(lease.reload).to be_registered
    end

    it "deduplicates orchestrator advance calls within one tick for leases sharing the same batch" do
      task_b = create(:system_task, account: account, operable: instance, command: "ci.module_build",
                                     status: "complete", completed_at: Time.current,
                                     options: { "module" => "mod-y", "sha" => "abc", "oci_ref" => "def5678", "batch_id" => "batch-1" })
      task.update!(status: "complete", completed_at: Time.current)
      build_module_build_lease(task: task, status: "busy")
      build_module_build_lease(task: task_b, status: "busy")
      allow(::System::NativeModuleBuildOrchestrator).to receive(:task_batch_id).and_return("batch-1")

      expect(::System::NativeModuleBuildOrchestrator).to receive(:advance_for_task!).once do |t|
        System::CiRunnerLease.where(build_task_id: t.id).update_all(status: "released", released_at: Time.current)
      end

      described_class.run!(account: account)

      expect(System::CiRunnerLease.for_account(account).active.count).to eq(0)
    end
  end
end
