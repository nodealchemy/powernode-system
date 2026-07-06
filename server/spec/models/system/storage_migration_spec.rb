# frozen_string_literal: true

require "rails_helper"

# Increment 9 (campaign 019f3458) — revert_binding! (R) / cleanup (C).
# Covers reachability rules, metadata persistence (prior_binding at
# promote, promote_failed on rescue, cutover_diverged on mark_failed!
# from cutover), and the cleanup grace-window resolution (default →
# SiteSetting → Account#settings override).
RSpec.describe System::StorageMigration, type: :model do
  let(:account)        { create(:account) }
  let(:nfs_volume_type) { create(:system_provider_volume_type, account: account, volume_type: "nfs", name: "nfs-pool") }
  let(:source_volume) do
    create(:system_provider_volume, account: account, volume_type: nfs_volume_type, name: "vol-a",
                                     config: { "nfs" => { "server" => "nas1", "export_path" => "/v1/Powernode" } })
  end
  let(:target_volume) do
    create(:system_provider_volume, account: account, volume_type: nfs_volume_type, name: "vol-b",
                                     config: { "nfs" => { "server" => "nas2", "export_path" => "/v2/Powernode" } })
  end
  let(:instance) { create(:system_node_instance, account: account) }

  def build_migration(status:, **attrs)
    described_class.create!(
      {
        account: account, node_instance: instance,
        source_volume: source_volume, target_volume: target_volume,
        role: "postgres", status: status,
        source_subpath: "deployments/test/postgres",
        target_subpath: "deployments/test/postgres",
        snapshot_subpath: "migrations/2026/test/postgres",
        plan: {}
      }.merge(attrs)
    )
  end

  describe "#promote_target_binding! (metadata persistence)" do
    it "persists the pre-promotion binding into metadata[prior_binding] before mutating node_instance" do
      instance.update!(config: { "storage_volume" => { "volume_id" => source_volume.id, "mount_point" => "/var/lib/postgresql" } })
      m = build_migration(status: "cutover")

      m.transition_to!("completed")

      expect(m.reload.metadata["prior_binding"]).to include("volume_id" => source_volume.id, "mount_point" => "/var/lib/postgresql")
    end

    it "sets metadata[promote_failed] and leaves node_instance untouched when the node_instance update raises" do
      instance.update!(config: { "storage_volume" => { "volume_id" => source_volume.id } })
      m = build_migration(status: "cutover")
      allow_any_instance_of(System::NodeInstance).to receive(:update!).and_raise(StandardError, "boom")

      m.transition_to!("completed")

      m.reload
      expect(m.metadata["promote_failed"]).to be true
      expect(m.metadata["promote_error"]).to eq("boom")
      expect(m.metadata["prior_binding"]).to be_present
      expect(instance.reload.config.dig("storage_volume", "volume_id")).to eq(source_volume.id)
    end
  end

  describe "#mark_failed! (cutover-divergence discrimination)" do
    it "flags metadata[cutover_diverged] when failing from status=cutover" do
      m = build_migration(status: "cutover")
      m.mark_failed!(reason: "agent crashed mid-remount")

      m.reload
      expect(m.status).to eq("failed")
      expect(m.metadata["cutover_diverged"]).to be true
      expect(m.metadata["cutover_diverged_at"]).to be_present
    end

    it "does NOT flag cutover_diverged when failing from an earlier phase (mount never touched)" do
      m = build_migration(status: "syncing")
      m.mark_failed!(reason: "rsync exited 23")

      expect(m.reload.metadata["cutover_diverged"]).to be_nil
    end
  end

  describe "#can_revert_binding? / #revert_binding!" do
    it "is reachable from failed" do
      m = build_migration(status: "failed", failed_at: Time.current, error_message: "boom")
      expect(m.can_revert_binding?).to be true
    end

    it "is reachable from completed only when promote_failed" do
      completed_clean = build_migration(status: "completed", completed_at: Time.current)
      expect(completed_clean.can_revert_binding?).to be false

      completed_promote_failed = build_migration(status: "completed", completed_at: Time.current,
                                                   metadata: { "promote_failed" => true })
      expect(completed_promote_failed.can_revert_binding?).to be true
    end

    it "is NOT reachable from an active (non-terminal) status" do
      m = build_migration(status: "syncing")
      expect(m.can_revert_binding?).to be false
      expect { m.revert_binding!(reason: "test") }.to raise_error(ArgumentError, /Cannot revert binding/)
    end

    it "records intent + audit entry, keyed to the requesting user" do
      user = create(:user, account: account)
      m = build_migration(status: "failed", failed_at: Time.current)

      m.revert_binding!(reason: "diverged mount", user: user)

      m.reload
      expect(m.metadata["revert_status"]).to eq("requested")
      expect(m.metadata["revert_requested_by_user_id"]).to eq(user.id)
      expect(m.audit_log.last["message"]).to include("Revert-to-source requested")
    end

    it "revert_completed! records one audit entry per artifact and marks metadata completed" do
      m = build_migration(status: "failed", failed_at: Time.current)
      m.revert_binding!(reason: nil, user: nil)

      m.revert_completed!(artifacts: [ { "path" => "a:/x/deployments/foo/postgres", "mount_point" => "/var/lib/postgresql" } ])

      m.reload
      expect(m.metadata["revert_status"]).to eq("completed")
      expect(m.metadata["reverted_at"]).to be_present
      expect(m.audit_log.last["message"]).to include("a:/x/deployments/foo/postgres")
    end
  end

  describe "#can_cleanup? / #request_cleanup!" do
    it "is reachable from failed" do
      m = build_migration(status: "failed", failed_at: Time.current)
      expect(m.can_cleanup?).to be true
    end

    it "is reachable from cancelled only once preparing was reached" do
      early_cancel = build_migration(status: "cancelled", cancelled_at: Time.current)
      expect(early_cancel.can_cleanup?).to be false

      post_preparing_cancel = build_migration(status: "cancelled", cancelled_at: Time.current, started_at: 1.hour.ago)
      expect(post_preparing_cancel.can_cleanup?).to be true
    end

    it "is NOT reachable from completed (target data is live, not partial)" do
      m = build_migration(status: "completed", completed_at: Time.current)
      expect(m.can_cleanup?).to be false
    end

    it "refuses to request cleanup before the grace window elapses" do
      m = build_migration(status: "failed", failed_at: 1.hour.ago)
      expect {
        m.request_cleanup!(grace_hours: 24)
      }.to raise_error(ArgumentError, /grace window not yet elapsed/i)
    end

    it "allows immediate: true to bypass the grace window" do
      m = build_migration(status: "failed", failed_at: Time.current)
      expect { m.request_cleanup!(grace_hours: 24, immediate: true) }.not_to raise_error
      expect(m.reload.metadata["cleanup_status"]).to eq("requested")
      expect(m.metadata["cleanup_immediate"]).to be true
    end

    it "allows the request once the grace window has elapsed" do
      m = build_migration(status: "failed", failed_at: 25.hours.ago)
      expect { m.request_cleanup!(grace_hours: 24) }.not_to raise_error
    end

    it "cleanup_completed! records one audit entry per artifact, naming already_clean artifacts" do
      m = build_migration(status: "failed", failed_at: Time.current)
      m.request_cleanup!(grace_hours: 24, immediate: true)

      m.cleanup_completed!(artifacts: [
        { "label" => "target_subpath", "path" => "b:/y/deployments/foo/postgres", "already_clean" => false },
        { "label" => "snapshot_subpath", "path" => "", "already_clean" => true }
      ])

      m.reload
      expect(m.metadata["cleanup_status"]).to eq("completed")
      expect(m.metadata["cleaned_at"]).to be_present
      messages = m.audit_log.last(2).map { |e| e["message"] }
      expect(messages).to include(a_string_matching("b:/y/deployments/foo/postgres"))
      expect(messages).to include(a_string_matching(/already clean/))
    end
  end

  describe "System::StorageMigration.cleanup_grace_hours (config-driven-config resolution)" do
    it "defaults to DEFAULT_CLEANUP_GRACE_HOURS when nothing is configured" do
      expect(described_class.cleanup_grace_hours(account: account)).to eq(described_class::DEFAULT_CLEANUP_GRACE_HOURS)
    end

    it "prefers the SiteSetting global default over the hardcoded default" do
      SiteSetting.set(described_class::CLEANUP_GRACE_HOURS_SETTING_KEY, "6", setting_type: "integer")
      expect(described_class.cleanup_grace_hours(account: account)).to eq(6)
    end

    it "prefers the Account#settings override over the SiteSetting global default" do
      SiteSetting.set(described_class::CLEANUP_GRACE_HOURS_SETTING_KEY, "6", setting_type: "integer")
      account.update!(settings: { described_class::CLEANUP_GRACE_HOURS_SETTING_KEY => 48 })
      expect(described_class.cleanup_grace_hours(account: account)).to eq(48)
    end
  end
end
