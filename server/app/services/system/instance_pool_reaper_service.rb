# frozen_string_literal: true

module System
  # Audit plan P2.5 gap #4 — periodic reaper that walks every active
  # InstancePool and runs the recycle + replenish cycle. Without this,
  # operators had to manually call InstancePoolService.recycle_stale_members!
  # + .replenish! per pool, which doesn't scale past a handful of pools.
  #
  # Invoked from the worker via SystemInstancePoolReaperJob (separate from
  # this class so the worker layer stays HTTP-only; this service does the
  # actual DB work). Recommended cadence: every 60s, mirrored on the same
  # tick as SystemFleetReconcileJob.
  #
  # Per pool, the reaper:
  #   1. recycle_stale_members! — terminate warming-too-long + ready-past-TTL
  #   2. replenish!             — bring ready+warming up to target_size
  #
  # Failures in one pool's tick do NOT abort the loop; each pool gets its
  # own rescue so a single-account misconfiguration doesn't starve every
  # other account's replenishment.
  class InstancePoolReaperService
    Result = Struct.new(:pools_visited, :replenished_total, :recycled_total,
                        :pools_failed, :errors, keyword_init: true)

    def self.tick_all!
      new.tick_all!
    end

    def tick_all!
      replenished = 0
      recycled    = 0
      visited     = 0
      failed      = 0
      errors      = []

      ::System::InstancePool.active.find_each do |pool|
        visited += 1
        begin
          recycle_result = ::System::InstancePoolService.recycle_stale_members!(pool: pool)
          recycled += recycle_result.values.sum if recycle_result.is_a?(Hash)

          repl_result = ::System::InstancePoolService.replenish!(pool: pool)
          replenished += repl_result[:provisioned].to_i if repl_result.is_a?(Hash)
        rescue StandardError => e
          failed += 1
          errors << { pool_id: pool.id, error: "#{e.class}: #{e.message}" }
          Rails.logger.warn(
            "[InstancePoolReaperService] pool='#{pool.name}' (id=#{pool.id}) tick failed: " \
            "#{e.class}: #{e.message}"
          )
        end
      end

      Result.new(
        pools_visited: visited,
        replenished_total: replenished,
        recycled_total: recycled,
        pools_failed: failed,
        errors: errors
      )
    end
  end
end
