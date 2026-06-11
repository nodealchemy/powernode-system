# frozen_string_literal: true

require "rails_helper"

# Audit F5-05 — ReplenishPool guarded its delegate with
# `pool.respond_to?(:replenish!)`, but replenish! lives on
# InstancePoolService (class method, pool: kwarg), NOT on the model.
# The guard was always false, so the gated replenish operation reported
# success with replenished: 0 and never provisioned anything.
RSpec.describe System::Executors::InstancePool::ReplenishPool do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }
  let(:deferred_operation) { double("Ai::DeferredOperation", account: account) }

  let(:pool) do
    System::InstancePool.create!(
      account: account,
      node_template: node_template,
      name: "replenish-target",
      target_size: 3,
      min_size: 1,
      max_size: 5,
      lifecycle_class: "ephemeral",
      status: "active",
      provider_region: provider_region,
      provider_instance_type: provider_instance_type
    )
  end

  before do
    # Same stub pattern as instance_pool_service_spec.rb — provisioning
    # dispatches to the cloud adapter chain, so return a successful
    # Runtime::Result with a fresh stub instance per call.
    allow(::System::ProvisioningService).to receive(:provision_instance) do |node:, **|
      stub_instance = create(:system_node_instance,
                             node: node,
                             name: "warm-#{SecureRandom.hex(3)}",
                             variety: "cloud",
                             status: "pending",
                             provider_region: provider_region,
                             provider_instance_type: provider_instance_type)
      ::System::Runtime::Result.ok(data: { instance: stub_instance })
    end
  end

  it "is resolvable from the exact string the controller dispatches" do
    expect("System::Executors::InstancePool::ReplenishPool".constantize)
      .to eq(described_class)
  end

  describe ".execute" do
    it "provisions warming members up to target_size and reports the count" do
      result = described_class.execute({ pool_id: pool.id },
                                       deferred_operation: deferred_operation)

      expect(result[:success]).to be true
      expect(result[:data][:replenished]).to eq(3)
      expect(pool.reload.warming_count).to eq(3)
    end

    it "is a no-op when the pool is already at capacity" do
      described_class.execute({ pool_id: pool.id }, deferred_operation: deferred_operation)

      result = described_class.execute({ pool_id: pool.id },
                                       deferred_operation: deferred_operation)

      expect(result[:data][:replenished]).to eq(0)
      expect(pool.reload.warming_count).to eq(3)
    end

    it "raises for a paused pool (gate surfaces the refusal)" do
      pool.update!(status: "paused")

      expect {
        described_class.execute({ pool_id: pool.id }, deferred_operation: deferred_operation)
      }.to raise_error(System::InstancePoolService::PoolNotActiveError)
    end
  end
end
