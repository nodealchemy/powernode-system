# frozen_string_literal: true

require "rails_helper"

# D6 — the cross-AZ replenishment reader (InstancePoolService#pick_region_for_slot)
# skips regions marked unhealthy in pool.metadata["region_health"], but nothing
# WROTE that map. This sensor now stamps it each perception pass.
RSpec.describe System::Fleet::Sensors::InstanceStatusSensor, type: :service do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:region_healthy)   { create(:system_provider_region, account: account) }
  let(:region_unhealthy) { create(:system_provider_region, account: account) }
  let(:region_empty)     { create(:system_provider_region, account: account) }

  let(:pool) do
    System::InstancePool.create!(
      account: account, node_template: template, name: "xaz-pool-#{SecureRandom.hex(3)}",
      target_size: 3, min_size: 0, max_size: 10, lifecycle_class: "ephemeral", status: "active",
      preferred_regions: [ region_healthy.id, region_unhealthy.id, region_empty.id ]
    )
  end

  def pooled_instance(region:, heartbeat:)
    create(:system_node_instance, :running, account: account,
           provider_region: region, instance_pool_id: pool.id, pool_state: "ready",
           last_heartbeat_at: heartbeat)
  end

  describe "#sense region_health stamping" do
    before do
      pooled_instance(region: region_healthy,   heartbeat: Time.current)  # live
      pooled_instance(region: region_unhealthy, heartbeat: 1.hour.ago)    # silent
      # region_empty: intentionally has no members
      described_class.new(account: account).sense
      pool.reload
    end

    it "marks a region with a live member healthy" do
      expect(pool.metadata.dig("region_health", region_healthy.id)).to eq("healthy")
    end

    it "marks a region whose members are all silent unhealthy" do
      expect(pool.metadata.dig("region_health", region_unhealthy.id)).to eq("unhealthy")
    end

    it "marks a member-less preferred region unknown (still pickable)" do
      expect(pool.metadata.dig("region_health", region_empty.id)).to eq("unknown")
    end
  end

  it "leaves single-AZ pools (no preferred_regions) untouched" do
    single = System::InstancePool.create!(
      account: account, node_template: template, name: "single-#{SecureRandom.hex(3)}",
      target_size: 1, min_size: 0, max_size: 5, lifecycle_class: "ephemeral", status: "active"
    )
    described_class.new(account: account).sense
    expect(single.reload.metadata["region_health"]).to be_nil
  end
end
