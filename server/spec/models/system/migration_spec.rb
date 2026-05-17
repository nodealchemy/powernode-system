# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Migration, type: :model do
  describe "constants" do
    it "defines OPERATIONS and STATUSES" do
      expect(described_class::OPERATIONS).to eq(%w[duplicate migrate])
      expect(described_class::STATUSES).to include("planned", "validating", "conflict", "completed", "failed")
      expect(described_class::TERMINAL_STATUSES).to eq(%w[completed failed cancelled])
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:destination_peer).class_name("System::FederationPeer").optional }
    it { is_expected.to belong_to(:initiated_by_user).class_name("User").optional }
    it { is_expected.to have_many(:plan_steps).class_name("System::MigrationPlanStep").dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:system_migration) }

    it { is_expected.to validate_inclusion_of(:operation).in_array(described_class::OPERATIONS) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_presence_of(:root_resource_kind) }
    it { is_expected.to validate_presence_of(:root_resource_id) }
  end

  describe "scopes" do
    let!(:active_one) { create(:system_migration, :validating) }
    let!(:completed)  { create(:system_migration, :completed) }
    let!(:failed)     { create(:system_migration, :failed) }
    let!(:dup)        { create(:system_migration, :duplicate) }
    let!(:mig)        { create(:system_migration, :migrate) }

    it ".active excludes terminal" do
      expect(described_class.active).to include(active_one)
      expect(described_class.active).not_to include(completed, failed)
    end

    it ".terminal includes completed + failed + cancelled" do
      expect(described_class.terminal).to include(completed, failed)
      expect(described_class.terminal).not_to include(active_one)
    end

    it ".duplicates / .migrates filter by operation" do
      expect(described_class.duplicates).to include(dup)
      expect(described_class.migrates).to include(mig)
      expect(described_class.duplicates).not_to include(mig)
    end
  end

  describe "transitions" do
    it "permits planned → validating" do
      m = build(:system_migration, status: "planned")
      expect(m.can_transition_to?(:validating)).to be true
    end

    it "permits validating → conflict / transferring / cancelled / failed" do
      m = build(:system_migration, status: "validating")
      %w[transferring conflict cancelled failed].each { |t| expect(m.can_transition_to?(t)).to be true }
    end

    it "permits conflict → validating (retry) / cancelled / failed" do
      m = build(:system_migration, status: "conflict")
      %w[validating cancelled failed].each { |t| expect(m.can_transition_to?(t)).to be true }
      expect(m.can_transition_to?(:completed)).to be false
    end

    it "marks completed/failed/cancelled as terminal" do
      %w[completed failed cancelled].each do |s|
        m = build(:system_migration, status: s)
        expect(m.terminal?).to be true
        %w[planned validating transferring].each { |t| expect(m.can_transition_to?(t)).to be false }
      end
    end
  end

  describe "#transition_to!" do
    it "stamps started_at on first move into transferring" do
      m = create(:system_migration, :validating)
      m.transition_to!(:transferring)
      expect(m.reload.started_at).to be_within(2.seconds).of(Time.current)
      expect(m.status).to eq("transferring")
    end

    it "stamps completed_at on move to completed" do
      m = create(:system_migration, :transferring)
      m.transition_to!(:applying)
      m.transition_to!(:completed)
      expect(m.reload.completed_at).to be_within(2.seconds).of(Time.current)
    end

    it "records error_message + failed_at on failed" do
      m = create(:system_migration, :validating)
      m.transition_to!(:failed, error_message: "destination NACKed")
      m.reload
      expect(m.status).to eq("failed")
      expect(m.error_message).to eq("destination NACKed")
      expect(m.failed_at).to be_within(2.seconds).of(Time.current)
    end

    it "returns false for an illegal transition" do
      m = create(:system_migration, :completed)
      expect(m.transition_to!(:validating)).to be false
      expect(m.reload.status).to eq("completed")
    end
  end

  describe "#append_audit! + #append_conflict!" do
    it "appends entries with auto-timestamps" do
      m = create(:system_migration)
      m.append_audit!("event" => "started")
      m.reload
      expect(m.audit_log.last["event"]).to eq("started")
      expect(m.audit_log.last["at"]).to be_present
    end

    it "appends conflict entries with auto-timestamps" do
      m = create(:system_migration)
      m.append_conflict!("kind" => "skill", "field" => "name", "reason" => "duplicate")
      m.reload
      expect(m.conflict_log.last["kind"]).to eq("skill")
      expect(m.conflict_log.last["at"]).to be_present
    end
  end
end
