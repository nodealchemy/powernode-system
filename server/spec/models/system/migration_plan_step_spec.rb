# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::MigrationPlanStep, type: :model do
  describe "constants" do
    it "defines ACTIONS and CONFLICT_POLICIES" do
      expect(described_class::ACTIONS).to eq(%w[create link_local skip conflict])
      expect(described_class::CONFLICT_POLICIES).to eq(%w[skip_if_exists rename_with_suffix overwrite fail])
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:migration).class_name("System::Migration") }
  end

  describe "validations" do
    subject { build(:system_migration_plan_step) }

    it { is_expected.to validate_presence_of(:step_order) }
    it { is_expected.to validate_presence_of(:resource_kind) }
    it { is_expected.to validate_presence_of(:resource_id) }
    it { is_expected.to validate_inclusion_of(:action).in_array(described_class::ACTIONS) }
    it { is_expected.to validate_inclusion_of(:conflict_policy).in_array(described_class::CONFLICT_POLICIES) }

    it "enforces step_order uniqueness within a migration via DB index" do
      first = create(:system_migration_plan_step, step_order: 1)
      dup = build(:system_migration_plan_step, migration: first.migration, step_order: 1,
                                                resource_id: SecureRandom.uuid)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "scopes" do
    let(:migration) { create(:system_migration) }
    let!(:step_a) { create(:system_migration_plan_step, migration: migration, step_order: 2) }
    let!(:step_b) { create(:system_migration_plan_step, migration: migration, step_order: 1) }
    let!(:applied_step) do
      create(:system_migration_plan_step,
             migration: migration, step_order: 3, applied_at: Time.current)
    end

    it ".ordered returns by step_order ascending" do
      expect(migration.plan_steps.ordered.to_a).to eq([ step_b, step_a, applied_step ])
    end

    it ".pending excludes applied" do
      expect(migration.plan_steps.pending).to include(step_a, step_b)
      expect(migration.plan_steps.pending).not_to include(applied_step)
    end

    it ".applied returns only those with applied_at" do
      expect(migration.plan_steps.applied).to eq([ applied_step ])
    end
  end

  describe "lifecycle helpers" do
    it "#mark_applied! sets applied_at" do
      step = create(:system_migration_plan_step)
      step.mark_applied!
      expect(step.reload.applied?).to be true
    end

    it "#mark_failed! truncates very long error messages" do
      step = create(:system_migration_plan_step)
      step.mark_failed!("x" * 5000)
      expect(step.reload.error_message.length).to eq(2000)
    end
  end

  describe "account delegation" do
    it "exposes account via the migration" do
      migration = create(:system_migration)
      step = create(:system_migration_plan_step, migration: migration)
      expect(step.account).to eq(migration.account)
      expect(step.account_id).to eq(migration.account_id)
    end
  end
end
