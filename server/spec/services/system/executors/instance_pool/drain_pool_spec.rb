# frozen_string_literal: true

require "rails_helper"

# Audit F5-05 — DrainPool guarded its delegate with
# `pool.respond_to?(:drain!)`, but drain! lives on InstancePoolService
# (class method, pool: kwarg), NOT on the model. The guard was always
# false, so the gated drain operation reported success with drained: 0
# while leaving every ready member running.
RSpec.describe System::Executors::InstancePool::DrainPool do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }
  let(:deferred_operation) { double("Ai::DeferredOperation", account: account) }

  let(:pool) do
    System::InstancePool.create!(
      account: account,
      node_template: node_template,
      name: "drain-target",
      target_size: 3,
      min_size: 0,
      max_size: 5,
      lifecycle_class: "ephemeral",
      status: "active",
      provider_region: provider_region,
      provider_instance_type: provider_instance_type
    )
  end

  def seed_pool_member(state:, acquired_at: nil)
    node = create(:system_node, account: account, node_template: node_template,
                                lifecycle_class: "ephemeral")
    create(:system_node_instance,
           node: node,
           name: "member-#{SecureRandom.hex(3)}",
           variety: "cloud",
           status: state == "ready" ? "running" : "pending",
           provider_region: provider_region,
           provider_instance_type: provider_instance_type,
           instance_pool_id: pool.id,
           pool_state: state,
           pool_warming_started_at: 1.minute.ago,
           pool_acquired_at: acquired_at)
  end

  before do
    allow(::System::ProvisioningService).to receive(:terminate_instance)
      .and_return(::System::Runtime::Result.ok(data: {}))
  end

  it "is resolvable from the exact string the controller dispatches" do
    expect("System::Executors::InstancePool::DrainPool".constantize)
      .to eq(described_class)
  end

  describe ".execute" do
    let!(:ready_one) { seed_pool_member(state: "ready") }
    let!(:ready_two) { seed_pool_member(state: "ready") }
    let!(:claimed)   { seed_pool_member(state: "claimed", acquired_at: 5.minutes.ago) }

    it "terminates ready members, reports the count, and sets the pool draining" do
      result = described_class.execute({ pool_id: pool.id },
                                       deferred_operation: deferred_operation)

      expect(result[:success]).to be true
      expect(result[:data][:drained]).to eq(2)
      expect(pool.reload.status).to eq("draining")
      expect(ready_one.reload.pool_state).to eq("draining")
      expect(ready_two.reload.pool_state).to eq("draining")
      expect(::System::ProvisioningService).to have_received(:terminate_instance).twice
    end

    it "never touches claimed members — live workloads survive the drain" do
      described_class.execute({ pool_id: pool.id }, deferred_operation: deferred_operation)

      expect(claimed.reload.pool_state).to eq("claimed")
      expect(::System::ProvisioningService)
        .not_to have_received(:terminate_instance).with(instance: claimed)
    end
  end
end
