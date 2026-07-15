# frozen_string_literal: true

require "rails_helper"

# Skill: package_repository_sync — enqueues a background sync (async). It must
# NOT run the minutes-long sync inline (would block the autonomy loop / trip the
# puma RSS recycler); it marks the repo syncing and hands off to the worker job.
RSpec.describe System::Ai::Skills::PackageRepositorySyncExecutor do
  let(:account) { create(:account) }
  let(:exec)    { described_class.new(account: account) }
  let!(:repo)   { create(:system_package_repository, account: account) }

  before { allow(::System::WorkerJobEnqueuer).to receive(:enqueue) }

  describe ".descriptor" do
    it "declares an async (queued) devops skill" do
      d = described_class.descriptor
      expect(d[:name]).to eq("package_repository_sync")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:outputs, :queued)).to eq(:boolean)
    end
  end

  describe "#execute" do
    it "enqueues a background sync and never calls the service inline" do
      expect(::System::PackageRepositorySyncService).not_to receive(:call)

      r = exec.execute(repository_id: repo.id)

      expect(r[:success]).to be true
      expect(repo.reload.sync_status).to eq("syncing")
      expect(::System::WorkerJobEnqueuer).to have_received(:enqueue).with(
        hash_including(job_class: "SystemPackageRepositorySyncJob")
      )
    end

    it "fails cleanly for an unknown / inaccessible repository" do
      r = exec.execute(repository_id: SecureRandom.uuid)
      expect(r[:success]).to be false
    end
  end
end
