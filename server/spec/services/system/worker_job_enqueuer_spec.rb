# frozen_string_literal: true

require "rails_helper"

# Audit F5-12 — WorkerJobEnqueuer is a hand-rolled Sidekiq wire-protocol
# writer (raw LPUSH of the job JSON into the worker's Redis DB) that no-ops
# silently when Redis is down. Untested, any payload-shape regression would
# silently drop jobs. These specs pin the wire format, the fail-soft
# behavior, and the env-var URL override.
RSpec.describe System::WorkerJobEnqueuer do
  let(:redis) { instance_double(Redis) }

  before do
    allow(described_class).to receive(:worker_redis).and_return(redis)
    allow(redis).to receive(:sadd)
    allow(redis).to receive(:lpush)
  end

  describe ".enqueue wire format" do
    it "SADDs the queue and LPUSHes a Sidekiq-shaped payload, returning the jid" do
      jid = described_class.enqueue(
        job_class: "SystemFleetReconcileJob",
        args: [ { "account_id" => "acct-1" } ],
        queue: "ai_execution",
        retry_count: 3
      )

      expect(jid).to match(/\A[0-9a-f]{24}\z/)
      expect(redis).to have_received(:sadd).with("queues", "ai_execution")
      expect(redis).to have_received(:lpush) do |list_key, raw|
        expect(list_key).to eq("queue:ai_execution")
        payload = JSON.parse(raw)
        expect(payload).to include(
          "class" => "SystemFleetReconcileJob",
          "args"  => [ { "account_id" => "acct-1" } ],
          "queue" => "ai_execution",
          "jid"   => jid,
          "retry" => 3
        )
        expect(payload["created_at"]).to be_a(Numeric)
        expect(payload["enqueued_at"]).to be_a(Numeric)
      end
    end

    it "defaults queue and retry when omitted" do
      described_class.enqueue(job_class: "SomeJob", args: [])

      expect(redis).to have_received(:sadd).with("queues", "default")
      expect(redis).to have_received(:lpush) do |list_key, raw|
        expect(list_key).to eq("queue:default")
        expect(JSON.parse(raw)["retry"]).to eq(described_class::DEFAULT_RETRY)
      end
    end
  end

  describe ".enqueue fail-soft" do
    it "returns nil and logs (does not raise) when Redis is unreachable" do
      allow(redis).to receive(:sadd).and_raise(Redis::CannotConnectError.new("connection refused"))
      expect(Rails.logger).to receive(:error).with(/WorkerJobEnqueuer.*enqueue failed/)

      result = nil
      expect { result = described_class.enqueue(job_class: "SomeJob", args: []) }.not_to raise_error
      expect(result).to be_nil
    end
  end

  # IMP-daecbb8a050e — the enqueuer no longer carries its own address (it used
  # to read SIDEKIQ_REDIS_URL, then POWERNODE_WORKER_REDIS_URL, then a hardcoded
  # /1). It resolves through Powernode::Redis.worker_url, so it shares the
  # override precedence with the Sidekiq health checks and, in the test env,
  # the lane rewrite: an enqueue from a spec can never reach a live queue.
  describe ".worker_redis_url" do
    around do |example|
      original = described_class.instance_variable_get(:@worker_redis)
      described_class.instance_variable_set(:@worker_redis, nil)
      Powernode::Redis.instance_variable_set(:@deprecated_worker_url_env_warned, nil)
      example.run
    ensure
      described_class.instance_variable_set(:@worker_redis, original)
      Powernode::Redis.instance_variable_set(:@deprecated_worker_url_env_warned, nil)
    end

    before do
      allow(ENV).to receive(:[]).and_call_original
      # Hermetic against a parallel run (the dedicated test daemon replaces the whole URL).
      allow(ENV).to receive(:[]).with("TEST_REDIS_PORT").and_return(nil)
      allow(ENV).to receive(:[]).with("SIDEKIQ_REDIS_URL").and_return(nil)
      allow(ENV).to receive(:[]).with("POWERNODE_WORKER_REDIS_URL").and_return(nil)
    end

    let(:lane_db) { Powernode::Redis.test_worker_database }

    it "is Powernode::Redis.worker_url" do
      expect(described_class.worker_redis_url).to eq(Powernode::Redis.worker_url)
    end

    it "has no default of its own" do
      expect(described_class.const_defined?(:DEFAULT_WORKER_REDIS_URL, false)).to be(false)
    end

    it "honors POWERNODE_WORKER_REDIS_URL, on this lane's worker database in the test env" do
      allow(ENV).to receive(:[]).with("POWERNODE_WORKER_REDIS_URL").and_return("redis://alt:6379/9")

      expect(described_class.worker_redis_url).to eq("redis://alt:6379/#{lane_db}")
    end

    it "prefers POWERNODE_WORKER_REDIS_URL over the deprecated SIDEKIQ_REDIS_URL" do
      allow(ENV).to receive(:[]).with("POWERNODE_WORKER_REDIS_URL").and_return("redis://alt:6379/9")
      allow(ENV).to receive(:[]).with("SIDEKIQ_REDIS_URL").and_return("redis://sidekiq-host:6380/5")

      expect(described_class.worker_redis_url).to eq("redis://alt:6379/#{lane_db}")
    end

    it "still honors SIDEKIQ_REDIS_URL alone, as a deprecated alias" do
      allow(ENV).to receive(:[]).with("SIDEKIQ_REDIS_URL").and_return("redis://sidekiq-host:6380/5")
      allow(Rails.logger).to receive(:warn).and_call_original

      expect(described_class.worker_redis_url).to eq("redis://sidekiq-host:6380/#{lane_db}")
      expect(Rails.logger).to have_received(:warn).with(/SIDEKIQ_REDIS_URL is deprecated/)
    end

    it "never resolves onto an application database (0/1/2) in the test env" do
      expect([ 0, 1, 2 ]).not_to include(Integer(URI.parse(described_class.worker_redis_url).path.delete("/"), 10))
    end

    it "builds its client with Powernode::Redis.new_worker_client (that URL, short timeouts)" do
      allow(::Redis).to receive(:new).and_return(redis)
      allow(described_class).to receive(:worker_redis).and_call_original

      expect(described_class.worker_redis).to be(redis)

      expect(::Redis).to have_received(:new).with(
        url: Powernode::Redis.worker_url,
        connect_timeout: Powernode::Redis::WORKER_CONNECT_TIMEOUT,
        read_timeout: Powernode::Redis::WORKER_READ_TIMEOUT,
        write_timeout: Powernode::Redis::WORKER_READ_TIMEOUT
      )
    end
  end
end
