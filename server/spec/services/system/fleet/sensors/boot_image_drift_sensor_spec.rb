# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Fleet::Sensors::BootImageDriftSensor do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node) { create(:system_node, account: account, node_template: template) }
  let(:sensor) { described_class.new(account: account) }

  describe "#sense" do
    context "when no instances have drifted" do
      it "returns an empty array" do
        # Create running instance with no booted_image_git_sha
        create(:system_node_instance, :running, node: node)

        signals = sensor.sense

        expect(signals).to eq([])
      end

      it "excludes instances that are in sync" do
        sha = "in-sync-sha"
        drifted = create(:system_node_instance, :running, node: node)
        synced = create(:system_node_instance, :running, node: node)

        drifted.update!(booted_image_git_sha: "old-sha")
        synced.update!(booted_image_git_sha: sha)
        platform.update!(disk_image_git_sha: sha)

        signals = sensor.sense

        expect(signals.size).to eq(1)
        expect(signals.first.payload["instance_id"]).to eq(drifted.id)
      end
    end

    context "when instances have drifted boot images" do
      it "emits one signal per drifted running instance" do
        inst1 = create(:system_node_instance, :running, node: node)
        inst2 = create(:system_node_instance, :running, node: node)

        inst1.update!(booted_image_git_sha: "old-sha-1")
        inst2.update!(booted_image_git_sha: "old-sha-2")
        platform.update!(disk_image_git_sha: "new-sha")

        signals = sensor.sense

        expect(signals.size).to eq(2)
        instance_ids = signals.map { |s| s.payload["instance_id"] }
        expect(instance_ids).to include(inst1.id, inst2.id)
      end

      it "includes correct signal attributes" do
        instance = create(:system_node_instance, :running, node: node)
        booted_sha = "abc123def456"
        promoted_sha = "xyz789uvw012"

        instance.update!(booted_image_git_sha: booted_sha)
        platform.update!(disk_image_git_sha: promoted_sha)

        signals = sensor.sense

        expect(signals.size).to eq(1)
        signal = signals.first

        expect(signal.kind).to eq("system.boot_image_drift")
        expect(signal.severity).to eq(:medium)
        expect(signal.payload["instance_id"]).to eq(instance.id)
        expect(signal.payload["platform_id"]).to eq(platform.id)
        expect(signal.payload["booted_git_sha"]).to eq(booted_sha)
        expect(signal.payload["promoted_git_sha"]).to eq(promoted_sha)
      end

      it "uses fingerprint with format boot_image_drift:<instance_id> (per-instance, not per-promoted_sha)" do
        instance = create(:system_node_instance, :running, node: node)
        promoted_sha = "promoted-xyz"
        instance.update!(booted_image_git_sha: "old-sha")
        platform.update!(disk_image_git_sha: promoted_sha)

        signals = sensor.sense

        # Fingerprint is per-instance only; promoted sha is in payload but not fingerprint
        # so a promotion bump during a settle window doesn't falsely clear remediation state
        expected_fingerprint = "boot_image_drift:#{instance.id}"
        expect(signals.first.fingerprint).to eq(expected_fingerprint)
      end

      it "fingerprint remains stable even when promoted image changes" do
        instance = create(:system_node_instance, :running, node: node)
        instance.update!(booted_image_git_sha: "booted-sha")
        platform.update!(disk_image_git_sha: "promoted-v1")

        signals1 = sensor.sense
        fingerprint1 = signals1.first.fingerprint

        # Promotion bump: new promoted sha, same instance
        platform.update!(disk_image_git_sha: "promoted-v2")
        signals2 = sensor.sense
        fingerprint2 = signals2.first.fingerprint

        # Fingerprints must be identical so remediation state persists across promotion bumps
        expect(fingerprint1).to eq(fingerprint2)
        expect(fingerprint1).to eq("boot_image_drift:#{instance.id}")
      end
    end

    context "when promoted image has no disk_image_git_sha" do
      it "skips instances even when booted_image_git_sha is set" do
        instance = create(:system_node_instance, :running, node: node)
        instance.update!(booted_image_git_sha: "old-sha")
        platform.update!(disk_image_git_sha: nil)

        signals = sensor.sense

        expect(signals).to eq([])
      end
    end

    context "when instance booted_image_git_sha is blank" do
      it "skips the instance even if promoted sha differs" do
        instance = create(:system_node_instance, :running, node: node)
        instance.update!(booted_image_git_sha: nil)
        platform.update!(disk_image_git_sha: "promoted-sha")

        signals = sensor.sense

        expect(signals).to eq([])
      end

      it "skips empty string booted_image_git_sha" do
        instance = create(:system_node_instance, :running, node: node)
        instance.update!(booted_image_git_sha: "")
        platform.update!(disk_image_git_sha: "promoted-sha")

        signals = sensor.sense

        expect(signals).to eq([])
      end
    end

    context "when instance is not running" do
      it "excludes stopped instances" do
        instance = create(:system_node_instance, :stopped, node: node)
        instance.update!(booted_image_git_sha: "old-sha")
        platform.update!(disk_image_git_sha: "new-sha")

        signals = sensor.sense

        expect(signals).to eq([])
      end

      it "excludes terminated instances" do
        instance = create(:system_node_instance, node: node, status: "terminated")
        instance.update!(booted_image_git_sha: "old-sha")
        platform.update!(disk_image_git_sha: "new-sha")

        signals = sensor.sense

        expect(signals).to eq([])
      end

      it "excludes pending instances" do
        instance = create(:system_node_instance, node: node, status: "pending")
        instance.update!(booted_image_git_sha: "old-sha")
        platform.update!(disk_image_git_sha: "new-sha")

        signals = sensor.sense

        expect(signals).to eq([])
      end

      it "includes running instances" do
        instance = create(:system_node_instance, :running, node: node)
        instance.update!(booted_image_git_sha: "old-sha")
        platform.update!(disk_image_git_sha: "new-sha")

        signals = sensor.sense

        expect(signals.size).to eq(1)
      end
    end

    context "with cross-account isolation" do
      it "only senses instances from the specified account" do
        other_account = create(:account)
        other_platform = create(:system_node_platform, account: other_account)
        other_template = create(:system_node_template, account: other_account, node_platform: other_platform)
        other_node = create(:system_node, account: other_account, node_template: other_template)

        # Instance in target account
        inst1 = create(:system_node_instance, :running, node: node)
        inst1.update!(booted_image_git_sha: "old-sha")
        platform.update!(disk_image_git_sha: "new-sha")

        # Instance in other account (should be ignored)
        inst2 = create(:system_node_instance, :running, node: other_node)
        inst2.update!(booted_image_git_sha: "old-sha")
        other_platform.update!(disk_image_git_sha: "new-sha")

        signals = sensor.sense

        expect(signals.size).to eq(1)
        expect(signals.first.payload["instance_id"]).to eq(inst1.id)
      end
    end

    context "with multiple nodes and instances" do
      it "correctly handles a complex fleet state" do
        node2 = create(:system_node, account: account, node_template: template)
        node3 = create(:system_node, account: account, node_template: template)

        # Running, drifted
        drifted1 = create(:system_node_instance, :running, node: node)
        drifted1.update!(booted_image_git_sha: "v1.0")

        # Running, in-sync
        synced = create(:system_node_instance, :running, node: node2)
        synced.update!(booted_image_git_sha: "v2.0")

        # Running, drifted
        drifted2 = create(:system_node_instance, :running, node: node3)
        drifted2.update!(booted_image_git_sha: "v1.0")

        # Stopped, drifted (should be ignored)
        stopped = create(:system_node_instance, :stopped, node: node)
        stopped.update!(booted_image_git_sha: "v1.0")

        platform.update!(disk_image_git_sha: "v2.0")

        signals = sensor.sense

        expect(signals.size).to eq(2)
        drifted_ids = signals.map { |s| s.payload["instance_id"] }
        expect(drifted_ids).to include(drifted1.id, drifted2.id)
        expect(drifted_ids).not_to include(synced.id, stopped.id)
      end
    end
  end
end
