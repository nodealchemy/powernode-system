# frozen_string_literal: true

require "rails_helper"

# Phase 3 (Federation & Multi-Site) — slice 3b-3 multi_tenant_isolation.
#
# Asserts the executor composes EXISTING SDWAN services with correctly
# tenant-scoped params: a VRF-isolated Sdwan::Network (ibgp RIB), tenant-CIDR
# nftables firewall rules, an OVN logical switch (sibling compose executor),
# and tenant-CIDR OVN ACLs (sibling apply-acl executor) — then tears them
# down in reverse order. SDWAN-native: no k8s, no VLAN.
RSpec.describe System::Ai::Skills::MultiTenantIsolationExecutor do
  let(:account) { create(:account) }

  # APO-1c (IMP-7e2bdc1774e4). This executor declares `requires_approval: true`,
  # and BaseSkillExecutor#execute now resolves Ai::InterventionPolicy BEFORE
  # #perform — an unconfigured category defaults to require_approval, so every
  # example below would park an approval instead of performing. These examples
  # are about what #perform DOES, so an operator policy puts the gate on its
  # proceed branch rather than removing it: the real entry point still runs.
  # See spec/support/skill_gate_helpers.rb.
  before { auto_execute_skill_policy!(account, described_class) }
  let(:exec)    { described_class.new(account: account) }

  let(:nb_endpoint) { "tcp:127.0.0.1:6641" }
  let(:sb_endpoint) { "tcp:127.0.0.1:6642" }

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, high blast radius, and rollback" do
      d = described_class.descriptor

      expect(d[:name]).to eq("multi_tenant_isolation")
      expect(d[:category]).to eq("federation")
      expect(d[:requires_approval]).to be true
      expect(d.dig(:inputs, :tenant_key, :required)).to be true
      expect(d.dig(:inputs, :network_name, :required)).to be false
      expect(d.dig(:inputs, :tenant_cidr, :required)).to be false
      expect(d.dig(:outputs, :outputs)).to include(
        :sdwan_network_id, :sdwan_network_handle, :vrf_name, :tenant_cidr,
        :firewall_rule_ids, :ovn_deployment_id, :ovn_logical_switch_id,
        :ovn_acl_ids, :ovn_acl_allocations
      )
      expect(d[:rollback]).to eq(:rollback_multi_tenant_isolation)
      expect(d[:blast_radius]).to eq(:high)
    end
  end

  describe "#execute" do
    it "binds to the System Topology Designer agent" do
      # Sanity that the SDWAN-native composition is owned by the topology
      # specialist, not the chat Concierge.
      expect(described_class.descriptor[:domain]).to eq("system")
    end

    context "with a blank tenant_key" do
      it "rejects before persisting anything" do
        expect {
          r = exec.execute(tenant_key: "  ", nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)
          expect(r[:success]).to be false
          expect(r[:error]).to match(/tenant_key is required/)
        }.not_to change(::Sdwan::Network, :count)
      end
    end

    context "with a malformed explicit tenant_cidr" do
      it "rejects" do
        r = exec.execute(tenant_key: "acme", tenant_cidr: "not-a-cidr",
                         nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/tenant_cidr must be/)
      end
    end

    context "with no OVN deployment and missing endpoints" do
      it "rejects (the account needs OVN db endpoints to seed the first deployment)" do
        r = exec.execute(tenant_key: "acme")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/nb_db_endpoint and sb_db_endpoint are required/)
      end
    end

    context "in dry_run mode" do
      it "returns a plan without persisting any Sdwan rows" do
        expect {
          r = exec.execute(tenant_key: "acme-prod", tenant_cidr: "fd00:abcd:1::/64",
                           nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint,
                           dry_run: true)
          expect(r[:success]).to be true
          d = r[:data]
          expect(d[:dry_run]).to be true
          expect(d[:tenant_key]).to eq("acme-prod")
          expect(d[:tenant_cidr]).to eq("fd00:abcd:1::/64")
          steps = d[:planned_actions].map { |s| s[:step] }
          expect(steps).to include("create_network", "create_firewall_rule",
                                   "create_ovn_deployment", "compose_ovn_switch",
                                   "apply_ovn_acls")
          expect(d[:outputs][:sdwan_network_id]).to be_nil
        }.to change(::Sdwan::Network, :count).by(0)
          .and change(::Sdwan::FirewallRule, :count).by(0)
          .and change(::Sdwan::OvnLogicalSwitch, :count).by(0)
      end
    end

    context "live execute (full SDWAN-native composition)" do
      it "creates a VRF-isolated network, tenant-CIDR firewall rules, an OVN switch, and tenant-CIDR ACLs" do
        r = exec.execute(tenant_key: "acme-prod", network_name: "acme overlay",
                         nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)

        expect(r[:success]).to be true
        d = r[:data]
        out = d[:outputs]

        # 1. Network — its own VRF + isolated iBGP RIB, non-overlapping /64.
        network = ::Sdwan::Network.find(out[:sdwan_network_id])
        expect(network.account_id).to eq(account.id)
        expect(network.routing_protocol).to eq("ibgp")
        expect(network.settings["tenant_key"]).to eq("acme-prod")
        expect(out[:sdwan_network_handle]).to eq(network.network_handle)
        expect(out[:vrf_name]).to eq(network.vrf_name_for)
        # Tenant CIDR defaults to the auto-allocated /64.
        expect(out[:tenant_cidr]).to eq(network.cidr_64)
        expect(d[:tenant_cidr]).to eq(network.cidr_64)

        # 2. nftables firewall rules scoped to the tenant CIDR.
        expect(out[:firewall_rule_ids].size).to eq(2)
        rules = ::Sdwan::FirewallRule.where(id: out[:firewall_rule_ids]).index_by(&:name)
        allow_rule = rules["tenant-acme-prod-allow-intra"]
        deny_rule  = rules["tenant-acme-prod-deny-default"]
        expect(allow_rule.action).to eq("accept")
        expect(allow_rule.src_selector).to eq("cidr" => network.cidr_64)
        expect(allow_rule.dst_selector).to eq("cidr" => network.cidr_64)
        expect(allow_rule.priority).to be < deny_rule.priority
        expect(deny_rule.action).to eq("drop")
        expect(deny_rule.src_selector).to eq("all" => true)
        expect(rules.values.map(&:account_id).uniq).to eq([ account.id ])

        # 3. OVN logical switch on the (newly-created) account deployment.
        expect(out[:ovn_deployment_id]).to be_present
        switch = ::Sdwan::OvnLogicalSwitch.find(out[:ovn_logical_switch_id])
        expect(switch.account_id).to eq(account.id)
        expect(switch.name).to eq("ls-tenant-acme-prod")
        expect(switch.state).to eq("active")

        # 4. Tenant-CIDR OVN ACLs: allow intra-tenant, drop cross-tenant.
        expect(out[:ovn_acl_ids].size).to eq(2)
        acls = ::Sdwan::OvnAcl.where(id: out[:ovn_acl_ids]).index_by(&:name)
        intra = acls["tenant-acme-prod-allow-intra"]
        cross = acls["tenant-acme-prod-deny-cross"]
        expect(intra.action).to eq("allow-related")
        expect(intra.match).to eq("ip6.src == #{network.cidr_64}")
        expect(cross.action).to eq("drop")
        expect(cross.match).to eq("ip6.src != #{network.cidr_64}")
        expect(intra.priority).to be > cross.priority

        expect(d[:partial]).to be false
        expect(d[:failures]).to be_empty
      end

      it "composes the canonical Sdwan::Executors for network + firewall rules" do
        # Reuse assertion: the network and both firewall rules MUST be created
        # through the canonical Sdwan::Executors capabilities (account-scoping
        # + default attributes live there), not via direct model writes.
        allow(::Sdwan::Executors::CreateNetwork).to receive(:execute).and_call_original
        allow(::Sdwan::Executors::CreateFirewallRule).to receive(:execute).and_call_original

        r = exec.execute(tenant_key: "compose-me",
                         nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)
        expect(r[:success]).to be true

        expect(::Sdwan::Executors::CreateNetwork).to have_received(:execute).once do |params, kwargs|
          attrs = params[:attributes]
          expect(attrs[:routing_protocol]).to eq("ibgp")
          expect(attrs[:settings]).to include("tenant_key" => "compose-me")
          # Account flows in via the deferred_operation stand-in (CreateNetwork
          # merges account: deferred_operation.account onto the attributes).
          expect(kwargs[:deferred_operation].account).to eq(account)
        end

        expect(::Sdwan::Executors::CreateFirewallRule).to have_received(:execute).twice do |params, _kwargs|
          expect(params[:network_id]).to be_present
          expect(params.dig(:attributes, :account_id)).to eq(account.id)
        end

        # And the composed result is the same account-scoped row set.
        out = r[:data][:outputs]
        network = ::Sdwan::Network.find(out[:sdwan_network_id])
        expect(network.account_id).to eq(account.id)
        expect(network.routing_protocol).to eq("ibgp")
        expect(out[:firewall_rule_ids].size).to eq(2)
      end

      it "threads the composed services with tenant-scoped params (spies)" do
        compose_spy = instance_spy(System::Ai::Skills::SdwanOvnComposeTopologyExecutor)
        acl_spy     = instance_spy(System::Ai::Skills::SdwanOvnApplyAclExecutor)
        allow(System::Ai::Skills::SdwanOvnComposeTopologyExecutor)
          .to receive(:new).and_return(compose_spy)
        allow(System::Ai::Skills::SdwanOvnApplyAclExecutor)
          .to receive(:new).and_return(acl_spy)

        switch_id = SecureRandom.uuid
        allow(compose_spy).to receive(:execute).and_return(
          { success: true,
            data: { outputs: { ovn_deployment_id: SecureRandom.uuid,
                               created_deployment: true,
                               logical_switch_ids: [ switch_id ],
                               logical_switch_port_ids: [] },
                    failures: [] } }
        )
        allow(acl_spy).to receive(:execute).and_return(
          { success: true,
            data: { outputs: { logical_switch_id: switch_id,
                               ovn_acl_ids: [ SecureRandom.uuid, SecureRandom.uuid ],
                               allocations: [] },
                    failures: [] } }
        )

        r = exec.execute(tenant_key: "globex", tenant_cidr: "fd00:beef:2::/64",
                         nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)
        expect(r[:success]).to be true

        # Compose executor invoked with a single tenant switch carrying the
        # tenant CIDR and the OVN endpoints.
        expect(compose_spy).to have_received(:execute).with(
          switches: [ { name: "ls-tenant-globex", cidr: "fd00:beef:2::/64" } ],
          nb_db_endpoint: nb_endpoint,
          sb_db_endpoint: sb_endpoint
        )

        # Apply-ACL executor invoked with the returned switch id + two
        # tenant-CIDR ACL match expressions.
        expect(acl_spy).to have_received(:execute) do |kwargs|
          expect(kwargs[:logical_switch_id]).to eq(switch_id)
          matches = kwargs[:acls].map { |a| a[:match] }
          expect(matches).to contain_exactly("ip6.src == fd00:beef:2::/64",
                                              "ip6.src != fd00:beef:2::/64")
          actions = kwargs[:acls].map { |a| a[:action] }
          expect(actions).to contain_exactly("allow-related", "drop")
        end
      end

      it "uses the ip4 OVN match family when the tenant CIDR is IPv4" do
        acl_spy = instance_spy(System::Ai::Skills::SdwanOvnApplyAclExecutor)
        allow(System::Ai::Skills::SdwanOvnApplyAclExecutor).to receive(:new).and_return(acl_spy)
        allow(acl_spy).to receive(:execute).and_return(
          { success: true,
            data: { outputs: { logical_switch_id: SecureRandom.uuid, ovn_acl_ids: [], allocations: [] },
                    failures: [] } }
        )

        exec.execute(tenant_key: "legacy", tenant_cidr: "10.20.0.0/16",
                     nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)

        expect(acl_spy).to have_received(:execute) do |kwargs|
          expect(kwargs[:acls].map { |a| a[:match] })
            .to contain_exactly("ip4.src == 10.20.0.0/16", "ip4.src != 10.20.0.0/16")
        end
      end

      it "reuses an existing account OvnDeployment instead of creating a second" do
        existing = ::Sdwan::OvnDeployment.create!(
          account_id: account.id, nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint
        )

        expect {
          r = exec.execute(tenant_key: "reuse-dep")
          expect(r[:success]).to be true
          expect(r[:data][:outputs][:ovn_deployment_id]).to eq(existing.id)
        }.not_to change(::Sdwan::OvnDeployment, :count)
      end

      it "marks the run partial and stops before ACLs when the OVN switch fails to compose" do
        compose_spy = instance_spy(System::Ai::Skills::SdwanOvnComposeTopologyExecutor)
        acl_spy     = instance_spy(System::Ai::Skills::SdwanOvnApplyAclExecutor)
        allow(System::Ai::Skills::SdwanOvnComposeTopologyExecutor).to receive(:new).and_return(compose_spy)
        allow(System::Ai::Skills::SdwanOvnApplyAclExecutor).to receive(:new).and_return(acl_spy)
        allow(compose_spy).to receive(:execute).and_return({ success: false, error: "ovn nb unreachable" })
        allow(acl_spy).to receive(:execute)

        r = exec.execute(tenant_key: "halfbaked", tenant_cidr: "fd00:dead:3::/64",
                         nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)

        # Network + firewall rules landed; switch failed → partial, ACLs skipped.
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:partial]).to be true
        expect(d[:outputs][:sdwan_network_id]).to be_present
        expect(d[:outputs][:firewall_rule_ids].size).to eq(2)
        expect(d[:outputs][:ovn_logical_switch_id]).to be_nil
        expect(d[:failures].any? { |f| f[:step] == "compose_ovn_switch" }).to be true
        expect(acl_spy).not_to have_received(:execute)
      end
    end
  end

  describe "#rollback_multi_tenant_isolation" do
    it "tears down ACLs → switch → firewall rules → network in reverse order" do
      r = exec.execute(tenant_key: "teardown",
                       nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)
      expect(r[:success]).to be true
      out = r[:data][:outputs]

      network_id   = out[:sdwan_network_id]
      switch_id    = out[:ovn_logical_switch_id]
      acl_ids      = out[:ovn_acl_ids]
      rule_ids     = out[:firewall_rule_ids]
      expect(::Sdwan::Network.find_by(id: network_id)).to be_present

      rb = exec.rollback_multi_tenant_isolation(
        ovn_acl_allocations: out[:ovn_acl_allocations],
        ovn_logical_switch_id: switch_id,
        ovn_deployment_id: out[:ovn_deployment_id],
        created_ovn_deployment: out[:created_ovn_deployment],
        firewall_rule_ids: rule_ids,
        sdwan_network_id: network_id
      )

      expect(rb[:success]).to be true
      expect(rb[:errors]).to be_empty
      expect(::Sdwan::OvnAcl.where(id: acl_ids)).to be_empty
      expect(::Sdwan::OvnLogicalSwitch.find_by(id: switch_id)).to be_nil
      expect(::Sdwan::FirewallRule.where(id: rule_ids)).to be_empty
      expect(::Sdwan::Network.find_by(id: network_id)).to be_nil
    end

    it "leaves a pre-existing account OvnDeployment intact (created_ovn_deployment: false)" do
      existing = ::Sdwan::OvnDeployment.create!(
        account_id: account.id, nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint
      )
      r = exec.execute(tenant_key: "keep-dep")
      out = r[:data][:outputs]
      expect(out[:created_ovn_deployment]).to be false

      exec.rollback_multi_tenant_isolation(
        ovn_acl_allocations: out[:ovn_acl_allocations],
        ovn_logical_switch_id: out[:ovn_logical_switch_id],
        ovn_deployment_id: out[:ovn_deployment_id],
        created_ovn_deployment: out[:created_ovn_deployment],
        firewall_rule_ids: out[:firewall_rule_ids],
        sdwan_network_id: out[:sdwan_network_id]
      )

      expect(::Sdwan::OvnDeployment.find_by(id: existing.id)).to be_present
    end

    it "collects errors but continues when a firewall-rule destroy raises" do
      net = ::Sdwan::Network.create!(account_id: account.id, name: "rb-err",
                                     routing_protocol: "ibgp", settings: {})
      bad_rule = instance_double("Sdwan::FirewallRule", id: SecureRandom.uuid)
      allow(bad_rule).to receive(:destroy!).and_raise(StandardError.new("fk constraint"))
      relation = double
      allow(::Sdwan::FirewallRule).to receive(:where).with(account_id: account.id).and_return(relation)
      allow(relation).to receive(:find_by).with(id: bad_rule.id).and_return(bad_rule)

      rb = exec.rollback_multi_tenant_isolation(
        ovn_acl_allocations: [],
        ovn_logical_switch_id: nil,
        firewall_rule_ids: [ bad_rule.id ],
        sdwan_network_id: net.id
      )

      expect(rb[:success]).to be false
      expect(rb[:errors].first).to include(resource: "sdwan_firewall_rule", id: bad_rule.id)
      expect(rb[:errors].first[:error]).to match(/fk constraint/)
      # Network teardown still proceeds despite the firewall-rule error.
      expect(::Sdwan::Network.find_by(id: net.id)).to be_nil
    end

    it "tolerates missing rows / empty inputs" do
      rb = exec.rollback_multi_tenant_isolation(
        ovn_acl_allocations: [], ovn_logical_switch_id: nil,
        firewall_rule_ids: [], sdwan_network_id: nil
      )
      expect(rb[:success]).to be true
      expect(rb[:errors]).to be_empty
    end
  end

  # IMP-134062908364 (Part A) — the rescue-StandardError-continue at
  # #create_firewall_rule (multi_tenant_isolation_executor.rb:413-415) is the
  # documented per-rule failure contract, and it must hold for the
  # CrossAccountError Sdwan::Executors::CreateFirewallRule now raises when handed
  # a network outside @account. The composition collects it as a keyed failure
  # rather than aborting the whole slice, no rule is planted in the foreign
  # network, and the collected message is SAFE — it names the caller's OWN
  # account (@account), never the victim's identifiers. Before the fix the bare
  # .find inside CreateFirewallRule planted the rule in the foreign overlay and
  # nothing was recorded as a failure.
  describe "#create_firewall_rule cross-account contract" do
    let(:foreign) { create(:sdwan_network) }
    let(:rule_attributes) do
      { name: "tenant-acme-allow-intra", priority: 100, action: "accept",
        direction: "both", protocol: "any" }
    end

    it "records the cross-account refusal as a per-rule failure instead of planting the rule" do
      failures = []

      result = exec.send(:create_firewall_rule,
                         network: foreign, attributes: rule_attributes, failures: failures)

      expect(result).to be_nil
      expect(foreign.firewall_rules.count).to eq(0),
                                              "a foreign network reached CreateFirewallRule and a rule was planted in the victim's overlay"
      expect(failures.size).to eq(1)
      expect(failures.first).to include(step: "create_firewall_rule", name: "tenant-acme-allow-intra")
      expect(failures.first[:error]).to include(account.id),
                                        "the recorded failure must name the caller's OWN account"
      expect(failures.first[:error]).not_to include(foreign.account_id),
                                            "the recorded failure must not name the victim's account"
    end
  end
end
