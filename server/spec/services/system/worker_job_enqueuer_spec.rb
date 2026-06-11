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

  describe ".worker_redis_url env override" do
    around do |example|
      original = described_class.instance_variable_get(:@worker_redis)
      described_class.instance_variable_set(:@worker_redis, nil)
      example.run
      described_class.instance_variable_set(:@worker_redis, original)
    end

    it "honors SIDEKIQ_REDIS_URL first" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SIDEKIQ_REDIS_URL").and_return("redis://sidekiq-host:6380/5")
      expect(described_class.worker_redis_url).to eq("redis://sidekiq-host:6380/5")
    end

    it "falls back to POWERNODE_WORKER_REDIS_URL, then the DB-1 default" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SIDEKIQ_REDIS_URL").and_return(nil)
      allow(ENV).to receive(:[]).with("POWERNODE_WORKER_REDIS_URL").and_return("redis://alt:6379/9")
      expect(described_class.worker_redis_url).to eq("redis://alt:6379/9")

      allow(ENV).to receive(:[]).with("POWERNODE_WORKER_REDIS_URL").and_return(nil)
      expect(described_class.worker_redis_url).to eq(described_class::DEFAULT_WORKER_REDIS_URL)
    end
  end
end
