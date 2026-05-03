# frozen_string_literal: true

module System
  module Runtime
    # Atomically claims pending System::Task rows for execution.
    # Uses PostgreSQL FOR UPDATE SKIP LOCKED so concurrent dispatchers
    # never claim the same operation. Each claimed operation transitions
    # `pending → scheduled` inside the lock; the caller (typically
    # SystemOperationDispatchJob) then enqueues a per-operation worker
    # job for actual execution.
    class TaskDispatcher
      DEFAULT_BATCH_SIZE = 20

      def self.call(limit: DEFAULT_BATCH_SIZE)
        new(limit: limit).call
      end

      def initialize(limit: DEFAULT_BATCH_SIZE)
        @limit = limit
      end

      def call
        claimed_ids = []

        ::System::Task.transaction do
          pending = ::System::Task
                      .where(status: "pending")
                      .lock("FOR UPDATE SKIP LOCKED")
                      .order(created_at: :asc)
                      .limit(@limit)
                      .to_a

          pending.each do |op|
            event = build_event("scheduled", "Claimed by TaskDispatcher")
            op.update!(
              status: "scheduled",
              scheduled_at: Time.current,
              events: (op.events || []) + [ event ]
            )
            claimed_ids << op.id
          end
        end

        Result.ok(data: { claimed_ids: claimed_ids, count: claimed_ids.size })
      rescue StandardError => e
        Result.err(
          error: "TaskDispatcher failed: #{e.message}",
          data: {
            exception: e.class.name,
            backtrace: Array(e.backtrace).first(10)
          }
        )
      end

      private

      def build_event(type, message)
        {
          "type" => type,
          "message" => message,
          "timestamp" => Time.current.iso8601,
          "data" => {}
        }
      end
    end
  end
end
