# frozen_string_literal: true

require "rails_helper"

# HIER-P2F — the Disk Image Manager's retention skill. Thin over
# System::Executors::DiskImage::UpdateRetention, gated on the agent's own
# `system.disk_image_retention_update` row (declared auto_approve: GC config,
# reversible), so the row — not the descriptor — decides whether it runs.
RSpec.describe System::Ai::Skills::DiskImageRetentionExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account, disk_image_retention_count: 3) }
  let(:exec)     { described_class.new(account: account) }

  describe ".descriptor" do
    it "gates on the Disk Image Manager's declared retention category and binds to that agent" do
      d = described_class.descriptor
      expect(d[:name]).to eq("disk_image_retention")
      expect(d[:requires_approval]).to be true
      expect(d[:inputs].keys).to contain_exactly(:platform_id, :retention_count)

      expect(described_class.action_category).to eq("system.disk_image_retention_update")
      expect(System::Governance::PolicyDeclarations::DISK_IMAGE_MANAGER_POLICIES)
        .to have_key(described_class.action_category)

      reg = System::Ai::Skills::SkillBindings.all.find { |r| r[:executor] == described_class }
      expect(reg[:agents]).to eq([ "disk-image-manager" ])
    end
  end

  describe "#execute (policy auto-executes)" do
    before { auto_execute_skill_policy!(account, described_class) }

    it "updates the platform's retention count" do
      r = exec.execute(platform_id: platform.id, retention_count: 5)

      expect(r[:success]).to be true
      expect(r.dig(:data, :retention_count)).to eq(5)
      expect(r.dig(:data, :previous_retention_count)).to eq(3)
      expect(platform.reload.disk_image_retention_count).to eq(5)
    end

    it "refuses a count below 1 without touching the platform" do
      r = exec.execute(platform_id: platform.id, retention_count: 0)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/retention_count must be/)
      expect(platform.reload.disk_image_retention_count).to eq(3)
    end

    it "surfaces the model's upper bound as a failure" do
      r = exec.execute(platform_id: platform.id, retention_count: 500)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/less than or equal to 50/)
      expect(platform.reload.disk_image_retention_count).to eq(3)
    end

    it "refuses a platform that belongs to another account" do
      foreign = create(:system_node_platform, disk_image_retention_count: 3)

      r = exec.execute(platform_id: foreign.id, retention_count: 5)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found/)
      expect(foreign.reload.disk_image_retention_count).to eq(3)
    end
  end

  describe "the approval gate" do
    it "parks the update (no write) when no policy auto-executes it" do
      r = exec.execute(platform_id: platform.id, retention_count: 5)

      expect(r[:pending]).to be true
      expect(platform.reload.disk_image_retention_count).to eq(3)
    end
  end

  # HIER-P2F review — admission runs BEFORE the approval gate. No auto-execute
  # policy here: a bound check left in #perform would park a deferred operation
  # for an update that can only fail on replay.
  describe "admission before the approval gate" do
    it "refuses a foreign platform without parking an approval" do
      foreign = create(:system_node_platform, disk_image_retention_count: 3)

      r = exec.execute(platform_id: foreign.id, retention_count: 5)

      expect(r[:success]).to be false
      expect(r[:pending]).to be_falsey
      expect(r[:error]).to match(/not found/)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end

    it "refuses a count below 1 without parking an approval" do
      r = exec.execute(platform_id: platform.id, retention_count: 0)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/retention_count must be/)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end

    it "refuses a count past the model bound without parking an approval" do
      r = exec.execute(platform_id: platform.id, retention_count: 500)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/less than or equal to 50/)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
      expect(platform.reload.disk_image_retention_count).to eq(3)
    end
  end

end
