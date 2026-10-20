# frozen_string_literal: true

require "rails_helper"

# IMP-f127c3f21e27 -- census of the retired image-creation paths.
#
# Images are generic per platform (memory:image-distribution-model); per-instance
# snapshots and per-architecture image builds are outside the model. Everything
# that created images was unreachable (the internal/system family has no routes)
# or reachable only through a provider image API nothing called. This spec pins
# that those symbols stay gone, so a future author cannot quietly re-wire them.
RSpec.describe "retired image-creation paths" do
  it "no longer defines System::ImageCreationService" do
    expect(defined?(System::ImageCreationService)).to be_nil
    expect { "System::ImageCreationService".constantize }.to raise_error(NameError)
  end

  it "removes the internal/system controllers' image and public-ip actions" do
    if defined?(Api::V1::Internal::System::NodeInstancesController)
      klass = Api::V1::Internal::System::NodeInstancesController
      %w[create_image associate_public_ip disassociate_public_ip].each do |action|
        expect(klass.instance_methods(false).map(&:to_s)).not_to include(action)
      end
    end
    expect(defined?(Api::V1::Internal::System::NodeArchitecturesController)).to be_nil
  end

  it "routes no request to internal/system create_image or the public-ip doors" do
    paths = %w[node_instances node_architectures].product(%w[create_image associate_public_ip disassociate_public_ip])
    paths.each do |resource, action|
      expect {
        Rails.application.routes.recognize_path(
          "/api/v1/internal/system/#{resource}/#{SecureRandom.uuid}/#{action}", method: :post
        )
      }.to raise_error(ActionController::RoutingError)
    end
  end

  describe "provider image API" do
    let(:image_methods) { %i[create_image get_image delete_image] }

    it "is gone from BaseProvider and every adapter" do
      providers = [ System::Providers::BaseProvider ] +
                  System::Providers::BaseProvider.descendants
      expect(providers.size).to be > 5
      providers.each do |klass|
        image_methods.each do |m|
          expect(klass.instance_methods(false)).not_to include(m), "#{klass}##{m} still defined"
        end
      end
    end

    it "does not declare an :images capability" do
      expect(System::Providers::BaseProvider::CAPABILITIES).not_to include(:images)
      System::Providers::BaseProvider.descendants.each do |klass|
        consts = klass.const_defined?(:CAPABILITIES) ? klass::CAPABILITIES : []
        expect(consts).not_to include(:images), "#{klass} still declares :images"
      end
    end

    it "no longer documents the Images table in the adapter authoring guide" do
      guide = Rails.root.join("..", "docs", "PROVIDER_ADAPTER_AUTHORING.md")
      guide = Pathname.new(File.expand_path("../../../../docs/PROVIDER_ADAPTER_AUTHORING.md", __dir__)) unless guide.exist?
      skip "guide not found" unless guide.exist?
      expect(guide.read).not_to match(/`(create|get|delete)_image`/)
    end
  end
end
