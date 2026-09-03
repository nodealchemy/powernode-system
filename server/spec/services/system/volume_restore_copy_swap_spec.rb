# frozen_string_literal: true

require "rails_helper"

# IMP-e025722ef14e — APO-5 remainder, door 3: the :copy restore can SWAP.
#
# On a provider whose restore mode is :copy (Azure), APO-5 records the copy
# as a ProviderVolume and stops: the source stays attached to its instance,
# the copy sits unattached, and every surface tells the caller "attach the
# copy to finish the restore" — a restore that leaves the instance running
# on the un-restored disk. No verb composed the swap.
#
# `swap_into_place` is OPT-IN by operator direction: the default still leaves
# both volumes where they are, because the swap detaches a live disk. When
# asked, the service detaches the source and attaches the copy at the same
# device on the same instance, and it reports each outcome honestly — a swap
# that fails midway is a FAILURE that names where it stopped and which volume
# is now detached, never a success with a footnote.
RSpec.describe "Volume restore copy swap (IMP-e025722ef14e)" do
  let(:account) { create(:account) }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node, cloud_instance_id: "i-1") }

  let(:source) do
    create(:system_provider_volume, account: account, status: "in-use", external_id: "vol-src",
                                    node_instance: instance, device_name: "/dev/sdb")
  end
  let(:snapshot) do
    create(:system_provider_volume_snapshot, account: account, volume: source,
                                             status: "completed", external_id: "snap-1")
  end

  let(:adapter) { instance_double(System::Providers::BaseProvider) }

  before do
    allow(System::Providers::Registry).to receive(:for_volume).and_return(adapter)
    allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
    allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:copy)
    allow(adapter).to receive(:restore_volume_snapshot)
      .and_return({ success: true, volume_id: "vol-copy", size_gb: 100 })
    allow(adapter).to receive(:detach_volume).and_return({ success: true })
    allow(adapter).to receive(:attach_volume).and_return({ success: true, device: "/dev/sdb" })
  end

  def recorded_copy
    ::System::ProviderVolume.find_by(account: account, external_id: "vol-copy")
  end

  describe System::VolumeManagementService do
    it "leaves source and copy unswapped by default" do
      result = described_class.restore_snapshot(snapshot: snapshot)

      expect(result.success?).to be(true)
      expect(result.data[:swapped]).to be(false)
      expect(source.reload.node_instance_id).to eq(instance.id)
      expect(recorded_copy.node_instance_id).to be_nil
      expect(adapter).not_to have_received(:detach_volume)
      expect(adapter).not_to have_received(:attach_volume)
    end

    it "swaps the copy into the source's place on the same instance and device when asked" do
      result = described_class.restore_snapshot(snapshot: snapshot, swap_into_place: true)

      expect(result.success?).to be(true), result.error.to_s
      expect(adapter).to have_received(:detach_volume).with("vol-src", force: false)
      expect(adapter).to have_received(:attach_volume).with("vol-copy", "i-1", device: "/dev/sdb")

      source.reload
      copy = recorded_copy.reload
      aggregate_failures do
        expect(source.node_instance_id).to be_nil
        expect(source.status).to eq("available")
        expect(copy.node_instance_id).to eq(instance.id)
        expect(copy.device_name).to eq("/dev/sdb")
        expect(copy.status).to eq("in-use")
        expect(result.data[:restored_in_place]).to be(false)
        expect(result.data[:swapped]).to be(true)
        expect(result.data[:swapped_instance_id]).to eq(instance.id)
        expect(result.data[:swapped_device]).to eq("/dev/sdb")
        expect(result.data[:restored_volume].id).to eq(copy.id)
      end
    end

    it "reports a swap that failed at DETACH as a failure, with the copy still recorded and the source untouched" do
      allow(adapter).to receive(:detach_volume).and_return({ success: false, error: "disk busy" })

      result = described_class.restore_snapshot(snapshot: snapshot, swap_into_place: true)

      expect(result.success?).to be(false)
      expect(result.error).to include("detach")
      expect(result.error).to include("disk busy")
      expect(result.data[:swap_stage]).to eq("detach")
      expect(result.data[:swapped]).to be(false)
      expect(result.data[:restored_volume]).to be_present
      expect(source.reload.node_instance_id).to eq(instance.id)
      expect(recorded_copy.node_instance_id).to be_nil
      expect(adapter).not_to have_received(:attach_volume)
    end

    it "reports a swap that failed at ATTACH, naming the now-detached source" do
      allow(adapter).to receive(:attach_volume).and_return({ success: false, error: "no free slot" })

      result = described_class.restore_snapshot(snapshot: snapshot, swap_into_place: true)

      expect(result.success?).to be(false)
      expect(result.error).to include("DETACHED")
      expect(result.error).to include("no free slot")
      expect(result.data[:swap_stage]).to eq("attach")
      expect(result.data[:swapped]).to be(false)
      expect(source.reload.node_instance_id).to be_nil
      expect(recorded_copy.node_instance_id).to be_nil
    end

    it "has nothing to swap out of when the source is unattached, and says so" do
      source.update!(node_instance: nil, device_name: nil, status: "available")

      result = described_class.restore_snapshot(snapshot: snapshot, swap_into_place: true)

      expect(result.success?).to be(true)
      expect(result.data[:swapped]).to be(false)
      expect(result.data[:swap_skipped]).to be_present
      expect(adapter).not_to have_received(:detach_volume)
      expect(adapter).not_to have_received(:attach_volume)
    end

    it "does not swap on an in-place provider — the source itself was restored" do
      allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:in_place)
      allow(adapter).to receive(:restore_volume_snapshot).and_return({ success: true })

      result = described_class.restore_snapshot(snapshot: snapshot, swap_into_place: true)

      expect(result.success?).to be(true)
      expect(result.data[:restored_in_place]).to be(true)
      expect(result.data[:swapped]).to be(false)
      expect(result.data[:swap_skipped]).to be_present
      expect(source.reload.node_instance_id).to eq(instance.id)
      expect(adapter).not_to have_received(:detach_volume)
    end

    # THE OPT-IN IS A BOOLEAN, NOT A TRUTHY OBJECT. Every door above this one
    # carries untyped JSON: an MCP argument, a skill input, a controller
    # param. The string "false" is truthy in Ruby, so a caller that says NO in
    # the only vocabulary it has would otherwise detach a live disk. The cast
    # lives HERE, at the one boundary all three doors pass through, rather
    # than being repeated at each of them.
    it "does not opt in on a string \"false\" from an untyped door" do
      result = described_class.restore_snapshot(snapshot: snapshot, swap_into_place: "false")

      expect(result.success?).to be(true), result.error.to_s
      expect(result.data[:swapped]).to be(false)
      expect(source.reload.node_instance_id).to eq(instance.id)
      expect(adapter).not_to have_received(:detach_volume)
      expect(adapter).not_to have_received(:attach_volume)
    end

    it "still opts in on a string \"true\"" do
      result = described_class.restore_snapshot(snapshot: snapshot, swap_into_place: "true")

      expect(result.success?).to be(true), result.error.to_s
      expect(result.data[:swapped]).to be(true)
      expect(recorded_copy.node_instance_id).to eq(instance.id)
    end

    # A PROVIDER-SIDE DETACH IS NOT A ROW RELEASE. ProviderVolume#detach! is a
    # no-op returning false unless the row is `in-use` AND attached, and the
    # service's #detach drops that return — so a source whose status drifted
    # off "in-use" (a health check writes the provider's status verbatim
    # without touching node_instance_id) keeps its instance and device while
    # the provider detaches. Attaching the copy at that same device would then
    # record TWO volumes on one instance/device. The swap's own precondition
    # (`attached?`) is strictly weaker than `can_detach?`, so it must verify
    # the release rather than assume it.
    it "fails at the detach stage when the source row did not actually release" do
      source.update_columns(status: "error")

      result = described_class.restore_snapshot(snapshot: snapshot, swap_into_place: true)

      expect(result.success?).to be(false)
      expect(result.data[:swap_stage]).to eq("detach")
      expect(result.data[:swapped]).to be(false)
      expect(result.data[:restored_volume]).to be_present
      expect(recorded_copy.node_instance_id).to be_nil
      expect(adapter).not_to have_received(:attach_volume)
    end
  end

  describe Ai::Tools::SystemFleetTool do
    let(:operator) do
      create(:user, account: account, permissions: %w[system.volumes.read system.volumes.manage])
    end
    let(:tool) { described_class.new(account: account, user: operator) }

    def restore!(params = {})
      tool.execute(params: { action: "system_restore_volume_snapshot", id: snapshot.id }
                             .merge(params).with_indifferent_access)
    end

    it "advertises swap_into_place on the restore verb" do
      params = described_class.action_definitions["system_restore_volume_snapshot"][:parameters]

      expect(params).to have_key(:swap_into_place)
      expect(params[:swap_into_place][:type]).to eq("boolean")
      expect(params[:swap_into_place][:required]).to be(false)
    end

    it "passes the opt-in through to the service and reports the swap" do
      response = restore!(swap_into_place: true)

      expect(response[:success]).to be(true), response[:error].to_s
      expect(response[:data][:restored_in_place]).to be(false)
      expect(response[:data][:swapped]).to be(true)
      expect(response[:data][:restored_volume][:attached_to]).to eq(instance.id)
      expect(response[:data][:volume][:attached_to]).to be_nil
    end

    it "does not swap unless asked" do
      response = restore!

      expect(response[:success]).to be(true)
      expect(response[:swapped]).to be_nil
      expect(response[:data][:swapped]).to be(false)
      expect(source.reload.node_instance_id).to eq(instance.id)
    end

    # A failed swap must not lose the copy: without its id on the error the
    # caller has a billable, unattached disk it cannot find.
    it "surfaces the recorded copy and the failed stage when the swap fails" do
      allow(adapter).to receive(:attach_volume).and_return({ success: false, error: "no free slot" })

      response = restore!(swap_into_place: true)

      expect(response[:success]).to be(false)
      expect(response[:error]).to include("no free slot")
      expect(response[:data][:swap_stage]).to eq("attach")
      expect(response[:data][:restored_volume][:id]).to eq(recorded_copy.id)
    end
  end

  describe System::Ai::Skills::RestoreVolumeExecutor do
    let(:executor) { described_class.new(account: account) }

    def run(**inputs) = executor.execute(gated: true, **inputs)

    it "advertises the opt-in input and the swapped output" do
      descriptor = described_class.descriptor

      expect(descriptor[:inputs][:swap_into_place]).to include(type: "boolean", required: false, default: false)
      expect(descriptor[:outputs][:outputs]).to have_key(:swapped)
    end

    it "swaps when asked and records the step" do
      result = run(snapshot_id: snapshot.id, take_snapshot_first: false, swap_into_place: true)

      expect(result[:success]).to be(true)
      expect(result[:data][:failures]).to be_empty
      expect(result[:data][:planned_actions].map { |a| a[:step] }).to eq(%w[restore_volume swap_into_place])
      expect(result[:data][:outputs][:swapped]).to be(true)
      expect(result[:data][:outputs][:restored_in_place]).to be(false)
      expect(result[:data][:outputs][:restored_volume_id]).to eq(recorded_copy.id)
      expect(result[:data][:outputs][:storage_volume_ids]).to eq([ recorded_copy.id ])
      expect(recorded_copy.node_instance_id).to eq(instance.id)
    end

    it "does not swap by default" do
      result = run(snapshot_id: snapshot.id, take_snapshot_first: false)

      expect(result[:success]).to be(true)
      expect(result[:data][:outputs][:swapped]).to be(false)
      expect(result[:data][:planned_actions].map { |a| a[:step] }).to eq(%w[restore_volume])
      expect(source.reload.node_instance_id).to eq(instance.id)
    end

    it "reports a failed swap as a failure while still naming the copy that holds the data" do
      allow(adapter).to receive(:attach_volume).and_return({ success: false, error: "no free slot" })

      result = run(snapshot_id: snapshot.id, take_snapshot_first: false, swap_into_place: true)

      expect(result[:data][:failures].map { |f| f[:step] }).to eq([ "swap_into_place" ])
      expect(result[:data][:failures].first[:stage]).to eq("attach")
      expect(result[:data][:planned_actions].map { |a| a[:step] }).to eq([ "restore_volume" ])
      expect(result[:data][:outputs][:swapped]).to be(false)
      expect(result[:data][:outputs][:restored_volume_id]).to eq(recorded_copy.id)
      expect(result[:data][:outputs][:storage_volume_ids]).to eq([ recorded_copy.id ])
      expect(result[:data][:partial]).to be(true)
    end

    it "plans the swap step on dry_run when asked" do
      result = run(snapshot_id: snapshot.id, dry_run: true, take_snapshot_first: false, swap_into_place: true)

      expect(result[:data][:dry_run]).to be(true)
      expect(result[:data][:planned_actions].map { |a| a[:step] }).to eq(%w[restore_volume swap_into_place])
      expect(adapter).not_to have_received(:restore_volume_snapshot)
    end

    # BaseSkillExecutor coerces nothing — #validate_inputs! checks presence
    # only and #perform receives the raw value — so this door is the one that
    # hands a truthy string straight through. It is also the destructive one:
    # `dry_run` and `take_snapshot_first` misread a string in the SAFE
    # direction; this one detaches a live disk.
    it "does not swap when an untyped caller passes the string \"false\"" do
      result = run(snapshot_id: snapshot.id, take_snapshot_first: false, swap_into_place: "false")

      expect(result[:success]).to be(true)
      expect(result[:data][:outputs][:swapped]).to be(false)
      expect(result[:data][:planned_actions].map { |a| a[:step] }).to eq(%w[restore_volume])
      expect(source.reload.node_instance_id).to eq(instance.id)
      expect(adapter).not_to have_received(:detach_volume)
    end

    # The dry_run plan is built from the INPUT, never reaching the service, so
    # it needs the same reading of the flag — a plan that announces a swap the
    # real run would not perform is a plan of a different operation.
    it "plans no swap step for the string \"false\"" do
      result = run(snapshot_id: snapshot.id, dry_run: true, take_snapshot_first: false,
                   swap_into_place: "false")

      expect(result[:data][:planned_actions].map { |a| a[:step] }).to eq(%w[restore_volume])
    end
  end
end
