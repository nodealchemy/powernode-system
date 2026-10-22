# frozen_string_literal: true

require "rails_helper"

# IMP-a9fa85399526 — a job may only release a concurrency lock it holds.
#
# The shared DistributedLock concern (worker/app/services/concerns/
# distributed_lock.rb) already releases with a token-checked compare-and-delete.
# These system jobs did not use it: each took its own lock with SET NX EX and
# released it with a bare DEL in an `ensure`. That broke mutual exclusion two
# ways, both driven here against real Redis:
#
#   - a STALE holder, whose lock expired mid-run and was then taken by another
#     run, deleted that newer run's lock when it finished;
#   - a run that LOST the race returned "already locked" from inside the method
#     whose `ensure` deletes the lock, so merely being refused deleted the
#     current holder's lock and admitted the next tick alongside it.
#
# The fix is the operator's: an atomic token-checked release, nothing else.
RSpec.describe "system job concurrency locks release only their own lock" do
  jobs_dir = File.expand_path("../../app/jobs", __dir__)

  # Every job here that takes its lock through acquire_lock, found by reading
  # the sources, so a new job written the old way is covered without an edit.
  single_lock_jobs = Dir[File.join(jobs_dir, "*.rb")].sort.filter_map do |path|
    source = File.read(path)
    next unless source.include?("CONCURRENCY_LOCK =")

    File.basename(path, ".rb").camelize.constantize
  end

  let(:api_client) { instance_double(BackendApiClient) }

  def lock_value(key)
    Sidekiq.redis { |c| c.get(key) }
  end

  # The jobs POST through #post or #post_no_retry; stub both the same way.
  def stub_api(&block)
    %i[post post_no_retry].each { |verb| allow(api_client).to receive(verb, &block) }
  end

  it "covers the jobs that take a concurrency lock" do
    expect(single_lock_jobs.size).to eq(11)
  end

  single_lock_jobs.each do |job_class|
    describe job_class.name do
      let(:job) { job_class.new }
      let(:key) { job_class::CONCURRENCY_LOCK }

      before do
        allow(job).to receive(:api_client).and_return(api_client)
        Sidekiq.redis { |c| c.del(key) }
      end

      after { Sidekiq.redis { |c| c.del(key) } }

      it "releases its own lock when it finishes" do
        stub_api { { "data" => {} } }

        job.execute

        expect(lock_value(key)).to be_nil
      end

      it "a stale holder cannot release the lock a newer run has taken" do
        stub_api do
          # This run's lock expires mid-call and another run takes it.
          Sidekiq.redis { |c| c.set(key, "newer-run", ex: 60) }
          { "data" => {} }
        end

        job.execute

        expect(lock_value(key)).to eq("newer-run"),
          "#{job_class.name} deleted a lock it no longer held"
      end

      it "a run refused the lock leaves the holder's lock alone" do
        stub_api { { "data" => {} } }
        Sidekiq.redis { |c| c.set(key, "current-holder", ex: 60) }

        expect(job.execute).to include(skipped: true)

        expect(lock_value(key)).to eq("current-holder"),
          "#{job_class.name} deleted the holder's lock merely by being refused it"
        expect(api_client).not_to have_received(:post)
        expect(api_client).not_to have_received(:post_no_retry)
      end
    end
  end

  describe SystemPackageEmbeddingJob do
    let(:job) { described_class.new }
    let(:repository_id) { SecureRandom.uuid }
    let(:key) { "system:pkg:embed:#{repository_id}" }

    before do
      allow(job).to receive(:api_client).and_return(api_client)
      Sidekiq.redis { |c| c.del(key) }
    end

    after { Sidekiq.redis { |c| c.del(key) } }

    it "releases its own per-repository lock when it finishes" do
      allow(api_client).to receive(:post).and_return({ "data" => { "processed" => 0, "remaining" => 0 } })

      job.execute(repository_id)

      expect(lock_value(key)).to be_nil
    end

    it "a stale holder cannot release the lock a newer run has taken" do
      allow(api_client).to receive(:post) do
        Sidekiq.redis { |c| c.set(key, "newer-run", ex: 60) }
        { "data" => { "processed" => 0, "remaining" => 0 } }
      end

      job.execute(repository_id)

      expect(lock_value(key)).to eq("newer-run")
    end

    it "a run refused the lock leaves the holder's lock alone" do
      allow(api_client).to receive(:post)
      Sidekiq.redis { |c| c.set(key, "current-holder", ex: 60) }

      expect(job.execute(repository_id)).to include(skipped: true)

      expect(lock_value(key)).to eq("current-holder")
    end
  end
end
