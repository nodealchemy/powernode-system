# frozen_string_literal: true

require "rails_helper"

# AI-Driven Provisioning plan — slice 8 (M2 adaptive evolution).
RSpec.describe System::Ai::Skills::RelocateWorkloadExecutor do
  let(:account)        { create(:account) }
  let(:mission)        { create(:ai_mission, account: account, mission_type: "infrastructure") }
  let(:platform)       { create(:system_node_platform, account: account) }
  let(:template)       { create(:system_node_template, account: account, node_platform: platform) }
  let(:provider)       { create(:system_provider, account: account) }
  let(:from_region)    { create(:system_provider_region, account: account, provider: provider) }
  let(:to_region)      { create(:system_provider_region, account: account, provider: provider) }
  let(:instance_type)  { create(:system_provider_instance_type, account: account, provider: provider) }
  let(:exec)           { described_class.new(account: account) }

  let(:source_node)     { create(:system_node, account: account, node_template: template, name: "src-1") }
  let(:source_instance) { create(:system_node_instance, :running, node: source_node) }

  let(:new_instance_stub) { instance_double("System::NodeInstance", id: SecureRandom.uuid) }

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, instance-method rollback, and high blast_radius" do
      d = described_class.descriptor

      expect(d[:name]).to eq("relocate_workload")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :project_id, :required)).to be true
      expect(d.dig(:inputs, :from_region_id, :required)).to be true
      expect(d.dig(:inputs, :to_region_id, :required)).to be true
      expect(d.dig(:inputs, :cutover_strategy, :required)).to be true
      expect(d.dig(:inputs, :source_instance_ids, :required)).to be true
      expect(d.dig(:outputs, :outputs)).to include(:node_instance_ids, :sdwan_peer_ids,
                                                    :storage_volume_ids, :terminated_instance_ids)
      expect(d[:rollback]).to eq(:rollback_relocate_workload)
      expect(d[:requires_approval]).to be true
      expect(d[:blast_radius]).to eq(:high)
    end
  end

  describe "#execute" do
    context "with an unknown cutover_strategy" do
      it "rejects" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "bogus",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [source_instance.id])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/cutover_strategy must be/)
      end
    end

    context "with an empty source set" do
      it "rejects" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/source_instance_ids must contain/)
      end
    end

    context "with a missing project" do
      it "returns failure" do
        r = exec.execute(project_id: SecureRandom.uuid, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [SecureRandom.uuid])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/project not found/)
      end
    end

    context "in dry_run mode" do
      it "returns a plan without provisioning or terminating" do
        expect(::System::ProvisioningService).not_to receive(:provision_instance)
        expect(::System::ProvisioningService).not_to receive(:terminate_instance)

        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 2,
                         source_instance_ids: [source_instance.id], dry_run: true)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:dry_run]).to be true
        expect(d[:cutover_strategy]).to eq("blue_green")
        expect(d[:planned_actions].any? { |a| a[:step] == "provision_target_instance" }).to be true
        expect(d[:planned_actions].any? { |a| a[:step] == "terminate_source" }).to be true
      end
    end

    context "blue_green execute (provisioning + termination stubbed at the service layer)" do
      let(:ok_prov) do
        ::System::Runtime::Result.ok(data: { instance: new_instance_stub, cloud_instance_id: "ci-bg" })
      end
      let(:ok_terminate) { ::System::Runtime::Result.ok }

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(ok_prov)
        allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(ok_terminate)
      end

      it "provisions the target stack first, then terminates the source" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [source_instance.id])

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:cutover_strategy]).to eq("blue_green")
        expect(d[:outputs][:node_instance_ids].size).to eq(1)
        expect(d[:outputs][:terminated_instance_ids]).to include(source_instance.id)

        # Order: provision first, then terminate
        expect(::System::ProvisioningService).to have_received(:provision_instance).ordered
        expect(::System::ProvisioningService).to have_received(:terminate_instance).ordered
      end
    end

    context "drain execute" do
      let(:ok_prov) do
        ::System::Runtime::Result.ok(data: { instance: new_instance_stub, cloud_instance_id: "ci-dr" })
      end
      let(:ok_terminate) { ::System::Runtime::Result.ok }

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(ok_prov)
        allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(ok_terminate)
      end

      it "terminates the source first, then provisions the target" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "drain",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [source_instance.id])

        expect(r[:success]).to be true
        expect(r[:data][:cutover_strategy]).to eq("drain")
        expect(::System::ProvisioningService).to have_received(:terminate_instance).ordered
        expect(::System::ProvisioningService).to have_received(:provision_instance).ordered
      end
    end

    context "blue_green refusal when target stack fails" do
      let(:bad_prov) { ::System::Runtime::Result.err(error: "region quota exhausted") }

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(bad_prov)
      end

      it "does not terminate source instances when no target instance came up" do
        expect(::System::ProvisioningService).not_to receive(:terminate_instance)

        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [source_instance.id])

        expect(r[:success]).to be true
        expect(r[:data][:partial]).to be true
        expect(r[:data][:failures].any? { |f| f[:step] == "blue_green_cutover" }).to be true
      end
    end
  end

  describe "#rollback_relocate_workload" do
    let(:new_instance_id) { SecureRandom.uuid }
    let(:volume_id)       { SecureRandom.uuid }

    it "terminates new instances and deletes new volumes; ignores sdwan peer ids" do
      instance = instance_double("System::NodeInstance", id: new_instance_id)
      volume   = instance_double("System::ProviderVolume", id: volume_id)
      allow(::System::NodeInstance).to receive(:find_by).with(id: new_instance_id).and_return(instance)
      allow(::System::ProviderVolume).to receive(:find_by).with(id: volume_id).and_return(volume)

      ok = ::System::Runtime::Result.ok
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(ok)
      allow(::System::VolumeManagementService).to receive(:delete).and_return(ok)

      r = exec.rollback_relocate_workload(
        node_instance_ids: [new_instance_id],
        storage_volume_ids: [volume_id],
        sdwan_peer_ids: [SecureRandom.uuid]
      )

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
    end

    it "collects errors when termination fails but does not raise" do
      instance = instance_double("System::NodeInstance", id: new_instance_id)
      allow(::System::NodeInstance).to receive(:find_by).with(id: new_instance_id).and_return(instance)

      bad = ::System::Runtime::Result.err(error: "provider rejected terminate")
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(bad)

      r = exec.rollback_relocate_workload(
        node_instance_ids: [new_instance_id],
        storage_volume_ids: [],
        sdwan_peer_ids: []
      )

      expect(r[:success]).to be false
      expect(r[:errors].first).to include(resource: "node_instance", id: new_instance_id)
    end

    it "tolerates the runner forwarding terminated_instance_ids and unknown kwargs" do
      r = exec.rollback_relocate_workload(
        node_instance_ids: [],
        storage_volume_ids: [],
        sdwan_peer_ids: [],
        terminated_instance_ids: [SecureRandom.uuid]
      )

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
    end
  end
end
