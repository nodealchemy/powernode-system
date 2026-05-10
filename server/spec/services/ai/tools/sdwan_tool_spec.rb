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
        addresses: ["10.42.0.5"]
      )
      expect(r[:success]).to be true
      port = r[:data][:ovn_logical_switch_port]
      expect(port[:logical_switch_id]).to eq(switch.id)
      expect(port[:name]).to eq("vm-port-1")
      expect(port[:kind]).to eq("vm")
      expect(port[:host_node_instance_id]).to eq(host.id)
      expect(port[:addresses]).to eq(["10.42.0.5"])
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
        addresses: ["10.42.0.7"]
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
      expect(ls_add[:args]).to eq(["compiled-sw"])

      lsp_add = plan[:plan].find { |e| e[:cmd] == "lsp-add" }
      expect(lsp_add[:args]).to eq(["compiled-sw", "compiled-port"])
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
