# frozen_string_literal: true

require "rails_helper"

# Phase O6 of the OVS+OVN dual-profile networking roadmap.
RSpec.describe System::Ai::Skills::SdwanComposeFullTopologyExecutor do
  let(:account)    { create(:account) }
  let(:platform)   { create(:system_node_platform, account: account) }
  let(:template)   { create(:system_node_template, account: account, node_platform: platform) }
  let(:node_a)     { create(:system_node, account: account, node_template: template, name: "n-a") }
  let(:node_b)     { create(:system_node, account: account, node_template: template, name: "n-b") }
  let(:instance_a) { create(:system_node_instance, :running, node: node_a) }
  let(:instance_b) { create(:system_node_instance, :running, node: node_b) }
  let(:exec)       { described_class.new(account: account) }

  let(:nb_endpoint)    { "tcp:127.0.0.1:6641" }
  let(:sb_endpoint)    { "tcp:127.0.0.1:6642" }

  describe ".descriptor" do
    it "advertises required inputs and per-sub-skill structured outputs" do
      d = described_class.descriptor

      expect(d[:name]).to eq("sdwan_compose_full_topology")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :host_node_instance_ids, :required)).to be true
      expect(d.dig(:inputs, :ovn_topology, :required)).to be false
      expect(d.dig(:inputs, :ipfix_collector, :required)).to be false
      expect(d.dig(:outputs, :outputs)).to include(:host_bridges, :ovn, :ipfix)
      expect(d[:rollback]).to eq(:rollback_sdwan_compose_full_topology)
      expect(d[:blast_radius]).to eq(:medium)
    end
  end

  describe "#execute" do
    context "bridges only (no ovn / no ipfix)" do
      it "runs only the bridge sub-skill" do
        r = exec.execute(host_node_instance_ids: [ instance_a.id, instance_b.id ])
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:outputs][:host_bridges]).to be_present
        expect(d[:outputs][:host_bridges][:bridge_count]).to eq(2)
        expect(d[:outputs][:ovn]).to be_nil
        expect(d[:outputs][:ipfix]).to be_nil
        expect(d[:failures]).to eq([])
        expect(d[:partial]).to be false
      end
    end

    context "bridges + ovn topology" do
      it "runs both sub-skills and aggregates outputs" do
        r = exec.execute(
          host_node_instance_ids: [ instance_a.id ],
          ovn_topology: {
            nb_db_endpoint: nb_endpoint,
            sb_db_endpoint: sb_endpoint,
            switches: [
              { name: "ls-app", ports: [ { name: "p-app", kind: "vm",
                                            host_node_instance_id: instance_a.id } ] }
            ]
          }
        )

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:outputs][:host_bridges][:bridge_count]).to eq(1)
        expect(d[:outputs][:ovn][:switch_count]).to eq(1)
        expect(d[:outputs][:ovn][:port_count]).to eq(1)
        expect(d[:outputs][:ipfix]).to be_nil
        expect(d[:planned_actions].map { |a| a[:step] })
          .to eq(%w[host_bridge_compose ovn_compose_topology])
      end
    end

    context "all three sub-skills" do
      it "runs everything in dependency order and aggregates outputs" do
        r = exec.execute(
          host_node_instance_ids: [ instance_a.id ],
          ovn_topology: {
            nb_db_endpoint: nb_endpoint,
            sb_db_endpoint: sb_endpoint,
            switches: [
              { name: "ls-app", ports: [ { name: "p-app", kind: "external" } ] }
            ]
          },
          ipfix_collector: {
            name: "primary",
            host: "10.0.0.1",
            port: 4739,
            sampling_rate: 100
          }
        )

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:outputs][:host_bridges][:bridge_count]).to eq(1)
        expect(d[:outputs][:ovn][:outputs][:created_deployment]).to be true
        expect(d[:outputs][:ipfix][:outputs][:created]).to be true
        expect(d[:outputs][:ipfix][:outputs][:target_endpoint]).to eq("10.0.0.1:4739")
        expect(d[:planned_actions].map { |a| a[:step] })
          .to eq(%w[host_bridge_compose ovn_compose_topology ipfix_collector_compose])
        expect(d[:failures]).to eq([])
        expect(d[:partial]).to be false
      end
    end

    context "in dry_run mode" do
      it "invokes each sub-skill in dry_run and persists nothing" do
        hb_before    = ::Sdwan::HostBridge.count
        ovn_before   = ::Sdwan::OvnDeployment.count
        ipfix_before = ::Sdwan::IpfixCollector.count

        r = exec.execute(
          host_node_instance_ids: [ instance_a.id ],
          ovn_topology: {
            nb_db_endpoint: nb_endpoint,
            sb_db_endpoint: sb_endpoint,
            switches: [ { name: "ls-app", ports: [ { name: "p-app", kind: "external" } ] } ]
          },
          ipfix_collector: { name: "primary", host: "10.0.0.1", port: 4739 },
          dry_run: true
        )

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:dry_run]).to be true
        expect(d[:outputs][:host_bridges][:dry_run]).to be true
        expect(d[:outputs][:ovn][:dry_run]).to be true
        expect(d[:outputs][:ipfix][:dry_run]).to be true

        expect(::Sdwan::HostBridge.count).to eq(hb_before)
        expect(::Sdwan::OvnDeployment.count).to eq(ovn_before)
        expect(::Sdwan::IpfixCollector.count).to eq(ipfix_before)
      end
    end

    context "partial failure" do
      it "collects sub-skill failures without short-circuiting" do
        r = exec.execute(
          host_node_instance_ids: [ instance_a.id ],
          ovn_topology: {
            # Missing endpoints — ovn sub-skill rejects but bridges already ran.
            switches: [ { name: "ls-bad", ports: [ { name: "p-bad", kind: "external" } ] } ]
          },
          ipfix_collector: { name: "primary", host: "10.0.0.1", port: 4739 }
        )

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:partial]).to be true
        expect(d[:outputs][:host_bridges]).to be_present
        expect(d[:outputs][:ovn]).to be_nil
        expect(d[:outputs][:ipfix]).to be_present
        expect(d[:failures].map { |f| f[:step] }).to eq([ "ovn_compose_topology" ])
      end
    end
  end

  describe "#rollback_sdwan_compose_full_topology" do
    it "delegates to each sub-executor's rollback in reverse dependency order" do
      r = exec.execute(
        host_node_instance_ids: [ instance_a.id ],
        ovn_topology: {
          nb_db_endpoint: nb_endpoint,
          sb_db_endpoint: sb_endpoint,
          switches: [ { name: "ls-doomed", ports: [ { name: "p-doomed", kind: "external" } ] } ]
        },
        ipfix_collector: { name: "doomed", host: "10.0.0.1", port: 4739 }
      )

      d = r[:data]
      expect(::Sdwan::HostBridge.where(account_id: account.id).count).to eq(1)
      expect(::Sdwan::OvnDeployment.where(account_id: account.id).count).to eq(1)
      expect(::Sdwan::IpfixCollector.where(account_id: account.id).count).to eq(1)

      rb = exec.rollback_sdwan_compose_full_topology(
        host_bridges: d[:outputs][:host_bridges],
        ovn: d[:outputs][:ovn],
        ipfix: d[:outputs][:ipfix]
      )

      expect(rb[:success]).to be true
      bridge_id = d[:outputs][:host_bridges][:outputs][:host_bridge_ids].first
      expect(::Sdwan::HostBridge.find(bridge_id).state).to eq("removed")
      expect(::Sdwan::OvnDeployment.where(account_id: account.id).count).to eq(0)
      expect(::Sdwan::IpfixCollector.where(account_id: account.id).count).to eq(0)
    end
  end
end
