# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::NodeApi::RuntimeConfigBuilder do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node) { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  describe ".build" do
    describe "docker runtime" do
      it "includes boot_image block when platform has disk_image_git_sha" do
        git_sha = "abc123def456"
        oci_ref = "registry.example.com/powernode:abc123"
        sha256 = "def456abc123"

        platform.update!(
          disk_image_git_sha: git_sha,
          disk_image_oci_ref: oci_ref,
          disk_image_sha256: sha256
        )

        result = described_class.build(runtime: "docker", instance: instance)

        expect(result[:boot_image]).to be_present
        expect(result[:boot_image][:git_sha]).to eq(git_sha)
        expect(result[:boot_image][:oci_ref]).to eq(oci_ref)
        expect(result[:boot_image][:sha256]).to eq(sha256)
      end

      it "omits boot_image when platform has no disk_image_git_sha" do
        platform.update!(disk_image_git_sha: nil, disk_image_oci_ref: nil, disk_image_sha256: nil)

        result = described_class.build(runtime: "docker", instance: instance)

        expect(result).not_to have_key(:boot_image)
      end

      it "includes other docker config fields alongside boot_image" do
        platform.update!(
          disk_image_git_sha: "test-sha",
          disk_image_oci_ref: "ref",
          disk_image_sha256: "sha256"
        )

        result = described_class.build(runtime: "docker", instance: instance)

        expect(result[:runtime]).to eq("docker")
        expect(result).to have_key(:daemon_overrides)
        expect(result).to have_key(:content_hash)
        expect(result).to have_key(:boot_image)
      end
    end

    describe "k3s_server runtime" do
      it "includes boot_image block when platform has disk_image_git_sha" do
        git_sha = "xyz789uvw012"
        oci_ref = "registry.example.com/powernode:xyz789"
        sha256 = "uvw012xyz789"

        platform.update!(
          disk_image_git_sha: git_sha,
          disk_image_oci_ref: oci_ref,
          disk_image_sha256: sha256
        )

        result = described_class.build(runtime: "k3s_server", instance: instance)

        expect(result[:boot_image]).to be_present
        expect(result[:boot_image][:git_sha]).to eq(git_sha)
        expect(result[:boot_image][:oci_ref]).to eq(oci_ref)
        expect(result[:boot_image][:sha256]).to eq(sha256)
      end

      it "omits boot_image when platform has no disk_image_git_sha" do
        platform.update!(disk_image_git_sha: nil)

        result = described_class.build(runtime: "k3s_server", instance: instance)

        expect(result).not_to have_key(:boot_image)
      end

      it "includes k3s bootstrap_config fields alongside boot_image" do
        platform.update!(
          disk_image_git_sha: "test-sha",
          disk_image_oci_ref: "ref",
          disk_image_sha256: "sha256"
        )

        result = described_class.build(runtime: "k3s_server", instance: instance)

        expect(result[:runtime]).to eq("k3s_server")
        expect(result).to have_key(:bootstrap_config)
        expect(result).to have_key(:content_hash)
        expect(result).to have_key(:boot_image)
      end
    end

    describe "unknown/empty runtime" do
      it "includes boot_image block when platform has disk_image_git_sha" do
        platform.update!(
          disk_image_git_sha: "test-sha",
          disk_image_oci_ref: "test-ref",
          disk_image_sha256: "test-256"
        )

        result = described_class.build(runtime: "unknown", instance: instance)

        expect(result[:boot_image]).to be_present
        expect(result[:boot_image][:git_sha]).to eq("test-sha")
        expect(result[:boot_image][:oci_ref]).to eq("test-ref")
        expect(result[:boot_image][:sha256]).to eq("test-256")
      end

      it "omits boot_image when platform has no disk_image_git_sha" do
        platform.update!(disk_image_git_sha: nil)

        result = described_class.build(runtime: "unknown", instance: instance)

        expect(result).not_to have_key(:boot_image)
      end

      it "still includes other empty-runtime fields" do
        platform.update!(disk_image_git_sha: nil)

        result = described_class.build(runtime: "unknown", instance: instance)

        expect(result[:runtime]).to eq("unknown")
        expect(result).to have_key(:daemon_overrides)
        expect(result).to have_key(:content_hash)
      end
    end

    describe "boot_image presence conditions" do
      it "requires all three disk_image_* fields to be present" do
        platform.update!(
          disk_image_git_sha: "sha",
          disk_image_oci_ref: nil,
          disk_image_sha256: nil
        )

        result = described_class.build(runtime: "docker", instance: instance)

        expect(result[:boot_image]).to be_present
      end

      it "omits boot_image when only oci_ref is present" do
        platform.update!(
          disk_image_git_sha: nil,
          disk_image_oci_ref: "ref",
          disk_image_sha256: nil
        )

        result = described_class.build(runtime: "docker", instance: instance)

        expect(result).not_to have_key(:boot_image)
      end

      it "omits boot_image when git_sha is blank string" do
        platform.update!(
          disk_image_git_sha: "",
          disk_image_oci_ref: "ref",
          disk_image_sha256: "sha"
        )

        result = described_class.build(runtime: "docker", instance: instance)

        expect(result).not_to have_key(:boot_image)
      end
    end

    describe "node/platform chain resolution" do
      it "correctly reads from instance.node.node_platform" do
        git_sha = "chain-test-sha"
        platform.update!(disk_image_git_sha: git_sha)

        result = described_class.build(runtime: "docker", instance: instance)

        expect(result[:boot_image][:git_sha]).to eq(git_sha)
      end

      it "safely handles missing platform disk_image_git_sha values" do
        new_platform = create(:system_node_platform, account: account, disk_image_git_sha: nil)
        new_template = create(:system_node_template, account: account, node_platform: new_platform)
        new_node = create(:system_node, account: account, node_template: new_template)
        new_instance = create(:system_node_instance, :running, node: new_node)

        result = described_class.build(runtime: "docker", instance: new_instance)

        expect(result).not_to have_key(:boot_image)
      end

      it "reads from a different platform correctly" do
        other_platform = create(:system_node_platform, account: account, disk_image_git_sha: "other-sha")
        other_template = create(:system_node_template, account: account, node_platform: other_platform)
        other_node = create(:system_node, account: account, node_template: other_template)
        other_instance = create(:system_node_instance, :running, node: other_node)

        result = described_class.build(runtime: "docker", instance: other_instance)

        expect(result[:boot_image][:git_sha]).to eq("other-sha")
      end
    end

    describe "boot_image block structure" do
      it "returns exact three-key structure: git_sha, oci_ref, sha256" do
        platform.update!(
          disk_image_git_sha: "git-value",
          disk_image_oci_ref: "oci-value",
          disk_image_sha256: "sha256-value"
        )

        result = described_class.build(runtime: "docker", instance: instance)
        boot_image = result[:boot_image]

        expect(boot_image.keys.sort).to eq([ :git_sha, :oci_ref, :sha256 ].sort)
        expect(boot_image[:git_sha]).to eq("git-value")
        expect(boot_image[:oci_ref]).to eq("oci-value")
        expect(boot_image[:sha256]).to eq("sha256-value")
      end
    end

    describe "runtime-independent behavior" do
      it "returns same boot_image for docker and k3s_server" do
        platform.update!(
          disk_image_git_sha: "same-sha",
          disk_image_oci_ref: "same-ref",
          disk_image_sha256: "same-256"
        )

        docker_result = described_class.build(runtime: "docker", instance: instance)
        k3s_result = described_class.build(runtime: "k3s_server", instance: instance)

        expect(docker_result[:boot_image]).to eq(k3s_result[:boot_image])
      end

      it "omits boot_image uniformly for all runtimes when git_sha is absent" do
        platform.update!(disk_image_git_sha: nil)

        docker_result = described_class.build(runtime: "docker", instance: instance)
        k3s_result = described_class.build(runtime: "k3s_server", instance: instance)
        unknown_result = described_class.build(runtime: "unknown", instance: instance)

        expect(docker_result).not_to have_key(:boot_image)
        expect(k3s_result).not_to have_key(:boot_image)
        expect(unknown_result).not_to have_key(:boot_image)
      end
    end
  end

  describe "integration with instance and platform data" do
    it "handles multiple instances with the same platform correctly" do
      inst1 = create(:system_node_instance, :running, node: node)
      inst2_node = create(:system_node, account: account, node_template: template)
      inst2 = create(:system_node_instance, :running, node: inst2_node)

      platform.update!(
        disk_image_git_sha: "platform-sha",
        disk_image_oci_ref: "platform-ref",
        disk_image_sha256: "platform-256"
      )

      result1 = described_class.build(runtime: "docker", instance: inst1)
      result2 = described_class.build(runtime: "docker", instance: inst2)

      expect(result1[:boot_image][:git_sha]).to eq("platform-sha")
      expect(result2[:boot_image][:git_sha]).to eq("platform-sha")
    end
  end
end
