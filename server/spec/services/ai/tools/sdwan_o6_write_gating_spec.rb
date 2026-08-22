# frozen_string_literal: true

require "rails_helper"

# IMP-97c7b4123d8f — the Phase O6 write family was outside the executor/gate
# regime entirely: every OVN, host-bridge and IPFIX mutation on SdwanTool was a
# direct model write, with no Sdwan::Executors class, no ACTION_CATEGORY and no
# seeded policy row — so an operator could not have configured a tier for them
# even deliberately. For the OVN family REST is READ-ONLY (index/show on
# ovn_deployments; no routes at all for switches, ports or ACLs), which inverts
# the platform's AI-first parity pattern: an agent holding this tool had
# strictly WIDER destructive capability than a console operator, including
# tearing down the account's OVN control-plane row.
#
# Host bridges and IPFIX were NOT that shape — their controllers carried
# ungated REST writes (host_bridges#destroy force-releases; ipfix
# #update/#destroy) — so for those two the gap this file closes is the MCP
# half only. IPFIX's REST half was closed afterwards by IMP-6bbe5c673c38
# (spec/requests/api/v1/system/sdwan/ipfix_collectors_spec.rb, "approval
# gating on the state toggle and the delete"); host_bridges#destroy is still
# open.
#
# This file is a CLASS guard rather than fifteen bespoke gate specs. The defect
# was never one arm — it was a whole family shipped outside the regime, and the
# thing worth pinning is that no member of it writes without passing the gate.
# Each example asserts the same two properties, which is what "gated" has to
# mean for a write:
#
#   1. the response is the gate's parked shape (`pending`), not a success body
#   2. the row is UNCHANGED — not created, not destroyed, not transitioned
#
# Property 2 is what a response-shape-only assertion would miss: an arm that
# wrote first and reported `pending` afterwards would satisfy (1) alone.
#
# The default policy resolution is require_approval, so nothing is stubbed —
# these run against the same tier a fresh account gets.
RSpec.describe "SdwanTool Phase O6 write gating (IMP-97c7b4123d8f)" do
  let(:account) { create(:account) }
  let(:tool)    { Ai::Tools::SdwanTool.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  # Every example asserts the parked shape the same way, so a change in what
  # `gated_result` returns fails once here rather than fifteen times.
  def expect_parked(response)
    expect(response[:success]).to be(true), "gated arm reported failure: #{response.inspect}"
    expect(response[:data][:pending]).to be(true),
                                         "arm executed inline instead of parking for approval: #{response.inspect}"
    response
  end

  # Approve the operation THIS response parked — resolved by the response's own
  # deferred_operation_id rather than by "the latest row", so an example that
  # parks more than one cannot silently execute the wrong one.
  #
  # Every example runs this. These fifteen executors are new classes whose only
  # dispatcher is the arm under test, so "the arm parks" and "the parked
  # operation performs the write" are two different claims and only the second
  # one says the feature still works. Nothing is stubbed between the tool and
  # the executor: a params-key mismatch surfaces as RecordNotFound here rather
  # than as a well-formed-looking hash.
  def approve!(response)
    deferred = Ai::DeferredOperation.find_by(id: response.dig(:data, :deferred_operation_id))
    expect(deferred).to be_present, "no deferred operation was parked: #{response.inspect}"
    deferred.execute_now!
    deferred
  end

  describe "host bridges (O1)" do
    let(:instance) { create(:system_node_instance, account: account) }

    it "parks create_host_bridge instead of allocating" do
      parked = expect_parked(call("system_sdwan_create_host_bridge",
                                  node_instance_id: instance.id, kind: "linux"))
      expect(::Sdwan::HostBridge.where(account_id: account.id)).to be_empty

      approve!(parked)

      expect(::Sdwan::HostBridge.where(account_id: account.id).count).to eq(1)
    end

    it "parks activate_host_bridge instead of transitioning" do
      bridge = create(:sdwan_host_bridge, account: account, node_instance: instance, state: "pending")

      parked = expect_parked(call("system_sdwan_activate_host_bridge", id: bridge.id))
      expect(bridge.reload.state).to eq("pending")

      approve!(parked)

      expect(bridge.reload.state).to eq("active")
    end

    it "parks release_host_bridge instead of releasing" do
      bridge = create(:sdwan_host_bridge, account: account, node_instance: instance, state: "active")

      parked = expect_parked(call("system_sdwan_release_host_bridge", id: bridge.id, force: true))
      expect(bridge.reload.state).to eq("active")

      approve!(parked)

      expect(bridge.reload.state).not_to eq("active")
    end
  end

  describe "OVN deployments, switches, ports and ACLs (O3)" do
    let(:deployment) { create(:sdwan_ovn_deployment, account: account) }
    let(:switch) do
      deployment.logical_switches.create!(account: account, name: "ls-app", cidr: "10.90.0.0/24", settings: {})
    end

    it "parks create_ovn_deployment instead of creating the control-plane row" do
      parked = expect_parked(call("system_sdwan_create_ovn_deployment",
                                  nb_db_endpoint: "tcp:[fd00::1]:6641",
                                  sb_db_endpoint: "tcp:[fd00::1]:6642"))
      expect(::Sdwan::OvnDeployment.where(account_id: account.id)).to be_empty

      approve!(parked)

      expect(::Sdwan::OvnDeployment.where(account_id: account.id).count).to eq(1)
    end

    # The most destructive arm in the family: it tears down the account's
    # entire OVN control-plane row, and REST offers no equivalent at all.
    it "parks delete_ovn_deployment instead of destroying it" do
      target = deployment

      parked = expect_parked(call("system_sdwan_delete_ovn_deployment", deployment_id: target.id))
      expect(::Sdwan::OvnDeployment.exists?(target.id)).to be(true)

      approve!(parked)

      expect(::Sdwan::OvnDeployment.exists?(target.id)).to be(false)
    end

    it "parks create_ovn_logical_switch instead of creating" do
      parked = expect_parked(call("system_sdwan_create_ovn_logical_switch",
                                  deployment_id: deployment.id, name: "ls-new", cidr: "10.91.0.0/24"))
      expect(::Sdwan::OvnLogicalSwitch.where(name: "ls-new")).to be_empty

      approve!(parked)

      expect(::Sdwan::OvnLogicalSwitch.where(name: "ls-new").count).to eq(1)
    end

    it "parks activate_ovn_logical_switch instead of transitioning" do
      target = switch

      parked = expect_parked(call("system_sdwan_activate_ovn_logical_switch",
                                  logical_switch_id: target.id))
      expect(target.reload.state).to eq("pending")

      approve!(parked)

      expect(target.reload.state).to eq("active")
    end

    it "parks delete_ovn_logical_switch instead of destroying" do
      target = switch

      parked = expect_parked(call("system_sdwan_delete_ovn_logical_switch",
                                  logical_switch_id: target.id))
      expect(::Sdwan::OvnLogicalSwitch.exists?(target.id)).to be(true)

      approve!(parked)

      expect(::Sdwan::OvnLogicalSwitch.exists?(target.id)).to be(false)
    end

    it "parks create_ovn_logical_switch_port instead of creating" do
      parked = expect_parked(call("system_sdwan_create_ovn_logical_switch_port",
                                  logical_switch_id: switch.id, name: "lsp-new", kind: "vm"))
      expect(::Sdwan::OvnLogicalSwitchPort.where(name: "lsp-new")).to be_empty

      approve!(parked)

      expect(::Sdwan::OvnLogicalSwitchPort.where(name: "lsp-new").count).to eq(1)
    end

    it "parks activate_ovn_logical_switch_port instead of transitioning" do
      port = switch.ports.create!(account: account, name: "lsp-a", kind: "vm", addresses: [])

      parked = expect_parked(call("system_sdwan_activate_ovn_logical_switch_port", port_id: port.id))
      expect(port.reload.state).to eq("pending")

      approve!(parked)

      expect(port.reload.state).to eq("active")
    end

    it "parks delete_ovn_logical_switch_port instead of destroying" do
      port = switch.ports.create!(account: account, name: "lsp-b", kind: "vm", addresses: [])

      parked = expect_parked(call("system_sdwan_delete_ovn_logical_switch_port", port_id: port.id))
      expect(::Sdwan::OvnLogicalSwitchPort.exists?(port.id)).to be(true)

      approve!(parked)

      expect(::Sdwan::OvnLogicalSwitchPort.exists?(port.id)).to be(false)
    end

    # ACLs are the multi-tenant isolation mechanism, and this arm also
    # auto-activates — so ungated it both wrote the rule and made it live.
    it "parks create_ovn_acl instead of creating and auto-activating" do
      parked = expect_parked(call("system_sdwan_create_ovn_acl",
                                  logical_switch_id: switch.id, name: "acl-new",
                                  direction: "to-lport", match: "ip4.src == 10.0.0.0/8",
                                  acl_action: "allow"))
      expect(::Sdwan::OvnAcl.where(name: "acl-new")).to be_empty

      approve!(parked)

      created = ::Sdwan::OvnAcl.find_by(name: "acl-new")
      expect(created).to be_present
      # The auto-activate moved INSIDE the executor, so approval must still
      # leave the rule live rather than parked in `pending`.
      expect(created.state).to eq("active")
    end

    it "parks delete_ovn_acl instead of destroying" do
      acl = switch.acls.create!(account: account, name: "acl-a", direction: "to-lport",
                                match: "ip4.src == 10.0.0.0/8", action: "allow")

      parked = expect_parked(call("system_sdwan_delete_ovn_acl", acl_id: acl.id))
      expect(::Sdwan::OvnAcl.exists?(acl.id)).to be(true)

      approve!(parked)

      expect(::Sdwan::OvnAcl.exists?(acl.id)).to be(false)
    end
  end

  # gated_result's contract: "Validate BEFORE calling — account scoping,
  # transition matrices, and token checks all run first, so a request that can
  # only ever fail parks no approval an operator has to dispose of."
  #
  # Routing an arm through the gate is exactly when this starts to matter: an
  # unvalidated doomed payload used to fail immediately and now, under
  # require_approval, would sit in an operator's queue until they approved it
  # and watched it fail. Each example asserts the refusal AND that nothing was
  # parked — the second half is the contract, the first is only an error.
  describe "refusing an impossible request before the gate" do
    let(:deployment) { create(:sdwan_ovn_deployment, account: account) }
    let(:switch) do
      deployment.logical_switches.create!(account: account, name: "ls-app", cidr: "10.90.0.0/24", settings: {})
    end

    def expect_refused_without_parking
      expect { @response = yield }.not_to change(Ai::DeferredOperation, :count)
      expect(@response[:success]).to be(false),
                                     "an impossible request was accepted: #{@response.inspect}"
    end

    it "refuses a malformed OVN endpoint" do
      expect_refused_without_parking do
        call("system_sdwan_create_ovn_deployment", nb_db_endpoint: "not-an-endpoint",
                                                   sb_db_endpoint: "also-not-one")
      end
    end

    it "refuses an invalid logical-switch name" do
      expect_refused_without_parking do
        call("system_sdwan_create_ovn_logical_switch",
             deployment_id: deployment.id, name: "Not A Valid Name!", cidr: "10.91.0.0/24")
      end
    end

    it "refuses an invalid switch-port kind" do
      expect_refused_without_parking do
        call("system_sdwan_create_ovn_logical_switch_port",
             logical_switch_id: switch.id, name: "lsp-bad", kind: "not-a-kind")
      end
    end

    it "refuses a duplicate IPFIX collector name" do
      create(:sdwan_ipfix_collector, account: account, name: "dupe")

      expect_refused_without_parking do
        call("system_sdwan_create_ipfix_collector", name: "dupe", host: "fd00::9")
      end
    end

    it "refuses an unknown host-bridge kind" do
      instance = create(:system_node_instance, account: account)

      expect_refused_without_parking do
        call("system_sdwan_create_host_bridge", node_instance_id: instance.id, kind: "not-a-kind")
      end
    end

    # The transition matrix is the case the contract names explicitly, and the
    # one most likely to be forgotten: `may_mark_active?` is free and
    # write-free, so an impossible activation never needs an operator at all.
    it "refuses activating a removed host bridge" do
      instance = create(:system_node_instance, account: account)
      bridge = create(:sdwan_host_bridge, account: account, node_instance: instance, state: "removed")

      expect_refused_without_parking { call("system_sdwan_activate_host_bridge", id: bridge.id) }

      expect(@response[:error]).to match(/readopt/)
    end

    it "refuses activating a removed logical switch" do
      switch.update!(state: "removed")

      expect_refused_without_parking do
        call("system_sdwan_activate_ovn_logical_switch", logical_switch_id: switch.id)
      end
    end

    it "refuses activating a removed switch port" do
      port = switch.ports.create!(account: account, name: "lsp-r", kind: "vm", addresses: [])
      port.update!(state: "removed")

      expect_refused_without_parking do
        call("system_sdwan_activate_ovn_logical_switch_port", port_id: port.id)
      end
    end
  end

  describe "IPFIX collectors (O5)" do
    it "parks create_ipfix_collector instead of creating" do
      parked = expect_parked(call("system_sdwan_create_ipfix_collector",
                                  name: "ipfix-new", host: "fd00::9"))
      expect(::Sdwan::IpfixCollector.where(name: "ipfix-new")).to be_empty

      approve!(parked)

      expect(::Sdwan::IpfixCollector.where(name: "ipfix-new").count).to eq(1)
    end

    it "parks delete_ipfix_collector instead of destroying" do
      collector = create(:sdwan_ipfix_collector, account: account)

      parked = expect_parked(call("system_sdwan_delete_ipfix_collector", collector_id: collector.id))
      expect(::Sdwan::IpfixCollector.exists?(collector.id)).to be(true)

      approve!(parked)

      expect(::Sdwan::IpfixCollector.exists?(collector.id)).to be(false)
    end
  end
end
