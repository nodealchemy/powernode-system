# frozen_string_literal: true

require "rails_helper"

# Audit F4-06 — sync_region_instances called provider_adapter.list_instances
# with no rescue, so a provider without a region-listing surface (pro_cloud)
# blew up the sync with a raised NotImplementedError instead of a structured
# result.
RSpec.describe System::CloudSyncService do
  let(:account)    { create(:account) }
  let(:region)     { create(:system_provider_region) }
  let(:connection) { double("provider connection") }
  let(:adapter) do
    instance_double("System::Providers::BaseProvider", provider_type: "pro_cloud")
  end

  before do
    allow(System::Providers::Registry).to receive(:find_connection_for_region)
      .with(region, account).and_return(connection)
    allow(System::Providers::Registry).to receive(:for)
      .with(connection, region: region).and_return(adapter)
  end

  # IMP-23c89e2be535 — Proxmox recycles VMIDs. A terminated row's
  # cloud_instance_id can name a NEW guest, which the provider reports as
  # running/stopped. Matching by id alone rewrote the dead row's status (and
  # IPs) to the new guest's, and index_by let the dead row shadow the new guest's
  # own row. A terminated row names no guest any more, so no sync path may read
  # the provider for it.
  describe "a terminated row whose recycled VMID now names another guest" do
    def terminated_row(cloud_instance_id)
      row = create(:system_node_instance, :running, provider_region: region, cloud_instance_id: cloud_instance_id)
      row.update_columns(status: "terminated", private_ip_address: "192.0.2.10", public_ip_address: nil,
                         last_synced_at: 2.days.ago)
      row.reload
    end

    def list!(*entries)
      allow(adapter).to receive(:list_instances).and_return(
        success: true, instances: entries, page_count: 1, truncated: false
      )
    end

    before { allow(adapter).to receive(:supports?).with(:sync).and_return(true) }

    it "sync_region_instances leaves the dead row's status, addresses and clock alone" do
      dead = terminated_row("9101")
      synced_before = dead.last_synced_at
      list!({ cloud_instance_id: "9101", status: "running", private_ip_address: "192.0.2.77", public_ip_address: nil })

      described_class.new.sync_region_instances(region: region, account: account)

      dead.reload
      expect(dead.status).to eq("terminated")
      expect(dead.private_ip_address).to eq("192.0.2.10")
      expect(dead.last_synced_at).to be_within(1.second).of(synced_before)
      expect(dead.provider_power_state).to be_nil
    end

    it "sync_region_instances reconciles the live row that shares the recycled id, not the dead one" do
      live = create(:system_node_instance, :running, provider_region: region, cloud_instance_id: "9102")
      # Created last: with no ORDER BY, Postgres usually returns it last, so an
      # index_by over both rows typically kept the dead one. Typical, not guaranteed.
      dead = terminated_row("9102")
      list!({ cloud_instance_id: "9102", status: "stopped",
              private_ip_address: live.private_ip_address, public_ip_address: live.public_ip_address })

      described_class.new.sync_region_instances(region: region, account: account)

      expect(live.reload.status).to eq("stopped")
      expect(dead.reload.status).to eq("terminated")
    end

    it "sync_instance_state answers terminated for a terminated row without asking the provider" do
      dead = terminated_row("9103")
      provider = instance_double("System::Providers::BaseProvider")
      allow(System::Providers::Registry).to receive(:for_instance).and_return(provider)
      allow(provider).to receive(:get_instance).and_return(
        success: true, status: "running", private_ip_address: "192.0.2.99", public_ip_address: nil
      )

      result = described_class.new.sync_instance_state(instance: dead)

      expect(result.data).to include(status: "terminated", updated: false)
      expect(provider).not_to have_received(:get_instance)
    end

    it "sync_node_instances does not rewrite a terminated row from the provider" do
      dead = terminated_row("9104")
      provider = instance_double("System::Providers::BaseProvider")
      allow(System::Providers::Registry).to receive(:for_instance).and_return(provider)
      allow(provider).to receive(:get_instance).and_return(
        success: true, status: "running", private_ip_address: "192.0.2.88", public_ip_address: nil
      )

      described_class.new.sync_node_instances(node: dead.node)

      dead.reload
      expect(dead.status).to eq("terminated")
      expect(dead.private_ip_address).to eq("192.0.2.10")
    end
  end

  describe "#sync_region_instances" do
    it "returns a structured error when the provider lacks sync support" do
      allow(adapter).to receive(:supports?).with(:sync).and_return(false)
      allow(adapter).to receive(:list_instances)

      result = described_class.new.sync_region_instances(region: region, account: account)

      expect(result.success?).to be false
      expect(result.error).to match(/does not support .*sync/i)
      expect(adapter).not_to have_received(:list_instances)
    end

    # IMP-231f17d71dfa — THE PATH THAT ACTUALLY PRODUCED THE FLAP.
    #
    # The finding was filed against the worker_api controller's
    # finalize_state_from_cloud, and that method really did map provider-alive
    # onto mark_running!. But the hourly SystemCloudSyncJob reaches the fleet
    # through THIS method, which writes `status:` with a bare update! — no AASM
    # event, so no may_X? guard on the model's transitions is consulted at all.
    # Guarding only the controllers would have turned the whole suite green while
    # six instances kept flapping once an hour in production, which is why the
    # decision lives in NodeInstance#provider_state_may_promote? and every
    # reconciliation path asks it rather than each guarding its own mechanism.
    #
    # Both directions are required here or a wrong fix passes: refusing every
    # stale-heartbeat row would strand instances that genuinely come back, and
    # the direction is explicit that error -> running must stay legal.
    context "when the provider reports a presumed-dead instance as powered on" do
      before { allow(adapter).to receive(:supports?).with(:sync).and_return(true) }

      # The IP keys are supplied and MATCH the row. Omitting them makes
      # state_changed? true from an IP mismatch (nil vs the row's value), so the
      # example would enter the update branch without the STATUS arm of
      # state_changed? ever being the reason — and would then also write
      # private_ip_address: nil over a real address. With them matching, status
      # is the only thing that differs, which is what these examples are about.
      def list_as_running!(instance)
        allow(adapter).to receive(:list_instances).and_return(
          success: true,
          instances: [ { cloud_instance_id: instance.cloud_instance_id,
                         status: "running",
                         private_ip_address: instance.private_ip_address,
                         public_ip_address: instance.public_ip_address } ],
          page_count: 1, truncated: false
        )
      end

      def presumed_dead_instance(last_heartbeat_at:, presumed_dead_at:)
        inst = create(:system_node_instance, :running, provider_region: region,
                      cloud_instance_id: "i-silent")
        inst.update_columns(status: "error",
                            last_heartbeat_at: last_heartbeat_at,
                            presumed_dead_at: presumed_dead_at)
        inst.reload
      end

      it "leaves a silent instance in error rather than re-describing it as running" do
        instance = presumed_dead_instance(last_heartbeat_at: 3.days.ago,
                                          presumed_dead_at: 1.hour.ago)
        list_as_running!(instance)

        expect { described_class.new.sync_region_instances(region: region, account: account) }
          .not_to change { instance.reload.status }.from("error")
      end

      # A refusal must be inert, not a competing verdict: the sync still records
      # what the provider said and still advances its own bookkeeping. Declining
      # to believe the power state says nothing about the rest of the payload.
      it "still records the provider's observation and the sync timestamp" do
        instance = presumed_dead_instance(last_heartbeat_at: 3.days.ago,
                                          presumed_dead_at: 1.hour.ago)
        list_as_running!(instance)

        described_class.new.sync_region_instances(region: region, account: account)

        instance.reload
        expect(instance.provider_power_state).to eq("running")
        expect(instance.provider_power_state_at).to be_present
        expect(instance.last_synced_at).to be_present
      end

      # A refusal that leaves no trace is indistinguishable from a sync that
      # found nothing to do. held_count is what tells an operator that instances
      # are sitting presumed-dead with their VMs still powered on, and it must
      # not be folded into updated_count — the status was NOT updated.
      it "counts the refusal separately from an update that landed" do
        instance = presumed_dead_instance(last_heartbeat_at: 3.days.ago,
                                          presumed_dead_at: 1.hour.ago)
        list_as_running!(instance)

        result = described_class.new.sync_region_instances(region: region, account: account)

        expect(result.data[:held_count]).to eq(1)
        expect(result.data[:updated_count]).to eq(0)
      end

      # The observation is what the provider LAST reported, so it must be
      # recorded on every sweep — not only on the sweeps that changed something.
      # Written inside the change branch it would be freshest on refused rows and
      # stale on healthy ones, which inverts the column's meaning.
      it "records the observation even when nothing about the row changed" do
        healthy = create(:system_node_instance, :running, provider_region: region,
                         cloud_instance_id: "i-healthy")
        list_as_running!(healthy)

        described_class.new.sync_region_instances(region: region, account: account)

        expect(healthy.reload.provider_power_state).to eq("running")
      end

      it "promotes an instance whose agent has resumed heartbeating since the reap" do
        instance = presumed_dead_instance(last_heartbeat_at: 30.seconds.ago,
                                          presumed_dead_at: 10.minutes.ago)
        list_as_running!(instance)

        expect { described_class.new.sync_region_instances(region: region, account: account) }
          .to change { instance.reload.status }.from("error").to("running")
      end

      # IMP-42cf03360656's stranded-row self-heal. No reap judged this row dead,
      # so there is no verdict to protect and cloud state is the best evidence
      # there is. Without this example the guard could be written as "never
      # promote a stale-heartbeat row" and still pass everything above.
      it "promotes a row errored for some other reason, even with an old heartbeat" do
        instance = presumed_dead_instance(last_heartbeat_at: 3.days.ago,
                                          presumed_dead_at: nil)
        list_as_running!(instance)

        expect { described_class.new.sync_region_instances(region: region, account: account) }
          .to change { instance.reload.status }.from("error").to("running")
      end
    end

    # IMP-555e29eeb4ab: a VM deleted out-of-band never appears in
    # list_instances, and this method only iterated the cloud listing — the
    # row was never terminated by the scheduled path (SystemCloudSyncJob,
    # hourly). NotFound->terminated exists only in sync_instance_state,
    # which nothing schedules, so the deleted instance decayed into the
    # error-state strand instead of ever reaching :terminated.
    context "when a local instance is missing from the cloud listing (deleted out-of-band)" do
      before { allow(adapter).to receive(:supports?).with(:sync).and_return(true) }

      it "marks the missing instance terminated but leaves the still-present one alone" do
        present = create(:system_node_instance, :running, provider_region: region, cloud_instance_id: "i-present")
        deleted = create(:system_node_instance, :running, provider_region: region, cloud_instance_id: "i-deleted")
        deleted.update_column(:created_at, 1.hour.ago) # outside the termination-sweep grace period

        allow(adapter).to receive(:list_instances).and_return(
          success: true,
          instances: [
            { cloud_instance_id: "i-present", status: "running",
              private_ip_address: present.private_ip_address, public_ip_address: present.public_ip_address }
          ],
          page_count: 1, truncated: false
        )

        result = described_class.new.sync_region_instances(region: region, account: account)

        expect(result.success?).to be true
        expect(deleted.reload.status).to eq("terminated")
        expect(present.reload.status).to eq("running")
      end

      it "does not terminate a just-provisioned instance the provider hasn't listed yet (eventual consistency)" do
        fresh = create(:system_node_instance, :running, provider_region: region, cloud_instance_id: "i-brand-new")

        allow(adapter).to receive(:list_instances).and_return(
          success: true, instances: [], page_count: 1, truncated: false
        )

        described_class.new.sync_region_instances(region: region, account: account)

        expect(fresh.reload.status).to eq("running")
      end

      it "does not terminate an already-terminated instance again" do
        instance = create(:system_node_instance, provider_region: region, cloud_instance_id: "i-gone", status: "terminated")

        allow(adapter).to receive(:list_instances).and_return(
          success: true, instances: [], page_count: 1, truncated: false
        )

        expect { described_class.new.sync_region_instances(region: region, account: account) }
          .not_to change { instance.reload.updated_at }
      end

      it "does not terminate when the listing was truncated (can't distinguish deletion from an unseen page)" do
        instance = create(:system_node_instance, :running, provider_region: region, cloud_instance_id: "i-1")
        allow(connection).to receive(:provider_id).and_return("conn-1")

        allow(adapter).to receive(:list_instances).and_return(
          success: true, instances: [], page_count: 1, truncated: true
        )

        described_class.new.sync_region_instances(region: region, account: account)

        expect(instance.reload.status).to eq("running")
      end
    end
  end
end
