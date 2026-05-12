# frozen_string_literal: true

module System
  # Server-side helper for enqueueing Sidekiq worker jobs from Rails code
  # without depending on the Sidekiq gem.
  #
  # The server doesn't run Sidekiq — the worker process does — and the
  # Sidekiq gem isn't in the server's Gemfile. But the wire format is just
  # JSON in Redis: LPUSH queue:<name> of `{class, args, jid, created_at,
  # retry, enqueued_at}` plus SADD queues <name>. That's it.
  #
  # Use this from PackageRepositorySyncService, controllers, rake tasks —
  # anywhere on the server that needs to dispatch work to the worker.
  # Falls back to a logged no-op if Redis is unreachable rather than
  # raising, so a Redis hiccup doesn't break the calling code path
  # (the worker job's job, not the enqueuer's, is to be idempotent).
  module WorkerJobEnqueuer
    DEFAULT_QUEUE = "default"
    DEFAULT_RETRY = 2
    # Worker uses Redis DB 1 by convention (server is DB 0, ActionCable DB 2).
    # Override via SIDEKIQ_REDIS_URL or POWERNODE_WORKER_REDIS_URL env vars
    # so deployments with non-standard Redis can point at the right place.
    DEFAULT_WORKER_REDIS_URL = "redis://localhost:6379/1"

    module_function

    # Enqueue `job_class` with `args` to the named queue. Returns the JID
    # on success, nil on failure (logged).
    def enqueue(job_class:, args:, queue: DEFAULT_QUEUE, retry_count: DEFAULT_RETRY)
      redis = worker_redis
      jid   = SecureRandom.hex(12)
      now   = Time.current.to_f
      payload = {
        "class"       => job_class.to_s,
        "args"        => args,
        "queue"       => queue,
        "jid"         => jid,
        "created_at"  => now,
        "enqueued_at" => now,
        "retry"       => retry_count
      }.to_json
      redis.sadd("queues", queue)
      redis.lpush("queue:#{queue}", payload)
      jid
    rescue StandardError => e
      Rails.logger.error("[WorkerJobEnqueuer] #{job_class} enqueue failed: #{e.class}: #{e.message}")
      nil
    end

    # Lazy-initialized per-process client to the worker's Redis. Distinct
    # from Powernode::Redis.client (server DB 0) — the worker process
    # reads from its own DB.
    def worker_redis
      @worker_redis ||= ::Redis.new(url: worker_redis_url)
    end

    def worker_redis_url
      ENV["SIDEKIQ_REDIS_URL"] || ENV["POWERNODE_WORKER_REDIS_URL"] || DEFAULT_WORKER_REDIS_URL
    end
  end
end
