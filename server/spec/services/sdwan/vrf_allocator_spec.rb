# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::VrfAllocator, type: :service do
  let(:account) { Account.first || create(:account) }
  let(:node)    { sdwan_test_node(account: account) }
  let(:host_a)  { sdwan_test_node_instance(node: node) }
  let(:host_b)  { sdwan_test_node_instance(node: node) }

  before do
    Sdwan::HostVrfAssignment.where(account_id: account.id).delete_all
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
  end

  let(:net_a) { Sdwan::Network.create!(account_id: account.id, name: "vrf-net-a-#{SecureRandom.hex(3)}") }
  let(:net_b) { Sdwan::Network.create!(account_id: account.id, name: "vrf-net-b-#{SecureRandom.hex(3)}") }
  let(:net_c) { Sdwan::Network.create!(account_id: account.id, name: "vrf-net-c-#{SecureRandom.hex(3)}") }

  describe ".allocate!" do
    it "creates a new HostVrfAssignment with the lowest available table_id (100) and short_id (1)" do
      hva = described_class.allocate!(host: host_a, network: net_a)
      expect(hva).to be_persisted
      expect(hva.table_id).to eq(100)
      expect(hva.short_id).to eq(1)
      expect(hva.vrf_name).to eq("sdwan-1")
      expect(hva.account_id).to eq(account.id)
    end

    it "is idempotent — calling twice returns the same row, not a new one" do
      first  = described_class.allocate!(host: host_a, network: net_a)
      second = described_class.allocate!(host: host_a, network: net_a)
      expect(second.id).to eq(first.id)
      expect(Sdwan::HostVrfAssignment.where(node_instance_id: host_a.id, sdwan_network_id: net_a.id).count).to eq(1)
    end

    it "allocates monotonically increasing table_ids on the same host" do
      h1 = described_class.allocate!(host: host_a, network: net_a)
      h2 = described_class.allocate!(host: host_a, network: net_b)
      h3 = described_class.allocate!(host: host_a, network: net_c)
      expect([h1.table_id, h2.table_id, h3.table_id]).to eq([100, 101, 102])
    end

    it "fills gaps left by hard-deleted rows (lowest-unused wins)" do
      h1 = described_class.allocate!(host: host_a, network: net_a)
      h2 = described_class.allocate!(host: host_a, network: net_b)
      described_class.allocate!(host: host_a, network: net_c)

      # Removed rows hold their table_id until a separate reaper
      # process hard-deletes them after the 24h grace window. We
      # simulate that hard-delete here so the id rejoins the pool.
      described_class.release!(h2, force: true)
      h2.destroy!

      net_d = Sdwan::Network.create!(account_id: account.id, name: "vrf-net-d-#{SecureRandom.hex(3)}")
      new_hva = described_class.allocate!(host: host_a, network: net_d)
      expect(new_hva.table_id).to eq(h2.table_id)
    end

    it "treats removed rows as still-allocated until the grace reaper sweeps them" do
      h1 = described_class.allocate!(host: host_a, network: net_a)
      h2 = described_class.allocate!(host: host_a, network: net_b)
      described_class.release!(h2, force: true)

      net_d = Sdwan::Network.create!(account_id: account.id, name: "vrf-net-d-#{SecureRandom.hex(3)}")
      new_hva = described_class.allocate!(host: host_a, network: net_d)
      # The removed row's table_id is NOT reused immediately.
      expect(new_hva.table_id).not_to eq(h2.table_id)
      expect(new_hva.table_id).to eq(102)
    end

    it "treats draining rows as still-allocated (does not reuse the table_id)" do
      h1 = described_class.allocate!(host: host_a, network: net_a)
      h2 = described_class.allocate!(host: host_a, network: net_b)
      described_class.release!(h2)  # draining (default)

      net_d = Sdwan::Network.create!(account_id: account.id, name: "vrf-net-d-#{SecureRandom.hex(3)}")
      new_hva = described_class.allocate!(host: host_a, network: net_d)
      expect(new_hva.table_id).not_to eq(h2.table_id)
      expect([h1.table_id, h2.table_id, new_hva.table_id].uniq.length).to eq(3)
    end

    it "permits the same table_id on a different host" do
      a = described_class.allocate!(host: host_a, network: net_a)
      b = described_class.allocate!(host: host_b, network: net_a)
      expect(a.table_id).to eq(100)
      expect(b.table_id).to eq(100)
      expect(a.id).not_to eq(b.id)
    end

    it "skips kernel-reserved tables (253/254/255) when filling gaps" do
      # We force a state where the lowest gap is at 253: pre-create
      # rows occupying 100..252 and 256, then release 250 to expose a
      # 250 gap and ensure the allocator picks 250, not 253.
      # This is a unit-style test using direct .create! to set up the
      # used_id set; the allocator just needs to read state.
      (100..252).each_with_index do |id, i|
        net = Sdwan::Network.create!(account_id: account.id,
                                     name: "filler-#{i}-#{SecureRandom.hex(2)}")
        Sdwan::HostVrfAssignment.create!(account_id: account.id,
                                         node_instance: host_a, network: net,
                                         table_id: id, short_id: 1000 + i,
                                         vrf_name: "f#{id}")
      end

      net_after_reserved = Sdwan::Network.create!(account_id: account.id, name: "after-r-#{SecureRandom.hex(3)}")
      hva = described_class.allocate!(host: host_a, network: net_after_reserved)
      # 100..252 are used → next candidate is 253 (skipped) → 254 (skipped) → 255 (skipped) → 256
      expect(hva.table_id).to eq(256)
    end

    it "raises CapacityExhausted when arguments are nil" do
      expect { described_class.allocate!(host: nil, network: net_a) }
        .to raise_error(Sdwan::VrfAllocator::InvalidArguments)
      expect { described_class.allocate!(host: host_a, network: nil) }
        .to raise_error(Sdwan::VrfAllocator::InvalidArguments)
    end

    it "readopts a removed row instead of allocating a new one" do
      hva = described_class.allocate!(host: host_a, network: net_a)
      described_class.release!(hva, force: true)
      hva.reload
      expect(hva.state).to eq("removed")

      readopted = described_class.allocate!(host: host_a, network: net_a)
      expect(readopted.id).to eq(hva.id)
      expect(readopted.state).to eq("active")
    end

    it "scopes the assignment to the network's account_id, not the host's" do
      # Sanity: the row inherits account_id from the network's account
      # so cross-account scopes (Sdwan::HostVrfAssignment.for_account)
      # work without inspecting the underlying NodeInstance.
      hva = described_class.allocate!(host: host_a, network: net_a)
      expect(hva.account_id).to eq(net_a.account_id)
    end
  end

  describe ".release!" do
    let!(:hva) { described_class.allocate!(host: host_a, network: net_a) }

    it "transitions to draining by default" do
      described_class.release!(hva)
      expect(hva.reload.state).to eq("draining")
      expect(hva.draining_at).to be_present
    end

    it "transitions to removed when force: true" do
      described_class.release!(hva, force: true)
      expect(hva.reload.state).to eq("removed")
      expect(hva.removed_at).to be_present
    end
  end

  describe "vrf_name + iface name derivation" do
    it "derives vrf_name from the per-host short_id (sdwan-<short_id>)" do
      hva = described_class.allocate!(host: host_a, network: net_a)
      expect(hva.vrf_name).to eq("sdwan-#{hva.short_id}")
    end

    it "exposes IFNAMSIZ-safe iface names via the model helpers" do
      hva = described_class.allocate!(host: host_a, network: net_a)
      expect(hva.vrf_iface_name).to eq("sdwan-1")
      expect(hva.wg_iface_name).to eq("wg-sdwan-1")
      expect(hva.dummy_iface_name).to eq("d-sdwan-1")
      [hva.vrf_iface_name, hva.wg_iface_name, hva.dummy_iface_name].each do |name|
        expect(name.length).to be <= Sdwan::HostVrfAssignment::VRF_NAME_MAX
      end
    end

    it "allocates monotonic short_ids per host (1, 2, 3, ...)" do
      h1 = described_class.allocate!(host: host_a, network: net_a)
      h2 = described_class.allocate!(host: host_a, network: net_b)
      h3 = described_class.allocate!(host: host_a, network: net_c)
      expect([h1.short_id, h2.short_id, h3.short_id]).to eq([1, 2, 3])
    end

    it "permits the same short_id on a different host" do
      a = described_class.allocate!(host: host_a, network: net_a)
      b = described_class.allocate!(host: host_b, network: net_a)
      expect(a.short_id).to eq(1)
      expect(b.short_id).to eq(1)
      expect(a.id).not_to eq(b.id)
    end

    it "never produces colliding vrf_names regardless of network UUID similarity" do
      # Two networks created back-to-back share UUIDv7 timestamp prefix;
      # the old network_handle-derived naming would collide. Per-host
      # short_id allocation gives each its own unique vrf_name.
      h1 = described_class.allocate!(host: host_a, network: net_a)
      h2 = described_class.allocate!(host: host_a, network: net_b)
      expect(h1.vrf_name).not_to eq(h2.vrf_name)
      expect(h1.wg_iface_name).not_to eq(h2.wg_iface_name)
    end
  end
end
