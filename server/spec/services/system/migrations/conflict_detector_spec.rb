# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Migrations::ConflictDetector, type: :service do
  let(:account) { create(:account) }
  let(:migration) { create(:system_migration, account: account) }

  describe ".scan!" do
    it "returns no conflicts when destination has no matching rows" do
      step = migration.plan_steps.create!(
        step_order: 0,
        resource_kind: "user",
        resource_id: SecureRandom.uuid,
        action: "create",
        conflict_policy: "fail",
        payload: { "email" => "unique-#{SecureRandom.hex}@example.com",
                   "first_name" => "Alice" }
      )
      result = described_class.scan!(migration: migration)
      expect(result.ok?).to be true
      expect(result.conflict_count).to eq(0)
    end

    it "detects a unique-constraint collision on User.email" do
      existing = create(:user, account: account, email: "collide@example.com")
      step = migration.plan_steps.create!(
        step_order: 0,
        resource_kind: "user",
        resource_id: SecureRandom.uuid,
        action: "create",
        conflict_policy: "rename_with_suffix",
        payload: { "email" => "collide@example.com" }
      )
      result = described_class.scan!(migration: migration)
      expect(result.conflict_count).to eq(1)
      conflict = result.conflicts.first
      expect(conflict["resource_kind"]).to eq("user")
      expect(conflict["columns"]).to include("email")
      expect(conflict["conflicting_record_id"]).to eq(existing.id)
      expect(conflict["suggested_policy"]).to eq("rename_with_suffix")
    end

    it "ignores collisions where the conflict would be the source record itself" do
      user = create(:user, account: account, email: "self@example.com")
      step = migration.plan_steps.create!(
        step_order: 0,
        resource_kind: "user",
        resource_id: user.id,  # same id — self-collision
        action: "create",
        conflict_policy: "fail",
        payload: { "email" => "self@example.com" }
      )
      result = described_class.scan!(migration: migration)
      expect(result.conflict_count).to eq(0)
    end

    it "skips steps with empty payload" do
      migration.plan_steps.create!(
        step_order: 0,
        resource_kind: "user",
        resource_id: SecureRandom.uuid,
        action: "create",
        conflict_policy: "fail",
        payload: {}
      )
      result = described_class.scan!(migration: migration)
      expect(result.conflict_count).to eq(0)
    end

    it "skips steps where action != 'create'" do
      _existing = create(:user, account: account, email: "collide2@example.com")
      migration.plan_steps.create!(
        step_order: 0,
        resource_kind: "user",
        resource_id: SecureRandom.uuid,
        action: "link_local",  # not "create"
        conflict_policy: "fail",
        payload: { "email" => "collide2@example.com" }
      )
      result = described_class.scan!(migration: migration)
      expect(result.conflict_count).to eq(0)
    end

    it "appends conflicts to migration.conflict_log" do
      create(:user, account: account, email: "conflictlog@example.com")
      migration.plan_steps.create!(
        step_order: 0,
        resource_kind: "user",
        resource_id: SecureRandom.uuid,
        action: "create",
        conflict_policy: "fail",
        payload: { "email" => "conflictlog@example.com" }
      )
      described_class.scan!(migration: migration)
      migration.reload
      expect(migration.conflict_log.size).to eq(1)
      audit = migration.audit_log
      expect(audit.last["event"]).to eq("conflicts_detected")
    end
  end
end
