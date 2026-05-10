# frozen_string_literal: true

require "rails_helper"

# Phase O6 of the OVS+OVN dual-profile networking roadmap.
RSpec.describe System::Ai::Skills::SdwanHostBridgeComposeExecutor do
  let(:account)    { create(:account) }
  let(:platform)   { create(:system_node_platform, account: account) }
  let(:template)   { create(:system_node_template, account: account, node_platform: platform) }
  let(:node_a)     { create(:system_node, account: account, node_template: template, name: "n-a") }
  let(:node_b)     { create(:system_node, account: account, node_template: template, name: "n-b") }
  let(:instance_a) { create(:system_node_instance, :running, node: node_a) }
  let(:instance_b) { create(:system_node_instance, :running, node: node_b) }
  let(:exec)       { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, and instance-method rollback" do
      d = described_class.descriptor

      expect(d[:name]).to eq("sdwan_host_bridge_compose")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :host_node_instance_ids, :required)).to be true
      expect(d.dig(:inputs, :kind, :required)).to be false
      expect(d.dig(:outputs, :outputs)).to include(:host_bridge_ids, :allocations)
      expect(d[:rollback]).to eq(:rollback_sdwan_host_bridge_compose)
      expect(d[:requires_approval]).to be false
      expect(d[:blast_radius]).to eq(:low)
    end
  end

  describe "#execute" do
    context "with no host ids" do
      it "rejects" do
        r = exec.execute(host_node_instance_ids: [])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/at least one id/)
      end
    end

    context "with a host id outside the account" do
      it "returns failure listing the missing id" do
        stranger_id = SecureRandom.uuid
        r = exec.execute(host_node_instance_ids: [ stranger_id ])
        expect(r[:success]).to be false
        expect(r[:error]).to include(stranger_id)
      end
    end

    context "with an explicit invalid kind" do
      it "rejects" do
        r = exec.execute(host_node_instance_ids: [ instance_a.id ], kind: "ghost")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/kind must be one of/)
      end
    end

    context "in dry_run mode" do
      it "returns a plan without persisting bridges" do
        expect {
          r = exec.execute(host_node_instance_ids: [ instance_a.id, instance_b.id ], dry_run: true)
          expect(r[:success]).to be true
          d = r[:data]
          expect(d[:dry_run]).to be true
          expect(d[:bridge_count]).to eq(2)
          expect(d[:outputs][:host_bridge_ids]).to eq([])
          expect(d[:outputs][:allocations].map { |a| a[:projected_kind] }.uniq).to eq([ "linux" ])
        }.not_to change(::Sdwan::HostBridge, :count)
      end

      it "projects ovs for a heavyweight host" do
        instance_a.update!(network_profile: "heavyweight")
        r = exec.execute(host_node_instance_ids: [ instance_a.id ], dry_run: true)
        expect(r[:data][:outputs][:allocations].first[:projected_kind]).to eq("ovs")
      end

      it "projects the explicit override regardless of profile" do
        instance_a.update!(network_profile: "lightweight")
        r = exec.execute(host_node_instance_ids: [ instance_a.id ], kind: "ovs", dry_run: true)
        expect(r[:data][:outputs][:allocations].first[:projected_kind]).to eq("ovs")
      end
    end

    context "live execute on lightweight hosts" do
      it "allocates a Linux bridge per host" do
        r = exec.execute(host_node_instance_ids: [ instance_a.id, instance_b.id ])
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:bridge_count]).to eq(2)
        expect(d[:outputs][:host_bridge_ids].size).to eq(2)
        expect(d[:outputs][:allocations].map { |a| a[:kind] }.uniq).to eq([ "linux" ])
        expect(d[:outputs][:allocations].map { |a| a[:reused] }.uniq).to eq([ false ])
        expect(d[:outputs][:allocations].first[:bridge_name]).to start_with("pwnbr-")
        expect(d[:failures]).to eq([])
        expect(d[:partial]).to be false
      end
    end

    context "live execute with explicit ovs override on a lightweight host" do
      it "allocates an OVS bridge regardless of profile" do
        instance_a.update!(network_profile: "lightweight")
        r = exec.execute(host_node_instance_ids: [ instance_a.id ], kind: "ovs")
        expect(r[:success]).to be true
        expect(r[:data][:outputs][:allocations].first[:kind]).to eq("ovs")
      end
    end

    context "idempotency" do
      it "returns reused=true when called twice for the same host" do
        first  = exec.execute(host_node_instance_ids: [ instance_a.id ])
        second = exec.execute(host_node_instance_ids: [ instance_a.id ])

        expect(second[:success]).to be true
        expect(second[:data][:outputs][:host_bridge_ids])
          .to eq(first[:data][:outputs][:host_bridge_ids])
        expect(second[:data][:outputs][:allocations].first[:reused]).to be true
        expect(::Sdwan::HostBridge.where(node_instance_id: instance_a.id).count).to eq(1)
      end
    end
  end

  describe "#rollback_sdwan_host_bridge_compose" do
    it "releases (force-removes) only the bridges this call created" do
      r = exec.execute(host_node_instance_ids: [ instance_a.id ])
      bridge_id = r[:data][:outputs][:host_bridge_ids].first
      expect(::Sdwan::HostBridge.find(bridge_id).state).to eq("pending")

      rb = exec.rollback_sdwan_host_bridge_compose(allocations: r[:data][:outputs][:allocations])

      expect(rb[:success]).to be true
      expect(::Sdwan::HostBridge.find(bridge_id).state).to eq("removed")
    end

    it "leaves re-used bridges alone" do
      first  = exec.execute(host_node_instance_ids: [ instance_a.id ])
      bridge_id = first[:data][:outputs][:host_bridge_ids].first
      second = exec.execute(host_node_instance_ids: [ instance_a.id ])
      expect(second[:data][:outputs][:allocations].first[:reused]).to be true

      exec.rollback_sdwan_host_bridge_compose(allocations: second[:data][:outputs][:allocations])
      expect(::Sdwan::HostBridge.find(bridge_id).state).to eq("pending")
    end
  end
end
