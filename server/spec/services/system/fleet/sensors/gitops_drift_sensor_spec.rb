# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Fleet::Sensors::GitopsDriftSensor do
  let(:account) { create(:account) }
  let(:sensor) { described_class.new(account: account) }

  let!(:repo) do
    ::System::GitopsRepository.create!(
      account: account, name: "drift-test",
      repo_url: "https://example.com/repo.git", branch: "main",
      enabled: true
    )
  end

  describe "#sense" do
    it "emits a signal when latest sync_run reports diff_count > 0" do
      ::System::GitopsSyncRun.create!(
        gitops_repository: repo,
        started_at: 10.minutes.ago,
        completed_at: 5.minutes.ago,
        status: "success",
        diff_count: 3,
        diff_summary: { "create" => 2, "update" => 1 },
        synced_revision: "abc123"
      )

      signals = sensor.sense
      expect(signals.size).to eq(1)
      expect(signals.first[:kind]).to eq("system.gitops.drift_detected")
      expect(signals.first[:severity]).to eq(:medium)
      expect(signals.first[:payload][:diff_count]).to eq(3)
      expect(signals.first[:fingerprint]).to include(repo.id, "abc123")
    end

    it "returns no signals when latest sync_run has zero diffs" do
      ::System::GitopsSyncRun.create!(
        gitops_repository: repo,
        started_at: 10.minutes.ago,
        completed_at: 5.minutes.ago,
        status: "success",
        diff_count: 0
      )

      expect(sensor.sense).to be_empty
    end

    it "ignores still-running syncs" do
      ::System::GitopsSyncRun.create!(
        gitops_repository: repo,
        started_at: 1.minute.ago,
        status: "running",
        diff_count: 0
      )

      expect(sensor.sense).to be_empty
    end

    it "ignores stale sync_runs (>24h old)" do
      ::System::GitopsSyncRun.create!(
        gitops_repository: repo,
        started_at: 2.days.ago,
        completed_at: 2.days.ago + 1.minute,
        status: "success",
        diff_count: 5
      )

      expect(sensor.sense).to be_empty
    end

    it "rates many diffs as high severity" do
      ::System::GitopsSyncRun.create!(
        gitops_repository: repo,
        started_at: 5.minutes.ago,
        completed_at: 2.minutes.ago,
        status: "success",
        diff_count: 25,
        diff_summary: { "create" => 25 }
      )

      expect(sensor.sense.first[:severity]).to eq(:high)
    end

    it "rates destroy-class changes as high severity" do
      ::System::GitopsSyncRun.create!(
        gitops_repository: repo,
        started_at: 5.minutes.ago,
        completed_at: 2.minutes.ago,
        status: "success",
        diff_count: 2,
        diff_summary: { "destroy" => 2 }
      )

      expect(sensor.sense.first[:severity]).to eq(:high)
    end

    it "ignores disabled repositories" do
      repo.update!(enabled: false)
      ::System::GitopsSyncRun.create!(
        gitops_repository: repo,
        started_at: 5.minutes.ago,
        completed_at: 2.minutes.ago,
        status: "success",
        diff_count: 5
      )

      expect(sensor.sense).to be_empty
    end

    it "scopes to current account" do
      other_account = create(:account)
      other_repo = ::System::GitopsRepository.create!(
        account: other_account, name: "other",
        repo_url: "https://example.com/other.git", branch: "main"
      )
      ::System::GitopsSyncRun.create!(
        gitops_repository: other_repo,
        started_at: 5.minutes.ago,
        completed_at: 2.minutes.ago,
        status: "success",
        diff_count: 99
      )

      expect(sensor.sense).to be_empty
    end
  end
end
