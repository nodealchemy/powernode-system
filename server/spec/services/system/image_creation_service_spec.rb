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
  end
end
