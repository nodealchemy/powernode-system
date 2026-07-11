# frozen_string_literal: true

require "rails_helper"

# Campaign 019f505f increment 4 — UpgradeDispatcher guards all dispatch paths
# (operator MCP tool + fleet drift rollout executor) via fail-closed security
# chain (guards: platform / promoted image / standalone UKI / cosign pubkey /
# UKI cosign bundle). Returns a Result struct (upgraded/task/reason/already_current/
# deduplicated/target_git_sha, with #ok? == reason.nil?).
RSpec.describe System::BootImage::UpgradeDispatcher do
  let(:account) { create(:account) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform_record) }
  let(:node) { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:user) { create(:user, account: account) }
  let(:cosign_public_key_pem) do
    "-----BEGIN PUBLIC KEY-----\n" \
    "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEzKyqKWW5nHvyLMYqwP5xPeOXDw" \
    "tz+sKlxGqKcvK9I5CDLQQRi8S6X8L6kqJMPj7pZ9nFNqnCwHGh/JFVRqZDjA==\n" \
    "-----END PUBLIC KEY-----"
  end

  def setup_platform(target_sha: "target-sha", oki_ref: "oki-ref", uki_ref: "uki-ref", uki_sha256: "sha256:uki")
    platform_record.update!(
      disk_image_git_sha: target_sha,
      disk_image_oci_ref: oki_ref,
      disk_image_uki_oci_ref: uki_ref,
      disk_image_uki_sha256: uki_sha256
    )
  end

  def setup_publication(target_sha: "target-sha", oki_ref: "oki-ref", bundle: "base64_bundle")
    System::DiskImagePublication.create!(
      account: account,
      node_platform: platform_record,
      git_sha: target_sha,
      arch: "amd64",
      oci_ref: oki_ref,
      sha256: "#{'a' * 64}",
      size_bytes: 1024,
      uki_cosign_bundle: bundle
    )
  end

  describe ".dispatch!" do
    describe "fail-closed guards" do
      it "returns err when instance has no resolvable platform" do
        # Create a mock instance with node returning nil for node_platform
        mock_instance = instance_double("System::NodeInstance", node: nil, booted_image_git_sha: nil)
        mock_instance.extend(Module.new { define_method(:id) { "test-id" } })

        result = described_class.dispatch!(instance: mock_instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/no resolvable node platform/)
        expect(result.upgraded).to be false
        expect(result.task).to be_nil
      end

      it "returns err when platform has no promoted disk_image_git_sha" do
        platform_record.update!(disk_image_git_sha: nil, disk_image_oci_ref: "ref")

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/no promoted disk image/)
        expect(result.upgraded).to be false
      end

      it "returns err when platform has no promoted disk_image_oci_ref" do
        platform_record.update!(disk_image_git_sha: "sha-abc", disk_image_oci_ref: nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/no promoted disk image/)
      end

      it "returns err when platform has no standalone UKI artifact (disk_image_uki_oci_ref blank)" do
        setup_platform(uki_ref: nil, uki_sha256: nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/no standalone UKI artifact/)
        expect(result.reason).to match(/republish/)
      end

      it "returns err when ENV POWERNODE_COSIGN_PUBLIC_KEY is unset" do
        setup_platform
        setup_publication

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/cosign public key/)
        expect(result.reason).to match(/not configured/)
      end

      it "returns err when promoted publication has no uki_cosign_bundle" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        System::DiskImagePublication.create!(
          account: account,
          node_platform: platform_record,
          git_sha: target_sha,
          arch: "amd64",
          oci_ref: "test-oci-ref",
          sha256: "#{'b' * 64}",
          size_bytes: 1024,
          uki_cosign_bundle: nil
        )

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/no UKI cosign signature bundle/)
      end
    end

    describe "already_current guard" do
      it "returns already_current:true when booted sha equals target sha and !force" do
        matching_sha = "shared-sha-abc123"
        setup_platform(target_sha: matching_sha)
        setup_publication(target_sha: matching_sha)
        instance.update!(booted_image_git_sha: matching_sha)

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: false)

        expect(result.ok?).to be true
        expect(result.upgraded).to be false
        expect(result.already_current).to be true
        expect(result.reason).to be_nil
        expect(result.task).to be_nil
        expect(result.target_git_sha).to eq(matching_sha)
        expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(0)
      end

      it "creates a task when already_current but force:true" do
        matching_sha = "shared-sha-abc123"
        setup_platform(target_sha: matching_sha)
        setup_publication(target_sha: matching_sha)
        instance.update!(booted_image_git_sha: matching_sha)

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: true)

        expect(result.ok?).to be true
        expect(result.upgraded).to be true
        expect(result.task).to be_present
        expect(result.target_git_sha).to eq(matching_sha)
        expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(1)
      end
    end

    describe "deduplication guard" do
      it "returns deduplicated:true when an in-flight pending task exists and !force" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha)

        existing_task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          initiated_by: user
        )

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: false)

        expect(result.ok?).to be true
        expect(result.upgraded).to be false
        expect(result.deduplicated).to be true
        expect(result.task).to eq(existing_task)
        expect(result.target_git_sha).to eq(target_sha)
        expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(1)
      end

      it "returns deduplicated:true when an in-flight scheduled task exists" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha)

        existing_task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "scheduled",
          initiated_by: user
        )

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: false)

        expect(result.deduplicated).to be true
        expect(result.task).to eq(existing_task)
      end

      it "returns deduplicated:true when an in-flight running task exists" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha)

        existing_task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "running",
          initiated_by: user
        )

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: false)

        expect(result.deduplicated).to be true
        expect(result.task).to eq(existing_task)
      end

      it "creates a new task when force:true, bypassing dedup" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha)

        existing_task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          initiated_by: user
        )

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: true)

        expect(result.upgraded).to be true
        expect(result.task).to be_present
        expect(result.task.id).not_to eq(existing_task.id)
        expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(2)
      end

      it "creates a new task when a completed task exists (dedup only in-flight)" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha)

        completed_task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "complete",
          initiated_by: user
        )

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: false)

        expect(result.upgraded).to be true
        expect(result.task).to be_present
        expect(result.task.id).not_to eq(completed_task.id)
        expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(2)
      end
    end

    describe "happy path" do
      it "creates a pending upgrade_boot_image task with all options populated" do
        target_sha = "target-sha-xyz"
        oki_ref = "ghcr.io/nodealchemy/system/boot:0.1.0"
        uki_ref = "ghcr.io/nodealchemy/system/boot-uki:0.1.0"
        uki_sha256 = "sha256:uki_abc"
        cosign_bundle_b64 = "LS0tLS1CRUdJTiBQR1AgU0lHTkVEIE1FU1NBR0UtLS0tLQo="

        setup_platform(target_sha: target_sha, oki_ref: oki_ref, uki_ref: uki_ref, uki_sha256: uki_sha256)
        setup_publication(target_sha: target_sha, oki_ref: oki_ref, bundle: cosign_bundle_b64)

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "fleet_rollout", initiated_by: user)

        expect(result.ok?).to be true
        expect(result.upgraded).to be true
        expect(result.task).to be_present
        expect(result.target_git_sha).to eq(target_sha)

        task = result.task
        expect(task).to have_attributes(
          command: "upgrade_boot_image",
          status: "pending",
          operable_type: "System::NodeInstance",
          operable_id: instance.id,
          account_id: account.id,
          initiated_by_id: user.id
        )

        expect(task.options).to include(
          "target_git_sha"       => target_sha,
          "uki_oci_ref"          => uki_ref,
          "uki_sha256"           => uki_sha256,
          "cosign_public_key"    => cosign_public_key_pem,
          "cosign_bundle_b64"    => cosign_bundle_b64,
          "download_path"        => "/api/v1/system/node_api/boot_image/download",
          "source"               => "fleet_rollout",
          "triggered_by_user_id" => user.id
        )
        expect(task.options["triggered_at"]).to be_present
      end

      it "initializes booted_image_git_sha absent from the instance" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha)
        instance.update!(booted_image_git_sha: nil)

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be true
        expect(result.upgraded).to be true
        expect(result.task).to be_present
      end
    end

    describe "#platform_cosign_public_key" do
      it "reads from ENV POWERNODE_COSIGN_PUBLIC_KEY when set" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        key = described_class.platform_cosign_public_key

        expect(key).to eq(cosign_public_key_pem)
      end

      it "returns nil when ENV unset and file path missing" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        key = described_class.platform_cosign_public_key

        expect(key).to be_nil
      end

      it "returns nil when file path does not exist" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return("/nonexistent/path")

        key = described_class.platform_cosign_public_key

        expect(key).to be_nil
      end

      it "reads from ENV POWERNODE_COSIGN_PUBLIC_KEY_FILE path when ENV unset" do
        key_content = "file-based-key-content"
        tmpfile = Tempfile.new("cosign_key")
        tmpfile.write(key_content)
        tmpfile.flush

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(tmpfile.path)

        key = described_class.platform_cosign_public_key

        expect(key).to eq(key_content)

        tmpfile.close
        tmpfile.unlink
      end
    end
  end

  describe "Result struct" do
    it "#ok? returns true when reason is nil" do
      result = described_class::Result.new(upgraded: true, task: nil, reason: nil)
      expect(result.ok?).to be true
    end

    it "#ok? returns false when reason is present" do
      result = described_class::Result.new(upgraded: false, reason: "some error")
      expect(result.ok?).to be false
    end
  end

  describe ".platform_blocker" do
    it "returns nil when all preflight checks pass" do
      target_sha = "target-sha"
      setup_platform(target_sha: target_sha)
      setup_publication(target_sha: target_sha)

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to be_nil
    end

    it "returns reason when platform is nil" do
      blocker = described_class.platform_blocker(nil)

      expect(blocker).to match(/no resolvable node platform/)
    end

    it "returns reason when disk_image_git_sha is blank" do
      platform_record.update!(disk_image_git_sha: nil, disk_image_oci_ref: "ref")

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to match(/no promoted disk image/)
    end

    it "returns reason when disk_image_oki_ref is blank" do
      platform_record.update!(disk_image_git_sha: "sha", disk_image_oci_ref: nil)

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to match(/no promoted disk image/)
    end

    it "returns reason when disk_image_uki_oci_ref is blank" do
      target_sha = "target-sha"
      platform_record.update!(
        disk_image_git_sha: target_sha,
        disk_image_oci_ref: "ref",
        disk_image_uki_oci_ref: nil
      )

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to match(/no standalone UKI artifact/)
    end

    it "returns reason when cosign public key is unset" do
      setup_platform
      setup_publication

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to match(/cosign public key/)
    end

    it "returns reason when uki_cosign_bundle is missing" do
      target_sha = "target-sha"
      setup_platform(target_sha: target_sha)
      System::DiskImagePublication.create!(
        account: account,
        node_platform: platform_record,
        git_sha: target_sha,
        arch: "amd64",
        oci_ref: "oki-ref",
        sha256: "#{'c' * 64}",
        size_bytes: 1024,
        uki_cosign_bundle: nil
      )

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to match(/cosign signature bundle/)
    end
  end
end
