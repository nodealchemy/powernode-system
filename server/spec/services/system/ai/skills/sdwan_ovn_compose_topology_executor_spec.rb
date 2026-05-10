# frozen_string_literal: true

require "rails_helper"

# Phase O6 of the OVS+OVN dual-profile networking roadmap.
RSpec.describe System::Ai::Skills::SdwanOvnComposeTopologyExecutor do
  let(:account)        { create(:account) }
  let(:platform)       { create(:system_node_platform, account: account) }
  let(:template)       { create(:system_node_template, account: account, node_platform: platform) }
  let(:node_a)         { create(:system_node, account: account, node_template: template, name: "n-a") }
  let(:node_b)         { create(:system_node, account: account, node_template: template, name: "n-b") }
  let(:instance_a)     { create(:system_node_instance, :running, node: node_a) }
  let(:instance_b)     { create(:system_node_instance, :running, node: node_b) }
  let(:exec)           { described_class.new(account: account) }

  let(:nb_endpoint)    { "tcp:127.0.0.1:6641" }
  let(:sb_endpoint)    { "tcp:127.0.0.1:6642" }

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, and instance-method rollback" do
      d = described_class.descriptor

      expect(d[:name]).to eq("sdwan_ovn_compose_topology")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :switches, :required)).to be true
      expect(d.dig(:inputs, :nb_db_endpoint, :required)).to be false
      expect(d.dig(:outputs, :outputs)).to include(:ovn_deployment_id, :created_deployment,
                                                   :logical_switch_ids, :logical_switch_port_ids,
                                                   :compiled_plan)
      expect(d[:rollback]).to eq(:rollback_sdwan_ovn_compose_topology)
      expect(d[:requires_approval]).to be false
      expect(d[:blast_radius]).to eq(:medium)
    end
  end

  describe "#execute" do
    context "with no switches" do
      it "rejects" do
        r = exec.execute(switches: [], nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/at least one entry/)
      end
    end

    context "with a switch missing a name" do
      it "rejects" do
        r = exec.execute(switches: [ { ports: [] } ],
                         nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/name is required/)
      end
    end

    context "with an unknown port kind" do
      it "rejects" do
        r = exec.execute(switches: [ { name: "ls0", ports: [ { name: "p0", kind: "ghost" } ] } ],
                         nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/kind must be one of/)
      end
    end

    context "with a vm port missing host_node_instance_id" do
      it "rejects" do
        r = exec.execute(switches: [ { name: "ls0", ports: [ { name: "p0", kind: "vm" } ] } ],
                         nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/requires host_node_instance_id/)
      end
    end

    context "with a host_node_instance_id outside the account" do
      it "returns failure listing the missing id" do
        stranger_id = SecureRandom.uuid
        r = exec.execute(switches: [ {
                            name: "ls0",
                            ports: [ { name: "p0", kind: "vm", host_node_instance_id: stranger_id } ]
                          } ],
                          nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)
        expect(r[:success]).to be false
        expect(r[:error]).to include(stranger_id)
      end
    end

    context "without an existing deployment and missing endpoints" do
      it "rejects" do
        r = exec.execute(switches: [ { name: "ls0", ports: [ { name: "p0", kind: "external" } ] } ])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/nb_db_endpoint and sb_db_endpoint are required/)
      end
    end

    context "in dry_run mode" do
      it "returns a plan without persisting OVN rows" do
        expect {
          r = exec.execute(switches: [
                             { name: "ls-web",
                               ports: [
                                 { name: "p-web-0", kind: "vm", host_node_instance_id: instance_a.id }
                               ] }
                           ],
                           nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint,
                           dry_run: true)
          expect(r[:success]).to be true
          d = r[:data]
          expect(d[:dry_run]).to be true
          expect(d[:switch_count]).to eq(1)
          expect(d[:port_count]).to eq(1)
          expect(d[:outputs][:created_deployment]).to be true
          expect(d[:outputs][:logical_switch_ids]).to eq([])
          expect(d[:outputs][:logical_switch_port_ids]).to eq([])
          expect(d[:outputs][:compiled_plan]).to be_nil
          expect(d[:planned_actions].first[:step]).to eq("create_deployment")
          expect(d[:planned_actions].last[:step]).to eq("compile_topology")
        }.not_to change(::Sdwan::OvnDeployment, :count)
      end
    end

    context "live execute on a fresh account" do
      it "creates deployment + switches + ports + compiles plan" do
        r = exec.execute(switches: [
                           { name: "ls-web", cidr: "10.10.0.0/24",
                             ports: [
                               { name: "p-web-0", kind: "vm",
                                 host_node_instance_id: instance_a.id,
                                 addresses: [ "dynamic" ] }
                             ] },
                           { name: "ls-uplink",
                             ports: [
                               { name: "p-uplink", kind: "external" }
                             ] }
                         ],
                         nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint,
                         northd_host: "fd00::1")

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:switch_count]).to eq(2)
        expect(d[:port_count]).to eq(2)
        expect(d[:outputs][:created_deployment]).to be true
        expect(d[:outputs][:ovn_deployment_id]).to be_present
        expect(d[:outputs][:logical_switch_ids].size).to eq(2)
        expect(d[:outputs][:logical_switch_port_ids].size).to eq(2)
        expect(d[:outputs][:compiled_plan]).to be_present
        expect(d[:outputs][:compiled_plan][:plan]).to be_present
        expect(d[:failures]).to eq([])
        expect(d[:partial]).to be false

        deployment = ::Sdwan::OvnDeployment.for_account(account).first
        expect(deployment).to be_present
        expect(deployment.logical_switches.count).to eq(2)
        expect(deployment.logical_switches.flat_map(&:ports).count).to eq(2)
      end
    end

    context "live execute reusing an existing deployment" do
      it "does not re-create the deployment but adds new switches" do
        existing = ::Sdwan::OvnDeployment.create!(
          account_id: account.id, nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint
        )

        r = exec.execute(switches: [
                           { name: "ls-extra",
                             ports: [ { name: "p-ext", kind: "external" } ] }
                         ])

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:outputs][:created_deployment]).to be false
        expect(d[:outputs][:ovn_deployment_id]).to eq(existing.id)
        expect(::Sdwan::OvnDeployment.for_account(account).count).to eq(1)
      end
    end
  end

  describe "#rollback_sdwan_ovn_compose_topology" do
    it "tears down ports + switches + (when created) deployment" do
      r = exec.execute(switches: [
                         { name: "ls-doomed",
                           ports: [ { name: "p-doomed", kind: "external" } ] }
                       ],
                       nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint)

      expect(r[:success]).to be true
      d = r[:data]
      expect(::Sdwan::OvnDeployment.for_account(account).count).to eq(1)

      rb = exec.rollback_sdwan_ovn_compose_topology(
        ovn_deployment_id: d[:outputs][:ovn_deployment_id],
        logical_switch_ids: d[:outputs][:logical_switch_ids],
        logical_switch_port_ids: d[:outputs][:logical_switch_port_ids],
        created_deployment: d[:outputs][:created_deployment]
      )

      expect(rb[:success]).to be true
      expect(::Sdwan::OvnDeployment.for_account(account).count).to eq(0)
    end

    it "leaves the deployment alone when created_deployment is false" do
      existing = ::Sdwan::OvnDeployment.create!(
        account_id: account.id, nb_db_endpoint: nb_endpoint, sb_db_endpoint: sb_endpoint
      )
      r = exec.execute(switches: [
                         { name: "ls-keepable",
                           ports: [ { name: "p-keepable", kind: "external" } ] }
                       ])
      d = r[:data]

      exec.rollback_sdwan_ovn_compose_topology(
        ovn_deployment_id: d[:outputs][:ovn_deployment_id],
        logical_switch_ids: d[:outputs][:logical_switch_ids],
        logical_switch_port_ids: d[:outputs][:logical_switch_port_ids],
        created_deployment: false
      )

      expect(::Sdwan::OvnDeployment.for_account(account).reload.first&.id).to eq(existing.id)
    end
  end
end
