# frozen_string_literal: true

require "rails_helper"

# IMP-64d9f2cdff63 — the half of the finding no record-side fix can reach.
#
# On 2026-09-08 the hypervisor held five ci-native-builders VMs, three of them
# running for up to 22 days, that NO System::NodeInstance row named. Their
# records had been pruned; the VMs had not been destroyed. Once the record is
# gone nothing on the platform lists the guest again, so the only remaining
# evidence is the provider's own inventory, read by the NAME the pool gave the
# guest. A provider id is not usable for this: Proxmox recycles vmids, and the
# 12 dead rows of the same incident carried ids already handed to other guests.
#
# The sensor only DETECTS. What happens to a detected orphan is the
# system.pool_guest_reap lane's decision, placed in the pool's plane.
RSpec.describe System::Fleet::Sensors::OrphanPoolGuestSensor do
  let(:account)                { create(:account) }
  let(:node_template)          { create(:system_node_template, account: account) }
  let(:provider_region)        { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }
  let(:connection)             { instance_double("System::ProviderConnection") }
  let(:adapter)                { instance_double("System::Providers::BaseProvider") }
  let(:sensor)                 { described_class.new(account: account) }

  let!(:pool) { make_pool("ci-builders") }

  def make_pool(name, lifecycle_class: "ephemeral", owner: account, template: node_template)
    System::InstancePool.create!(
      account: owner, node_template: template, name: name,
      target_size: 1, min_size: 0, max_size: 3, lifecycle_class: lifecycle_class, status: "active",
      provider_region: provider_region, provider_instance_type: provider_instance_type
    )
  end

  def guest(name, vmid: 9004, status: "running")
    { cloud_instance_id: "pve1/qemu/#{vmid}", name: name, status: status, node: "pve1", kind: "qemu", vmid: vmid }
  end

  def stub_listing(guests, success: true, truncated: false)
    allow(System::Providers::Registry).to receive(:find_connection_for_region).and_return(connection)
    allow(System::Providers::Registry).to receive(:for).with(connection, region: provider_region).and_return(adapter)
    allow(adapter).to receive(:supports?).with(:sync).and_return(true)
    allow(adapter).to receive(:list_instances).and_return(success: success, instances: guests, truncated: truncated)
  end

  def row_named(guest_name, owner: account, template: node_template, recorded_as: :provider_guest_name)
    node = create(:system_node, account: owner, node_template: template)
    row = create(:system_node_instance, node: node, status: "running")
    if recorded_as == :provider_guest_name
      row.merge_config!("provider_guest_name" => guest_name)
    else
      row.update_columns(name: guest_name)
    end
    row
  end

  def other_account_template
    other = create(:account)
    [ other, create(:system_node_template, account: other) ]
  end

  describe "#sense" do
    it "reports a guest named for one of the account's pools that no platform row knows" do
      stub_listing([ guest("ci-builders-pool-1789188789-0-20260912045310-cc99", vmid: 9002) ])

      signals = sensor.sense

      expect(signals.map(&:kind)).to eq([ described_class::SIGNAL_KIND ])
      expect(signals.first.payload).to include(
        "instance_pool_id" => pool.id,
        "environment_id" => pool.environment_id,
        "provider_region_id" => provider_region.id,
        "cloud_instance_id" => "pve1/qemu/9002",
        "guest_name" => "ci-builders-pool-1789188789-0-20260912045310-cc99",
        "guest_status" => "running"
      )
    end

    # The fingerprint names the guest by id AND name: a recycled id wearing a
    # different guest is a different orphan, not a repeat of the first.
    it "fingerprints the orphan by provider id and guest name" do
      stub_listing([ guest("ci-builders-pool-1-0", vmid: 9002) ])

      expect(sensor.sense.first.fingerprint).to eq("pool_guest_orphaned:pve1/qemu/9002:ci-builders-pool-1-0")
    end

    it "stays quiet for a guest a platform row created (provider_guest_name)" do
      row_named("ci-builders-pool-1-0")
      stub_listing([ guest("ci-builders-pool-1-0") ])

      expect(sensor.sense).to be_empty
    end

    # Rows written before the guest name was captured carry only `name`, which
    # is what the guest was created as.
    it "stays quiet for a guest an older row knows only by its name" do
      row_named("ci-builders-pool-1-0", recorded_as: :name)
      stub_listing([ guest("ci-builders-pool-1-0") ])

      expect(sensor.sense).to be_empty
    end

    # A row marked lost gave up its provider id, not its name: while it exists,
    # the guest it created is still accounted for.
    it "stays quiet for a guest a row marked lost still names" do
      row = row_named("ci-builders-pool-1-0")
      row.mark_provider_guest_lost!(reason: "id recycled")
      stub_listing([ guest("ci-builders-pool-1-0") ])

      expect(sensor.sense).to be_empty
    end

    # A hypervisor can serve more than one account. A guest another tenant's
    # row still owns is not an orphan of this one's pool, whatever its name.
    it "stays quiet for a guest a row in ANOTHER account knows" do
      other, template = other_account_template
      row_named("ci-builders-pool-1-0", owner: other, template: template)
      stub_listing([ guest("ci-builders-pool-1-0") ])

      expect(sensor.sense).to be_empty
    end

    # Two accounts with a pool of the same name on one hypervisor: the name
    # cannot say whose guest it is, nor which plane to reap it in.
    it "stays quiet when another account also has a pool of that name" do
      other, template = other_account_template
      make_pool("ci-builders", owner: other, template: template)
      stub_listing([ guest("ci-builders-pool-1-0") ])

      expect(sensor.sense).to be_empty
    end

    it "never reports a guest that is not named for one of the account's pools" do
      stub_listing([ guest("sdwan-testbed-a", vmid: 9004), guest("control-plane-hub", vmid: 600),
                     guest("ci-builders", vmid: 9005), guest("other-pool-pool-1-0", vmid: 9006) ])

      expect(sensor.sense).to be_empty
    end

    it "attributes a guest to the pool whose name it carries, not to a pool whose name is merely a prefix" do
      longer = make_pool("ci-builders-arm64")
      stub_listing([ guest("ci-builders-arm64-pool-7-0", vmid: 9007) ])

      expect(sensor.sense.map { |s| s.payload["instance_pool_id"] }).to eq([ longer.id ])
    end

    # "ci" is ephemeral; "ci-pool-gpu" is not. Its guest "ci-pool-gpu-pool-…"
    # also starts with "ci-pool-", and must not be claimed by the shorter pool.
    it "never lets a shorter ephemeral pool claim the guest of a longer-named non-ephemeral pool" do
      make_pool("ci")
      make_pool("ci-pool-gpu", lifecycle_class: "spot")
      stub_listing([ guest("ci-pool-gpu-pool-1-0", vmid: 9010) ])

      expect(sensor.sense).to be_empty
    end

    # The reap lane is for DISPOSABLE members (the operator direction: ci /
    # ephemeral). A spot member's guest can be a provider reclaim in flight.
    it "ignores pools that are not ephemeral" do
      make_pool("spot-builders", lifecycle_class: "spot")
      stub_listing([ guest("spot-builders-pool-1-0", vmid: 9008) ])

      expect(sensor.sense).to be_empty
    end

    # Members are placed in preferred_regions too (pick_region_for_slot).
    it "reads the pool's preferred regions as well as its own" do
      elsewhere = create(:system_provider_region)
      pool.update!(preferred_regions: [ elsewhere.id ])
      other_adapter = instance_double("System::Providers::BaseProvider")
      stub_listing([])
      allow(System::Providers::Registry).to receive(:for).with(connection, region: elsewhere).and_return(other_adapter)
      allow(other_adapter).to receive(:supports?).with(:sync).and_return(true)
      allow(other_adapter).to receive(:list_instances)
        .and_return(success: true, instances: [ guest("ci-builders-pool-9-0", vmid: 9011) ], truncated: false)

      expect(sensor.sense.map { |s| s.payload["provider_region_id"] }).to eq([ elsewhere.id ])
    end

    # A cluster-wide listing answers the same guest from every region on it.
    it "reports a guest once when two listed regions return it" do
      elsewhere = create(:system_provider_region)
      pool.update!(preferred_regions: [ elsewhere.id ])
      stub_listing([ guest("ci-builders-pool-1-0", vmid: 9002) ])
      allow(System::Providers::Registry).to receive(:for).with(connection, region: elsewhere).and_return(adapter)

      expect(sensor.sense.size).to eq(1)
    end

    # UNKNOWN IS NOT ORPHANED. A partial or failed listing cannot prove a guest
    # is unrecorded — it cannot even prove which guests exist.
    it "emits nothing from a failed listing" do
      stub_listing([], success: false)

      expect(sensor.sense).to be_empty
    end

    it "emits nothing from a truncated listing" do
      stub_listing([ guest("ci-builders-pool-1-0") ], truncated: true)

      expect(sensor.sense).to be_empty
    end

    it "emits nothing when the region has no usable provider connection" do
      allow(System::Providers::Registry).to receive(:find_connection_for_region).and_return(nil)

      expect(sensor.sense).to be_empty
    end

    it "emits nothing when the provider cannot list its inventory" do
      stub_listing([ guest("ci-builders-pool-1-0") ])
      allow(adapter).to receive(:supports?).with(:sync).and_return(false)

      expect(sensor.sense).to be_empty
    end

    it "emits nothing when the listing raises" do
      stub_listing([])
      allow(adapter).to receive(:list_instances).and_raise(StandardError, "connection reset")

      expect(sensor.sense).to be_empty
    end

    it "lists each region once however many pools share it" do
      make_pool("ci-builders-arm64")
      stub_listing([])

      sensor.sense

      expect(adapter).to have_received(:list_instances).once
    end

    it "bounds the signals it emits in one tick" do
      stub_listing((1..5).map { |i| guest("ci-builders-pool-#{i}-0", vmid: 9100 + i) })
      allow(described_class).to receive(:resolved_thresholds).and_return("max_per_tick" => 2)

      expect(sensor.sense.size).to eq(2)
    end
  end
end
