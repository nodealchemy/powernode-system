# frozen_string_literal: true

require "rails_helper"

# Phase O6 — SdwanTool MCP surface.
#
# Mirrors system_fleet_tool_spec.rb's shape: invoke `.execute(params:)`
# directly and assert success_result/error_result content. Coverage here
# focuses on the 8 new Phase O6 actions that surface the O1 host-bridge,
# O3 OVN deployment + switches + ports + plan, and O5 IPFIX models so AI
# agents can compose with them.
RSpec.describe Ai::Tools::SdwanTool do
  let(:account) { create(:account) }
  let(:node)    { sdwan_test_node(account: account) }
  let(:tool)    { described_class.new(account: account) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  describe ".action_definitions" do
    it "registers all 8 Phase O6 actions" do
      keys = described_class.action_definitions.keys
      %w[
        system_sdwan_create_host_bridge
        system_sdwan_list_host_bridges
        system_sdwan_create_ovn_deployment
        system_sdwan_create_ovn_logical_switch
        system_sdwan_create_ovn_logical_switch_port
        system_sdwan_compile_ovn_plan
        system_sdwan_create_ipfix_collector
        system_sdwan_list_ipfix_collectors
      ].each do |action|
        expect(keys).to include(action), "expected #{action} in action_definitions"
      end
    end

    it "registers the federation peer mutation + residency + audit actions" do
      keys = described_class.action_definitions.keys
      %w[
        system_sdwan_update_federation_peer
        system_sdwan_set_data_residency
        system_sdwan_get_audit_log
      ].each do |action|
        expect(keys).to include(action), "expected #{action} in action_definitions"
      end
    end
  end

  # ─── D8: peer firewall tags ──────────────────────────────────────────

  describe "system_sdwan_set_peer_tags" do
    let(:network)  { Sdwan::Network.create!(account_id: account.id, name: "tag-#{SecureRandom.hex(4)}") }
    let(:instance) { create(:system_node_instance, node: node, name: "ti-#{SecureRandom.hex(3)}") }
    let!(:peer)    { Sdwan::PeerEnroller.call(network: network, node_instance: instance) }

    it "sets + normalizes (trim/dedup/drop-blank) the peer's tags" do
      r = call("system_sdwan_set_peer_tags", peer_id: peer.id, tags: [" database ", "edge", "database", ""])
      expect(r[:success]).to be true
      expect(r[:data][:tags]).to eq(%w[database edge])
      expect(peer.reload.tags).to eq(%w[database edge])
    end

    it "clears tags with an empty array" do
      peer.update!(tags: %w[old])
      r = call("system_sdwan_set_peer_tags", peer_id: peer.id, tags: [])
      expect(r[:success]).to be true
      expect(peer.reload.tags).to eq([])
    end

    it "is registered with the peers.manage permission" do
      expect(described_class::ACTION_PERMISSIONS.fetch("system_sdwan_set_peer_tags")).to eq("system.sdwan.peers.manage")
    end
  end

  # ─── Federation peer mutation + residency + audit ────────────────────

  describe "system_sdwan_update_federation_peer" do
    let!(:peer) { create(:system_federation_peer, account: account, status: "proposed") }

    it "updates mutable fields and serializes the peer" do
      r = call(
        "system_sdwan_update_federation_peer",
        federation_peer_id: peer.id,
        remote_instance_url: "https://renamed.example.com",
        metadata: { "note" => "updated" }
      )
      expect(r[:success]).to be true
      fp = r[:data][:federation_peer]
      expect(fp[:id]).to eq(peer.id)
      expect(fp[:remote_instance_url]).to eq("https://renamed.example.com")
      expect(peer.reload.metadata["note"]).to eq("updated")
    end

    it "allows an in-matrix status transition (proposed → accepted)" do
      r = call("system_sdwan_update_federation_peer", federation_peer_id: peer.id, status: "accepted")
      expect(r[:success]).to be true
      expect(r[:data][:federation_peer][:status]).to eq("accepted")
      expect(peer.reload.status).to eq("accepted")
    end

    it "rejects an out-of-matrix status transition (proposed → active)" do
      r = call("system_sdwan_update_federation_peer", federation_peer_id: peer.id, status: "active")
      expect(r[:success]).to be false
      expect(r[:error]).to match(/not permitted/)
      expect(peer.reload.status).to eq("proposed")
    end

    it "rejects a peer belonging to a different account" do
      other_peer = create(:system_federation_peer, account: create(:account))
      r = call("system_sdwan_update_federation_peer", federation_peer_id: other_peer.id, status: "accepted")
      expect(r[:success]).to be false
    end
  end

  describe "system_sdwan_set_data_residency" do
    let!(:peer) { create(:system_federation_peer, account: account) }

    it "sets the data_residency tag and surfaces it in the serializer" do
      r = call("system_sdwan_set_data_residency", federation_peer_id: peer.id, data_residency: "eu-west")
      expect(r[:success]).to be true
      expect(r[:data][:federation_peer][:data_residency]).to eq("eu-west")
      expect(peer.reload.data_residency).to eq("eu-west")
    end

    it "rejects a peer belonging to a different account" do
      other_peer = create(:system_federation_peer, account: create(:account))
      r = call("system_sdwan_set_data_residency", federation_peer_id: other_peer.id, data_residency: "eu-west")
      expect(r[:success]).to be false
    end
  end

  describe "system_sdwan_get_audit_log" do
    let!(:peer) { create(:system_federation_peer, account: account) }

    it "returns audit shipments (non-secret fields) and federation events for the peer" do
      shipment = ::System::FederationAuditShipment.create!(
        account: account,
        federation_peer: peer,
        period_start: 2.days.ago,
        period_end: 1.day.ago,
        event_count: 3,
        sha256: "a" * 64,
        sealed_path: "/worm/secret-path.jsonl",
        status: "sealed"
      )
      event = ::System::FleetEvent.create!(
        account: account,
        kind: "federation.peer.accepted",
        severity: "low",
        source: "federation_peer",
        payload: { "federation_peer_id" => peer.id }
      )

      r = call("system_sdwan_get_audit_log", federation_peer_id: peer.id)
      expect(r[:success]).to be true

      shipments = r[:data][:audit_shipments]
      expect(shipments.map { |s| s[:id] }).to include(shipment.id)
      shipment_row = shipments.find { |s| s[:id] == shipment.id }
      expect(shipment_row[:event_count]).to eq(3)
      expect(shipment_row[:status]).to eq("sealed")
      # Secret fields are not surfaced.
      expect(shipment_row).not_to have_key(:sealed_path)
      expect(shipment_row).not_to have_key(:error_message)

      expect(r[:data][:events].map { |e| e[:id] }).to include(event.id)
    end

    it "excludes events that don't reference this peer" do
      other_peer = create(:system_federation_peer, account: account)
      ::System::FleetEvent.create!(
        account: account,
        kind: "federation.peer.accepted",
        severity: "low",
        source: "federation_peer",
        payload: { "federation_peer_id" => other_peer.id }
      )

      r = call("system_sdwan_get_audit_log", federation_peer_id: peer.id)
      expect(r[:success]).to be true
      expect(r[:data][:events]).to be_empty
    end

    it "honors the limit param" do
      3.times do
        ::System::FleetEvent.create!(
          account: account,
          kind: "federation.peer.heartbeat",
          severity: "low",
          source: "federation_peer",
          payload: { "federation_peer_id" => peer.id }
        )
      end
      r = call("system_sdwan_get_audit_log", federation_peer_id: peer.id, limit: 2)
      expect(r[:success]).to be true
      expect(r[:data][:events].size).to eq(2)
    end

    it "rejects a peer belonging to a different account" do
      other_peer = create(:system_federation_peer, account: create(:account))
      r = call("system_sdwan_get_audit_log", federation_peer_id: other_peer.id)
      expect(r[:success]).to be false
    end
  end

  # ─── Phase O6 — host bridges (O1) ────────────────────────────────────

  describe "system_sdwan_create_host_bridge" do
    let(:host) { sdwan_test_node_instance(node: node) }

    it "allocates a HostBridge for the given host (lightweight host → linux kind)" do
      r = call("system_sdwan_create_host_bridge", node_instance_id: host.id)
      expect(r[:success]).to be true
      bridge = r[:data][:host_bridge]
      expect(bridge[:node_instance_id]).to eq(host.id)
      expect(bridge[:account_id]).to eq(account.id)
      expect(bridge[:short_id]).to eq(1)
      expect(bridge[:bridge_name]).to eq("pwnbr-1")
      expect(bridge[:kind]).to eq("linux")
      expect(bridge[:state]).to eq("pending")
    end

    it "honors an explicit kind override" do
      r = call("system_sdwan_create_host_bridge", node_instance_id: host.id, kind: "ovs")
      expect(r[:success]).to be true
      expect(r[:data][:host_bridge][:kind]).to eq("ovs")
    end

    it "is idempotent — repeated allocations return the same bridge for the same kind" do
      r1 = call("system_sdwan_create_host_bridge", node_instance_id: host.id)
      r2 = call("system_sdwan_create_host_bridge", node_instance_id: host.id)
      expect(r1[:data][:host_bridge][:id]).to eq(r2[:data][:host_bridge][:id])
    end

    it "rejects a host belonging to a different account" do
      other_account = create(:account)
      other_node = sdwan_test_node(account: other_account)
      other_host = sdwan_test_node_instance(node: other_node)
      r = call("system_sdwan_create_host_bridge", node_instance_id: other_host.id)
      expect(r[:success]).to be false
    end
  end

  describe "system_sdwan_list_host_bridges" do
    let(:host) { sdwan_test_node_instance(node: node) }

    it "lists bridges scoped to the current account" do
      created = call("system_sdwan_create_host_bridge", node_instance_id: host.id)
      expect(created[:success]).to be true
      created_id = created[:data][:host_bridge][:id]

      r = call("system_sdwan_list_host_bridges")
      expect(r[:success]).to be true
      ids = r[:data][:host_bridges].map { |b| b[:id] }
      expect(ids).to include(created_id)
      expect(r[:data][:count]).to be >= 1
    end

    it "filters by node_instance_id when provided" do
      host_a = sdwan_test_node_instance(node: node, name: "host-a")
      host_b = sdwan_test_node_instance(node: node, name: "host-b")
      call("system_sdwan_create_host_bridge", node_instance_id: host_a.id)
      call("system_sdwan_create_host_bridge", node_instance_id: host_b.id)

      r = call("system_sdwan_list_host_bridges", node_instance_id: host_a.id)
      expect(r[:success]).to be true
      ids = r[:data][:host_bridges].map { |b| b[:node_instance_id] }
      expect(ids).to all(eq(host_a.id))
    end

    it "excludes bridges from other accounts" do
      other_account = create(:account)
      other_node = sdwan_test_node(account: other_account)
      other_host = sdwan_test_node_instance(node: other_node)
      ::Sdwan::HostBridgeAllocator.allocate!(host: other_host, account: other_account)

      r = call("system_sdwan_list_host_bridges")
      account_ids = r[:data][:host_bridges].map { |b| b[:account_id] }.uniq
      expect(account_ids).not_to include(other_account.id)
    end
  end

  # ─── Phase O6 — OVN deployment + switches + ports + plan (O3) ────────

  describe "system_sdwan_create_ovn_deployment" do
    it "creates an OvnDeployment with required endpoints" do
      r = call(
        "system_sdwan_create_ovn_deployment",
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642",
        northd_host: "northd-host-1"
      )
      expect(r[:success]).to be true
      deployment = r[:data][:ovn_deployment]
      expect(deployment[:account_id]).to eq(account.id)
      expect(deployment[:nb_db_endpoint]).to eq("tcp:nb.example:6641")
      expect(deployment[:sb_db_endpoint]).to eq("tcp:sb.example:6642")
      expect(deployment[:northd_host]).to eq("northd-host-1")
      expect(deployment[:status]).to eq("pending")
    end

    it "rejects a malformed endpoint" do
      r = call(
        "system_sdwan_create_ovn_deployment",
        nb_db_endpoint: "not-a-real-endpoint",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
      expect(r[:success]).to be false
      expect(r[:error]).to match(/nb db endpoint|invalid/i)
    end

    it "is per-account unique — second create surfaces a validation error" do
      call(
        "system_sdwan_create_ovn_deployment",
        nb_db_endpoint: "tcp:nb1.example:6641",
        sb_db_endpoint: "tcp:sb1.example:6642"
      )
      r2 = call(
        "system_sdwan_create_ovn_deployment",
        nb_db_endpoint: "tcp:nb2.example:6641",
        sb_db_endpoint: "tcp:sb2.example:6642"
      )
      expect(r2[:success]).to be false
    end
  end

  describe "system_sdwan_create_ovn_logical_switch" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end

    it "creates a logical switch under the deployment" do
      r = call(
        "system_sdwan_create_ovn_logical_switch",
        deployment_id: deployment.id,
        name: "tenant-switch",
        cidr: "10.42.0.0/24",
        description: "Phase O6 smoke switch"
      )
      expect(r[:success]).to be true
      switch = r[:data][:ovn_logical_switch]
      expect(switch[:deployment_id]).to eq(deployment.id)
      expect(switch[:name]).to eq("tenant-switch")
      expect(switch[:cidr]).to eq("10.42.0.0/24")
      expect(switch[:state]).to eq("pending")
    end

    it "rejects an invalid name" do
      r = call(
        "system_sdwan_create_ovn_logical_switch",
        deployment_id: deployment.id,
        name: "has spaces and ! chars"
      )
      expect(r[:success]).to be false
    end

    it "rejects a deployment from another account" do
      other_account = create(:account)
      other_deployment = ::Sdwan::OvnDeployment.create!(
        account: other_account,
        nb_db_endpoint: "tcp:nb.other:6641",
        sb_db_endpoint: "tcp:sb.other:6642"
      )
      r = call(
        "system_sdwan_create_ovn_logical_switch",
        deployment_id: other_deployment.id,
        name: "leakage"
      )
      expect(r[:success]).to be false
    end
  end

  describe "system_sdwan_create_ovn_logical_switch_port" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end
    let!(:switch) do
      deployment.logical_switches.create!(account: account, name: "lsw-1")
    end
    let(:host) { sdwan_test_node_instance(node: node) }

    it "creates a vm-kind port with auto-generated MAC" do
      r = call(
        "system_sdwan_create_ovn_logical_switch_port",
        logical_switch_id: switch.id,
        name: "vm-port-1",
        kind: "vm",
        host_node_instance_id: host.id,
        addresses: [ "10.42.0.5" ]
      )
      expect(r[:success]).to be true
      port = r[:data][:ovn_logical_switch_port]
      expect(port[:logical_switch_id]).to eq(switch.id)
      expect(port[:name]).to eq("vm-port-1")
      expect(port[:kind]).to eq("vm")
      expect(port[:host_node_instance_id]).to eq(host.id)
      expect(port[:addresses]).to eq([ "10.42.0.5" ])
      # Auto-gen MAC starts with the locally-administered `02:` prefix.
      expect(port[:mac]).to match(/\A02:[0-9a-f]{2}(:[0-9a-f]{2}){4}\z/)
    end

    it "respects an explicit MAC override" do
      r = call(
        "system_sdwan_create_ovn_logical_switch_port",
        logical_switch_id: switch.id,
        name: "vm-port-2",
        kind: "vm",
        host_node_instance_id: host.id,
        mac: "02:aa:bb:cc:dd:ee"
      )
      expect(r[:success]).to be true
      expect(r[:data][:ovn_logical_switch_port][:mac]).to eq("02:aa:bb:cc:dd:ee")
    end

    it "creates an external port without a host" do
      r = call(
        "system_sdwan_create_ovn_logical_switch_port",
        logical_switch_id: switch.id,
        name: "uplink-1",
        kind: "external"
      )
      expect(r[:success]).to be true
      expect(r[:data][:ovn_logical_switch_port][:kind]).to eq("external")
      expect(r[:data][:ovn_logical_switch_port][:host_node_instance_id]).to be_nil
    end

    it "rejects an invalid kind via model validation" do
      r = call(
        "system_sdwan_create_ovn_logical_switch_port",
        logical_switch_id: switch.id,
        name: "bad-kind",
        kind: "router"
      )
      expect(r[:success]).to be false
    end
  end

  # IMP-b0292ddd5ee9 — create_ovn_logical_switch / create_ovn_logical_switch_port
  # land rows in `pending` (matching create_host_bridge's design) but, unlike
  # host bridges, had no activation path via MCP: no tool ever called
  # switch.mark_active!/port.mark_active!, so the documented create -> compile
  # sequence silently produced an empty plan with zero errors.
  describe "the documented create -> compile sequence" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end

    it "materializes the plan once the switch and port are activated via the tool" do
      switch_r = call(
        "system_sdwan_create_ovn_logical_switch",
        deployment_id: deployment.id,
        name: "trap-switch"
      )
      switch_id = switch_r[:data][:ovn_logical_switch][:id]

      port_r = call(
        "system_sdwan_create_ovn_logical_switch_port",
        logical_switch_id: switch_id,
        name: "trap-port",
        kind: "external"
      )
      port_id = port_r[:data][:ovn_logical_switch_port][:id]

      # Before activation: the trap. Zero errors, but nothing compiles.
      empty_plan = call("system_sdwan_compile_ovn_plan", deployment_id: deployment.id)
      expect(empty_plan[:success]).to be true
      expect(empty_plan[:data][:plan][:plan]).to eq([])

      switch_activation = call("system_sdwan_activate_ovn_logical_switch", logical_switch_id: switch_id)
      expect(switch_activation[:success]).to be true
      expect(switch_activation[:data][:ovn_logical_switch][:state]).to eq("active")

      port_activation = call("system_sdwan_activate_ovn_logical_switch_port", port_id: port_id)
      expect(port_activation[:success]).to be true
      expect(port_activation[:data][:ovn_logical_switch_port][:state]).to eq("active")

      plan = call("system_sdwan_compile_ovn_plan", deployment_id: deployment.id)
      cmds = plan[:data][:plan][:plan].map { |e| e[:cmd] }
      expect(cmds).to include("ls-add", "lsp-add")
    end
  end

  describe "system_sdwan_activate_ovn_logical_switch" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end
    let!(:switch) { deployment.logical_switches.create!(account: account, name: "activate-me") }

    it "marks a pending switch active" do
      expect(switch.state).to eq("pending")
      r = call("system_sdwan_activate_ovn_logical_switch", logical_switch_id: switch.id)
      expect(r[:success]).to be true
      expect(r[:data][:ovn_logical_switch][:state]).to eq("active")
      expect(switch.reload.state).to eq("active")
    end

    it "rejects a switch from another account" do
      other_account = create(:account)
      other_deployment = ::Sdwan::OvnDeployment.create!(
        account: other_account,
        nb_db_endpoint: "tcp:nb.other:6641",
        sb_db_endpoint: "tcp:sb.other:6642"
      )
      other_switch = other_deployment.logical_switches.create!(account: other_account, name: "not-mine")
      r = call("system_sdwan_activate_ovn_logical_switch", logical_switch_id: other_switch.id)
      expect(r[:success]).to be false
    end

    it "reports an error instead of silently no-op'ing on a removed switch" do
      switch.mark_removed!
      r = call("system_sdwan_activate_ovn_logical_switch", logical_switch_id: switch.id)
      expect(r[:success]).to be false
      expect(switch.reload.state).to eq("removed")
    end
  end

  describe "system_sdwan_activate_ovn_logical_switch_port" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end
    let!(:switch) { deployment.logical_switches.create!(account: account, name: "port-parent") }
    let!(:port) do
      switch.ports.create!(account: account, name: "activate-me", kind: "external")
    end

    it "marks a pending port active" do
      expect(port.state).to eq("pending")
      r = call("system_sdwan_activate_ovn_logical_switch_port", port_id: port.id)
      expect(r[:success]).to be true
      expect(r[:data][:ovn_logical_switch_port][:state]).to eq("active")
      expect(port.reload.state).to eq("active")
    end

    it "rejects a port from another account" do
      other_account = create(:account)
      other_deployment = ::Sdwan::OvnDeployment.create!(
        account: other_account,
        nb_db_endpoint: "tcp:nb.other:6641",
        sb_db_endpoint: "tcp:sb.other:6642"
      )
      other_switch = other_deployment.logical_switches.create!(account: other_account, name: "not-mine")
      other_port = other_switch.ports.create!(account: other_account, name: "not-mine", kind: "external")
      r = call("system_sdwan_activate_ovn_logical_switch_port", port_id: other_port.id)
      expect(r[:success]).to be false
    end

    it "reports an error instead of silently no-op'ing on a removed port" do
      port.mark_removed!
      r = call("system_sdwan_activate_ovn_logical_switch_port", port_id: port.id)
      expect(r[:success]).to be false
      expect(port.reload.state).to eq("removed")
    end
  end

  describe "system_sdwan_compile_ovn_plan" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end
    let!(:switch) do
      sw = deployment.logical_switches.create!(account: account, name: "compiled-sw")
      sw.mark_active!
      sw
    end
    let!(:port) do
      p = switch.ports.create!(
        account: account,
        name: "compiled-port",
        kind: "vm",
        addresses: [ "10.42.0.7" ]
      )
      p.mark_active!
      p
    end

    it "returns the structured ovn-nbctl command plan" do
      r = call("system_sdwan_compile_ovn_plan", deployment_id: deployment.id)
      expect(r[:success]).to be true
      plan = r[:data][:plan]
      expect(plan[:deployment_id]).to eq(deployment.id)
      expect(plan[:plan]).to be_an(Array)
      expect(plan[:compiled_at]).to be_present

      cmds = plan[:plan].map { |e| e[:cmd] }
      expect(cmds).to include("ls-add", "lsp-add", "lsp-set-addresses")

      ls_add = plan[:plan].find { |e| e[:cmd] == "ls-add" }
      expect(ls_add[:args]).to eq([ "compiled-sw" ])

      lsp_add = plan[:plan].find { |e| e[:cmd] == "lsp-add" }
      expect(lsp_add[:args]).to eq([ "compiled-sw", "compiled-port" ])
    end

    it "rejects a deployment from another account" do
      other_account = create(:account)
      other_deployment = ::Sdwan::OvnDeployment.create!(
        account: other_account,
        nb_db_endpoint: "tcp:nb.other:6641",
        sb_db_endpoint: "tcp:sb.other:6642"
      )
      r = call("system_sdwan_compile_ovn_plan", deployment_id: other_deployment.id)
      expect(r[:success]).to be false
    end
  end

  # ─── Audit F8-06 — OVN read/prune symmetry ──────────────────────────
  # create/delete existed for deployments + switches, and create-only for
  # ports, with no way to REDISCOVER a deployment id after a session
  # restart or PRUNE a single port. These four close the gaps.
  describe "OVN read + port-prune symmetry (F8-06)" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end
    let!(:switch) { deployment.logical_switches.create!(account: account, name: "sw-1") }
    let!(:port) do
      switch.ports.create!(account: account, name: "port-1", kind: "vm", addresses: [ "10.42.0.7" ])
    end

    describe "system_sdwan_list_ovn_deployments" do
      it "lists the account's deployments for rediscovery" do
        r = call("system_sdwan_list_ovn_deployments")
        expect(r[:success]).to be true
        expect(r[:data][:ovn_deployments].map { |d| d[:id] }).to include(deployment.id)
      end

      it "does not leak other accounts' deployments" do
        other = create(:account)
        ::Sdwan::OvnDeployment.create!(account: other, nb_db_endpoint: "tcp:nb.o:6641", sb_db_endpoint: "tcp:sb.o:6642")
        r = call("system_sdwan_list_ovn_deployments")
        expect(r[:data][:ovn_deployments].map { |d| d[:account_id] }.uniq).to eq([ account.id ])
      end
    end

    describe "system_sdwan_get_ovn_deployment" do
      it "returns the deployment with its logical switches" do
        r = call("system_sdwan_get_ovn_deployment", deployment_id: deployment.id)
        expect(r[:success]).to be true
        expect(r[:data][:ovn_deployment][:id]).to eq(deployment.id)
        expect(r[:data][:ovn_deployment][:logical_switches].map { |s| s[:id] }).to include(switch.id)
      end

      it "rejects a deployment from another account" do
        other = create(:account)
        foreign = ::Sdwan::OvnDeployment.create!(account: other, nb_db_endpoint: "tcp:nb.o:6641", sb_db_endpoint: "tcp:sb.o:6642")
        r = call("system_sdwan_get_ovn_deployment", deployment_id: foreign.id)
        expect(r[:success]).to be false
      end
    end

    describe "system_sdwan_list_ovn_logical_switches" do
      it "lists switches and surfaces their ports so port ids are discoverable" do
        r = call("system_sdwan_list_ovn_logical_switches")
        expect(r[:success]).to be true
        sw = r[:data][:ovn_logical_switches].find { |s| s[:id] == switch.id }
        expect(sw).to be_present
        expect(sw[:ports].map { |p| p[:id] }).to include(port.id)
      end

      it "filters by deployment_id" do
        # OvnDeployment is one-per-account, so exercise the filter with a
        # second switch under the same deployment + a non-matching id.
        switch2 = deployment.logical_switches.create!(account: account, name: "sw-2")

        matched = call("system_sdwan_list_ovn_logical_switches", deployment_id: deployment.id)
        expect(matched[:data][:ovn_logical_switches].map { |s| s[:id] }).to contain_exactly(switch.id, switch2.id)

        none = call("system_sdwan_list_ovn_logical_switches", deployment_id: SecureRandom.uuid)
        expect(none[:data][:ovn_logical_switches]).to be_empty
      end
    end

    describe "system_sdwan_delete_ovn_logical_switch_port" do
      it "prunes a single port without touching the switch" do
        r = call("system_sdwan_delete_ovn_logical_switch_port", port_id: port.id)
        expect(r[:success]).to be true
        expect(r[:data][:deleted]).to be true
        expect(Sdwan::OvnLogicalSwitchPort.exists?(port.id)).to be false
        expect(Sdwan::OvnLogicalSwitch.exists?(switch.id)).to be true
      end

      it "rejects a port from another account" do
        other = create(:account)
        od = ::Sdwan::OvnDeployment.create!(account: other, nb_db_endpoint: "tcp:nb.o:6641", sb_db_endpoint: "tcp:sb.o:6642")
        os = od.logical_switches.create!(account: other, name: "sw-o")
        op = os.ports.create!(account: other, name: "port-o", kind: "vm", addresses: [ "10.9.0.1" ])
        r = call("system_sdwan_delete_ovn_logical_switch_port", port_id: op.id)
        expect(r[:success]).to be false
        expect(Sdwan::OvnLogicalSwitchPort.exists?(op.id)).to be true
      end
    end

    describe "system_sdwan_delete_ovn_deployment" do
      it "destroys the deployment without raising (model has no name column)" do
        r = call("system_sdwan_delete_ovn_deployment", deployment_id: deployment.id)
        expect(r[:success]).to be true
        expect(r[:data][:deleted]).to be true
        expect(Sdwan::OvnDeployment.exists?(deployment.id)).to be false
      end

      it "rejects a deployment from another account" do
        other = create(:account)
        foreign = ::Sdwan::OvnDeployment.create!(account: other, nb_db_endpoint: "tcp:nb.o:6641", sb_db_endpoint: "tcp:sb.o:6642")
        r = call("system_sdwan_delete_ovn_deployment", deployment_id: foreign.id)
        expect(r[:success]).to be false
        expect(Sdwan::OvnDeployment.exists?(foreign.id)).to be true
      end
    end

    describe "permission + registration" do
      it "maps read actions to system.sdwan.ovn.read and delete to system.sdwan.ovn.manage" do
        expect(described_class::ACTION_PERMISSIONS.fetch("system_sdwan_list_ovn_deployments")).to eq("system.sdwan.ovn.read")
        expect(described_class::ACTION_PERMISSIONS.fetch("system_sdwan_get_ovn_deployment")).to eq("system.sdwan.ovn.read")
        expect(described_class::ACTION_PERMISSIONS.fetch("system_sdwan_list_ovn_logical_switches")).to eq("system.sdwan.ovn.read")
        expect(described_class::ACTION_PERMISSIONS.fetch("system_sdwan_delete_ovn_logical_switch_port")).to eq("system.sdwan.ovn.manage")
      end

      it "documents all four in action_definitions" do
        defs = described_class.action_definitions
        %w[system_sdwan_list_ovn_deployments system_sdwan_get_ovn_deployment
           system_sdwan_list_ovn_logical_switches system_sdwan_delete_ovn_logical_switch_port].each do |a|
          expect(defs).to have_key(a)
        end
      end
    end
  end

  # ─── Phase O6 — IPFIX collectors (O5) ────────────────────────────────

  describe "system_sdwan_create_ipfix_collector" do
    it "creates an IPFIX collector with defaults" do
      r = call(
        "system_sdwan_create_ipfix_collector",
        name: "primary",
        host: "10.0.0.50"
      )
      expect(r[:success]).to be true
      collector = r[:data][:ipfix_collector]
      expect(collector[:name]).to eq("primary")
      expect(collector[:host]).to eq("10.0.0.50")
      expect(collector[:port]).to eq(4739)
      expect(collector[:sampling_rate]).to eq(1)
      expect(collector[:state]).to eq("active")
      expect(collector[:target_endpoint]).to eq("10.0.0.50:4739")
    end

    it "honors explicit port and sampling_rate" do
      r = call(
        "system_sdwan_create_ipfix_collector",
        name: "high-rate",
        host: "10.0.0.51",
        port: 9995,
        sampling_rate: 100
      )
      expect(r[:success]).to be true
      expect(r[:data][:ipfix_collector][:port]).to eq(9995)
      expect(r[:data][:ipfix_collector][:sampling_rate]).to eq(100)
      expect(r[:data][:ipfix_collector][:target_endpoint]).to eq("10.0.0.51:9995")
    end

    it "brackets IPv6 host literals in target_endpoint" do
      r = call(
        "system_sdwan_create_ipfix_collector",
        name: "v6-collector",
        host: "fd00::1"
      )
      expect(r[:success]).to be true
      expect(r[:data][:ipfix_collector][:target_endpoint]).to eq("[fd00::1]:4739")
    end

    it "rejects duplicate names within the same account" do
      call("system_sdwan_create_ipfix_collector", name: "dup", host: "10.0.0.52")
      r = call("system_sdwan_create_ipfix_collector", name: "dup", host: "10.0.0.53")
      expect(r[:success]).to be false
    end
  end

  describe "system_sdwan_list_ipfix_collectors" do
    it "lists collectors scoped to the current account" do
      call("system_sdwan_create_ipfix_collector", name: "list-1", host: "10.0.0.60")
      call("system_sdwan_create_ipfix_collector", name: "list-2", host: "10.0.0.61")

      r = call("system_sdwan_list_ipfix_collectors")
      expect(r[:success]).to be true
      names = r[:data][:ipfix_collectors].map { |c| c[:name] }
      expect(names).to include("list-1", "list-2")
      expect(r[:data][:count]).to be >= 2
    end

    it "excludes collectors from other accounts" do
      other_account = create(:account)
      ::Sdwan::IpfixCollector.create!(
        account: other_account, name: "other-acct", host: "10.0.0.70"
      )

      r = call("system_sdwan_list_ipfix_collectors")
      account_ids = r[:data][:ipfix_collectors].map { |c| c[:account_id] }.uniq
      expect(account_ids).not_to include(other_account.id)
    end
  end

  # ─── Registry wiring ─────────────────────────────────────────────────

  describe "PlatformApiToolRegistry registration" do
    it "wires every Phase O6 action to SdwanTool" do
      registry = ::Ai::Tools::PlatformApiToolRegistry::TOOLS
      %w[
        system_sdwan_create_host_bridge
        system_sdwan_list_host_bridges
        system_sdwan_create_ovn_deployment
        system_sdwan_create_ovn_logical_switch
        system_sdwan_create_ovn_logical_switch_port
        system_sdwan_compile_ovn_plan
        system_sdwan_create_ipfix_collector
        system_sdwan_list_ipfix_collectors
      ].each do |action|
        expect(registry[action]).to eq("Ai::Tools::SdwanTool"), "expected #{action} → SdwanTool"
      end
    end
  end
end
