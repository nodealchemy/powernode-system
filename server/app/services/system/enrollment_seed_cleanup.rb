# frozen_string_literal: true

module System
  # Best-effort cleanup of the carrier of a platform-injected enrolment key once
  # the instance has enrolled (Provisioning D13, operator 2026-10-20). Single use
  # is the real control: the key is spent the moment the instance enrols. This
  # only narrows how long the (now inert) seed stays readable on the provider.
  #
  # Pull model, no new job class: enrolment does ONE cheap local write (#mark_pending!,
  # no provider call, so it can neither slow nor fail the enrolment), and the
  # existing worker reconcile tick (worker_api/fleet/reconcile) calls .sweep!, which
  # does the provider work with bounded retries. A failure is logged and retried; it
  # never reaches the enrolment. NEVER restarts a VM: Proxmox changes are queued for
  # the next natural stop, GCP's metadata edit is live, AWS/OpenStack are no-ops
  # recorded with an audit note (D12 neutralises their seed at the next start).
  # Reuses System::EnrollmentSeed (ever_seeded?/enrolled?) and the providers' own
  # D12 seed helpers; never logs or stores key material.
  #
  # State lives in NodeInstance#config["seed_cleanup"]:
  #   { state: pending|awaiting_stop|done|failed, attempts:, next_attempt_at:, ... }
  class EnrollmentSeedCleanup
    KEY = "seed_cleanup"
    MAX_ATTEMPTS = 5
    RETRY_BACKOFF = 5.minutes
    # How often to re-check a Proxmox VM that has not stopped yet.
    STOP_POLL_INTERVAL = 30.minutes
    # A VM that never stops within this window is left to D12 (neutralised at its next start).
    STOP_WAIT_LIMIT = 14.days
    ACTIVE_STATES = %w[pending awaiting_stop].freeze
    AUDIT_ACTION = "system.enrollment_seed.cleanup"
    AUDITED_ACTIONS = [ AUDIT_ACTION ].freeze
    # Small per-tick batch + wall-clock budget: the sweep does synchronous provider I/O
    # inside one worker request, so it must stop starting new items well inside the
    # request timeout (SystemSeedCleanupJob). A row is leased before its provider call.
    SWEEP_LIMIT = 5
    SWEEP_BUDGET = 15 # seconds
    # Worst case for ONE item is ~1 min (Proxmox: 4 calls at 5s connect + 8s read, a
    # 20s task wait), far below the lease; a stale holder's write-back is dropped anyway
    # (lease token), so an expired lease can never be overwritten by its old owner.
    LEASE = 3.minutes

    class << self
      # Called right after the enrolment commits. Never raises.
      def mark_pending!(instance)
        return false unless ::System::EnrollmentSeed.ever_seeded?(instance)

        instance.merge_config!(KEY => { "state" => "pending", "attempts" => 0,
                                        "requested_at" => Time.current.utc.iso8601 })
        true
      rescue StandardError => e
        Rails.logger.warn("[EnrollmentSeedCleanup] could not queue cleanup for #{instance&.id}: #{e.class}")
        false
      end

      # Accounts that have a due row, oldest due row first, so a busy account cannot
      # starve the ones after it within the shared budget.
      def accounts_by_oldest_due(accounts)
        ids = due_rows(::System::NodeInstance.where(account_id: accounts.select(:id)))
                .group(:account_id).order(Arel.sql("MIN(#{ORDER_EXPR})")).pluck(:account_id)
        by_id = ::Account.where(id: ids).index_by(&:id)
        ids.filter_map { |id| by_id[id] }
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Runs due cleanups of the account's instances, at most `limit`, starting no
      # new item once the monotonic `deadline` has passed. Each row is leased (CAS on
      # next_attempt_at) before its provider call, so two concurrent sweeps never
      # process the same instance. Returns how many ran. Never raises.
      def sweep!(account:, limit: SWEEP_LIMIT, deadline: nil)
        return 0 unless limit.to_i.positive?

        deadline ||= monotonic_now + SWEEP_BUDGET
        ran = 0
        due(account).limit(limit.to_i).to_a.each do |instance|
          break if monotonic_now >= deadline
          next unless (token = lease!(instance))

          run!(instance, lease_token: token)
          ran += 1
        rescue StandardError => e
          Rails.logger.warn("[EnrollmentSeedCleanup] sweep error for #{instance.id}: #{e.class}")
        end
        ran
      rescue StandardError => e
        Rails.logger.warn("[EnrollmentSeedCleanup] sweep failed: #{e.class}")
        0
      end

      # One cleanup attempt. Never raises. The outcome is written back as a patch to
      # the seed_cleanup key only (see #patch!), never as a whole-config rewrite.
      def run!(instance, lease_token: nil)
        cfg = instance.config.is_a?(Hash) ? instance.config[KEY] : nil
        return unless cfg.is_a?(Hash) && ACTIVE_STATES.include?(cfg["state"])

        outcome = clear_at_provider(instance)
        record(instance, cfg, outcome, lease_token)
      rescue StandardError => e
        # Class only: provider messages can echo request bodies.
        Rails.logger.warn("[EnrollmentSeedCleanup] attempt failed for #{instance.id}: #{e.class}")
        record_failure(instance, cfg || {}, e.class.name, lease_token)
      end

      private

      ORDER_EXPR = "COALESCE(system_node_instances.config->'#{KEY}'->>'next_attempt_at', " \
                   "system_node_instances.config->'#{KEY}'->>'requested_at')"

      def due(account)
        due_rows(::System::NodeInstance.where(account_id: account.id)).order(Arel.sql(ORDER_EXPR))
      end

      def due_rows(scope)
        scope
          .where("system_node_instances.config->'#{KEY}'->>'state' IN ('pending','awaiting_stop')")
          .where("system_node_instances.config->'#{KEY}'->>'next_attempt_at' IS NULL OR " \
                 "system_node_instances.config->'#{KEY}'->>'next_attempt_at' <= ?", Time.current.utc.iso8601)
          .where.not(status: "terminated")
      end

      # Compare-and-set: claims the row only while it is still due. The conditional
      # UPDATE is the lock; a second sweep sees next_attempt_at in the future.
      def lease!(instance)
        now = Time.current.utc.iso8601
        until_at = (Time.current + LEASE).utc.iso8601
        token = SecureRandom.hex(8)
        sql = ::System::NodeInstance.sanitize_sql_array([
          "UPDATE system_node_instances SET config = jsonb_set(jsonb_set(config, '{#{KEY},next_attempt_at}', to_jsonb(?::text)), " \
          "'{#{KEY},lease_token}', to_jsonb(?::text)) " \
          "WHERE id = ? AND config->'#{KEY}'->>'state' IN ('pending','awaiting_stop') AND " \
          "((config->'#{KEY}'->>'next_attempt_at') IS NULL OR (config->'#{KEY}'->>'next_attempt_at') <= ?)",
          until_at, token, instance.id, now
        ])
        ::System::NodeInstance.connection.exec_update(sql, "seed_cleanup_lease").positive? ? token : nil
      end

      # Atomic write-back of ONLY the seed_cleanup fields this attempt changed.
      # Guarded on (a) the request still being the one this attempt started from
      # (requested_at), so a concurrent mark_pending! is not overwritten, and (b) when
      # the attempt holds a lease, that lease still being ours (lease_token), so a
      # sweep whose lease expired and was taken over cannot overwrite the new owner.
      # Always releases the lease. Returns true when the patch was applied; a stale
      # attempt's patch is dropped (false) and must not be audited.
      def patch!(instance, requested_at, patch, lease_token = nil)
        sql = ::System::NodeInstance.sanitize_sql_array([
          "UPDATE system_node_instances SET config = jsonb_set(config, '{#{KEY}}', " \
          "COALESCE(config->'#{KEY}', '{}'::jsonb) || ?::jsonb) " \
          "WHERE id = ? AND (config->'#{KEY}'->>'requested_at') IS NOT DISTINCT FROM ? " \
          "AND (?::text IS NULL OR (config->'#{KEY}'->>'lease_token') = ?::text)",
          patch.merge("lease_token" => nil).to_json, instance.id, requested_at, lease_token, lease_token
        ])
        applied = ::System::NodeInstance.connection.exec_update(sql, "seed_cleanup_patch").positive?
        instance.reload
        applied
      end

      def clear_at_provider(instance)
        return { outcome: :noop, note: "instance has no cloud id", provider_type: nil } if instance.cloud_instance_id.blank?

        adapter = ::System::Providers::Registry.for_instance(instance)
        result = adapter.clear_enrollment_seed!(instance.cloud_instance_id, instance: instance)
        result.merge(provider_type: adapter.provider_type)
      end

      def record(instance, cfg, result, lease_token = nil)
        outcome = result[:outcome].to_s
        now = Time.current
        case outcome
        when "awaiting_stop"
          first = cfg["state"] != "awaiting_stop"
          since = cfg["waiting_since"].presence || now.utc.iso8601
          if Time.iso8601(since) < now - STOP_WAIT_LIMIT
            finish(instance, cfg, "done", result.merge(outcome: :abandoned,
                   note: "VM did not stop within #{STOP_WAIT_LIMIT.inspect}; the next start neutralises the seed"), lease_token)
          else
            applied = write(instance, cfg, lease_token, "state" => "awaiting_stop", "waiting_since" => since,
                                           "next_attempt_at" => (now + STOP_POLL_INTERVAL).utc.iso8601)
            audit(instance, result) if first && applied
          end
        else
          finish(instance, cfg, "done", result, lease_token)
        end
      end

      def finish(instance, cfg, state, result, lease_token = nil)
        applied = write(instance, cfg, lease_token, "state" => state, "next_attempt_at" => nil,
                                       "finished_at" => Time.current.utc.iso8601, "outcome" => result[:outcome].to_s)
        audit(instance, result) if applied
      end

      def record_failure(instance, cfg, error_class, lease_token = nil)
        attempts = cfg["attempts"].to_i + 1
        if attempts >= MAX_ATTEMPTS
          applied = write(instance, cfg, lease_token, "state" => "failed", "attempts" => attempts,
                                         "next_attempt_at" => nil, "outcome" => "failed")
          audit(instance, { outcome: :failed, note: "gave up after #{attempts} attempts (#{error_class}); D12 neutralises the seed at the next start" }) if applied
        else
          write(instance, cfg, lease_token, "state" => cfg["state"].presence || "pending", "attempts" => attempts,
                                         "next_attempt_at" => (Time.current + (RETRY_BACKOFF * attempts)).utc.iso8601)
        end
      rescue StandardError => e
        Rails.logger.warn("[EnrollmentSeedCleanup] could not record failure for #{instance.id}: #{e.class}")
      end

      def write(instance, cfg, lease_token, patch)
        patch!(instance, cfg["requested_at"], patch, lease_token)
      end

      # Best-effort: an audit hiccup is logged, never raised. No key material.
      def audit(instance, result)
        ::AuditLog.log_action(
          action: AUDIT_ACTION,
          resource: instance,
          account: instance.account,
          source: "system",
          metadata: { "outcome" => result[:outcome].to_s, "provider_type" => result[:provider_type],
                      "note" => result[:note].to_s.first(300) }.compact
        )
      rescue StandardError => e
        Rails.logger.warn("[EnrollmentSeedCleanup] audit write failed for #{instance.id}: #{e.class}")
      end
    end
  end
end
