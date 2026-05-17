# frozen_string_literal: true

require "rails_helper"

RSpec.describe Federation::SpawnProvisioner, type: :service do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  let(:template) do
    create(:system_node_template, account: account, name: "powernode-hub")
  end
  let!(:node) { create(:system_node, account: account, node_template: template) }
  let(:provider) do
    create(:system_provider, account: account, provider_type: "local_qemu")
  end
  let!(:region) do
    create(:system_provider_region, provider: provider, account: account)
  end
  let!(:instance_type) do
    create(:system_provider_instance_type, provider: provider, account: account)
  end

  let(:payload) do
    {
      "parent_url" => "https://parent.example.com",
      "acceptance_token" => "tok-xyz",
      "spawn_mode" => "managed_child",
      "parent_peer_id" => SecureRandom.uuid,
      "contract_version" => "v1"
    }
  end

  describe "#provision!" do
    context "with explicit hints" do
      let(:spawn_target) do
        {
          template_id: template.name,
          node_id: node.id,
          provider_region_id: region.id,
          provider_instance_type_id: instance_type.id
        }
      end

      let(:provisioning_result) do
        instance = create(:system_node_instance, node: node, provider_region: region,
                                                  provider_instance_type: instance_type)
        ::System::Runtime::Result.ok(data: { instance_id: instance.id, cloud_instance_id: "qemu-abc" })
      end

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance)
          .and_return(provisioning_result)
      end

      it "delegates to ProvisioningService with resolved IDs" do
        expect(::System::ProvisioningService).to receive(:provision_instance) do |kwargs|
          expect(kwargs[:node]).to eq(node)
          expect(kwargs[:provider_region_id]).to eq(region.id)
          expect(kwargs[:provider_instance_type_id]).to eq(instance_type.id)
          expect(kwargs[:options][:spawn_payload]).to eq(payload)
          provisioning_result
        end

        result = described_class.new(account: account, current_user: user)
                                .provision!(payload: payload, spawn_target: spawn_target)

        expect(result[:ok?]).to be true
        expect(result[:node_instance_id]).to be_present
        expect(result[:provider_type]).to eq("local_qemu")
      end

      it "stamps federation_spawn into NodeInstance#config on success" do
        described_class.new(account: account, current_user: user)
                       .provision!(payload: payload, spawn_target: spawn_target)

        instance = ::System::NodeInstance.find(provisioning_result.data[:instance_id])
        expect(instance.config["federation_spawn"]).to eq(payload)
      end
    end

    context "with only template_id (fallback resolution)" do
      let(:spawn_target) { { template_id: template.name } }

      before do
        instance = create(:system_node_instance, node: node, provider_region: region,
                                                  provider_instance_type: instance_type)
        allow(::System::ProvisioningService).to receive(:provision_instance)
          .and_return(::System::Runtime::Result.ok(data: { instance_id: instance.id }))
      end

      it "resolves node + region + instance_type from account defaults" do
        result = described_class.new(account: account, current_user: user)
                                .provision!(payload: payload, spawn_target: spawn_target)
        expect(result[:ok?]).to be true
      end
    end

    context "failure paths" do
      it "returns ok?=false when template_id is missing" do
        result = described_class.new(account: account, current_user: user)
                                .provision!(payload: payload, spawn_target: {})
        expect(result[:ok?]).to be false
        expect(result[:error]).to match(/template_id required/)
      end

      it "returns ok?=false when template not found" do
        result = described_class.new(account: account, current_user: user)
                                .provision!(payload: payload, spawn_target: { template_id: "nonexistent" })
        expect(result[:ok?]).to be false
        expect(result[:error]).to match(/template not found/)
      end

      it "returns ok?=false when no Node is bound to the template" do
        empty_template = create(:system_node_template, account: account, name: "no-host")
        result = described_class.new(account: account, current_user: user)
                                .provision!(payload: payload, spawn_target: { template_id: empty_template.name })
        expect(result[:ok?]).to be false
        expect(result[:error]).to match(/no host Node available/)
      end

      it "surfaces ProvisioningService failure as ok?=false" do
        allow(::System::ProvisioningService).to receive(:provision_instance)
          .and_return(::System::Runtime::Result.err(error: "quota exceeded"))

        result = described_class.new(account: account, current_user: user)
                                .provision!(payload: payload,
                                            spawn_target: { template_id: template.name })

        expect(result[:ok?]).to be false
        expect(result[:error]).to match(/provisioning failed.*quota exceeded/)
      end

      it "rescues StandardError and returns ok?=false" do
        allow(::System::ProvisioningService).to receive(:provision_instance)
          .and_raise(StandardError, "DB unreachable")

        result = described_class.new(account: account, current_user: user)
                                .provision!(payload: payload,
                                            spawn_target: { template_id: template.name })

        expect(result[:ok?]).to be false
        expect(result[:error]).to match(/DB unreachable|provisioning raised/)
      end
    end
  end
end
