# frozen_string_literal: true

require "rails_helper"

# IMP-1f0996aa7fa3 — dead CI builder rows are collected by the reaper, on a
# clock no observer resets, a window the operator sets, and only on the churn
# planes.
#
# The pool reaper already prunes dead members (prune_dead_records!), but it
# measured death by `updated_at`, which observers keep writing. The hourly
# CloudSyncService#sync_region_instances writes last_synced_at on every row whose
# provider id is still listed, whatever its status — a presumed-dead row whose
# VM is still up, or one whose recycled VMID now names another guest — so a dead
# row's age kept restarting. On 2026-09-13 the CI plane held
# 150 builder rows (134 terminated, 12 error), 61 of them silent for longer than
# the 7-day window, against an operator target of 2-3.
#
# OPERATOR DIRECTION: purge through the existing reaper seam, scoped to the
# ci/ephemeral tier, retention window is a SiteSetting, never purge a row in a
# protected plane automatically.
RSpec.describe System::InstancePoolService, "dead record retention clock" do
  let(:account) { create(:account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }

  def template_in(slug)
    create(:system_node_template, account: account, environment: account.environments.find_by!(slug: slug))
  end

  def pool_in(slug)
    System::InstancePool.create!(
      account: account, node_template: template_in(slug), name: "pool-#{slug}-#{SecureRandom.hex(2)}",
      target_size: 0, min_size: 0, max_size: 5,
      lifecycle_class: "ephemeral", status: "active",
      provider_region: provider_region, provider_instance_type: provider_instance_type
    )
  end

  # A pool member whose sign-of-life columns are set explicitly. `died` is the
  # default for each; `touched` is its row's last write by anyone. `plane` puts
  # the member's own Node on another plane than the pool's.
  def dead_member(pool, died:, touched: died, status: "terminated", pool_state: "draining", plane: nil,
                  heartbeat: died, warming: died, created: died, acquired: nil)
    template = plane ? template_in(plane) : pool.node_template
    node = create(:system_node, account: account, node_template: template,
                                config: { "instance_pool_id" => pool.id })
    member = create(:system_node_instance,
                    node: node, name: "member-#{SecureRandom.hex(3)}", variety: "cloud",
                    provider_region: provider_region, provider_instance_type: provider_instance_type,
                    instance_pool_id: pool.id, pool_state: pool_state)
    member.merge_config!("provider_guest_name" => member.name)
    member.update_columns(status: status, created_at: created, updated_at: touched,
                          pool_warming_started_at: warming, last_heartbeat_at: heartbeat,
                          pool_acquired_at: acquired)
    member
  end

  def kept?(member) = System::NodeInstance.where(id: member.id).exists?

  before do
    allow(::System::ProvisioningService).to receive(:terminate_instance)
      .and_return(::System::Runtime::Result.ok)
  end

  describe "the clock" do
    it "collects a member silent past the window although an observer wrote its row an hour ago" do
      pool = pool_in("ci")
      member = dead_member(pool, died: 30.days.ago, touched: 1.hour.ago)

      counts = described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(false)
      expect(counts[:records_pruned]).to eq(1)
    end

    it "keeps a member that showed life inside the window, however old its row's last write" do
      pool = pool_in("ci")
      member = dead_member(pool, died: 1.hour.ago, touched: 30.days.ago)

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(true)
      expect(::System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    it "collects a member that never heartbeated, warmed or was claimed, by its creation" do
      pool = pool_in("ci")
      member = dead_member(pool, died: 30.days.ago, heartbeat: nil, warming: nil, acquired: nil)

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(false)
    end

    # Each sign of life on its own, so dropping any one of them is caught.
    {
      "a recent heartbeat" => { heartbeat: 1.hour.ago },
      "a recent claim" => { acquired: 1.hour.ago },
      "a recent warm start" => { warming: 1.hour.ago, heartbeat: nil },
      "a recent creation" => { created: 1.hour.ago, warming: nil, heartbeat: nil }
    }.each do |label, fresh|
      it "counts #{label} alone as life" do
        pool = pool_in("ci")
        member = dead_member(pool, died: 30.days.ago, touched: 30.days.ago, **fresh)

        described_class.recycle_stale_members!(pool: pool)

        expect(kept?(member)).to be(true)
      end
    end
  end

  # The claimed arms flag and never terminate (F1-10). A claimed member the
  # reaper marked `error` for silence may still be running under its consumer,
  # and collecting its record means a provider terminate of that guest.
  describe "a claimed member" do
    it "is never collected while it is in error" do
      pool = pool_in("ci")
      member = dead_member(pool, died: 30.days.ago, status: "error", pool_state: "claimed", acquired: 30.days.ago)

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(true)
      expect(::System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    it "is collected once it is terminated" do
      pool = pool_in("ci")
      member = dead_member(pool, died: 30.days.ago, status: "terminated", pool_state: "claimed", acquired: 30.days.ago)

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(false)
    end
  end

  describe "the window" do
    it "is read from the SiteSetting" do
      SiteSetting.set("system.instance_pool.dead_record_retention_days", "60")
      pool = pool_in("ci")
      member = dead_member(pool, died: 30.days.ago)

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(true)
    end

    it "yields to a per-pool override" do
      SiteSetting.set("system.instance_pool.dead_record_retention_days", "60")
      pool = pool_in("ci")
      pool.update!(metadata: pool.metadata.merge("record_retention_days" => 3))
      member = dead_member(pool, died: 10.days.ago)

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(false)
    end

    it "keeps the 7-day default when the SiteSetting is absent" do
      pool = pool_in("ci")
      inside = dead_member(pool, died: 6.days.ago)
      outside = dead_member(pool, died: 8.days.ago)

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(inside)).to be(true)
      expect(kept?(outside)).to be(false)
    end

    it "keeps the default for a SiteSetting that is not a whole number, rather than disabling pruning" do
      SiteSetting.set("system.instance_pool.dead_record_retention_days", "a week")
      pool = pool_in("ci")
      member = dead_member(pool, died: 8.days.ago)

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(false)
    end

    it "disables pruning for a SiteSetting of 0" do
      SiteSetting.set("system.instance_pool.dead_record_retention_days", "0")
      pool = pool_in("ci")
      member = dead_member(pool, died: 30.days.ago)

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(true)
    end
  end

  describe "the plane" do
    it "never purges a member on a protected plane, even from a pool on a churn plane" do
      pool = pool_in("ci")
      member = dead_member(pool, died: 30.days.ago, plane: "ops")

      counts = described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(true)
      expect(System::Node.where(id: member.node_id)).to exist
      expect(::System::ProvisioningService).not_to have_received(:terminate_instance)
      expect(counts[:records_pruned]).to eq(0)
    end

    # The tier filter alone would keep ops and prod; an operator can also
    # protect a churn-tier plane, and only the plane's own rules catch that.
    it "keeps a member on a churn-tier plane an operator has protected" do
      account.environments.find_by!(slug: "dev").update_columns(is_protected: true)
      pool = pool_in("ci")
      member = dead_member(pool, died: 30.days.ago, plane: "dev")

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(true)
      expect(::System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    it "keeps a member above the churn tier even where the plane is not protected" do
      pool = pool_in("ci")
      member = dead_member(pool, died: 30.days.ago, plane: "staging")

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(true)
    end

    it "keeps a member with no plane recorded" do
      pool = pool_in("ci")
      member = dead_member(pool, died: 30.days.ago)
      member.update_columns(environment_id: nil)

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(member)).to be(true)
    end

    it "still purges the churn-plane members beside a protected one" do
      pool = pool_in("ci")
      protected_member = dead_member(pool, died: 30.days.ago, plane: "prod")
      churn_member = dead_member(pool, died: 30.days.ago, plane: "dev")

      described_class.recycle_stale_members!(pool: pool)

      expect(kept?(churn_member)).to be(false)
      expect(kept?(protected_member)).to be(true)
    end

    it "never collects a pool Node shell on a protected plane" do
      pool = pool_in("ci")
      shell = create(:system_node, account: account, node_template: template_in("ops"),
                                   config: { "instance_pool_id" => pool.id })
      shell.update_columns(updated_at: 30.days.ago)

      counts = described_class.recycle_stale_members!(pool: pool)

      expect(System::Node.where(id: shell.id)).to exist
      expect(counts[:node_shells_pruned]).to eq(0)
    end
  end
end
