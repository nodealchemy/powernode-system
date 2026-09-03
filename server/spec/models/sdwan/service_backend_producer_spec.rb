# frozen_string_literal: true

require "rails_helper"

# APO-3d (IMP-0c10b9fd5596) — the PRODUCER side of the backend set.
#
# APO-3c shipped Sdwan::ServiceBackend and the writer's fan-out, and then
# nothing wrote a row: no executor, verb, seed or controller. This is the
# instance-keyed API the producers (ScaleProjectExecutor, ReplaceInstanceExecutor,
# ReapInstanceExecutor) share, so all three resolve "which services route to
# this instance" and "which of its addresses does this service dial" in ONE
# place instead of three.
RSpec.describe Sdwan::ServiceBackend, "producer API (APO-3d)", type: :model do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }

  def instance!(private_ip:)
    node = create(:system_node, account: account)
    create(:system_node_instance, :running, node: node, private_ip_address: private_ip)
  end

  def service!(**attrs)
    create(:sdwan_service, { account: account, backend_host: "10.0.1.5", backend_port: 3000 }.merge(attrs))
  end

  describe ".instance_addresses" do
    it "lists the overlay peer address first, then the instance's own addresses, host form only" do
      instance = instance!(private_ip: "10.0.1.5")
      instance.update!(vpn_ip_address: "10.8.0.5")
      create(:sdwan_peer, account: account, network: network, node_instance: instance,
                          assigned_address: "fd00:abcd:1::5/128")

      expect(described_class.instance_addresses(instance))
        .to eq([ "fd00:abcd:1::5", "10.8.0.5", "10.0.1.5", instance.public_ip_address ])
    end
  end

  describe ".services_routed_to" do
    it "finds a service whose LEGACY backend_host is one of the instance's addresses" do
      instance = instance!(private_ip: "10.0.1.5")
      hit  = service!(backend_host: "10.0.1.5")
      _far = service!(slug: "other", backend_host: "10.0.1.99")

      expect(described_class.services_routed_to(account: account, instance: instance).map(&:id))
        .to eq([ hit.id ])
    end

    it "finds a service that reaches the instance through a MEMBER row" do
      instance = instance!(private_ip: "10.0.1.6")
      svc = service!(backend_host: "10.0.1.5")
      described_class.create!(service: svc, backend_host: "10.0.1.6", backend_port: 3000)

      expect(described_class.services_routed_to(account: account, instance: instance).map(&:id))
        .to eq([ svc.id ])
    end

    it "finds a service whose backend VIP is held by one of the instance's peers" do
      instance = instance!(private_ip: "10.0.1.7")
      peer = create(:sdwan_peer, account: account, network: network, node_instance: instance)
      vip  = create(:sdwan_virtual_ip, network: network, account: account, holder_peer_ids: [ peer.id ])
      svc  = service!(backend_host: nil, backend_vip: vip)

      expect(described_class.services_routed_to(account: account, instance: instance).map(&:id))
        .to eq([ svc.id ])
    end

    it "never crosses the account boundary" do
      instance = instance!(private_ip: "10.0.1.5")
      other = create(:account)
      create(:sdwan_service, account: other, backend_host: "10.0.1.5", backend_port: 3000)

      expect(described_class.services_routed_to(account: account, instance: instance)).to be_empty
    end
  end

  # The filter every instance-keyed producer applies. A VIP-fronted service is
  # NOT the backend set's business: the VIP move re-homes it, and a host-form
  # row beside a VIP row counts one machine twice in the round robin.
  describe ".host_routed_services" do
    it "keeps a service reached by the instance's address, through the legacy column or a member row" do
      instance = instance!(private_ip: "10.0.1.6")
      legacy = service!(slug: "legacy", backend_host: "10.0.1.6")
      member = service!(slug: "member", backend_host: "10.0.1.5")
      described_class.create!(service: member, backend_host: "10.0.1.6", backend_port: 3000)

      expect(described_class.host_routed_services(account: account, instance: instance).map(&:id))
        .to contain_exactly(legacy.id, member.id)
    end

    it "drops a service that reaches the instance ONLY through a backend VIP" do
      instance = instance!(private_ip: "10.0.1.7")
      peer = create(:sdwan_peer, account: account, network: network, node_instance: instance)
      vip  = create(:sdwan_virtual_ip, network: network, account: account, holder_peer_ids: [ peer.id ])
      vip_only = service!(slug: "vip-only", backend_host: nil, backend_vip: vip)

      expect(described_class.services_routed_to(account: account, instance: instance).map(&:id))
        .to eq([ vip_only.id ])
      expect(described_class.host_routed_services(account: account, instance: instance)).to be_empty
    end
  end

  describe "a cross-account backend VIP" do
    it "is refused: a row's account is the service's, so its VIP must be that account's too" do
      svc = service!(backend_host: "10.0.1.5")
      other = create(:account)
      other_network = create(:sdwan_network, account: other)
      foreign_vip = create(:sdwan_virtual_ip, network: other_network, account: other)

      row = described_class.new(service: svc, backend_vip: foreign_vip, backend_port: 3000)

      expect(row).not_to be_valid
      expect(row.errors[:backend_vip_id]).to include("must belong to the service's account")
    end
  end

  describe ".add_instance!" do
    it "materialises the legacy backend as the first row before adding the instance, so the " \
       "original backend keeps its share instead of being silently dropped by the explicit set" do
      svc = service!(backend_host: "10.0.1.5", backend_port: 3000)
      replica = instance!(private_ip: "10.0.1.6")

      row = described_class.add_instance!(service: svc, instance: replica)

      expect(row.backend_host).to eq("10.0.1.6")
      expect(row.backend_port).to eq(3000)
      expect(row.status).to eq("active")
      expect(svc.reload.load_balanced_backends.map(&:address)).to eq(%w[10.0.1.5 10.0.1.6])
    end

    # PRODUCTION SPELLING, deliberately: Sdwan::PrefixAllocator.compose_address_128
    # stores assigned_address WITH its /128 and Sdwan::Peer persists that
    # verbatim, while a backend host is always bare. A fixture that omits the
    # mask makes this example pass against a lookup that matches nothing on a
    # real fleet — and the fallback it then silently takes ("first address")
    # dials a multi-homed replica on whichever fabric its oldest peer is on.
    it "dials the instance over the SAME overlay network the service's existing backend lives on, " \
       "matching the peer address the allocator actually stores (with its /128)" do
      seed = instance!(private_ip: "10.0.1.5")
      create(:sdwan_peer, account: account, network: network, node_instance: seed,
                          assigned_address: "fd00:abcd:1::5/128")
      svc = service!(backend_host: "fd00:abcd:1::5", backend_port: 3000)

      replica = instance!(private_ip: "10.0.1.6")
      other_network = create(:sdwan_network, account: account)
      # The OLDER peer is on the wrong fabric, so "first address" is the wrong
      # answer and only the per-network lookup gets this right.
      create(:sdwan_peer, account: account, network: other_network, node_instance: replica,
                          assigned_address: "fd00:dead::6/128")
      create(:sdwan_peer, account: account, network: network, node_instance: replica,
                          assigned_address: "fd00:abcd:1::6/128")

      row = described_class.add_instance!(service: svc, instance: replica)

      expect(row.backend_host).to eq("fd00:abcd:1::6")
    end

    it "re-activates a draining row for the same address rather than minting a duplicate" do
      svc = service!(backend_host: "10.0.1.5")
      replica = instance!(private_ip: "10.0.1.6")
      stale = described_class.create!(service: svc, backend_host: "10.0.1.6", backend_port: 3000,
                                      status: "draining")

      row = described_class.add_instance!(service: svc, instance: replica)

      expect(row.id).to eq(stale.id)
      expect(row.reload.status).to eq("active")
      expect(svc.backends.count).to eq(1)
    end

    it "refuses an instance with no address at all, loudly" do
      svc = service!
      node = create(:system_node, account: account)
      bare = create(:system_node_instance, node: node, private_ip_address: nil, public_ip_address: nil)

      expect { described_class.add_instance!(service: svc, instance: bare) }
        .to raise_error(Sdwan::ServiceBackend::NoAddressError)
    end
  end

  describe ".drain_instance! / .remove_instance!" do
    let(:svc) { service!(backend_host: "10.0.1.5") }
    let(:replica) { instance!(private_ip: "10.0.1.6") }

    before { described_class.add_instance!(service: svc, instance: replica) }

    it "drains every host-form row at the instance's addresses and leaves the others alone" do
      drained = described_class.drain_instance!(service: svc, instance: replica)

      expect(drained.map(&:backend_host)).to eq([ "10.0.1.6" ])
      expect(svc.backends.reload.map { |b| [ b.backend_host, b.status ] })
        .to contain_exactly([ "10.0.1.5", "active" ], [ "10.0.1.6", "draining" ])
    end

    it "removes the rows outright" do
      removed = described_class.remove_instance!(service: svc, instance: replica)

      expect(removed.map(&:backend_host)).to eq([ "10.0.1.6" ])
      expect(svc.backends.reload.map(&:backend_host)).to eq([ "10.0.1.5" ])
    end

    it "does not touch a VIP-form row: the VIP move, not the backend set, re-homes those" do
      peer = create(:sdwan_peer, account: account, network: network, node_instance: replica)
      vip  = create(:sdwan_virtual_ip, network: network, account: account, holder_peer_ids: [ peer.id ])
      described_class.create!(service: svc, backend_vip: vip, backend_port: 3000)

      described_class.remove_instance!(service: svc, instance: replica)

      expect(svc.backends.reload.where(backend_vip_id: vip.id).count).to eq(1)
    end
  end

  # Operator ruling 2026-09-02: draining EVERY member takes the service out of
  # rotation. The old fallback — "all draining ⇒ emit the legacy columns" —
  # sent every request to a host that, after a replace cycle, is precisely the
  # one that died.
  describe "an all-draining set" do
    it "resolves to NO backends and reports itself fully drained" do
      svc = service!(backend_host: "10.0.1.5")
      described_class.create!(service: svc, backend_host: "10.0.1.11", backend_port: 3000,
                              status: "draining")

      expect(svc.reload.load_balanced_backends).to eq([])
      expect(svc.fully_drained?).to be(true)
    end

    it "is not confused with an EMPTY set, which still renders the legacy backend" do
      svc = service!(backend_host: "10.0.1.5")

      expect(svc.fully_drained?).to be(false)
      expect(svc.load_balanced_backends.map(&:address)).to eq([ "10.0.1.5" ])
    end
  end
end
