# frozen_string_literal: true

require "rails_helper"

# IMP-54fdf40fbf9d — the WireGuard interface name had FIVE producers on the
# server and they did not agree.
#
# Sdwan::HostVrfAssignment#wg_iface_name is "wg-sdwan-<short_id>" (an integer
# counter, per host+network), and that is the name the agent actually creates:
# TopologyCompiler#interface_name hands it to wg_applier.go, which does
# `ip link add <cfg.Name> type wireguard`. Every other producer re-derived a
# DIFFERENT name from the network handle (the first six hex of the network
# UUID) — so the firewall's `iif` clause, the k3s flannel interface and the
# storage mount hint all referenced a device that will never exist.
#
# The firewall case is the dangerous one and it fails OPEN: an nftables filter
# chain whose every rule matches `iif "wg-sdwan-019fe6"` on a host where the
# device is `wg-sdwan-1` matches no traffic at all. A default-deny intended for
# the overlay silently permits everything, and multi_tenant_isolation — which
# composes its blast-radius boundary out of exactly these rules — would report
# success while enforcing nothing.
#
# THE ORACLE IS BYTE-EQUALITY BETWEEN PRODUCERS, never a hardcoded literal. A
# golden string would pass against two producers that agree on the wrong name,
# and would have to be edited the next time the derivation legitimately
# changes — which is how the two derivations drifted apart in the first place.
# Each example therefore DRIFTS the underlying short_id and asserts the
# producers still agree, so the wire value is genuinely under test.
RSpec.describe "WireGuard interface name consistency across server-side producers" do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  # Same account as the network, peer and assignment below: the bare factory
  # gave the instance a FRESH account, a cross-tenant fixture that
  # System::StorageAssignment now refuses (#references_belong_to_account).
  let(:instance) { create(:system_node_instance, :running, account: account) }
  let(:peer) { enrolled_peer(instance) }

  def enrolled_peer(node_instance)
    create(:sdwan_peer, :active, account: account,
           network: network, node_instance: node_instance)
  end

  # The allocation Sdwan::PeerEnroller#allocate_vrf! performs for every
  # enrolled peer. short_id is deliberately NOT 1 in most examples — a
  # fixture that leaves it at the first counter value cannot tell
  # "wg-sdwan-<short_id>" apart from "wg-sdwan-<anything else that is 1>".
  def allocate_hva!(short_id:)
    # Built directly rather than via a factory: none exists for this model,
    # and adding one is scope this task does not need.
    ::Sdwan::HostVrfAssignment.create!(
      account: account,
      node_instance: instance,
      network: network,
      short_id: short_id,
      table_id: 100 + short_id,
      vrf_name: "sdwan-#{short_id}",
      state: "active"
    )
  end

  # THE REFERENCE VALUE: the `name` field of the interface block
  # TopologyCompiler builds for this peer. wg_applier.go creates whatever
  # lands there (`ip link add <cfg.Name> type wireguard`), so it IS the device
  # that will exist on the host, and it is the value every other producer must
  # agree with.
  #
  # Read through #interface_block rather than the full compile_for_peer:
  # the full compile also signs a membership credential, which needs Vault-
  # backed key material this spec has no business standing up. The block is
  # the exact structure the payload embeds — one call below the wire, not a
  # reimplementation of it.
  def topology_iface_name
    compiler = ::Sdwan::TopologyCompiler.new(
      network, federation_resolver: ->(_net) { [] }
    )
    block = compiler.send(:interface_block, peer)
    block[:name] || block["name"]
  end

  describe "the firewall compiler's iif" do
    it "equals the interface name the agent is told to create" do
      allocate_hva!(short_id: 7)

      firewall = ::Sdwan::FirewallCompiler.compile_for_peer(peer)

      expect(firewall[:interface]).to eq(topology_iface_name)
    end

    it "still equals it when the short_id drifts — so the assertion tests the wire value" do
      allocate_hva!(short_id: 4242)

      firewall = ::Sdwan::FirewallCompiler.compile_for_peer(peer)

      expect(firewall[:interface]).to eq(topology_iface_name)
      expect(firewall[:interface]).to eq("wg-sdwan-4242")
    end

    # The offer's own acceptance: prove the EMITTED nft text — not just the
    # summary field — names the device the applier creates. A compiler could
    # report the right `interface` and still emit rules keyed on the old one.
    it "references that device in the emitted ruleset when a real rule exists" do
      allocate_hva!(short_id: 7)
      create(:sdwan_firewall_rule, account: account, network: network)

      firewall = ::Sdwan::FirewallCompiler.compile_for_peer(peer)

      expect(firewall[:rule_count]).to be > 0
      expect(firewall[:ruleset]).to include(%(iif "#{topology_iface_name}"))
      expect(firewall[:ruleset]).not_to include("wg-sdwan-#{network.network_handle}")
    end
  end

  describe "the k3s flannel interface" do
    # Read through RuntimeConfigBuilder's PUBLIC entry point, not through the
    # shared resolver. Calling the resolver here would assert only that the
    # resolver agrees with itself: revert the runtime_config_builder change
    # entirely and such an example still passes, because the producer under
    # test is never invoked. The existing request spec cannot cover this
    # either — its fixture allocates no HostVrfAssignment, so it pins the
    # fallback branch. This is the one call site whose failure mode is a
    # silent cluster-networking failure, so it gets the end-to-end oracle.
    # Memoized: the fixture rows below are unique per node_instance, so a
    # second call would collide rather than re-read the producer.
    def flannel_iface_name
      return @flannel_iface_name if defined?(@flannel_iface_name)

      # peer is referenced so the attachment Sdwan::Peer exists — the builder
      # resolves the network through OverlayAddressResolver.attachment_peer_for.
      peer
      cluster = ::Devops::KubernetesCluster.create!(
        account: account, name: "k3s-iface-#{SecureRandom.hex(3)}",
        flavor: "k3s", environment: "production", status: "bootstrapping",
        cni_plugin: "flannel",
        api_endpoint: "https://[fd00::1]:6443",
        encrypted_kubeconfig: "kc", encrypted_server_token: "tok",
        encrypted_agent_token: "tok",
        metadata: { "pod_cidr" => "10.42.0.0/16", "sdwan_network_id" => network.id }
      )
      ::Devops::KubernetesNode.create!(
        kubernetes_cluster: cluster, node_instance: instance,
        name: "k-#{instance.id[0, 6]}", role: "server", status: "active"
      )

      config = ::System::NodeApi::RuntimeConfigBuilder.build(
        runtime: "k3s_server", instance: instance
      )
      @flannel_iface_name = config[:bootstrap_config][:flannel_iface]
    end

    it "equals the interface name the agent is told to create" do
      allocate_hva!(short_id: 31)

      expect(flannel_iface_name).to eq(topology_iface_name)
      expect(flannel_iface_name).to eq("wg-sdwan-31")
    end
  end

  describe "the storage mount hint" do
    it "equals the interface name the agent is told to create" do
      allocate_hva!(short_id: 88)
      # Enrol the peer FIRST. With the instance in the network's account, the
      # assignment's reconcile (AssignmentReconciliationService) reuses an
      # existing Sdwan::Peer and enrols one only when none exists, so creating
      # the assignment first would make this spec's own peer a duplicate.
      peer
      # The factory's file_storage_id is a bare uuid; the model validates both
      # that the row exists and that it is node_mount_capable, so a real
      # :node_mountable storage is needed here.
      assignment = create(
        :system_storage_assignment,
        account: account,
        node_instance: instance,
        sdwan_network: network,
        file_storage_id: create(:file_storage, :node_mountable, account: account).id
      )

      hint = ::System::Storage::TaskPayloadBuilder.new(assignment: assignment).send(:wg_interface_hint)

      expect(hint).to eq(topology_iface_name)
      expect(hint).to eq("wg-sdwan-88")
    end
  end

  # The fallback is NOT the defect and must survive. TopologyCompiler already
  # falls back to the network handle for static-only networks where no HVA is
  # allocated; the fix converges the other producers onto the SAME resolution,
  # fallback included, rather than deleting it.
  describe "a network with no HostVrfAssignment (static-only)" do
    it "falls back to the handle form, and every producer agrees on it" do
      expect(topology_iface_name).to eq("wg-sdwan-#{network.network_handle}")

      firewall = ::Sdwan::FirewallCompiler.compile_for_peer(peer)
      resolved = ::Sdwan::HostVrfAssignment.wg_iface_name_for(
        network: network, node_instance: instance
      )

      expect(firewall[:interface]).to eq(topology_iface_name)
      expect(resolved).to eq(topology_iface_name)
    end
  end

  # A draining assignment is still the live device — TopologyCompiler's own
  # lookup accepts active AND draining, so the shared resolver must too, or
  # the firewall would stop matching exactly while a host is being drained.
  describe "a draining assignment" do
    it "is still the interface name every producer uses" do
      hva = allocate_hva!(short_id: 12)
      hva.update!(state: "draining")

      firewall = ::Sdwan::FirewallCompiler.compile_for_peer(peer)

      expect(firewall[:interface]).to eq(topology_iface_name)
      expect(firewall[:interface]).to eq("wg-sdwan-12")
    end
  end

  # Per-host, not per-network: two hosts on one network get different
  # short_ids, so a network-scoped answer is wrong for at least one of them.
  # This is why the firewall compiler had to become peer-aware.
  describe "two peers on one network" do
    it "gives each peer its own interface name" do
      allocate_hva!(short_id: 5)

      other_instance = create(:system_node_instance, :running)
      other_peer = enrolled_peer(other_instance)
      ::Sdwan::HostVrfAssignment.create!(
        account: account, node_instance: other_instance, network: network,
        short_id: 6, table_id: 106, vrf_name: "sdwan-6", state: "active"
      )

      first = ::Sdwan::FirewallCompiler.compile_for_peer(peer)
      second = ::Sdwan::FirewallCompiler.compile_for_peer(other_peer)

      expect(first[:interface]).to eq("wg-sdwan-5")
      expect(second[:interface]).to eq("wg-sdwan-6")
      expect(first[:interface]).not_to eq(second[:interface])
    end
  end
end
