# frozen_string_literal: true

require "securerandom"
require "json"

module System
  # Pushes Sidekiq-formatted jobs directly to the worker's Redis queue.
  #
  # The platform server does NOT bundle the sidekiq gem (per platform rule:
  # workers run in a separate process; server is API-only). This helper
  # pushes raw JSON to Redis using the `redis` gem (which IS in the server's
  # Gemfile) so the standalone worker's Sidekiq picks the job up via its
  # normal queue mechanism. No Sidekiq client gem needed on the server side.
  #
  # Job format reference: https://github.com/sidekiq/sidekiq/wiki/Job-Format
  #
  # Used by Operation#after_commit on :create — when a pending operation is
  # created, this helper pushes a SystemExecuteTaskJob entry to Redis
  # which the worker process then claims via BRPOP.
  class WorkerDispatch
    DEFAULT_QUEUE = "system"

    # @param class_name [String] worker job class to invoke (must exist worker-side)
    # @param args [Array] arguments forwarded to the worker job's execute(*args)
    # @param queue [String] Sidekiq queue name
    # @param retry_count [Boolean, Integer] sidekiq_options retry value (false = no retries)
    # @return [String] jid (Sidekiq job ID, 24-char hex) of the enqueued job
    def self.enqueue(class_name, args:, queue: DEFAULT_QUEUE, retry_count: false)
      payload = {
        "class" => class_name,
        "args" => Array(args),
        "queue" => queue,
        "retry" => retry_count,
        "jid" => SecureRandom.hex(12),
        "created_at" => Time.current.to_f,
        "enqueued_at" => Time.current.to_f
      }

      with_redis do |conn|
        conn.sadd("queues", queue)
        conn.lpush("queue:#{queue}", JSON.generate(payload))
      end

      payload["jid"]
    end

    # Convenience wrapper: enqueue the operation executor for a specific op.
    # @param operation_id [String] UUID of the System::Task to execute
    # @return [String] sidekiq jid
    def self.enqueue_operation_execution(operation_id)
      enqueue("SystemExecuteTaskJob", args: [operation_id])
    end

    def self.with_redis
      conn = Redis.new(url: redis_url)
      yield conn
    ensure
      conn&.close
    end

    # Default to redis://localhost:6379/1 to match the worker's default
    # (worker/config/application.rb). Override via REDIS_URL env var.
    def self.redis_url
      ENV.fetch("REDIS_URL", "redis://localhost:6379/1")
    end
  end
end
