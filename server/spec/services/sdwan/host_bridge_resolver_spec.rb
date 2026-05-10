# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::HostBridgeResolver, type: :service do
  let(:account) { Account.first || create(:account) }
  let(:node)    { sdwan_test_node(account: account) }
  let(:host_a)  { sdwan_test_node_instance(node: node) }
  let(:host_b)  { sdwan_test_node_instance(node: node) }

  before do
    Sdwan::HostBridge.where(account_id: account.id).delete_all
  end

  describe ".bridge_name_for" do
    it "returns the kernel-visible bridge name for a host with an active bridge" do
      bridge = Sdwan::HostBridgeAllocator.allocate!(host: host_a)
      bridge.mark_active!
      expect(described_class.bridge_name_for(host_a)).to eq(bridge.bridge_name)
      expect(described_class.bridge_name_for(host_a)).to start_with("pwnbr-")
    end

    it "resolves draining bridges (still reachable during teardown grace)" do
      bridge = Sdwan::HostBridgeAllocator.allocate!(host: host_a)
      bridge.mark_active!
      Sdwan::HostBridgeAllocator.release!(bridge)
      expect(bridge.reload.state).to eq("draining")
      expect(described_class.bridge_name_for(host_a)).to eq(bridge.bridge_name)
    end

    it "resolves pending bridges (allocator just minted, agent not yet applied)" do
      # Pending bridges are NOT in the compilable scope — resolver should
      # raise so callers don't dispatch a libvirt define against a bridge
      # the kernel doesn't yet know about.
      Sdwan::HostBridgeAllocator.allocate!(host: host_a)  # state=pending
      expect { described_class.bridge_name_for(host_a) }
        .to raise_error(Sdwan::HostBridgeResolver::NoBridgeForHost)
    end

    it "raises NoBridgeForHost when no HostBridge exists for the host" do
      expect { described_class.bridge_name_for(host_a) }
        .to raise_error(Sdwan::HostBridgeResolver::NoBridgeForHost,
                        /no active Sdwan::HostBridge for host #{host_a.id}/)
    end

    it "raises NoBridgeForHost when the only HostBridge is removed" do
      bridge = Sdwan::HostBridgeAllocator.allocate!(host: host_a)
      bridge.mark_removed!
      expect { described_class.bridge_name_for(host_a) }
        .to raise_error(Sdwan::HostBridgeResolver::NoBridgeForHost)
    end

    it "raises NoBridgeForHost when host argument is nil" do
      expect { described_class.bridge_name_for(nil) }
        .to raise_error(Sdwan::HostBridgeResolver::NoBridgeForHost)
    end

    it "scopes to a single host — does not leak bridges from other hosts" do
      bridge_a = Sdwan::HostBridgeAllocator.allocate!(host: host_a)
      bridge_a.mark_active!
      # host_b has no bridge yet
      expect { described_class.bridge_name_for(host_b) }
        .to raise_error(Sdwan::HostBridgeResolver::NoBridgeForHost)
      # host_a still resolves fine
      expect(described_class.bridge_name_for(host_a)).to eq(bridge_a.bridge_name)
    end

    it "returns the lowest-short_id bridge when multiple compilable bridges exist" do
      # Phase O2 multi-tenant scenario: two bridges of different kinds.
      linux = Sdwan::HostBridgeAllocator.allocate!(host: host_a, kind: "linux")
      linux.mark_active!
      ovs = Sdwan::HostBridgeAllocator.allocate!(host: host_a, kind: "ovs")
      ovs.mark_active!

      # Default lookup picks lowest short_id (the linux bridge here).
      expect(described_class.bridge_name_for(host_a)).to eq(linux.bridge_name)
    end
  end

  describe ".bridge_name_for_kind" do
    it "filters by kind — finds the OVS bridge even when a Linux bridge sits in front" do
      linux = Sdwan::HostBridgeAllocator.allocate!(host: host_a, kind: "linux")
      linux.mark_active!
      ovs = Sdwan::HostBridgeAllocator.allocate!(host: host_a, kind: "ovs")
      ovs.mark_active!

      expect(described_class.bridge_name_for_kind(host_a, kind: "ovs")).to eq(ovs.bridge_name)
      expect(described_class.bridge_name_for_kind(host_a, kind: "linux")).to eq(linux.bridge_name)
    end

    it "raises NoBridgeForHost with kind detail when the requested kind has no compilable row" do
      linux = Sdwan::HostBridgeAllocator.allocate!(host: host_a, kind: "linux")
      linux.mark_active!
      expect { described_class.bridge_name_for_kind(host_a, kind: "ovs") }
        .to raise_error(Sdwan::HostBridgeResolver::NoBridgeForHost,
                        /kind=ovs/)
    end
  end

  describe ".bridge_for" do
    it "returns the HostBridge row (for callers needing CIDR / metadata)" do
      bridge = Sdwan::HostBridgeAllocator.allocate!(host: host_a)
      bridge.mark_active!
      resolved = described_class.bridge_for(host_a)
      expect(resolved.id).to eq(bridge.id)
      expect(resolved).to be_a(Sdwan::HostBridge)
    end
  end

  describe ".bridge_present?" do
    it "is true when an active bridge exists" do
      bridge = Sdwan::HostBridgeAllocator.allocate!(host: host_a)
      bridge.mark_active!
      expect(described_class.bridge_present?(host_a)).to be true
    end

    it "is true when a draining bridge exists" do
      bridge = Sdwan::HostBridgeAllocator.allocate!(host: host_a)
      bridge.mark_active!
      bridge.start_drain!
      expect(described_class.bridge_present?(host_a)).to be true
    end

    it "is false when no compilable bridge exists" do
      expect(described_class.bridge_present?(host_a)).to be false
    end

    it "is false when host is nil (does not raise)" do
      expect(described_class.bridge_present?(nil)).to be false
    end

    it "honors the kind filter" do
      bridge = Sdwan::HostBridgeAllocator.allocate!(host: host_a, kind: "linux")
      bridge.mark_active!
      expect(described_class.bridge_present?(host_a, kind: "linux")).to be true
      expect(described_class.bridge_present?(host_a, kind: "ovs")).to be false
    end
  end
end
