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
    SWEEP_LIMIT = 20

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

      # Runs every due cleanup of the account's instances. Returns how many ran.
      # Never raises.
      def sweep!(account:, limit: SWEEP_LIMIT)
        return 0 unless limit.to_i.positive?

        ran = 0
        due(account).limit(limit.to_i).each do |instance|
          run!(instance)
          ran += 1
        rescue StandardError => e
          Rails.logger.warn("[EnrollmentSeedCleanup] sweep error for #{instance.id}: #{e.class}")
        end
        ran
      rescue StandardError => e
        Rails.logger.warn("[EnrollmentSeedCleanup] sweep failed: #{e.class}")
        0
      end

      # One cleanup attempt. Never raises.
      def run!(instance)
        cfg = instance.config.is_a?(Hash) ? instance.config[KEY] : nil
        return unless cfg.is_a?(Hash) && ACTIVE_STATES.include?(cfg["state"])

        outcome = clear_at_provider(instance)
        record(instance, cfg, outcome)
      rescue StandardError => e
        # Class only: provider messages can echo request bodies.
        Rails.logger.warn("[EnrollmentSeedCleanup] attempt failed for #{instance.id}: #{e.class}")
        record_failure(instance, cfg || {}, e.class.name)
      end

      private

      def due(account)
        ::System::NodeInstance
          .where(account_id: account.id)
          .where("system_node_instances.config->'#{KEY}'->>'state' IN ('pending','awaiting_stop')")
          .where("system_node_instances.config->'#{KEY}'->>'next_attempt_at' IS NULL OR " \
                 "system_node_instances.config->'#{KEY}'->>'next_attempt_at' <= ?", Time.current.utc.iso8601)
          .where.not(status: "terminated")
          .order(:updated_at)
      end

      def clear_at_provider(instance)
        return { outcome: :noop, note: "instance has no cloud id", provider_type: nil } if instance.cloud_instance_id.blank?

        adapter = ::System::Providers::Registry.for_instance(instance)
        result = adapter.clear_enrollment_seed!(instance.cloud_instance_id, instance: instance)
        result.merge(provider_type: adapter.provider_type)
      end

      def record(instance, cfg, result)
        outcome = result[:outcome].to_s
        now = Time.current
        case outcome
        when "awaiting_stop"
          first = cfg["state"] != "awaiting_stop"
          since = cfg["waiting_since"].presence || now.utc.iso8601
          if Time.iso8601(since) < now - STOP_WAIT_LIMIT
            finish(instance, cfg, "done", result.merge(outcome: :abandoned,
                   note: "VM did not stop within #{STOP_WAIT_LIMIT.inspect}; the next start neutralises the seed"))
          else
            write(instance, cfg.merge("state" => "awaiting_stop", "waiting_since" => since,
                                      "next_attempt_at" => (now + STOP_POLL_INTERVAL).utc.iso8601))
            audit(instance, result) if first
          end
        else
          finish(instance, cfg, "done", result)
        end
      end

      def finish(instance, cfg, state, result)
        write(instance, cfg.merge("state" => state, "next_attempt_at" => nil, "finished_at" => Time.current.utc.iso8601,
                                  "outcome" => result[:outcome].to_s))
        audit(instance, result)
      end

      def record_failure(instance, cfg, error_class)
        attempts = cfg["attempts"].to_i + 1
        if attempts >= MAX_ATTEMPTS
          write(instance, cfg.merge("state" => "failed", "attempts" => attempts, "next_attempt_at" => nil,
                                    "outcome" => "failed"))
          audit(instance, { outcome: :failed, note: "gave up after #{attempts} attempts (#{error_class}); D12 neutralises the seed at the next start" })
        else
          write(instance, cfg.merge("state" => cfg["state"].presence || "pending", "attempts" => attempts,
                                    "next_attempt_at" => (Time.current + (RETRY_BACKOFF * attempts)).utc.iso8601))
        end
      rescue StandardError => e
        Rails.logger.warn("[EnrollmentSeedCleanup] could not record failure for #{instance.id}: #{e.class}")
      end

      def write(instance, cfg)
        instance.merge_config!(KEY => cfg)
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
