# frozen_string_literal: true

module System
  # Campaign 019f6084 inc-M — the reconciler that drives durable fulfillment
  # requests forward and reaps expired leases. The fulfillment analog of
  # System::CiRunnerLeaseSweepService: called on a tick (server-side, where the
  # DB + models live — the server runs no Sidekiq), it advances every open
  # request and terminates task-scoped instances whose lease has elapsed.
  #
  # Two responsibilities, both idempotent + safe to retry:
  #
  #   advance_open! — for each ADVANCEABLE request (approved..smoking), invoke
  #     System::FulfillmentAdvanceOrchestrator#advance!. This is what resumes a
  #     request parked in `building` once its module-build batch finishes (the
  #     orchestrator returns immediately, without sleeping, while the batch is
  #     still running), and what carries a request approved out-of-band (interactive
  #     operator approval) through to `ready`.
  #
  #   reap_expired! — the task-scoped lease reaper. A `ready` request past its
  #     record-level expires_at has its instances terminated and transitions to
  #     `expired`; as a backstop, any task_scoped node instance past its own
  #     lease_expires_at is terminated directly. Mirrors the pool reaper's
  #     best-effort terminate-and-log posture (a terminate failure is logged, not
  #     raised — the reaper retries next tick).
  #
  # NOTE (integration seam): wiring a periodic worker tick to call .run! per
  # account is the remaining integration step (mirror
  # worker/app/jobs/system/ci_runner_lease_reconcile_job.rb → a
  # worker_api/fulfillment_requests/advance endpoint). Until then the fulfill
  # skill drives the first advance inline on approval, and this service is
  # callable directly (specs + any operator/agent-invoked reconcile).
  class FulfillmentRequestSweepService
    def self.run!(account:)
      new(account: account).run!
    end

    def initialize(account:)
      @account = account
      @summary = { advanced: 0, reached_ready: 0, failed: 0, waiting: 0,
                   requests_expired: 0, instances_reaped: 0, errored: 0 }
    end

    def run!
      advance_open!
      reap_expired!
      @summary
    end

    private

    def advance_open!
      ::System::FulfillmentRequest.for_account(@account).advanceable.find_each do |request|
        result = ::System::FulfillmentAdvanceOrchestrator.advance!(request: request)
        @summary[:advanced] += 1
        @summary[:waiting]  += 1 if result.waiting
        @summary[:reached_ready] += 1 if request.reload.ready?
        @summary[:failed] += 1 if request.failed?
      rescue StandardError => e
        Rails.logger.error("[FulfillmentRequestSweep] advance ##{request.id} failed: #{e.message}")
        @summary[:errored] += 1
      end
    end

    def reap_expired!
      now = Time.current

      # (1) Record-level: a ready run whose lease elapsed → terminate its
      # instances + transition to `expired`.
      ::System::FulfillmentRequest.for_account(@account)
                                  .where(state: "ready")
                                  .where("expires_at IS NOT NULL AND expires_at < ?", now)
                                  .find_each do |request|
        terminate_instances(request.node_instance_ids)
        request.expire! if request.may_expire?
        @summary[:requests_expired] += 1
      rescue StandardError => e
        Rails.logger.error("[FulfillmentRequestSweep] expire ##{request.id} failed: #{e.message}")
        @summary[:errored] += 1
      end

      # (2) Instance-level backstop: any task_scoped instance past its own
      # lease_expires_at that is still active (e.g. its owning request was already
      # archived, or step (1) partially failed) → terminate directly.
      ::System::NodeInstance.where(account_id: @account.id, lifecycle_class: "task_scoped")
                            .where("lease_expires_at IS NOT NULL AND lease_expires_at < ?", now)
                            .where.not(status: "terminated")
                            .find_each do |instance|
        terminate_instance(instance)
      end
    end

    def terminate_instances(ids)
      ::System::NodeInstance.where(account_id: @account.id, id: Array(ids)).find_each do |instance|
        terminate_instance(instance)
      end
    end

    def terminate_instance(instance)
      return if instance.status == "terminated"

      ::System::ProvisioningService.terminate_instance(instance: instance)
      @summary[:instances_reaped] += 1
    rescue StandardError => e
      Rails.logger.warn("[FulfillmentRequestSweep] terminate instance #{instance.id} failed: #{e.message}")
    end
  end
end
