# frozen_string_literal: true

require "rails_helper"

# GPU-aware pool scheduling (audit P6) — a pool's accelerator capability
# derives from its bound provider_instance_type SKU.
RSpec.describe System::InstancePool, type: :model do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }

  def itype(**attrs)
    create(:system_provider_instance_type, account: account, **attrs)
  end

  def pool(instance_type)
    described_class.create!(
      account: account,
      name: "pool-#{SecureRandom.hex(4)}",
      node_template_id: template.id,
      provider_instance_type: instance_type,
      target_size: 1, min_size: 0, max_size: 2
    )
  end

  describe "GPU scopes" do
    let!(:cpu_pool)  { pool(itype(gpu_count: 0)) }
    let!(:l40_pool)  { pool(itype(gpu_count: 1, gpu_type: "L40S", gpu_memory_mb: 49_152)) }
    let!(:h100_pool) { pool(itype(gpu_count: 8, gpu_type: "H100", gpu_memory_mb: 81_920)) }

    it ".with_gpu returns only pools bound to a GPU SKU" do
      expect(described_class.where(account_id: account.id).with_gpu).to contain_exactly(l40_pool, h100_pool)
    end

    it ".by_gpu filters by accelerator type (case-insensitive)" do
      expect(described_class.where(account_id: account.id).by_gpu("h100")).to contain_exactly(h100_pool)
    end

    it ".by_gpu honors a minimum GPU count" do
      expect(described_class.where(account_id: account.id).by_gpu(nil, min_count: 2)).to contain_exactly(h100_pool)
    end
  end
end
