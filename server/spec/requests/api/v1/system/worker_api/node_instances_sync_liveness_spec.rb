# frozen_string_literal: true

require "rails_helper"

# IMP-231f17d71dfa — provider power state and agent liveness are two different
# facts, and #sync mapped the first onto an AASM event that erased the second.
#
# The live symptom this pins: system_cloud_sync runs at "17 * * * *", finds the
# VM powered on at the hypervisor, and calls mark_running! on an instance the
# fleet reaper had marked :error from agent silence. The :18 tick reaps it
# again. Six instances were flapping this way on 2026-09-06, some silent for
# four weeks — every event carrying previous_status "running" while
# last_heartbeat_at never moved.
#
# THE DISCRIMINATOR IS NOT A DURATION. The operator direction named
# "last_heartbeat_at beyond the presumed-dead threshold", but there are three
# disagreeing thresholds in this subsystem (the model's 3-minute
# HEARTBEAT_STALE_AFTER, the reaper's 30-minute PRESUMED_DEAD_SILENCE_SECONDS,
# and the sensor's account-tunable silent_threshold_seconds), and picking one
# would either refuse promotions the reaper leaves alone or couple an API
# controller to a reconciler's ENV constant. Comparing the heartbeat against
# WHEN THE REAP HAPPENED needs no threshold at all and is exact: an agent that
# has reported since it was presumed dead is back, and one that has not is not.
#
# NOTE ON A PREDICATE THAT LOOKS RIGHT AND IS NOT: NodeInstance#silence_verdict
# already answers agent liveness, but it returns nil unless the status is in
# HEARTBEAT_EXPECTED_STATUSES = %w[running starting]. :error is absent, so
# reusing it here would make the guard vacuous — it would answer "no evidence of
# silence" for precisely the rows this exists to catch.
RSpec.describe "POST /api/v1/system/worker_api/node_instances/:id/sync — provider power vs agent liveness",
               type: :request do
  let(:account) { create(:account) }
  let!(:worker) { create(:worker, :system_worker, status: "active") }
  let(:headers) { worker_mtls_headers(worker) }
  # set_instance scopes by system_nodes.worker_id = current_worker.id, so a node
  # not managed by this worker answers 404 and every example below would pass or
  # fail for a reason that has nothing to do with liveness.
  let(:node) { create(:system_node, account: account, worker: worker) }

  before do
    allow_any_instance_of(Worker).to receive(:has_permission?)
      .with("system.node_instances.manage").and_return(true)

    # The provider says the VM is powered on. That is the ONLY thing the
    # hypervisor can tell us, and it is true in every example here — what
    # differs between them is whether an agent has spoken.
    allow(::System::CloudSyncService).to receive(:sync_instance_state)
      .and_return(::System::Runtime::Result.ok(data: { status: "running" }))
  end

  def sync!
    post "/api/v1/system/worker_api/node_instances/#{instance.id}/sync", headers: headers
  end

  # A cloud instance needs a provider identity or mark_running! is refused by
  # provider_identity_present? for an unrelated reason (the F1 seed-
  # contamination guard) — which would make every example below pass without
  # exercising the liveness guard at all.
  def build_instance!(status:, last_heartbeat_at:, presumed_dead_at:)
    inst = create(:system_node_instance,
                  account: account, node: node, variety: "cloud",
                  cloud_instance_id: "hv-1/qemu/9010", status: status)
    inst.update_columns(last_heartbeat_at: last_heartbeat_at,
                        presumed_dead_at: presumed_dead_at)
    inst.reload
  end

  context "when the agent has been silent since the reap marked it error" do
    let(:instance) do
      build_instance!(status: "error",
                      last_heartbeat_at: 3.days.ago,
                      presumed_dead_at: 1.hour.ago)
    end

    it "leaves the instance in error — a powered-on VM is not a running agent" do
      expect { sync! }.not_to change { instance.reload.status }.from("error")
      expect(response).to have_http_status(:ok)
    end

    it "still records what the provider reported, rather than discarding it" do
      sync!
      instance.reload
      expect(instance.provider_power_state).to eq("running")
      expect(instance.provider_power_state_at).to be_present
    end
  end

  context "when the agent has resumed heartbeating since the reap" do
    let(:instance) do
      build_instance!(status: "error",
                      last_heartbeat_at: 30.seconds.ago,
                      presumed_dead_at: 10.minutes.ago)
    end

    # The direction is explicit that error -> running must stay legal: blocking
    # the transition outright would strand instances that genuinely come back.
    it "promotes it to running" do
      expect { sync! }.to change { instance.reload.status }.from("error").to("running")
    end
  end

  context "when the instance was errored for a reason other than agent silence" do
    let(:instance) do
      build_instance!(status: "error",
                      last_heartbeat_at: 3.days.ago,
                      presumed_dead_at: nil)
    end

    # IMP-42cf03360656's stranded-row self-heal. A nil presumed_dead_at means no
    # reap ever judged this row dead, so cloud state is the best evidence there
    # is and the old behaviour must survive. Without this example the guard
    # could be written as "never promote a stale-heartbeat row" and still pass.
    it "still promotes it from provider state" do
      expect { sync! }.to change { instance.reload.status }.from("error").to("running")
    end
  end

  context "when the instance is not in error at all" do
    let(:instance) do
      build_instance!(status: "starting",
                      last_heartbeat_at: nil,
                      presumed_dead_at: nil)
    end

    it "promotes a mid-boot instance whose agent has not reported yet" do
      expect { sync! }.to change { instance.reload.status }.from("starting").to("running")
    end
  end
end
