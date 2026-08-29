# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::NodeInstance, type: :model do
  describe "boot image drift detection (campaign 019f505f)" do
    let(:account) { create(:account) }
    let(:platform) { create(:system_node_platform, account: account) }
    let(:template) { create(:system_node_template, account: account, node_platform: platform) }
    let(:node) { create(:system_node, account: account, node_template: template) }
    let(:instance) { create(:system_node_instance, :running, node: node) }

    describe "record_heartbeat! with booted_image_git_sha" do
      it "persists the booted_image_git_sha when present" do
        sha = "abc123def456"

        instance.record_heartbeat!(
          agent_version: "1.0.0",
          boot_id: "boot-123",
          booted_image_git_sha: sha
        )

        expect(instance.reload.booted_image_git_sha).to eq(sha)
      end

      it "preserves existing value when no sha reported and boot_id unchanged (agent restart)" do
        instance.update!(booted_image_git_sha: "existing-sha", boot_id: "boot-123")

        instance.record_heartbeat!(
          agent_version: "1.0.0",
          boot_id: "boot-123",
          booted_image_git_sha: nil
        )

        expect(instance.reload.booted_image_git_sha).to eq("existing-sha")
      end

      it "clears stale sha when no sha reported and boot_id changed (new boot into old image)" do
        instance.update!(booted_image_git_sha: "old-sha", boot_id: "boot-old")

        instance.record_heartbeat!(
          agent_version: "1.0.0",
          boot_id: "boot-new",
          booted_image_git_sha: nil
        )

        expect(instance.reload.booted_image_git_sha).to be_nil
      end

      it "does not clear sha when boot_id not present in stored value" do
        instance.update!(booted_image_git_sha: "existing-sha", boot_id: nil)

        instance.record_heartbeat!(
          agent_version: "1.0.0",
          boot_id: "boot-123",
          booted_image_git_sha: nil
        )

        # boot_id was nil before, now it's boot-123, so it's a change but no stored boot_id to compare
        expect(instance.reload.booted_image_git_sha).to eq("existing-sha")
      end

      it "updates booted_image_git_sha if it differs from the current value" do
        instance.update!(booted_image_git_sha: "old-sha")

        instance.record_heartbeat!(
          agent_version: "1.0.0",
          boot_id: "boot-123",
          booted_image_git_sha: "new-sha"
        )

        expect(instance.reload.booted_image_git_sha).to eq("new-sha")
      end

      it "persists other heartbeat fields alongside booted_image_git_sha" do
        sha = "test-sha"
        version = "2.1.0"
        boot_id = "boot-456"
        digests = { "module-1" => "sha256:abc" }

        instance.record_heartbeat!(
          agent_version: version,
          boot_id: boot_id,
          booted_image_git_sha: sha,
          module_digests: digests,
          architecture: "arm64"
        )

        instance.reload
        expect(instance.booted_image_git_sha).to eq(sha)
        expect(instance.agent_version).to eq(version)
        expect(instance.boot_id).to eq(boot_id)
        expect(instance.running_module_digests).to eq(digests)
        expect(instance.architecture).to eq("arm64")
      end
    end

    describe "record_heartbeat! bounds node-supplied identifier strings (IMP-dab7cb6a117a)" do
      let(:oversized) { "x" * 500 }

      it "truncates an oversized boot_id to the cap and still records the heartbeat" do
        before_time = Time.current

        instance.record_heartbeat!(
          agent_version: "1.0.0",
          boot_id: oversized
        )
        instance.reload

        expect(instance.boot_id.length).to eq(System::NodeInstance::MAX_IDENTIFIER_CHARS)
        expect(instance.boot_id).to eq(oversized[0, System::NodeInstance::MAX_IDENTIFIER_CHARS])
        expect(instance.last_heartbeat_at).to be >= before_time
      end

      it "truncates an oversized agent_version to the cap and still records the heartbeat" do
        instance.record_heartbeat!(
          agent_version: oversized,
          boot_id: "boot-123"
        )
        instance.reload

        expect(instance.agent_version.length).to eq(System::NodeInstance::MAX_IDENTIFIER_CHARS)
        expect(instance.agent_version).to eq(oversized[0, System::NodeInstance::MAX_IDENTIFIER_CHARS])
        expect(instance.last_heartbeat_at).to be_present
      end

      it "truncates an oversized booted_image_git_sha to the cap and still records the heartbeat" do
        instance.record_heartbeat!(
          agent_version: "1.0.0",
          boot_id: "boot-123",
          booted_image_git_sha: oversized
        )
        instance.reload

        expect(instance.booted_image_git_sha.length).to eq(System::NodeInstance::MAX_IDENTIFIER_CHARS)
        expect(instance.booted_image_git_sha).to eq(oversized[0, System::NodeInstance::MAX_IDENTIFIER_CHARS])
        expect(instance.last_heartbeat_at).to be_present
      end

      it "leaves in-bound values untouched" do
        instance.record_heartbeat!(
          agent_version: "1.0.0",
          boot_id: "boot-123",
          booted_image_git_sha: "short-sha"
        )
        instance.reload

        expect(instance.boot_id).to eq("boot-123")
        expect(instance.agent_version).to eq("1.0.0")
        expect(instance.booted_image_git_sha).to eq("short-sha")
      end
    end

    describe "#promoted_image_git_sha" do
      it "returns the platform's disk_image_git_sha" do
        platform.update!(disk_image_git_sha: "promoted-abc123")

        expect(instance.promoted_image_git_sha).to eq("promoted-abc123")
      end

      it "returns nil when platform has no disk_image_git_sha" do
        platform.update!(disk_image_git_sha: nil)

        expect(instance.promoted_image_git_sha).to be_nil
      end

      it "returns the value even if it's blank" do
        other_platform = create(:system_node_platform, account: account, disk_image_git_sha: "")
        other_template = create(:system_node_template, account: account, node_platform: other_platform)
        other_node = create(:system_node, account: account, node_template: other_template)
        other_instance = create(:system_node_instance, :running, node: other_node)

        # promoted_image_git_sha returns whatever is in the column, even if blank
        expect(other_instance.promoted_image_git_sha).to eq("")
      end

      it "reads the full chain: instance → node → template → platform" do
        other_platform = create(:system_node_platform, account: account, disk_image_git_sha: "other-sha")
        other_template = create(:system_node_template, account: account, node_platform: other_platform)
        other_node = create(:system_node, account: account, node_template: other_template)
        other_instance = create(:system_node_instance, :running, node: other_node)

        expect(other_instance.promoted_image_git_sha).to eq("other-sha")
      end
    end

    describe "#boot_image_drifted?" do
      context "when both booted and promoted shas are present and equal" do
        it "returns false" do
          sha = "same-sha-123"
          instance.update!(booted_image_git_sha: sha)
          platform.update!(disk_image_git_sha: sha)

          expect(instance.boot_image_drifted?).to be false
        end
      end

      context "when both booted and promoted shas are present and differ" do
        it "returns true" do
          instance.update!(booted_image_git_sha: "booted-abc")
          platform.update!(disk_image_git_sha: "promoted-xyz")

          expect(instance.boot_image_drifted?).to be true
        end
      end

      context "when booted_image_git_sha is nil" do
        it "returns false" do
          instance.update!(booted_image_git_sha: nil)
          platform.update!(disk_image_git_sha: "promoted-xyz")

          expect(instance.boot_image_drifted?).to be false
        end
      end

      context "when booted_image_git_sha is blank string" do
        it "returns false" do
          instance.update!(booted_image_git_sha: "")
          platform.update!(disk_image_git_sha: "promoted-xyz")

          expect(instance.boot_image_drifted?).to be false
        end
      end

      context "when promoted_image_git_sha is nil" do
        it "returns false" do
          instance.update!(booted_image_git_sha: "booted-abc")
          platform.update!(disk_image_git_sha: nil)

          expect(instance.boot_image_drifted?).to be false
        end
      end

      context "when promoted_image_git_sha is blank string" do
        it "returns false" do
          instance.update!(booted_image_git_sha: "booted-abc")
          platform.update!(disk_image_git_sha: "")

          expect(instance.boot_image_drifted?).to be false
        end
      end

      context "when neither sha is present" do
        it "returns false" do
          instance.update!(booted_image_git_sha: nil)
          platform.update!(disk_image_git_sha: nil)

          expect(instance.boot_image_drifted?).to be false
        end
      end

      context "with real-world scenario: drift detection" do
        it "correctly identifies a drifted node vs in-sync node" do
          drifted = create(:system_node_instance, :running, node: node)
          drifted.update!(booted_image_git_sha: "old-build-sha")
          platform.update!(disk_image_git_sha: "new-build-sha")

          synced = create(:system_node_instance, :running, node: node)
          synced.update!(booted_image_git_sha: "new-build-sha")

          expect(drifted.boot_image_drifted?).to be true
          expect(synced.boot_image_drifted?).to be false
        end
      end
    end
  end
end
