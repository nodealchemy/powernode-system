# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::OvnCompiler, type: :service do
  let(:account) { Account.first || create(:account) }
  let(:deployment) do
    Sdwan::OvnDeployment.create!(
      account: account,
      nb_db_endpoint: "tcp:10.0.0.1:6641",
      sb_db_endpoint: "tcp:10.0.0.1:6642"
    )
  end

  before do
    Sdwan::OvnLogicalSwitchPort.where(account_id: account.id).delete_all
    Sdwan::OvnLogicalSwitch.where(account_id: account.id).delete_all
    Sdwan::OvnDeployment.where(account_id: account.id).delete_all
  end

  def make_switch(name:, state: "active")
    s = Sdwan::OvnLogicalSwitch.create!(
      account: account,
      sdwan_ovn_deployment_id: deployment.id,
      name: name
    )
    s.mark_active! if state == "active"
    s.mark_removed! if state == "removed"
    s
  end

  def make_port(switch:, name:, mac: "02:11:22:33:44:55", addresses: [],
                kind: "vm", state: "active", settings: {})
    p = Sdwan::OvnLogicalSwitchPort.create!(
      account: account,
      sdwan_ovn_logical_switch_id: switch.id,
      name: name,
      mac: mac,
      kind: kind,
      addresses: addresses,
      settings: settings
    )
    p.mark_active! if state == "active"
    p.mark_removed! if state == "removed"
    p
  end

  describe ".compile_for_deployment" do
    it "returns deployment_id, plan, compiled_at" do
      result = described_class.compile_for_deployment(deployment)
      expect(result.keys).to contain_exactly(:deployment_id, :plan, :compiled_at)
      expect(result[:deployment_id]).to eq(deployment.id)
      expect(result[:plan]).to eq([])
      expect(result[:compiled_at]).to match(/\AT?\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe "ls-add emission" do
    it "emits one ls-add per active switch" do
      make_switch(name: "ls-a")
      make_switch(name: "ls-b")
      plan = described_class.compile_for_deployment(deployment)[:plan]

      ls_adds = plan.select { |e| e[:cmd] == "ls-add" }
      expect(ls_adds.size).to eq(2)
      expect(ls_adds.map { |e| e[:args].first }).to contain_exactly("ls-a", "ls-b")
    end

    it "skips pending switches" do
      make_switch(name: "ls-pending", state: "pending")
      make_switch(name: "ls-active",  state: "active")
      plan = described_class.compile_for_deployment(deployment)[:plan]
      ls_adds = plan.select { |e| e[:cmd] == "ls-add" }
      expect(ls_adds.map { |e| e[:args].first }).to contain_exactly("ls-active")
    end

    it "skips removed switches" do
      ls = make_switch(name: "to-remove")
      ls.mark_removed!
      plan = described_class.compile_for_deployment(deployment)[:plan]
      expect(plan).to be_empty
    end

    it "orders switches alphabetically by name" do
      make_switch(name: "ls-zulu")
      make_switch(name: "ls-alpha")
      make_switch(name: "ls-mike")
      plan = described_class.compile_for_deployment(deployment)[:plan]
      ls_adds = plan.select { |e| e[:cmd] == "ls-add" }
      expect(ls_adds.map { |e| e[:args].first }).to eq(%w[ls-alpha ls-mike ls-zulu])
    end
  end

  describe "lsp-add and lsp-set-addresses emission" do
    it "emits lsp-add + lsp-set-addresses for each active port" do
      ls = make_switch(name: "ls1")
      make_port(switch: ls, name: "vm-001",
                mac: "02:11:22:33:44:55", addresses: ["10.0.0.5"])

      plan = described_class.compile_for_deployment(deployment)[:plan]
      expect(plan).to include({ cmd: "lsp-add",
                                args: ["ls1", "vm-001"] })
      expect(plan).to include({ cmd: "lsp-set-addresses",
                                args: ["vm-001", "02:11:22:33:44:55 10.0.0.5"] })
    end

    it "emits MAC-only addresses string when port has no IPs" do
      ls = make_switch(name: "ls1")
      make_port(switch: ls, name: "p-no-ip",
                mac: "02:aa:bb:cc:dd:ee", addresses: [])

      plan = described_class.compile_for_deployment(deployment)[:plan]
      expect(plan).to include({ cmd: "lsp-set-addresses",
                                args: ["p-no-ip", "02:aa:bb:cc:dd:ee"] })
    end

    it "joins multiple v4+v6 addresses with spaces" do
      ls = make_switch(name: "ls1")
      make_port(switch: ls, name: "dual",
                mac: "02:11:22:33:44:55",
                addresses: ["10.0.0.5", "fd00::5"])

      plan = described_class.compile_for_deployment(deployment)[:plan]
      addrs = plan.find { |e| e[:cmd] == "lsp-set-addresses" }
      expect(addrs[:args]).to eq(["dual", "02:11:22:33:44:55 10.0.0.5 fd00::5"])
    end

    it "skips pending ports" do
      ls = make_switch(name: "ls1")
      make_port(switch: ls, name: "pending-port", state: "pending")
      plan = described_class.compile_for_deployment(deployment)[:plan]
      expect(plan.select { |e| e[:cmd] == "lsp-add" }).to be_empty
    end

    it "skips removed ports" do
      ls = make_switch(name: "ls1")
      make_port(switch: ls, name: "removed-port", state: "removed")
      plan = described_class.compile_for_deployment(deployment)[:plan]
      expect(plan.select { |e| e[:cmd] == "lsp-add" }).to be_empty
    end

    it "orders ports within a switch alphabetically by name" do
      ls = make_switch(name: "ls1")
      make_port(switch: ls, name: "zulu-port")
      make_port(switch: ls, name: "alpha-port")
      make_port(switch: ls, name: "mike-port")

      plan = described_class.compile_for_deployment(deployment)[:plan]
      port_names = plan.select { |e| e[:cmd] == "lsp-add" }.map { |e| e[:args].last }
      expect(port_names).to eq(%w[alpha-port mike-port zulu-port])
    end
  end

  describe "external port emission" do
    it "emits lsp-set-type localnet for external ports by default" do
      ls = make_switch(name: "ls1")
      make_port(switch: ls, name: "uplink", kind: "external",
                mac: "02:00:00:00:00:01", addresses: [])

      plan = described_class.compile_for_deployment(deployment)[:plan]
      expect(plan).to include({ cmd: "lsp-set-type",
                                args: ["uplink", "localnet"] })
    end

    it "honors per-port settings.ovn_type override" do
      ls = make_switch(name: "ls1")
      make_port(switch: ls, name: "rport", kind: "external",
                mac: "02:00:00:00:00:01",
                settings: { "ovn_type" => "router" })

      plan = described_class.compile_for_deployment(deployment)[:plan]
      expect(plan).to include({ cmd: "lsp-set-type", args: ["rport", "router"] })
    end

    it "does NOT emit lsp-set-type for vm or container ports" do
      ls = make_switch(name: "ls1")
      make_port(switch: ls, name: "vm-port",  kind: "vm")
      make_port(switch: ls, name: "ctr-port", kind: "container")

      plan = described_class.compile_for_deployment(deployment)[:plan]
      types = plan.select { |e| e[:cmd] == "lsp-set-type" }
      expect(types).to be_empty
    end
  end

  describe "dependency ordering" do
    it "emits all ls-add entries before any lsp-add entries for those switches" do
      ls_a = make_switch(name: "ls-a")
      ls_b = make_switch(name: "ls-b")
      make_port(switch: ls_a, name: "p-a-1")
      make_port(switch: ls_b, name: "p-b-1")

      plan = described_class.compile_for_deployment(deployment)[:plan]
      cmds = plan.map { |e| e[:cmd] }

      first_lsp_add_idx = cmds.index("lsp-add")
      last_ls_add_idx   = cmds.rindex("ls-add")
      expect(last_ls_add_idx).to be < first_lsp_add_idx
    end

    it "emits a switch's ports immediately after the switch (within the per-switch group)" do
      ls_a = make_switch(name: "ls-a")
      ls_b = make_switch(name: "ls-b")
      make_port(switch: ls_a, name: "p-a-1")
      make_port(switch: ls_b, name: "p-b-1")

      plan = described_class.compile_for_deployment(deployment)[:plan]
      # Phase 1 emits ls-add for both switches (alphabetical), then phase
      # 2 emits the per-switch port blocks in the same order.
      expected_sequence = [
        { cmd: "ls-add", args: ["ls-a"] },
        { cmd: "ls-add", args: ["ls-b"] },
        { cmd: "lsp-add", args: ["ls-a", "p-a-1"] },
        { cmd: "lsp-set-addresses", args: ["p-a-1", "02:11:22:33:44:55"] },
        { cmd: "lsp-add", args: ["ls-b", "p-b-1"] },
        { cmd: "lsp-set-addresses", args: ["p-b-1", "02:11:22:33:44:55"] }
      ]
      expect(plan).to eq(expected_sequence)
    end
  end

  describe "idempotency" do
    it "produces a byte-identical plan on repeated compiles of the same DB state" do
      ls1 = make_switch(name: "ls-x")
      ls2 = make_switch(name: "ls-y")
      make_port(switch: ls1, name: "vm-002", mac: "02:aa:aa:aa:aa:01", addresses: ["10.0.0.2"])
      make_port(switch: ls1, name: "vm-001", mac: "02:aa:aa:aa:aa:02", addresses: ["10.0.0.1"])
      make_port(switch: ls2, name: "uplink", kind: "external", mac: "02:bb:bb:bb:bb:01")

      first  = described_class.compile_for_deployment(deployment)[:plan]
      second = described_class.compile_for_deployment(deployment)[:plan]
      expect(first).to eq(second)
    end
  end

  describe "empty deployment" do
    it "returns an empty plan when no switches exist" do
      result = described_class.compile_for_deployment(deployment)
      expect(result[:plan]).to eq([])
    end
  end

  describe "plan entry shape" do
    it "every entry is a hash with :cmd (String) and :args (Array of Strings)" do
      ls = make_switch(name: "ls1")
      make_port(switch: ls, name: "p1", addresses: ["10.0.0.1"])

      plan = described_class.compile_for_deployment(deployment)[:plan]
      plan.each do |entry|
        expect(entry).to be_a(Hash)
        expect(entry.keys).to contain_exactly(:cmd, :args)
        expect(entry[:cmd]).to be_a(String)
        expect(entry[:args]).to be_a(Array)
        expect(entry[:args]).to all(be_a(String))
      end
    end
  end
end
