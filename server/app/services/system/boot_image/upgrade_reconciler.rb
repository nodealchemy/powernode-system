# frozen_string_literal: true

module System
  module BootImage
    # Reconciles in-flight `upgrade_boot_image` tasks against the truth the node
    # reports post-reboot (campaign 019f505f increment 2).
    #
    # The upgrade task reboots the node, so the agent's own /complete POST races
    # the shutdown and is unreliable — the authoritative success signal is the
    # first post-reboot heartbeat's `booted_image_git_sha`. This service runs on
    # each heartbeat (cheap: it only does work when an in-flight upgrade exists):
    #
    #   - booted_image_git_sha == the task's target  → complete the task.
    #   - task older than the timeout and still not on target → fail it (the new
    #     UKI likely failed to boot and the node fell back to the prior image;
    #     single-slot has no auto-rollback until increment 3). Failing it frees
    #     the per-instance in-flight dedup so a retry can be queued.
    class UpgradeReconciler
      # Overridable via ENV (matches the fleet DEDUP_TTL convention); how long a
      # node has to come back reporting the target image before the upgrade is
      # scored a failure. Generous — a slow node + module reconcile can take a
      # while post-reboot.
      TIMEOUT_SECONDS = (ENV["BOOT_IMAGE_UPGRADE_TIMEOUT_SECONDS"] || 900).to_i

      IN_FLIGHT = %w[pending scheduled running].freeze

      def self.reconcile!(instance:)
        new(instance: instance).reconcile!
      end

      def initialize(instance:)
        @instance = instance
      end

      # Returns the number of tasks transitioned (completed or failed).
      def reconcile!
        booted = @instance.booted_image_git_sha
        transitioned = 0

        in_flight_upgrades.find_each do |task|
          target = task_target(task)
          next if target.blank?

          if booted.present? && booted == target
            complete!(task, booted)
            transitioned += 1
          elsif timed_out?(task)
            fail_timeout!(task, booted)
            transitioned += 1
          end
        end

        transitioned
      rescue StandardError => e
        # Never let reconciliation break the heartbeat path.
        ::Rails.logger.warn("[BootImage::UpgradeReconciler] instance=#{@instance.id}: #{e.class}: #{e.message}")
        0
      end

      private

      def in_flight_upgrades
        ::System::Task
          .where(operable: @instance, command: "upgrade_boot_image")
          .where(status: IN_FLIGHT)
      end

      def task_target(task)
        task.options.is_a?(Hash) ? task.options["target_git_sha"] : nil
      end

      def timed_out?(task)
        (task.started_at || task.created_at) < TIMEOUT_SECONDS.seconds.ago
      end

      # AASM requires an op to be `running` before it can `complete`/`fail`, so
      # a still-`pending` task (agent never acknowledged before the reboot) is
      # forced through `start!` first.
      def complete!(task, booted)
        task.start! if task.may_start?
        task.add_event("boot_image_upgrade_confirmed", "node booted target image #{booted}") if task.respond_to?(:add_event)
        task.complete! if task.may_complete?
      end

      def fail_timeout!(task, booted)
        task.start! if task.may_start?
        msg = "boot-image upgrade to #{task_target(task)} not confirmed within #{TIMEOUT_SECONDS}s " \
              "(node reports booted_image_git_sha=#{booted.presence || 'unknown'})"
        task.fail!(msg) if task.may_fail?
      end
    end
  end
end
