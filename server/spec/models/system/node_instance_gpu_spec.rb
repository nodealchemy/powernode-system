# frozen_string_literal: true

require "rails_helper"

# GPU/accelerator resolution (audit P6): prefer the bound provider_instance_type
# SKU, then fall back to the agent-reported config["gpu"] hint.
RSpec.describe System::NodeInstance, type: :model do
  let(:account) { create(:account) }

  def instance(type_attrs: { gpu_count: 0 }, config: {})
    create(
      :system_node_instance,
      account: account,
      provider_instance_type: create(:system_provider_instance_type, account: account, **type_attrs),
      config: config
    )
  end

  describe "GPU capability" do
    it "resolves GPU from the provider_instance_type SKU" do
      i = instance(type_attrs: { gpu_count: 2, gpu_type: "A100", gpu_memory_mb: 40_960 })
      expect(i.gpu?).to be(true)
      expect(i.gpu_count).to eq(2)
      expect(i.gpu_type).to eq("A100")
      expect(i.gpu_memory_mb).to eq(40_960)
    end

    it "falls back to the config['gpu'] agent hint when the SKU has none" do
      i = instance(config: { "gpu" => { "count" => 1, "type" => "RTX4090", "memory_mb" => 24_576 } })
      expect(i.gpu?).to be(true)
      expect(i.gpu_count).to eq(1)
      expect(i.gpu_type).to eq("RTX4090")
      expect(i.gpu_memory_mb).to eq(24_576)
    end

    it "prefers the SKU over the config hint" do
      i = instance(type_attrs: { gpu_count: 2, gpu_type: "A100" },
                   config: { "gpu" => { "count" => 1, "type" => "RTX4090" } })
      expect(i.gpu_count).to eq(2)
      expect(i.gpu_type).to eq("A100")
    end

    it "reports no GPU when neither source has one" do
      i = instance
      expect(i.gpu?).to be(false)
      expect(i.gpu_count).to eq(0)
      expect(i.gpu_type).to be_nil
      expect(i.gpu_memory_mb).to be_nil
    end
  end
end
