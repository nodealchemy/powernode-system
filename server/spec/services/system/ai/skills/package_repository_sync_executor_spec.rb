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

    # IMP-c90ba4ec46da — `force` is NOT a declared descriptor input, but
    # #perform declares it as a keyword and BaseSkillExecutor#acceptable_inputs
    # slices the caller's inputs to the keywords perform declares — so a
    # composed plan step carrying a `force` key reaches it. `accessible_to`
    # admits every shared repo, and force switches OFF the sync service's
    # mass-obsoletion guard, so the forced path on a SHARED repo needs
    # manage_shared. Oracle: nothing is enqueued (the enqueue is the last
    # observable act before the worker obsoletes rows).
    context "force gating" do
      let!(:shared) { create(:system_package_repository, :shared) }

      it "refuses (and enqueues nothing) when the caller cannot manage shared repos" do
        r = described_class.new(account: account).execute(repository_id: shared.id, force: true)

        expect(::System::WorkerJobEnqueuer).not_to have_received(:enqueue)
        expect(r[:success]).to be false
        expect(shared.reload.sync_status).not_to eq("syncing")
      end

      it "positive control: a manage_shared holder CAN force" do
        sharer = create(:user, account: account,
                        permissions: %w[system.package_repositories.manage_shared])

        r = described_class.new(account: account, user: sharer).execute(repository_id: shared.id, force: true)

        expect(r[:success]).to be true
        expect(::System::WorkerJobEnqueuer).to have_received(:enqueue).with(
          hash_including(job_class: "SystemPackageRepositorySyncJob", args: [ shared.id, { "force" => true } ])
        )
      end

      it "still enqueues an UNFORCED sync of a shared repo" do
        r = described_class.new(account: account).execute(repository_id: shared.id)

        expect(r[:success]).to be true
        expect(::System::WorkerJobEnqueuer).to have_received(:enqueue).with(
          hash_including(job_class: "SystemPackageRepositorySyncJob", args: [ shared.id, { "force" => false } ])
        )
      end

      it "still lets an ACCOUNT-SCOPED repo be forced (blast radius is the owner's own catalog)" do
        r = described_class.new(account: account).execute(repository_id: repo.id, force: true)

        expect(r[:success]).to be true
        expect(::System::WorkerJobEnqueuer).to have_received(:enqueue).with(
          hash_including(job_class: "SystemPackageRepositorySyncJob", args: [ repo.id, { "force" => true } ])
        )
      end
    end

    it "fails cleanly for an unknown / inaccessible repository" do
      r = exec.execute(repository_id: SecureRandom.uuid)
      expect(r[:success]).to be false
    end
  end
end
