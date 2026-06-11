# frozen_string_literal: true

require "rails_helper"

# Audit F4-06 — creating an image from an instance on a provider without an
# image surface (local_qemu) raised NotImplementedError mid-mission. The
# capability gate must refuse with a structured result before dispatching.
RSpec.describe System::ImageCreationService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) do
    # cloud_instance_id is a store_accessor into config, not a column
    create(:system_node_instance, :running, node: node, cloud_instance_id: "vm-123")
  end
  let(:adapter) do
    instance_double("System::Providers::BaseProvider", provider_type: "local_qemu")
  end

  before do
    allow(System::Providers::Registry).to receive(:with_adapter)
      .with(instance: instance).and_yield(adapter)
  end

  describe "#create_from_instance" do
    it "returns a structured error when the provider lacks image support" do
      allow(adapter).to receive(:supports?).with(:images).and_return(false)
      allow(adapter).to receive(:create_image)

      result = described_class.new.create_from_instance(instance: instance, name: "img-1")

      expect(result.success?).to be false
      expect(result.error).to match(/does not support image/i)
      expect(adapter).not_to have_received(:create_image)
    end

    # F4-09 — cloud-side happy + provider-error paths were uncovered.
    it "creates the image and remembers it on the instance config" do
      allow(adapter).to receive(:supports?).with(:images).and_return(true)
      allow(adapter).to receive(:create_image)
        .with("vm-123", name: "img-1", description: nil)
        .and_return({ success: true, image_id: "ami-9", status: "pending" })

      result = described_class.new.create_from_instance(instance: instance, name: "img-1")

      expect(result.success?).to be true
      expect(result.data[:image_id]).to eq("ami-9")
    end

    it "propagates a provider failure (e.g. image quota) as a structured error" do
      allow(adapter).to receive(:supports?).with(:images).and_return(true)
      allow(adapter).to receive(:create_image)
        .and_return({ success: false, error: "image quota exceeded" })

      result = described_class.new.create_from_instance(instance: instance, name: "img-1")

      expect(result.success?).to be false
      expect(result.error).to eq("image quota exceeded")
    end
  end

  # F4-09 — the local-synthesis arm (architecture -> bootable image on the
  # platform host) had zero coverage; its error paths (unsupported format,
  # missing host binaries, upload failure) must return structured errors,
  # never raise out of a mission step.
  describe "#create_from_architecture (local synthesis)" do
    let(:architecture) { create(:system_node_architecture) }
    let(:service) { described_class.new }

    it "rejects an unsupported image format" do
      result = service.create_from_architecture(architecture: architecture, format: "wim")

      expect(result.success?).to be false
      expect(result.error).to match(/unsupported image format/i)
    end

    it "returns a structured error when required host binaries are missing" do
      allow(service).to receive(:missing_binaries).with("qcow2").and_return(%w[qemu-img])

      result = service.create_from_architecture(architecture: architecture, format: "qcow2")

      expect(result.success?).to be false
      expect(result.error).to match(/missing required binaries.*qemu-img/i)
    end

    it "propagates an upload failure (e.g. storage quota) without linking the architecture" do
      allow(service).to receive(:missing_binaries).and_return([])
      allow(service).to receive(:build_raw_image).and_return(1024)
      allow(service).to receive(:upload_image)
        .and_return(System::Runtime::Result.err(error: "storage quota exceeded"))
      allow(service).to receive(:link_to_architecture)

      result = service.create_from_architecture(architecture: architecture, format: "img")

      expect(result.success?).to be false
      expect(result.error).to eq("storage quota exceeded")
      expect(service).not_to have_received(:link_to_architecture)
    end
  end
end
