# frozen_string_literal: true

require "rails_helper"

# AI-Driven Provisioning plan — slice 8 (M2 adaptive evolution).
RSpec.describe System::Ai::Skills::AttachStorageExecutor do
  let(:account)        { create(:account) }
  let(:platform)       { create(:system_node_platform, account: account) }
  let(:template)       { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)           { create(:system_node, account: account, node_template: template) }
  let(:instance)       { create(:system_node_instance, :running, node: node) }
  let(:exec)           { described_class.new(account: account) }

  let(:volume_stub) do
    instance_double("System::ProviderVolume", id: SecureRandom.uuid)
  end

  describe ".descriptor" do
    it "advertises required inputs, low blast_radius, and instance-method rollback" do
      d = described_class.descriptor

      expect(d[:name]).to eq("attach_storage")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :instance_id, :required)).to be true
      expect(d.dig(:inputs, :size_gb, :required)).to be true
      expect(d.dig(:inputs, :volume_type, :required)).to be false
      expect(d.dig(:inputs, :mount_point, :required)).to be false
      expect(d.dig(:outputs, :outputs)).to include(:storage_volume_ids, :node_instance_ids, :mount)
      expect(d[:rollback]).to eq(:rollback_attach_storage)
      expect(d[:requires_approval]).to be false
      expect(d[:blast_radius]).to eq(:low)
    end
  end

  # HIER-P2SWEEP (driver ruling): attach_storage runs DURING PROVISIONING —
  # it is the provisioning mission's adaptive-evolution step
  # (Ai::Provisioning::AdaptationProposerService, the `provisioning`
  # subdomain of system_provisioning_skills_seed.rb), so it binds to the agent
  # that owns the provisioning step, the Capacity Manager — not to the Storage
  # Manager, which owns the volume DATA plane (restore, snapshot delete,
  # assignment reconcile), and no longer to Fleet Autonomy, which since
  # HIER-P2DECL declares no provisioning category at all.
  describe "SkillBindings registration" do
    it "binds to the Capacity Manager (the provisioning-step owner), not Fleet Autonomy or the Storage Manager" do
      reg = System::Ai::Skills::SkillBindings.all.find { |r| r[:executor] == described_class }

      expect(reg).not_to be_nil
      expect(reg[:agents]).to eq([ "Capacity Manager" ])
    end
  end

  describe "#execute" do
    context "with size_gb out of bounds" do
      it "rejects 0" do
        r = exec.execute(instance_id: instance.id, size_gb: 0, mount_point: "/data")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/size_gb must be/)
      end

      it "rejects above MAX_GB" do
        r = exec.execute(instance_id: instance.id, size_gb: described_class::MAX_GB + 1, mount_point: "/data")
        expect(r[:success]).to be false
      end
    end

    context "with a non-absolute mount_point" do
      it "rejects" do
        r = exec.execute(instance_id: instance.id, size_gb: 10, mount_point: "data")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/mount_point must be an absolute path/)
      end
    end

    context "with a missing instance" do
      it "returns failure on lookup" do
        r = exec.execute(instance_id: SecureRandom.uuid, size_gb: 10, mount_point: "/data")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/instance not found/)
      end
    end

    context "in dry_run mode" do
      it "returns a plan without provisioning, attaching, or sshing" do
        expect(::System::VolumeManagementService).not_to receive(:provision)
        expect(::System::VolumeManagementService).not_to receive(:attach)
        expect(::System::SshExecutionService).not_to receive(:execute)

        r = exec.execute(instance_id: instance.id, size_gb: 50, mount_point: "/data", dry_run: true)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:dry_run]).to be true
        expect(d[:count]).to eq(1)
        expect(d[:planned_actions].map { |a| a[:step] }).to include("provision_volume", "attach_volume", "mount_filesystem")
        expect(d[:outputs][:storage_volume_ids]).to be_empty
        expect(d[:outputs][:mount][:mount_point]).to eq("/data")
      end
    end

    context "in execute mode (services stubbed at the boundary)" do
      let(:ok_prov)   { ::System::Runtime::Result.ok(data: { volume: volume_stub }) }
      let(:ok_attach) { ::System::Runtime::Result.ok(data: { device: "/dev/sdf" }) }
      let(:ok_ssh)    { ::System::Runtime::Result.ok(data: { exit_code: 0, stdout: "ok" }) }

      before do
        allow(::System::VolumeManagementService).to receive(:provision).and_return(ok_prov)
        allow(::System::VolumeManagementService).to receive(:attach).and_return(ok_attach)
        allow(::System::SshExecutionService).to receive(:execute).and_return(ok_ssh)
      end

      it "provisions, attaches, mounts, and surfaces device + mount_point" do
        r = exec.execute(instance_id: instance.id, size_gb: 50, mount_point: "/srv/data")

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:outputs][:storage_volume_ids]).to eq([ volume_stub.id ])
        expect(d[:outputs][:mount]).to include(instance_id: instance.id, mount_point: "/srv/data", device: "/dev/sdf")
        expect(::System::VolumeManagementService).to have_received(:provision).once
        expect(::System::VolumeManagementService).to have_received(:attach).with(volume: volume_stub, instance: instance)
        expect(::System::SshExecutionService).to have_received(:execute).with(hash_including(instance: instance, sudo: true))
      end
    end

    context "when provision fails" do
      let(:bad_prov) { ::System::Runtime::Result.err(error: "quota exhausted") }

      before do
        allow(::System::VolumeManagementService).to receive(:provision).and_return(bad_prov)
      end

      it "surfaces the failure without attaching or mounting" do
        expect(::System::VolumeManagementService).not_to receive(:attach)
        expect(::System::SshExecutionService).not_to receive(:execute)

        r = exec.execute(instance_id: instance.id, size_gb: 10, mount_point: "/data")

        expect(r[:success]).to be true
        expect(r[:data][:failures].first[:step]).to eq("provision_volume")
        expect(r[:data][:outputs][:storage_volume_ids]).to be_empty
      end
    end

    # IMP-0d9e7ca7b166 (sibling) — AttachStorageExecutor has the identical
    # defect ProvisionFullStackExecutor had: #finalize ALWAYS returns
    # success(), so a failed attach leaves a volume whose node_instance_id is
    # nil while the runner marks the step completed. rollback_attach_storage
    # holds the id but SkillCompositionRunner#rollback_step! is reachable only
    # from handle_failure, so it never runs — and nothing else can reach a
    # nil-FK volume. It bills indefinitely.
    context "when the attach fails" do
      let(:ok_prov)    { ::System::Runtime::Result.ok(data: { volume: volume_stub }) }
      let(:bad_attach) { ::System::Runtime::Result.err(error: "no free device paths") }

      before do
        allow(::System::VolumeManagementService).to receive(:provision).and_return(ok_prov)
        allow(::System::VolumeManagementService).to receive(:attach).and_return(bad_attach)
        allow(volume_stub).to receive(:attached?).and_return(false)
        allow(::System::VolumeManagementService).to receive(:delete)
          .and_return(::System::Runtime::Result.ok)
      end

      it "reclaims the volume it could not attach, instead of leaking an unreachable row" do
        r = exec.execute(instance_id: instance.id, size_gb: 10, mount_point: "/data")
        d = r[:data]

        expect(::System::VolumeManagementService).to have_received(:delete).with(volume: volume_stub)
        # No longer advertised as provisioned storage — and this is what the
        # wrapping ScaleProject/Relocate rollbacks read.
        expect(d[:outputs][:storage_volume_ids]).to be_empty
        # Still loud. Reclaiming must not turn the failure silent.
        expect(d[:failures].map { |f| f[:step] }).to include("attach_volume")
        # ...and the reclaim is observable rather than a silent delete.
        expect(d[:planned_actions].map { |a| a[:step] }).to include("reclaim_volume")
      end

      it "records a reclaim_volume failure and KEEPS the id when the delete also fails" do
        allow(::System::VolumeManagementService).to receive(:delete)
          .and_return(::System::Runtime::Result.err(error: "provider refused"))

        r = exec.execute(instance_id: instance.id, size_gb: 10, mount_point: "/data")
        d = r[:data]

        steps = d[:failures].map { |f| f[:step] }
        expect(steps).to include("attach_volume")
        expect(steps).to include("reclaim_volume")
        # The row survives, so the envelope MUST still name it — otherwise the
        # guard just moves the leak behind a quieter layer.
        expect(d[:outputs][:storage_volume_ids]).to eq([ volume_stub.id ])
      end

      it "reclaims when the attach RAISES, not only when it returns an error" do
        allow(::System::VolumeManagementService).to receive(:attach)
          .and_raise(::System::VolumeManagementService::VolumeError, "No available device paths")

        r = exec.execute(instance_id: instance.id, size_gb: 10, mount_point: "/data")

        # A raise escapes to BaseSkillExecutor#execute, which returns a BARE
        # failure(msg) — and the runner's rollback kwargs come from
        # metadata["last_outputs"], which only mark_completed writes. So on a
        # first-run failure the hook fires with EMPTY kwargs and reclaims
        # nothing. The volume is exactly as unreachable as on the error path.
        expect(::System::VolumeManagementService).to have_received(:delete).with(volume: volume_stub)
        expect(r[:success]).to be false
      end
    end

    context "when mount fails after attach" do
      let(:ok_prov)   { ::System::Runtime::Result.ok(data: { volume: volume_stub }) }
      let(:ok_attach) { ::System::Runtime::Result.ok(data: { device: "/dev/sdg" }) }
      let(:bad_ssh)   { ::System::Runtime::Result.err(error: "mkfs failed", data: { exit_code: 1 }) }

      before do
        allow(::System::VolumeManagementService).to receive(:provision).and_return(ok_prov)
        allow(::System::VolumeManagementService).to receive(:attach).and_return(ok_attach)
        allow(::System::SshExecutionService).to receive(:execute).and_return(bad_ssh)
      end

      it "marks the run partial, retains the volume id for rollback, and records the ssh failure" do
        r = exec.execute(instance_id: instance.id, size_gb: 10, mount_point: "/data")

        expect(r[:success]).to be true
        expect(r[:data][:partial]).to be true
        expect(r[:data][:outputs][:storage_volume_ids]).to eq([ volume_stub.id ])
        expect(r[:data][:failures].first[:step]).to eq("mount_filesystem")
      end
    end
  end

  describe "#rollback_attach_storage" do
    let(:volume_id) { SecureRandom.uuid }

    it "detaches and deletes the volume in reverse order, returning success when all clear" do
      volume = instance_double("System::ProviderVolume", id: volume_id)
      allow(::System::ProviderVolume).to receive(:find_by).with(id: volume_id).and_return(volume)

      ok = ::System::Runtime::Result.ok
      allow(::System::VolumeManagementService).to receive(:detach).and_return(ok)
      allow(::System::VolumeManagementService).to receive(:delete).and_return(ok)

      r = exec.rollback_attach_storage(storage_volume_ids: [ volume_id ])

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
      expect(::System::VolumeManagementService).to have_received(:detach).with(volume: volume)
      expect(::System::VolumeManagementService).to have_received(:delete).with(volume: volume)
    end

    it "collects errors when delete fails but does not raise" do
      volume = instance_double("System::ProviderVolume", id: volume_id)
      allow(::System::ProviderVolume).to receive(:find_by).with(id: volume_id).and_return(volume)

      bad_detach = ::System::Runtime::Result.err(error: "detach pending")
      bad_delete = ::System::Runtime::Result.err(error: "still attached")
      allow(::System::VolumeManagementService).to receive(:detach).and_return(bad_detach)
      allow(::System::VolumeManagementService).to receive(:delete).and_return(bad_delete)

      r = exec.rollback_attach_storage(storage_volume_ids: [ volume_id ])

      expect(r[:success]).to be false
      expect(r[:errors].first).to include(resource: "provider_volume", id: volume_id)
      expect(r[:errors].first[:error]).to match(/still attached/)
    end

    it "ignores extra kwargs forwarded by the runner (node_instance_ids, mount)" do
      r = exec.rollback_attach_storage(
        storage_volume_ids: [],
        node_instance_ids: [ SecureRandom.uuid ],
        mount: { mount_point: "/data" }
      )

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
    end
  end
end
