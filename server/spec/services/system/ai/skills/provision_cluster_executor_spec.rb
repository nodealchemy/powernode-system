# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M6.B — ProvisionClusterExecutor skill.
RSpec.describe System::Ai::Skills::ProvisionClusterExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:exec)     { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises required inputs and structured outputs" do
      d = described_class.descriptor
      expect(d[:name]).to eq("provision_cluster")
      expect(d.dig(:inputs, :template_id, :required)).to be true
      expect(d.dig(:inputs, :count, :required)).to be true
      expect(d.dig(:outputs)).to include(:created_nodes, :provisioned, :failures)
    end
  end

  describe "#execute" do
    context "with invalid count" do
      it "rejects 0" do
        r = exec.execute(template_id: template.id, count: 0,
                         provider_region_id: "r", provider_instance_type_id: "t")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/count must be/)
      end

      it "rejects above MAX_COUNT" do
        r = exec.execute(template_id: template.id, count: 100,
                         provider_region_id: "r", provider_instance_type_id: "t")
        expect(r[:success]).to be false
      end
    end

    context "in dry_run mode" do
      it "returns a plan without creating any nodes" do
        expect {
          r = exec.execute(template_id: template.id, count: 3,
                           provider_region_id: "r1", provider_instance_type_id: "t1",
                           name_prefix: "web", dry_run: true)
          expect(r[:success]).to be true
          expect(r[:data][:dry_run]).to be true
          expect(r[:data][:count]).to eq(3)
          expect(r[:data][:plan][:template_id]).to eq(template.id)
          expect(r[:data][:plan][:naming]).to eq("web-1..3")
          expect(r[:data][:plan][:estimated_steps]).to eq(6)
        }.not_to change(System::Node, :count)
      end
    end

    context "with a missing template" do
      it "returns failure on lookup" do
        r = exec.execute(template_id: SecureRandom.uuid, count: 1,
                         provider_region_id: "r", provider_instance_type_id: "t")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/template lookup failed/)
      end
    end

    context "in execute mode (provisioning stubbed at the service layer)" do
      let(:fake_result) do
        Struct.new(:ok?, :data, :error).new(
          true, { instance: instance_double("System::NodeInstance", id: SecureRandom.uuid, name: "x", node_id: SecureRandom.uuid, variety: nil, status: "provisioning", architecture: "amd64", private_ip_address: nil, public_ip_address: nil, last_heartbeat_at: nil, mtls_subject: nil, agent_version: nil), cloud_instance_id: "ci-abc" }, nil
        )
      end

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(fake_result)
      end

      it "creates N nodes and dispatches N provision calls" do
        r = exec.execute(template_id: template.id, count: 2,
                         provider_region_id: "r1", provider_instance_type_id: "t1")
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:count]).to eq(2)
        expect(d[:created_nodes].size).to eq(2)
        expect(d[:provisioned].size).to eq(2)
        expect(d[:failures]).to be_empty
        expect(::System::ProvisioningService).to have_received(:provision_instance).twice
      end
    end

    context "when provisioning partially fails" do
      let(:ok_result)  { Struct.new(:ok?, :data, :error).new(true, { instance: instance_double("System::NodeInstance", id: SecureRandom.uuid, name: "x", node_id: SecureRandom.uuid, variety: nil, status: "provisioning", architecture: "amd64", private_ip_address: nil, public_ip_address: nil, last_heartbeat_at: nil, mtls_subject: nil, agent_version: nil), cloud_instance_id: "ci-1" }, nil) }
      let(:bad_result) { Struct.new(:ok?, :data, :error).new(false, nil, "region unavailable") }

      before do
        call_count = 0
        allow(::System::ProvisioningService).to receive(:provision_instance) do
          call_count += 1
          call_count.odd? ? ok_result : bad_result
        end
      end

      it "marks the run as partial and surfaces failures" do
        r = exec.execute(template_id: template.id, count: 2,
                         provider_region_id: "r1", provider_instance_type_id: "t1")
        expect(r[:success]).to be true
        expect(r[:data][:partial]).to be true
        expect(r[:data][:provisioned].size).to eq(1)
        expect(r[:data][:failures].size).to eq(1)
        expect(r[:data][:failures].first[:step]).to eq("provision_instance")
        expect(r[:data][:failures].first[:error]).to match(/region unavailable/)
      end
    end
  end
end
