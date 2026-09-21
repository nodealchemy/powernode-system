# frozen_string_literal: true

require "rails_helper"

# system_readvance_module_build_batch — the operator door onto the lease
# sweep's readvance backstop (CiRunnerLeaseSweepService#readvance_stalled_batches!),
# scoped to ONE batch. That backstop is the only thing that resolves a member
# whose build task finished while its entry is still `dispatched`, and it runs
# only from a hub-worker cron: with the worker down, the batch deadlocked and
# no verb could move it (dispatch / cancel / get only).
#
# The observable effect asserted below is the batch's persisted per-module
# state and status, driven through the REAL orchestrator on its sign-free arm
# (a failed task with its attempts exhausted resolves to `failed`), so these
# examples cannot pass by a method merely being called.
RSpec.describe Ai::Tools::SystemFleetTool, "system_readvance_module_build_batch" do
  let(:account)  { create(:account) }
  let(:instance) { create(:system_node_instance, :running, account: account) }
  let(:tool)     { described_class.new(account: account, internal: true) }
  let(:batch) do
    System::ModuleBuildBatch.create_for(account: account, trigger: "manual", base_sha: "base", head_sha: "head",
                                        plan: [ { module: "mod-x", oci_ref: "abc1234" } ])
  end
  let!(:task) do
    create(:system_task, account: account, operable: instance, command: "ci.module_build", status: "failed",
                         completed_at: Time.current,
                         options: { "module" => "mod-x", "sha" => "abc", "oci_ref" => "abc1234", "batch_id" => batch.id })
  end

  def call(**rest)
    tool.execute(params: { action: "system_readvance_module_build_batch" }.merge(rest))
  end

  # attempts at the orchestrator's max, so the finished task resolves the entry
  # to `failed` (no retry, no re-dispatch, no signing).
  def park!(status: "dispatched", state: "dispatched", attempts: System::NativeModuleBuildOrchestrator::DEFAULT_MAX_ATTEMPTS)
    batch.update!(metadata: batch.metadata.merge("modules" => {
      "mod-x" => { "module" => "mod-x", "tag" => "abc1234", "state" => state, "attempts" => attempts,
                   "lease_id" => nil, "task_id" => task.id, "error" => nil }
    }))
    batch.update_columns(status: status)
  end

  def entry_state
    batch.reload.metadata.dig("modules", "mod-x", "state")
  end

  it "advances a stalled member through the real orchestrator and reports it" do
    park!

    result = call(batch_id: batch.id)

    expect(result[:success]).to be true
    expect(result[:data][:readvanced]).to be true
    expect(entry_state).to eq("failed")
    expect(batch.reload.status).to eq("failed")
    expect(result[:data][:module_build_batch]).to include(id: batch.id, status: "failed")
  end

  it "is a clear no-op, not an error, when no member is stalled" do
    task.update!(status: "running", started_at: Time.current, completed_at: nil)
    park!

    result = call(batch_id: batch.id)

    expect(result[:success]).to be true
    expect(result[:data][:readvanced]).to be false
    expect(result[:data][:reason]).to match(/no stalled member/i)
    expect(entry_state).to eq("dispatched")
    expect(batch.reload.status).to eq("dispatched")
  end

  it "is a no-op for a terminal batch even if it still carries a dispatched entry" do
    park!(status: "cancelled")

    result = call(batch_id: batch.id)

    expect(result[:success]).to be true
    expect(result[:data][:readvanced]).to be false
    expect(entry_state).to eq("dispatched")
  end

  it "refuses under the account kill switch and leaves the batch untouched" do
    park!
    account.suspend_ai!

    result = call(batch_id: batch.id)

    expect(result[:success]).to be false
    expect(result[:error]).to match(/kill-switch/i)
    expect(entry_state).to eq("dispatched")
    expect(batch.reload.status).to eq("dispatched")
  end

  it "refuses on a standby control plane and leaves the batch untouched" do
    park!
    allow(::System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(false)

    result = call(batch_id: batch.id)

    expect(result[:success]).to be false
    expect(result[:error]).to match(/control plane|control-plane/i)
    expect(entry_state).to eq("dispatched")
  end

  it "returns a generic refusal when the advance raises, never the exception's own text" do
    park!
    allow_any_instance_of(::System::CiRunnerLeaseSweepService)
      .to receive(:readvance_batch!).and_raise(RuntimeError, "PG::ConnectionBad SENTINEL-internal-host:5432")

    result = call(batch_id: batch.id)

    expect(result[:success]).to be false
    expect(result[:error]).to include("Re-advance of batch '#{batch.id}' failed")
    expect(result.to_json).not_to include("SENTINEL-internal-host")
    expect(result.to_json).not_to include("RuntimeError")
  end

  it "is a no-op when another advance holds the batch lock" do
    park!
    allow(::System::NativeModuleBuildOrchestrator).to receive(:advance!).and_return(
      System::NativeModuleBuildOrchestrator::Result.new(ok?: true, dispatched: 0, queued: 0, succeeded: 0,
                                                        retried: 0, failed: 0, busy: true)
    )

    result = call(batch_id: batch.id)

    expect(result[:success]).to be true
    expect(result[:data][:readvanced]).to be false
    expect(result[:data][:reason]).to match(/lock/i)
    expect(entry_state).to eq("dispatched")
  end

  describe "CiRunnerLeaseSweepService#readvance_batch! account boundary" do
    it "does not advance another account's stalled batch even when handed it directly" do
      park!
      other_service = ::System::CiRunnerLeaseSweepService.new(account: create(:account))
      expect(::System::NativeModuleBuildOrchestrator).not_to receive(:advance!)

      outcome = other_service.readvance_batch!(batch)

      expect(outcome).to include(ok: true, readvanced: false)
      expect(entry_state).to eq("dispatched")
    end
  end

  it "refuses a blank id and another account's batch" do
    expect(call(batch_id: "")[:error]).to include("batch_id is required")

    other = System::ModuleBuildBatch.create_for(account: create(:account), trigger: "manual", base_sha: "b", head_sha: "h",
                                                plan: [ { module: "mod-z", oci_ref: "abc1234" } ])
    expect(call(batch_id: other.id)[:error]).to include("not found")
  end

  describe "permission" do
    it "is a mutating verb on its own operator-granted module_builds permission" do
      expect(described_class::ACTION_PERMISSIONS.fetch("system_readvance_module_build_batch"))
        .to eq("system.module_builds.readvance")
      expect(described_class.declared_action("system_readvance_module_build_batch")&.fetch(:mutating)).to be true
      expect(::Permissions.permission_exists?("system.module_builds.readvance")).to be true
    end

    it "is reachable by a real admin role (like cancel), and refused without the permission" do
      park!
      %i[admin owner manager].each do |role|
        holder = create(:user, role, account: account)
        expect(holder.has_permission?("system.module_builds.readvance")).to be(true), "#{role} lacks readvance"
        expect(holder.has_permission?("system.module_builds.cancel")).to be(true), "#{role} lacks cancel (audience drifted)"
      end

      denied = create(:user, account: account, permissions: %w[system.nodes.read system.module_builds.read])
      result = described_class.new(account: account, user: denied)
                              .execute(params: { action: "system_readvance_module_build_batch", batch_id: batch.id })
      expect(result[:error]).to include("permission denied")
      expect(entry_state).to eq("dispatched")
    end
  end

  it "is registered against SystemFleetTool" do
    expect(Ai::Tools::PlatformApiToolRegistry::TOOLS["system_readvance_module_build_batch"]).to eq("Ai::Tools::SystemFleetTool")
  end
end
