# frozen_string_literal: true

require "rails_helper"

# Audit F5-05 — the gated pool-maintenance executors had zero spec
# coverage. They are dispatched by STRING class name from
# instance_pools_controller (gate! executor_class:), so a rename or typo
# is invisible until runtime — every spec here resolves the exact string
# the controller passes.
RSpec.describe System::Executors::InstancePool::CreatePool do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }
  let(:deferred_operation) { double("Ai::DeferredOperation", account: account) }

  let(:attributes) do
    {
      name: "warm-pool",
      target_size: 3,
      min_size: 1,
      max_size: 5,
      lifecycle_class: "ephemeral",
      status: "active",
      node_template_id: node_template.id,
      provider_region_id: provider_region.id,
      provider_instance_type_id: provider_instance_type.id
    }
  end

  it "is resolvable from the exact string the controller dispatches" do
    expect("System::Executors::InstancePool::CreatePool".constantize)
      .to eq(described_class)
  end

  describe ".execute" do
    it "creates the pool under the deferred operation's account" do
      result = described_class.execute({ attributes: attributes },
                                       deferred_operation: deferred_operation)

      expect(result[:success]).to be true
      pool = System::InstancePool.find(result[:data][:pool_id])
      expect(pool.account_id).to eq(account.id)
      expect(result[:data][:name]).to eq("warm-pool")
      expect(result[:data][:target_size]).to eq(3)
    end

    it "raises on invalid attributes (gate surfaces the failure, no silent half-create)" do
      expect {
        described_class.execute({ attributes: attributes.merge(name: "") },
                                deferred_operation: deferred_operation)
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(System::InstancePool.count).to eq(0)
    end
  end

  describe ".preview" do
    it "summarizes the pool name and capacity impact" do
      preview = described_class.preview({ attributes: attributes })

      expect(preview[:summary]).to include("warm-pool")
      expect(preview[:impact]).to match(/capacity/i)
    end
  end
end
