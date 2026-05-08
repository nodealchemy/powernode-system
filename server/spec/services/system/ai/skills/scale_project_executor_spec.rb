# frozen_string_literal: true

require "rails_helper"

# AI-Driven Provisioning plan — slice 8 (M2 adaptive evolution).
# Mirrors provision_full_stack_executor_spec in shape; adapts for the
# strategy switch (add_replicas / vertical_resize / add_region) and the
# unified outputs envelope.
RSpec.describe System::Ai::Skills::ScaleProjectExecutor do
  let(:account)        { create(:account) }
  let(:mission)        { create(:ai_mission, account: account, mission_type: "infrastructure") }
  let(:platform)       { create(:system_node_platform, account: account) }
  let(:template)       { create(:system_node_template, account: account, node_platform: platform) }
  let(:provider)       { create(:system_provider, account: account) }
  let(:region)         { create(:system_provider_region, account: account, provider: provider) }
  let(:instance_type)  { create(:system_provider_instance_type, account: account, provider: provider) }
  let(:exec)           { described_class.new(account: account) }

  let(:instance_stub) do
    instance_double("System::NodeInstance", id: SecureRandom.uuid)
  end

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, instance-method rollback, and blast_radius" do
      d = described_class.descriptor

      expect(d[:name]).to eq("scale_project")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :project_id, :required)).to be true
      expect(d.dig(:inputs, :target_count, :required)).to be true
      expect(d.dig(:inputs, :scaling_strategy, :required)).to be true
      expect(d.dig(:inputs, :template_id, :required)).to be false
      expect(d.dig(:inputs, :module_id, :required)).to be false
      expect(d.dig(:outputs, :outputs)).to include(:node_ids, :node_instance_ids, :sdwan_peer_ids,
                                                    :storage_volume_ids, :rolling_upgrade_plan)
      expect(d[:rollback]).to eq(:rollback_scale_project)
      expect(d[:requires_approval]).to be false
      expect(d[:blast_radius]).to eq(:medium)
    end
  end

  describe "#execute" do
    context "with an unknown strategy" do
      it "rejects" do
        r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "bogus")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/scaling_strategy must be/)
      end
    end

    context "with a missing project" do
      it "returns failure on lookup" do
        r = exec.execute(project_id: SecureRandom.uuid, target_count: 1, scaling_strategy: "add_replicas",
                         template_id: template.id, provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/project not found/)
      end
    end

    context "add_replicas" do
      it "rejects out-of-bounds target_count" do
        r = exec.execute(project_id: mission.id, target_count: 0, scaling_strategy: "add_replicas",
                         template_id: template.id, provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/target_count must be/)
      end

      it "rejects above MAX_DELTA" do
        r = exec.execute(project_id: mission.id, target_count: described_class::MAX_DELTA + 1,
                         scaling_strategy: "add_replicas",
                         template_id: template.id, provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
      end

      it "requires template_id" do
        r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "add_replicas",
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/template_id is required/)
      end

      context "in dry_run mode" do
        it "returns a plan without provisioning anything" do
          expect(::System::ProvisioningService).not_to receive(:provision_instance)

          r = exec.execute(project_id: mission.id, target_count: 2, scaling_strategy: "add_replicas",
                           template_id: template.id, provider_region_id: region.id,
                           provider_instance_type_id: instance_type.id,
                           dry_run: true)

          expect(r[:success]).to be true
          d = r[:data]
          expect(d[:dry_run]).to be true
          expect(d[:scaling_strategy]).to eq("add_replicas")
          expect(d[:count]).to eq(2)
          expect(d[:planned_actions].first[:step]).to eq("scale_project")
          expect(d[:outputs][:node_ids]).to be_empty
        end
      end

      context "in execute mode (provisioning stubbed at the service layer)" do
        let(:ok_prov) do
          ::System::Runtime::Result.ok(data: { instance: instance_stub, cloud_instance_id: "ci-abc" })
        end

        before do
          allow(::System::ProvisioningService).to receive(:provision_instance).and_return(ok_prov)
        end

        it "delegates to ProvisionFullStackExecutor and returns structured outputs" do
          r = exec.execute(project_id: mission.id, target_count: 2, scaling_strategy: "add_replicas",
                           template_id: template.id, provider_region_id: region.id,
                           provider_instance_type_id: instance_type.id)

          expect(r[:success]).to be true
          d = r[:data]
          expect(d[:scaling_strategy]).to eq("add_replicas")
          expect(d[:count]).to eq(2)
          expect(d[:outputs][:node_instance_ids].size).to eq(2)
          expect(::System::ProvisioningService).to have_received(:provision_instance).twice
        end
      end
    end

    context "add_region" do
      let(:other_region) { create(:system_provider_region, account: account, provider: provider) }
      let(:ok_prov) do
        ::System::Runtime::Result.ok(data: { instance: instance_stub, cloud_instance_id: "ci-r2" })
      end

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(ok_prov)
      end

      it "provisions a parallel stack at the new region" do
        r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "add_region",
                         template_id: template.id, provider_region_id: other_region.id,
                         provider_instance_type_id: instance_type.id)

        expect(r[:success]).to be true
        expect(r[:data][:scaling_strategy]).to eq("add_region")
        expect(r[:data][:outputs][:node_instance_ids].size).to eq(1)
      end
    end

    context "vertical_resize" do
      let(:category) { create(:system_node_module_category, account: account) }
      let(:mod) do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "subscription", name: "vresize-mod")
      end
      let!(:target_version) do
        ::System::NodeModuleVersion.create!(
          node_module: mod, version_number: 7,
          mask: [], file_spec: [], package_spec: [], config: {},
          oci_digest: "sha256:#{'c' * 64}"
        )
      end

      it "requires module_id and target_version_id" do
        r = exec.execute(project_id: mission.id, target_count: 0, scaling_strategy: "vertical_resize",
                         template_id: template.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/module_id is required/)
      end

      it "in dry_run, returns a plan with no rolling upgrade execution" do
        # Ensure RollingModuleUpgradeExecutor is NOT instantiated in dry_run
        expect(::System::Ai::Skills::RollingModuleUpgradeExecutor).not_to receive(:new)

        r = exec.execute(project_id: mission.id, target_count: 0, scaling_strategy: "vertical_resize",
                         template_id: template.id, module_id: mod.id,
                         target_version_id: target_version.id, dry_run: true)

        expect(r[:success]).to be true
        expect(r[:data][:dry_run]).to be true
        expect(r[:data][:planned_actions].first[:step]).to eq("rolling_module_upgrade_plan")
        expect(r[:data][:outputs][:rolling_upgrade_plan]).to be_nil
      end

      it "delegates to RollingModuleUpgradeExecutor and surfaces the batched plan" do
        plan = { total_instances: 5, batch_size: 1, batch_count: 5,
                 estimated_total_seconds: 600, batches: [], requires_approval: true }
        rmu = instance_double(::System::Ai::Skills::RollingModuleUpgradeExecutor,
                              execute: { success: true, data: plan })
        allow(::System::Ai::Skills::RollingModuleUpgradeExecutor).to receive(:new).and_return(rmu)

        r = exec.execute(project_id: mission.id, target_count: 0, scaling_strategy: "vertical_resize",
                         template_id: template.id, module_id: mod.id,
                         target_version_id: target_version.id)

        expect(r[:success]).to be true
        expect(r[:data][:scaling_strategy]).to eq("vertical_resize")
        expect(r[:data][:count]).to eq(5)
        expect(r[:data][:outputs][:rolling_upgrade_plan]).to eq(plan)
      end
    end
  end

  describe "#rollback_scale_project" do
    let(:instance_id_a) { SecureRandom.uuid }
    let(:volume_id)     { SecureRandom.uuid }

    it "reverses recorded outputs uniformly with the M0 envelope" do
      instance_a = instance_double("System::NodeInstance", id: instance_id_a)
      volume     = instance_double("System::ProviderVolume", id: volume_id)

      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id_a).and_return(instance_a)
      allow(::System::ProviderVolume).to receive(:find_by).with(id: volume_id).and_return(volume)

      ok = ::System::Runtime::Result.ok
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(ok)
      allow(::System::VolumeManagementService).to receive(:delete).and_return(ok)

      r = exec.rollback_scale_project(node_instance_ids: [instance_id_a], storage_volume_ids: [volume_id])

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
    end

    it "collects errors when termination fails but does not raise" do
      instance_a = instance_double("System::NodeInstance", id: instance_id_a)
      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id_a).and_return(instance_a)

      bad = ::System::Runtime::Result.err(error: "provider rejected terminate")
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(bad)

      r = exec.rollback_scale_project(node_instance_ids: [instance_id_a], storage_volume_ids: [])

      expect(r[:success]).to be false
      expect(r[:errors].first).to include(resource: "node_instance", id: instance_id_a)
    end

    it "ignores extra kwargs the runner forwards (sdwan_peer_ids, rolling_upgrade_plan)" do
      r = exec.rollback_scale_project(
        node_instance_ids: [], storage_volume_ids: [],
        sdwan_peer_ids: [SecureRandom.uuid], rolling_upgrade_plan: { foo: "bar" }
      )

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
    end
  end
end
