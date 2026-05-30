# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::TopologyCompiler, type: :service do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "compile-net-#{SecureRandom.hex(4)}") }

  # Two NodeInstances under the same account so peers can attach. We
  # bypass full instance setup and just stub the minimum.
  let!(:node) { create(:system_node, account: account, name: "compile-node-#{SecureRandom.hex(4)}") }
  let!(:hub_instance)   { create(:system_node_instance, node: node, name: "hub-#{SecureRandom.hex(2)}") }
  let!(:spoke_instance) { create(:system_node_instance, node: node, name: "spoke-#{SecureRandom.hex(2)}") }

  describe "hub-and-spoke topology" do
    let!(:hub_peer) do
      Sdwan::PeerEnroller.call(
        network: network,
        node_instance: hub_instance,
        publicly_reachable: true,
        endpoint_host: "203.0.113.10",
        endpoint_port: 51820
      )
    end

    let!(:spoke_peer) do
      Sdwan::PeerEnroller.call(
        network: network,
        node_instance: spoke_instance,
        publicly_reachable: false
      )
    end

    it "emits a hub view that lists every other peer with its /128 AllowedIP" do
      view = described_class.compile_for_peer(hub_peer)
      expect(view[:peer_id]).to eq(hub_peer.id)
      expect(view[:peers].size).to eq(1)
      spoke_view = view[:peers].first
      expect(spoke_view[:public_key]).to eq(spoke_peer.active_key.public_key)
      expect(spoke_view[:allowed_ips]).to eq([ spoke_peer.assigned_address ])
    end

    it "emits a spoke view that lists only the hub with the full /64 in AllowedIPs" do
      view = described_class.compile_for_peer(spoke_peer)
      expect(view[:peers].size).to eq(1)
      hub_view = view[:peers].first
      expect(hub_view[:public_key]).to eq(hub_peer.active_key.public_key)
      expect(hub_view[:allowed_ips]).to eq([ network.cidr_64 ])
      expect(hub_view[:endpoint]).to eq("203.0.113.10:51820")
      expect(hub_view[:persistent_keepalive]).to eq(25)
    end

    it "omits private_key from the operator-facing topology endpoint" do
      view = described_class.compile_for_peer(hub_peer, include_private_key: false)
      expect(view[:interface]).not_to have_key(:private_key)
      expect(view[:interface]).to have_key(:public_key)
    end

    it "inlines the private key on the node-API path when include_private_key: true" do
      view = described_class.compile_for_peer(hub_peer, include_private_key: true)
      # private_key may be nil if Vault isn't running in the test env, but
      # the key MUST be present in the hash (i.e. the path was taken).
      expect(view[:interface]).to have_key(:private_key)
    end

    it "emits an empty peers list for a spoke when the network has no hub" do
      Sdwan::Peer.where(sdwan_network_id: network.id, publicly_reachable: true).destroy_all
      view = described_class.compile_for_peer(spoke_peer.reload)
      expect(view[:peers]).to be_empty
    end
  end

  describe "compile_for_network" do
    it "returns one view per peer in the network" do
      Sdwan::PeerEnroller.call(
        network: network, node_instance: hub_instance,
        publicly_reachable: true, endpoint_host: "203.0.113.10", endpoint_port: 51820
      )
      Sdwan::PeerEnroller.call(network: network, node_instance: spoke_instance)
      views = described_class.compile_for_network(network)
      expect(views.size).to eq(2)
    end
  end

  # K3s overlay (2026-05-19) — when the network has pod_subnet_prefix +
  # the spoke is a k3s host, the spoke's allowed_ips through the hub
  # include the pod CIDR so the spoke's kernel routes pod traffic
  # through the WireGuard tunnel rather than the host primary NIC.
  describe "spoke_view with k3s pod overlay" do
    let!(:hub_peer) do
      Sdwan::PeerEnroller.call(
        network: network, node_instance: hub_instance,
        publicly_reachable: true,
        endpoint_host: "203.0.113.10", endpoint_port: 51820
      )
    end
    let!(:spoke_peer) do
      Sdwan::PeerEnroller.call(network: network, node_instance: spoke_instance, publicly_reachable: false)
    end

    let!(:k3s_module) do
      ::System::NodeModule.find_or_create_by!(account: account, name: "k3s-agent") do |m|
        m.assign_attributes(variety: "subscription", enabled: true, priority: 100,
                            description: "k3s-agent test seed")
      end
    end

    it "includes pod_subnet_prefix in spoke allowed_ips when spoke is a k3s host" do
      network.update!(pod_subnet_prefix: "10.42.0.0/16")
      ::System::NodeModuleAssignment.find_or_create_by!(
        node: spoke_instance.node, node_module: k3s_module
      ) { |a| a.enabled = true }

      view = described_class.compile_for_peer(spoke_peer.reload)
      hub_view = view[:peers].first
      expect(hub_view[:allowed_ips]).to include("10.42.0.0/16")
    end

    it "omits pod_subnet_prefix from spoke allowed_ips when spoke is NOT a k3s host" do
      network.update!(pod_subnet_prefix: "10.42.0.0/16")
      # NOT attaching k3s-agent to spoke

      view = described_class.compile_for_peer(spoke_peer.reload)
      hub_view = view[:peers].first
      expect(hub_view[:allowed_ips]).not_to include("10.42.0.0/16")
    end

    it "omits pod_subnet_prefix from spoke allowed_ips when network has no pod_subnet_prefix" do
      # NOT setting network.pod_subnet_prefix
      ::System::NodeModuleAssignment.find_or_create_by!(
        node: spoke_instance.node, node_module: k3s_module
      ) { |a| a.enabled = true }

      view = described_class.compile_for_peer(spoke_peer.reload)
      hub_view = view[:peers].first
      expect(hub_view[:allowed_ips].none? { |p| p.to_s.start_with?("10.42.") }).to be true
    end
  end

  # Phase 3 — federated-prefix injection. The TopologyCompiler now
  # defaults its federation_resolver to Sdwan::FederationPrefixResolver,
  # so a reachable System::FederationPeer's remote_prefix_advertisement
  # enters the data plane: it appears in the per-peer `federation` block,
  # in the spoke→hub WG AllowedIPs, and (iBGP) in the BGP announcements.
  describe "federated-prefix injection" do
    before do
      System::FederationPeer.where(account_id: account.id).delete_all
    end

    let!(:hub_peer) do
      Sdwan::PeerEnroller.call(
        network: network, node_instance: hub_instance,
        publicly_reachable: true, endpoint_host: "203.0.113.10", endpoint_port: 51820
      )
    end
    let!(:spoke_peer) do
      Sdwan::PeerEnroller.call(network: network, node_instance: spoke_instance, publicly_reachable: false)
    end

    def create_fed_peer(prefix:, status: "active", peer_kind: "platform")
      attrs = {
        account: account, remote_prefix_advertisement: prefix,
        status: status, peer_kind: peer_kind,
        # remote_instance_url is a presence + http/https-format column on
        # System::FederationPeer; the helper must supply a valid one or
        # create! raises RecordInvalid before the compile is exercised.
        remote_instance_url: "https://#{SecureRandom.hex(4)}.fed.example.test"
      }
      attrs[:spawn_role] = "symmetric" if peer_kind == "platform"
      System::FederationPeer.create!(attrs)
    end

    it "populates the per-peer federation block with real resolved entries" do
      create_fed_peer(prefix: "fd12:3456:789a::/48")

      view = described_class.compile_for_peer(hub_peer)
      expect(view[:federation]).to be_an(Array)
      expect(view[:federation].size).to eq(1)
      expect(view[:federation].first[:prefix]).to eq("fd12:3456:789a::/48")
      expect(view[:federation].first[:status]).to eq("active")
    end

    it "folds the federated prefix into the spoke's hub-facing WG AllowedIPs" do
      create_fed_peer(prefix: "fd12:3456:789a::/48")

      view = described_class.compile_for_peer(spoke_peer.reload)
      hub_view = view[:peers].first
      expect(hub_view[:allowed_ips]).to include("fd12:3456:789a::/48")
      # The base /64 is still present — federation is additive.
      expect(hub_view[:allowed_ips]).to include(network.cidr_64)
    end

    it "does NOT add the federated prefix to the hub's view of the spoke" do
      create_fed_peer(prefix: "fd12:3456:789a::/48")

      view = described_class.compile_for_peer(hub_peer)
      spoke_view = view[:peers].first
      # The hub is the egress; the federated prefix must not route back
      # to the spoke (that would be a loop). Hub→spoke AllowedIPs stays
      # the spoke's own /128.
      expect(spoke_view[:allowed_ips]).not_to include("fd12:3456:789a::/48")
      expect(spoke_view[:allowed_ips]).to eq([ spoke_peer.assigned_address ])
    end

    it "yields an empty federation block and no extra AllowedIPs when no peers contribute" do
      view = described_class.compile_for_peer(spoke_peer.reload)
      expect(view[:federation]).to eq([])
      hub_view = view[:peers].first
      expect(hub_view[:allowed_ips]).to eq([ network.cidr_64 ])
    end

    it "ignores a proposed federation peer (not yet reachable)" do
      create_fed_peer(prefix: "fd00:dead::/48", status: "proposed")

      view = described_class.compile_for_peer(spoke_peer.reload)
      expect(view[:federation]).to eq([])
      expect(view[:peers].first[:allowed_ips]).not_to include("fd00:dead::/48")
    end

    it "accepts a custom injected resolver (operator/preview override) returning bare strings" do
      resolver = ->(_network) { [ "fd00:cafe::/48" ] }
      view = described_class.compile_for_peer(spoke_peer.reload, federation_resolver: resolver)
      # bare-string resolver: federation block carries the strings as-is,
      # and the prefix still folds into AllowedIPs.
      expect(view[:peers].first[:allowed_ips]).to include("fd00:cafe::/48")
    end

    context "on an iBGP network with a federated prefix" do
      let!(:account_bgp) do
        Sdwan::AccountBgp.find_or_create_by!(account_id: account.id) do |b|
          b.as_number = 4_290_000_000 + rand(1_000_000)
          b.router_id_strategy = "peer_overlay_ipv6_hash"
          b.enabled = true
        end
      end

      before do
        account_bgp.update!(enabled: true)
        network.update!(routing_protocol: "ibgp")
        # FRR renders a `router bgp ... vrf <name>` block only for hosts
        # with an active HostVrfAssignment for the network — allocate one
        # for the hub so the frr_text announce path is exercised.
        Sdwan::VrfAllocator.allocate!(host: hub_instance, network: network).tap(&:mark_active!)
      end

      it "announces the federated prefix from the route-reflector (hub) peer's BGP block" do
        create_fed_peer(prefix: "fd12:3456:789a::/48")

        view = described_class.compile_for_peer(hub_peer.reload)
        expect(view[:bgp][:enabled]).to be(true)
        expect(view[:bgp][:networks]).to include("fd12:3456:789a::/48")
        # The frr_text rendering must carry the announce as a `network`
        # statement so FRR actually originates it.
        expect(view[:bgp][:frr_text]).to include("network fd12:3456:789a::/48")
      end

      it "does NOT announce the federated prefix from a spoke (would loop the prefix)" do
        create_fed_peer(prefix: "fd12:3456:789a::/48")

        view = described_class.compile_for_peer(spoke_peer.reload)
        expect(view[:bgp][:networks]).not_to include("fd12:3456:789a::/48")
      end
    end
  end

  # Phase 3 — the served OVN Northbound plan. ovn_nb_plan_for serves the
  # compiled ls-add/lsp-add/acl-add plan (plus the nb_db_endpoint the
  # compiler can't know) to heavyweight hosts with an active deployment.
  # Mirrors the agent's OvnNbPlan wire struct, consumed by the on-host
  # ShellOvnNbApplier which previously received nothing.
  describe ".ovn_nb_plan_for" do
    let!(:heavy_instance) do
      inst = create(:system_node_instance, node: node, name: "heavy-#{SecureRandom.hex(2)}")
      inst.update!(network_profile: "heavyweight")
      inst
    end

    before do
      Sdwan::OvnLogicalSwitchPort.where(account_id: account.id).delete_all
      Sdwan::OvnAcl.where(account_id: account.id).delete_all
      Sdwan::OvnLogicalSwitch.where(account_id: account.id).delete_all
      Sdwan::OvnDeployment.where(account_id: account.id).delete_all
    end

    # OvnDeployment#mark_active only transitions from bootstrapping/degraded/
    # active — a freshly-created (pending) deployment must walk the real
    # lifecycle pending → bootstrapping → active before it can serve a plan.
    def activate_deployment!(deployment)
      deployment.start_bootstrap!
      deployment.mark_active!
      deployment
    end

    it "returns nil for a lightweight host even with an active deployment" do
      light = create(:system_node_instance, node: node, name: "light-#{SecureRandom.hex(2)}")
      activate_deployment!(Sdwan::OvnDeployment.create!(
        account: account, nb_db_endpoint: "tcp:10.0.0.1:6641",
        sb_db_endpoint: "tcp:10.0.0.1:6642"
      ))

      expect(described_class.ovn_nb_plan_for(light)).to be_nil
    end

    it "returns nil for a heavyweight host when the account has no active deployment" do
      # A pending (not active) deployment must not produce a plan.
      Sdwan::OvnDeployment.create!(account: account)
      expect(described_class.ovn_nb_plan_for(heavy_instance)).to be_nil
    end

    it "serves the compiled plan plus the nb_db_endpoint stamped from the deployment" do
      deployment = activate_deployment!(Sdwan::OvnDeployment.create!(
        account: account, nb_db_endpoint: "tcp:10.9.9.9:6641",
        sb_db_endpoint: "tcp:10.9.9.9:6642"
      ))

      switch = Sdwan::OvnLogicalSwitch.create!(
        account: account, sdwan_ovn_deployment_id: deployment.id, name: "ls-app"
      )
      switch.mark_active!
      port = Sdwan::OvnLogicalSwitchPort.create!(
        account: account, sdwan_ovn_logical_switch_id: switch.id,
        name: "vm-001", mac: "02:11:22:33:44:55", kind: "vm", addresses: [ "10.0.0.5" ]
      )
      port.mark_active!

      plan = described_class.ovn_nb_plan_for(heavy_instance)
      expect(plan[:deployment_id]).to eq(deployment.id)
      expect(plan[:nb_db_endpoint]).to eq("tcp:10.9.9.9:6641")
      expect(plan[:compiled_at]).to be_present
      # Real compiled entries — not a stub.
      expect(plan[:plan]).to include({ cmd: "ls-add", args: [ "ls-app" ] })
      expect(plan[:plan]).to include({ cmd: "lsp-add", args: [ "ls-app", "vm-001" ] })
      expect(plan[:plan]).to include(
        { cmd: "lsp-set-addresses", args: [ "vm-001", "02:11:22:33:44:55 10.0.0.5" ] }
      )
    end

    it "includes isolation ACL entries in the served plan" do
      deployment = activate_deployment!(Sdwan::OvnDeployment.create!(
        account: account, nb_db_endpoint: "tcp:10.9.9.9:6641",
        sb_db_endpoint: "tcp:10.9.9.9:6642"
      ))
      switch = Sdwan::OvnLogicalSwitch.create!(
        account: account, sdwan_ovn_deployment_id: deployment.id, name: "ls-iso"
      )
      switch.mark_active!
      acl = Sdwan::OvnAcl.create!(
        account: account, sdwan_ovn_logical_switch_id: switch.id,
        name: "deny-cross-tenant", direction: "to-lport", priority: 2000,
        match: %(outport == "vm-001" && ip4.src == 10.0.0.0/8), action: "drop"
      )
      acl.mark_active!

      plan = described_class.ovn_nb_plan_for(heavy_instance)
      acl_entry = plan[:plan].find { |e| e[:cmd] == "acl-add" }
      expect(acl_entry).to be_present
      expect(acl_entry[:args]).to eq(
        [ "ls-iso", "to-lport", "2000", %(outport == "vm-001" && ip4.src == 10.0.0.0/8), "drop" ]
      )
    end

    it "produces a byte-identical plan on repeated serves (idempotent)" do
      deployment = activate_deployment!(Sdwan::OvnDeployment.create!(
        account: account, nb_db_endpoint: "tcp:10.9.9.9:6641",
        sb_db_endpoint: "tcp:10.9.9.9:6642"
      ))
      switch = Sdwan::OvnLogicalSwitch.create!(
        account: account, sdwan_ovn_deployment_id: deployment.id, name: "ls-stable"
      )
      switch.mark_active!

      first  = described_class.ovn_nb_plan_for(heavy_instance)
      second = described_class.ovn_nb_plan_for(heavy_instance)
      expect(first[:plan]).to eq(second[:plan])
      expect(first[:nb_db_endpoint]).to eq(second[:nb_db_endpoint])
    end

    # Hot-path efficiency — ovn_nb_plan_for is served on EVERY heavyweight
    # host's node_api poll. The compiled plan is byte-stable for unchanged
    # DB state, so it is cached keyed on the deployment id plus a version
    # stamp (max updated_at across the deployment, its switches, ports, and
    # ACLs). The stamp changing on any of those writes invalidates the
    # cache naturally — no explicit purge.
    describe "compiled-plan caching" do
      around do |example|
        previous = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
        example.run
      ensure
        Rails.cache = previous
      end

      let!(:deployment) do
        activate_deployment!(Sdwan::OvnDeployment.create!(
          account: account, nb_db_endpoint: "tcp:10.7.7.7:6641",
          sb_db_endpoint: "tcp:10.7.7.7:6642"
        ))
      end

      let!(:switch) do
        sw = Sdwan::OvnLogicalSwitch.create!(
          account: account, sdwan_ovn_deployment_id: deployment.id, name: "ls-cache"
        )
        sw.mark_active!
        sw
      end

      it "compiles once and serves the cached plan on repeated polls" do
        expect(Sdwan::OvnCompiler).to receive(:compile_for_deployment).once.and_call_original

        first  = described_class.ovn_nb_plan_for(heavy_instance)
        second = described_class.ovn_nb_plan_for(heavy_instance)
        expect(second).to eq(first)
      end

      it "recompiles after a port is added (child write advances the stamp)" do
        described_class.ovn_nb_plan_for(heavy_instance)

        # Ports belong to a switch, not the deployment, and don't touch the
        # parent — the stamp must query the port table directly for this to
        # invalidate. mark_active! is itself a write that bumps updated_at.
        Sdwan::OvnLogicalSwitchPort.create!(
          account: account, sdwan_ovn_logical_switch_id: switch.id,
          name: "vm-new", mac: "02:aa:bb:cc:dd:ee", kind: "vm", addresses: [ "10.0.0.9" ]
        ).mark_active!

        expect(Sdwan::OvnCompiler).to receive(:compile_for_deployment).once.and_call_original
        plan = described_class.ovn_nb_plan_for(heavy_instance)
        expect(plan[:plan]).to include({ cmd: "lsp-add", args: [ "ls-cache", "vm-new" ] })
      end

      it "recompiles after an ACL is added (child write advances the stamp)" do
        described_class.ovn_nb_plan_for(heavy_instance)

        Sdwan::OvnAcl.create!(
          account: account, sdwan_ovn_logical_switch_id: switch.id,
          name: "deny-x", direction: "to-lport", priority: 1000,
          match: %(outport == "vm-x"), action: "drop"
        ).mark_active!

        expect(Sdwan::OvnCompiler).to receive(:compile_for_deployment).once.and_call_original
        described_class.ovn_nb_plan_for(heavy_instance)
      end

      it "recompiles after the deployment row itself is touched" do
        described_class.ovn_nb_plan_for(heavy_instance)

        deployment.update_column(:updated_at, 1.hour.from_now)

        expect(Sdwan::OvnCompiler).to receive(:compile_for_deployment).once.and_call_original
        described_class.ovn_nb_plan_for(heavy_instance)
      end
    end
  end

  # Hot-path efficiency — federation prefixes are resolved ONCE per compile
  # and the node_api serving path injects a per-network-memoizing resolver
  # so a host with N peers on the same network runs the account-scoped
  # FederationPrefixResolver query once instead of N times. At the compiler
  # contract level this is the guarantee that compile_for_peer invokes the
  # injected resolver exactly once and produces output identical to the
  # default resolver.
  describe "federation resolver invocation" do
    let!(:fed_peer) do
      Sdwan::PeerEnroller.call(
        network: network, node_instance: hub_instance,
        publicly_reachable: true, endpoint_host: "203.0.113.10", endpoint_port: 51820
      )
    end

    it "invokes the injected resolver exactly once per compile_for_peer" do
      calls = 0
      resolver = lambda do |_network|
        calls += 1
        []
      end

      described_class.compile_for_peer(fed_peer.reload, federation_resolver: resolver)
      expect(calls).to eq(1)
    end

    it "produces output identical to the default resolver when an equivalent is injected" do
      injected = ->(net) { Sdwan::FederationPrefixResolver.resolve(net) }

      default_view  = described_class.compile_for_peer(fed_peer.reload)
      injected_view = described_class.compile_for_peer(fed_peer.reload, federation_resolver: injected)

      expect(injected_view[:federation]).to eq(default_view[:federation])
      expect(injected_view[:peers]).to eq(default_view[:peers])
    end
  end
end
