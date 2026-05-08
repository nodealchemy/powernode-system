# frozen_string_literal: true

require "rails_helper"

# AI-Driven Provisioning plan — slice 4 (M0). Mirrors
# provision_cluster_executor_spec.rb in shape; adapts for the richer outputs
# (node_instance_ids, sdwan_peer_ids, storage_volume_ids) and the
# class-method rollback contract.
RSpec.describe System::Ai::Skills::ProvisionFullStackExecutor do
  let(:account)        { create(:account) }
  let(:platform)       { create(:system_node_platform, account: account) }
  let(:template)       { create(:system_node_template, account: account, node_platform: platform) }
  let(:provider)       { create(:system_provider, account: account) }
  let(:region)         { create(:system_provider_region, account: account, provider: provider) }
  let(:instance_type)  { create(:system_provider_instance_type, account: account, provider: provider) }
  let(:exec)           { described_class.new(account: account) }

  # Stand-in for a real System::NodeInstance — we only need an .id surface
  # for the executor's outputs, so an instance_double is sufficient.
  let(:instance_stub) do
    instance_double("System::NodeInstance", id: SecureRandom.uuid)
  end
  let(:volume_stub) do
    instance_double("System::ProviderVolume", id: SecureRandom.uuid)
  end

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, rollback, and blast_radius" do
      d = described_class.descriptor

      expect(d[:name]).to eq("provision_full_stack")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :template_id, :required)).to be true
      expect(d.dig(:inputs, :count, :required)).to be true
      expect(d.dig(:inputs, :provider_region_id, :required)).to be true
      expect(d.dig(:inputs, :provider_instance_type_id, :required)).to be true
      expect(d.dig(:inputs, :network_id, :required)).to be false
      expect(d.dig(:inputs, :with_storage_gb, :required)).to be false
      expect(d.dig(:outputs, :outputs)).to include(:node_ids, :node_instance_ids, :sdwan_peer_ids, :storage_volume_ids)
      expect(d[:rollback]).to eq(:rollback_provision_full_stack)
      expect(d[:requires_approval]).to be false
      expect(d[:blast_radius]).to eq(:medium)
    end
  end

  describe "#execute" do
    context "with invalid count" do
      it "rejects 0" do
        r = exec.execute(template_id: template.id, count: 0,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/count must be/)
      end

      it "rejects above MAX_COUNT" do
        r = exec.execute(template_id: template.id, count: described_class::MAX_COUNT + 1,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
      end
    end

    context "with a missing template" do
      it "returns failure on lookup" do
        r = exec.execute(template_id: SecureRandom.uuid, count: 1,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/template not found/)
      end
    end

    context "with a missing provider_region_id" do
      it "returns failure" do
        r = exec.execute(template_id: template.id, count: 1,
                         provider_region_id: SecureRandom.uuid,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/provider region not found/)
      end
    end

    context "in dry_run mode" do
      it "returns a plan without provisioning anything" do
        expect(::System::ProvisioningService).not_to receive(:provision_instance)
        expect(::System::VolumeManagementService).not_to receive(:provision)

        r = exec.execute(template_id: template.id, count: 3,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id,
                         with_storage_gb: 50, dry_run: true)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:dry_run]).to be true
        expect(d[:count]).to eq(3)
        expect(d[:outputs]).to eq(node_ids: [], node_instance_ids: [], sdwan_peer_ids: [], storage_volume_ids: [])
        # 3 nodes × (create + provision + storage) = 9 planned steps
        expect(d[:planned_actions].size).to eq(9)
        expect(d[:planned_actions].first[:step]).to eq("create_node")
      end
    end

    context "in execute mode (provisioning stubbed at the service layer)" do
      let(:ok_prov) do
        ::System::Runtime::Result.ok(data: { instance: instance_stub, cloud_instance_id: "ci-abc" })
      end

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(ok_prov)
      end

      it "creates N nodes, dispatches N provision calls, and returns structured outputs" do
        r = exec.execute(template_id: template.id, count: 2,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:count]).to eq(2)
        expect(d[:outputs][:node_ids].size).to eq(2)
        expect(d[:outputs][:node_instance_ids].size).to eq(2)
        expect(d[:outputs][:storage_volume_ids]).to be_empty
        expect(d[:outputs][:sdwan_peer_ids]).to be_empty
        expect(d[:failures]).to be_empty
        expect(::System::ProvisioningService).to have_received(:provision_instance).twice
      end

      context "with with_storage_gb" do
        let(:ok_vol) { ::System::Runtime::Result.ok(data: { volume: volume_stub }) }

        before do
          allow(::System::VolumeManagementService).to receive(:provision).and_return(ok_vol)
        end

        it "provisions a per-instance volume" do
          r = exec.execute(template_id: template.id, count: 2,
                           provider_region_id: region.id,
                           provider_instance_type_id: instance_type.id,
                           with_storage_gb: 100)

          expect(r[:success]).to be true
          expect(r[:data][:outputs][:storage_volume_ids].size).to eq(2)
          expect(::System::VolumeManagementService).to have_received(:provision).twice
        end
      end

      context "with network_id" do
        # No :sdwan_network factory exists yet; stub the lookup with a
        # double so the spec doesn't depend on cidr_64 allocation infra.
        let(:network_id) { SecureRandom.uuid }
        let(:network) { instance_double("Sdwan::Network", id: network_id) }
        let(:peer_view) { { peer_id: SecureRandom.uuid, interface: {}, peers: [] } }

        before do
          relation = double("network_relation")
          allow(::Sdwan::Network).to receive(:where).with(account_id: account.id).and_return(relation)
          allow(relation).to receive(:find_by).with(id: network_id).and_return(network)
          allow(::Sdwan::TopologyCompiler).to receive(:compile_for_network).and_return([peer_view, peer_view])
        end

        it "compiles the SDWAN topology and returns peer ids" do
          r = exec.execute(template_id: template.id, count: 1,
                           provider_region_id: region.id,
                           provider_instance_type_id: instance_type.id,
                           network_id: network_id)

          expect(r[:success]).to be true
          expect(r[:data][:outputs][:sdwan_peer_ids].size).to eq(2)
          expect(::Sdwan::TopologyCompiler).to have_received(:compile_for_network).with(network)
        end
      end
    end

    context "when provisioning partially fails" do
      let(:ok_result)  { ::System::Runtime::Result.ok(data: { instance: instance_stub, cloud_instance_id: "ci-1" }) }
      let(:bad_result) { ::System::Runtime::Result.err(error: "region unavailable") }

      before do
        call_count = 0
        allow(::System::ProvisioningService).to receive(:provision_instance) do
          call_count += 1
          call_count.odd? ? ok_result : bad_result
        end
      end

      it "marks the run as partial and surfaces the failure" do
        r = exec.execute(template_id: template.id, count: 2,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)

        expect(r[:success]).to be true
        expect(r[:data][:partial]).to be true
        expect(r[:data][:outputs][:node_instance_ids].size).to eq(1)
        expect(r[:data][:failures].size).to eq(1)
        expect(r[:data][:failures].first[:step]).to eq("provision_instance")
        expect(r[:data][:failures].first[:error]).to match(/region unavailable/)
      end
    end
  end

  describe "#rollback_provision_full_stack" do
    let(:instance_id_a) { SecureRandom.uuid }
    let(:instance_id_b) { SecureRandom.uuid }
    let(:volume_id)     { SecureRandom.uuid }

    it "terminates instances and deletes volumes in reverse order, returning success when all clear" do
      instance_a = instance_double("System::NodeInstance", id: instance_id_a)
      instance_b = instance_double("System::NodeInstance", id: instance_id_b)
      volume     = instance_double("System::ProviderVolume", id: volume_id)

      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id_a).and_return(instance_a)
      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id_b).and_return(instance_b)
      allow(::System::ProviderVolume).to receive(:find_by).with(id: volume_id).and_return(volume)

      ok = ::System::Runtime::Result.ok
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(ok)
      allow(::System::VolumeManagementService).to receive(:delete).and_return(ok)

      result = exec.rollback_provision_full_stack(
        node_instance_ids: [instance_id_a, instance_id_b],
        storage_volume_ids: [volume_id]
      )

      expect(result[:success]).to be true
      expect(result[:errors]).to be_empty
      expect(::System::ProvisioningService).to have_received(:terminate_instance).twice
      expect(::System::VolumeManagementService).to have_received(:delete).once
    end

    it "collects errors when termination fails but does not raise" do
      instance_a = instance_double("System::NodeInstance", id: instance_id_a)
      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id_a).and_return(instance_a)
      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id_b).and_return(nil)
      allow(::System::ProviderVolume).to receive(:find_by).with(id: volume_id).and_return(nil)

      bad = ::System::Runtime::Result.err(error: "provider rejected terminate")
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(bad)

      result = exec.rollback_provision_full_stack(
        node_instance_ids: [instance_id_a, instance_id_b],
        storage_volume_ids: [volume_id]
      )

      expect(result[:success]).to be false
      expect(result[:errors].first).to include(resource: "node_instance", id: instance_id_a)
      expect(result[:errors].first[:error]).to match(/provider rejected/)
    end

    it "ignores extra kwargs that the runner may forward (sdwan_peer_ids, node_ids, etc.)" do
      result = exec.rollback_provision_full_stack(
        node_instance_ids: [],
        storage_volume_ids: [],
        sdwan_peer_ids: [SecureRandom.uuid],
        node_ids: [SecureRandom.uuid]
      )

      expect(result[:success]).to be true
      expect(result[:errors]).to be_empty
    end
  end
end
