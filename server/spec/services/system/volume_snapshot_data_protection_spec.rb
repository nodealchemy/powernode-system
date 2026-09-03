# frozen_string_literal: true

require "rails_helper"

# APO-5 / DR-2 (IMP-4b4bed6967ed) — project data protection.
#
# Before this increment the ONLY backup story on the platform was
# Maintenance::ScheduledBackupJob / DatabaseRestoreJob in worker/, which POST
# /api/v1/internal/maintenance/backups — the PLATFORM database. Nothing backed
# up a PROJECT's volumes:
#
#   * `provider_volumes#snapshot` existed as REST only and never reached a
#     provider — it INSERTed a ProviderVolumeSnapshot row with status "pending"
#     and returned 201. That is the "fake success" shape the operator direction
#     forbids: a caller is told a snapshot exists when no provider was asked.
#   * The MCP catalog carried no snapshot verb for a volume at all
#     (only system_compliance_snapshot, an unrelated governance read).
#   * No restore path existed at ANY surface — REST, MCP or skill executor.
#
# These specs pin the four pieces that close it: a provider capability seam
# that declines instead of faking, a service that keeps the snapshot row honest
# against what the provider actually did, the MCP verbs (create / list /
# restore in the APO-1a declaration shape — `mutating:` only, so the gate
# stays unarmed and the per-action permission check in #call still runs;
# DELETE is approval-gated since IMP-e025722ef14e, pinned in
# system_fleet_volume_snapshot_gating_spec.rb, so its dispatch examples below
# stand the gate down explicitly), and the restore executor.
RSpec.describe "Volume snapshot data protection (APO-5 / DR-2)" do
  # --------------------------------------------------------------------
  # 1. Provider seam — unavailable, NEVER fake success
  # --------------------------------------------------------------------
  describe System::Providers::BaseProvider do
    # BaseProvider#initialize dereferences connection.provider when no region
    # is given — pass a region stand-in, as provider_capabilities_spec does.
    let(:adapter) { described_class.new(nil, region: :capability_check_only) }

    it "reports no volume-snapshot support by default" do
      expect(adapter.supports_volume_snapshots?).to be(false)
    end

    it "declares NO restore primitive by default" do
      expect(adapter.volume_snapshot_restore_mode).to eq(:none)
    end

    it "structurally declines every snapshot verb rather than raising or faking" do
      results = {
        create: adapter.create_volume_snapshot("vol-1", name: "s1"),
        list: adapter.list_volume_snapshots("vol-1"),
        delete: adapter.delete_volume_snapshot("snap-1"),
        restore: adapter.restore_volume_snapshot("snap-1")
      }

      results.each do |verb, result|
        expect(result[:success]).to be(false), "#{verb} reported success on a provider with no snapshot support"
        expect(result[:unsupported]).to be(true), "#{verb} did not mark itself unsupported"
        expect(result[:error]).to match(/snapshot/i), "#{verb} gave no reason"
      end
    end
  end

  # A provider that CAN snapshot still has to say what its restore DOES. Azure's
  # restore creates a NEW disk from the snapshot and leaves the source disk
  # untouched (Microsoft.Compute: createOption "Copy"), so a caller that reported
  # "volume restored" against the source would be reporting something that did
  # not happen — the same fake-success class this increment exists to remove.
  describe System::Providers::AzureProvider do
    let(:adapter) { described_class.new(nil, region: :capability_check_only) }

    it "supports snapshots and declares COPY restore semantics" do
      expect(adapter.supports_volume_snapshots?).to be(true)
      expect(adapter.volume_snapshot_restore_mode).to eq(:copy)
    end
  end

  # --------------------------------------------------------------------
  # 2. Service seam — the row tracks what the provider actually did
  # --------------------------------------------------------------------
  describe System::VolumeManagementService do
    let(:account) { create(:account) }
    let(:volume) do
      create(:system_provider_volume, account: account, status: "in-use",
                                      external_id: "vol-abc123")
    end
    let(:adapter) { instance_double(System::Providers::BaseProvider) }

    before do
      allow(System::Providers::Registry).to receive(:for_volume).with(volume).and_return(adapter)
    end

    it "refuses on a provider without snapshot support and records NO snapshot row" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(false)

      expect {
        result = described_class.snapshot(volume: volume, name: "nightly-1")
        expect(result.success?).to be(false)
        expect(result.error).to match(/snapshot/i)
      }.not_to change(System::ProviderVolumeSnapshot, :count)
    end

    it "marks the row errored — never completed — when the provider call fails" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
      allow(adapter).to receive(:create_volume_snapshot)
        .and_return({ success: false, error: "PVE snapshot failed: storage busy" })

      result = described_class.snapshot(volume: volume, name: "nightly-2")

      expect(result.success?).to be(false)
      snap = System::ProviderVolumeSnapshot.find_by(account: account, name: "nightly-2")
      expect(snap).not_to be_nil, "the attempt left no record at all"
      expect(snap.status).to eq("error")
    end

    it "completes the row and stamps the provider id on success" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
      allow(adapter).to receive(:create_volume_snapshot)
        .and_return({ success: true, snapshot_id: "pve-snap-7" })

      result = described_class.snapshot(volume: volume, name: "nightly-3")

      expect(result.success?).to be(true)
      snap = result.data[:snapshot]
      expect(snap.status).to eq("completed")
      expect(snap.external_id).to eq("pve-snap-7")
      expect(snap.volume_id).to eq(volume.id)
    end

    it "records an ERROR row when the provider reports success but names no snapshot" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
      allow(adapter).to receive(:create_volume_snapshot).and_return({ success: true })

      result = described_class.snapshot(volume: volume, name: "nightly-noid")

      expect(result.success?).to be(false)
      expect(System::ProviderVolumeSnapshot.find_by(account: account, name: "nightly-noid").status)
        .to eq("error")
    end

    it "does not strand the row in 'creating' when the provider raises an unexpected error" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
      allow(adapter).to receive(:create_volume_snapshot).and_raise(Timeout::Error, "read timeout")

      result = described_class.snapshot(volume: volume, name: "nightly-boom")

      expect(result.success?).to be(false)
      expect(System::ProviderVolumeSnapshot.find_by(account: account, name: "nightly-boom").status)
        .to eq("error")
    end

    it "deletes a legacy fabricated row that never reached a provider" do
      legacy = create(:system_provider_volume_snapshot, account: account, volume: volume,
                                                        status: "pending", external_id: nil)

      result = described_class.delete_snapshot(snapshot: legacy)

      expect(result.success?).to be(true)
      expect(result.data[:provider_deleted]).to be(false)
      expect(System::ProviderVolumeSnapshot.find_by(id: legacy.id)).to be_nil
    end

    it "refuses to restore a snapshot that never completed" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
      snap = create(:system_provider_volume_snapshot, account: account, volume: volume,
                                                      status: "error")

      result = described_class.restore_snapshot(snapshot: snap)

      expect(result.success?).to be(false)
      expect(result.error).to match(/cannot be restored|not restorable|completed/i)
    end

    it "refuses to restore on a provider without snapshot support" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(false)
      snap = create(:system_provider_volume_snapshot, account: account, volume: volume,
                                                      status: "completed", external_id: "pve-snap-9")

      result = described_class.restore_snapshot(snapshot: snap)

      expect(result.success?).to be(false)
      expect(result.error).to match(/snapshot/i)
    end

    # === Restore SEMANTICS ===
    #
    # "Restored" is not one thing. A provider that rolls the source volume back
    # in place has restored it; a provider that copies the snapshot into a NEW
    # volume has not touched the source at all. Reporting the second as the
    # first tells an operator their data is back when it is sitting in a disk
    # the platform does not even have a row for.
    describe "restore semantics" do
      let(:snap) do
        create(:system_provider_volume_snapshot, account: account, volume: volume,
                                                 status: "completed", external_id: "provider-snap-1")
      end

      before { allow(adapter).to receive(:supports_volume_snapshots?).and_return(true) }

      it "refuses when the provider can snapshot but declares no restore primitive" do
        allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:none)
        allow(adapter).to receive(:restore_volume_snapshot)

        result = described_class.restore_snapshot(snapshot: snap)

        expect(result.success?).to be(false)
        expect(result.error).to match(/restore/i)
        expect(adapter).not_to have_received(:restore_volume_snapshot)
      end

      it "restores IN PLACE against the source volume itself" do
        allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:in_place)
        allow(adapter).to receive(:restore_volume_snapshot).and_return({ success: true })

        result = nil
        expect { result = described_class.restore_snapshot(snapshot: snap) }
          .not_to change(System::ProviderVolume, :count)

        expect(result.success?).to be(true)
        expect(result.data[:restored_in_place]).to be(true)
        expect(result.data[:restored_volume].id).to eq(volume.id)
      end

      it "records the COPY as a tracked volume and never claims the source was restored" do
        allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:copy)
        allow(adapter).to receive(:restore_volume_snapshot)
          .and_return({ success: true, volume_id: "vol-restored-1", size_gb: volume.size_gb })

        result = nil
        expect { result = described_class.restore_snapshot(snapshot: snap) }
          .to change(System::ProviderVolume, :count).by(1)

        expect(result.success?).to be(true)
        expect(result.data[:restored_in_place]).to be(false)

        restored = result.data[:restored_volume]
        expect(restored.id).not_to eq(volume.id)
        expect(restored.external_id).to eq("vol-restored-1")
        expect(restored.account_id).to eq(account.id)
        expect(restored.status).to eq("available")
        # The source is untouched — the platform must not imply otherwise.
        expect(volume.reload.external_id).to eq("vol-abc123")
      end

      it "refuses a copy restore the provider will not name a volume for" do
        allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:copy)
        allow(adapter).to receive(:restore_volume_snapshot).and_return({ success: true })

        result = nil
        expect { result = described_class.restore_snapshot(snapshot: snap) }
          .not_to change(System::ProviderVolume, :count)

        expect(result.success?).to be(false)
        expect(result.error).to match(/volume/i)
      end
    end
  end

  # --------------------------------------------------------------------
  # 3. MCP surface — the verbs exist, are declared, and are permission-gated
  # --------------------------------------------------------------------
  describe Ai::Tools::SystemFleetTool do
    # A `let`, not a file-level constant: a constant defined inside a describe
    # block leaks into Object and can be clobbered by another spec file in the
    # same (defined-order) run.
    let(:snapshot_actions) do
      {
        "system_snapshot_volume"         => { permission: "system.volumes.snapshot", mutating: true },
        "system_list_volume_snapshots"   => { permission: "system.volumes.read",     mutating: false },
        "system_delete_volume_snapshot"  => { permission: "system.volumes.delete",   mutating: true },
        "system_restore_volume_snapshot" => { permission: "system.volumes.manage",   mutating: true }
      }
    end

    let(:account) { create(:account) }
    let(:nobody)  { create(:user, account: account, permissions: []) }

    it "advertises every snapshot verb in its action definitions" do
      snapshot_actions.each_key do |action|
        expect(described_class.action_definitions).to have_key(action),
                                                     "#{action} is not advertised"
      end
    end

    it "declares each with the expected mutating flag (APO-1a shape)" do
      snapshot_actions.each do |action, expectation|
        declaration = described_class.declared_action(action)
        expect(declaration).not_to be_nil, "#{action} carries no declaration"
        expect(declaration[:mutating]).to be(expectation[:mutating]),
                                          "#{action} declared mutating: #{declaration[:mutating]}"
      end
    end

    it "refuses an unauthorized caller on each one" do
      tool = described_class.new(account: account, user: nobody)

      snapshot_actions.each do |action, expectation|
        result = tool.execute(params: { action: action }.with_indifferent_access)
        expect(result[:success]).to be(false), "#{action} did not refuse"
        expect(result[:error]).to eq("permission denied: #{expectation[:permission]} required"),
                                 "#{action} refused with an unexpected message"
      end
    end

    # DISPATCH, not just declaration: a declared action that no `when` arm
    # routes returns "unknown action", which every assertion above would still
    # pass. These two drive an AUTHORIZED caller through #execute to the
    # terminal service call.
    describe "dispatch (authorized caller)" do
      let(:operator) do
        create(:user, account: account,
                      permissions: %w[system.volumes.read system.volumes.snapshot
                                      system.volumes.delete system.volumes.manage])
      end
      let(:tool) { described_class.new(account: account, user: operator) }
      let(:volume) do
        create(:system_provider_volume, account: account, status: "available", external_id: "vol-1")
      end
      let(:adapter) { instance_double(System::Providers::BaseProvider) }

      before { allow(System::Providers::Registry).to receive(:for_volume).and_return(adapter) }

      def call(action, params = {})
        tool.execute(params: { action: action }.merge(params).with_indifferent_access)
      end

      it "snapshots through the provider and reports the completed row" do
        allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
        allow(adapter).to receive(:create_volume_snapshot)
          .and_return({ success: true, snapshot_id: "provider-snap-1" })

        result = call("system_snapshot_volume", volume_id: volume.id, name: "nightly")

        expect(result[:success]).to be(true)
        expect(result[:data][:snapshot][:status]).to eq("completed")
        expect(result[:data][:snapshot][:external_id]).to eq("provider-snap-1")
      end

      it "reports UNAVAILABLE — and writes no row — on a provider with no snapshot support" do
        allow(adapter).to receive(:supports_volume_snapshots?).and_return(false)

        expect {
          result = call("system_snapshot_volume", volume_id: volume.id, name: "nightly")
          expect(result[:success]).to be(false)
          expect(result[:error]).to match(/does not support volume snapshots/i)
        }.not_to change(System::ProviderVolumeSnapshot, :count)
      end

      it "lists a volume's snapshots" do
        snap = create(:system_provider_volume_snapshot, account: account, volume: volume)

        result = call("system_list_volume_snapshots", volume_id: volume.id)

        expect(result[:success]).to be(true)
        expect(result[:data][:snapshots].map { |s| s[:id] }).to eq([ snap.id ])
      end

      # The DB row is the platform's record; the PROVIDER is the authority on
      # whether the restore point still exists. A row whose provider-side
      # snapshot is gone is a fake restore point of exactly the kind this
      # increment removes, so the list can be asked to check.
      it "flags a row whose provider-side snapshot is gone when asked to reconcile" do
        allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
        allow(adapter).to receive(:list_volume_snapshots)
          .and_return({ success: true, snapshots: [ { snapshot_id: "kept" } ] })
        kept = create(:system_provider_volume_snapshot, account: account, volume: volume,
                                                        status: "completed", external_id: "kept")
        gone = create(:system_provider_volume_snapshot, account: account, volume: volume,
                                                        status: "completed", external_id: "gone")

        result = call("system_list_volume_snapshots", volume_id: volume.id, reconcile: true)

        rows = result[:data][:snapshots].index_by { |s| s[:id] }
        expect(rows[kept.id][:present_at_provider]).to be(true)
        expect(rows[gone.id][:present_at_provider]).to be(false)
      end

      it "refuses to restore a snapshot that is not a restore point" do
        allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
        allow(adapter).to receive(:restore_volume_snapshot).and_return({ success: true })
        snap = create(:system_provider_volume_snapshot, account: account, volume: volume,
                                                        status: "error", external_id: "s1")

        result = call("system_restore_volume_snapshot", id: snap.id)

        expect(result[:success]).to be(false)
        expect(adapter).not_to have_received(:restore_volume_snapshot)
      end

      # The delete verb is approval-gated (IMP-e025722ef14e): with no policy
      # row it PARKS, which is pinned in system_fleet_volume_snapshot_gating
      # _spec.rb. These two are about what the verb does at the provider once
      # it is allowed to run, so the gate is resolved to auto_approve — the
      # executor then replays the same action body, and the envelope below is
      # what that replay returned.
      describe "delete, with the gate auto-approved" do
        let(:operator) do
          create(:user, account: account,
                        permissions: %w[system.nodes.read system.volumes.read system.volumes.delete])
        end

        before do
          allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
            { policy: "auto_approve", channels: [], conditions: {}, record: nil }
          )
        end

        it "deletes a snapshot at the provider before dropping the row" do
          allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
          allow(adapter).to receive(:delete_volume_snapshot).and_return({ success: true })
          snap = create(:system_provider_volume_snapshot, account: account, volume: volume,
                                                          status: "completed", external_id: "s1")

          result = call("system_delete_volume_snapshot", id: snap.id)

          expect(result[:success]).to be(true)
          expect(adapter).to have_received(:delete_volume_snapshot).with("s1")
          expect(System::ProviderVolumeSnapshot.find_by(id: snap.id)).to be_nil
        end

        it "keeps the row when the provider will not confirm the delete" do
          allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
          allow(adapter).to receive(:delete_volume_snapshot)
            .and_return({ success: false, error: "provider busy" })
          snap = create(:system_provider_volume_snapshot, account: account, volume: volume,
                                                          status: "completed", external_id: "s1")

          result = call("system_delete_volume_snapshot", id: snap.id)

          expect(result[:success]).to be(false)
          expect(snap.reload.status).to eq("error")
        end
      end
    end

    it "routes every snapshot verb through the platform tool registry" do
      snapshot_actions.each_key do |action|
        expect(Ai::Tools::PlatformApiToolRegistry::TOOLS[action])
          .to eq("Ai::Tools::SystemFleetTool"), "#{action} is not registered"
      end
    end
  end

  # --------------------------------------------------------------------
  # 4. Restore executor — the skill surface DR needs
  # --------------------------------------------------------------------
  describe "System::Ai::Skills::RestoreVolumeExecutor" do
    let(:klass) { System::Ai::Skills::RestoreVolumeExecutor }

    it "exists and descends from the system skill executor base" do
      expect(klass.superclass).to eq(System::Ai::Skills::BaseSkillExecutor)
    end

    it "publishes a skill descriptor named restore_volume" do
      expect(klass.descriptor[:name]).to eq("restore_volume")
    end

    it "is bound to an agent so the seed can create the Ai::AgentSkill row" do
      registration = System::Ai::Skills::SkillBindings.all.find { |r| r[:executor].name == klass.name }
      expect(registration).not_to be_nil, "RestoreVolumeExecutor declares no binds_to"
      expect(registration[:agents]).not_to be_empty
    end

    it "is approval-gated and declares NO rollback (a restore has no inverse)" do
      expect(klass.descriptor[:requires_approval]).to be(true)
      expect(klass.descriptor).not_to have_key(:rollback)
      expect(klass.descriptor[:blast_radius]).to eq(:high)
    end

    describe "#perform" do
      let(:account) { create(:account) }
      let(:executor) { klass.new(account: account) }
      let(:volume) do
        create(:system_provider_volume, account: account, status: "in-use", external_id: "vol-1")
      end
      let(:snapshot) do
        create(:system_provider_volume_snapshot, account: account, volume: volume,
                                                 status: "completed", external_id: "provider-snap-1")
      end

      # `gated: true` — the approval decision is the CALLER's here; without it
      # every example below would park instead of running.
      def run(**inputs) = executor.execute(gated: true, **inputs)

      it "refuses a snapshot that is not a restore point, without touching the service" do
        expect(::System::VolumeManagementService).not_to receive(:restore_snapshot)
        snapshot.update!(status: "error")

        result = run(snapshot_id: snapshot.id)

        expect(result[:success]).to be(false)
        expect(result[:error]).to match(/not a restore point/i)
      end

      it "refuses a snapshot belonging to another account" do
        other = create(:system_provider_volume_snapshot, status: "completed")

        result = run(snapshot_id: other.id)

        expect(result[:success]).to be(false)
        expect(result[:error]).to match(/not found/i)
      end

      it "plans without acting on dry_run" do
        expect(::System::VolumeManagementService).not_to receive(:restore_snapshot)
        expect(::System::VolumeManagementService).not_to receive(:snapshot)

        result = run(snapshot_id: snapshot.id, dry_run: true)

        expect(result[:success]).to be(true)
        expect(result[:data][:dry_run]).to be(true)
        expect(result[:data][:planned_actions].map { |a| a[:step] })
          .to eq(%w[pre_restore_snapshot restore_volume])
      end

      it "ABORTS the restore when the pre-restore snapshot cannot be taken" do
        allow(::System::VolumeManagementService).to receive(:snapshot)
          .and_return(::System::Runtime::Result.err(error: "provider cannot snapshot"))
        expect(::System::VolumeManagementService).not_to receive(:restore_snapshot)

        result = run(snapshot_id: snapshot.id)

        # The envelope is a success (the runner reads `failures`), but the
        # restore did NOT happen — which is the whole point of the flag.
        expect(result[:data][:failures].map { |f| f[:step] }).to eq([ "pre_restore_snapshot" ])
        expect(result[:data][:outputs][:storage_volume_ids]).to be_empty
      end

      it "restores after taking the pre-restore snapshot" do
        pre = create(:system_provider_volume_snapshot, account: account, volume: volume)
        allow(::System::VolumeManagementService).to receive(:snapshot)
          .and_return(::System::Runtime::Result.ok(data: { snapshot: pre }))
        allow(::System::VolumeManagementService).to receive(:restore_snapshot)
          .and_return(::System::Runtime::Result.ok(data: { volume: volume, snapshot: snapshot }))

        result = run(snapshot_id: snapshot.id)

        expect(result[:success]).to be(true)
        expect(result[:data][:failures]).to be_empty
        expect(result[:data][:outputs][:pre_restore_snapshot_id]).to eq(pre.id)
        expect(result[:data][:outputs][:restored_from_snapshot_id]).to eq(snapshot.id)
        expect(result[:data][:planned_actions].map { |a| a[:step] })
          .to eq(%w[pre_restore_snapshot restore_volume])
      end

      it "skips the pre-restore snapshot when the caller opts out" do
        expect(::System::VolumeManagementService).not_to receive(:snapshot)
        allow(::System::VolumeManagementService).to receive(:restore_snapshot)
          .and_return(::System::Runtime::Result.ok(data: { volume: volume, snapshot: snapshot }))

        result = run(snapshot_id: snapshot.id, take_snapshot_first: false)

        expect(result[:success]).to be(true)
        expect(result[:data][:outputs][:pre_restore_snapshot_id]).to be_nil
      end
    end
  end
end
