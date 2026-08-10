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
  # Periodic tick (inc-O): SystemFulfillmentRequestReconcileJob
  # (extensions/system/worker/app/jobs/system_fulfillment_request_reconcile_job.rb)
  # POSTs worker_api/fulfillment/sweep every 60s, which calls .run! per
  # account in scope — the fulfill skill still drives the first advance
  # inline on approval, and this service remains callable directly (specs +
  # any operator/agent-invoked reconcile).
  class FulfillmentRequestSweepService
    include ::System::Autonomy::KillSwitchGuard
    include ::System::Autonomy::ControlPlaneGuard

    attr_reader :account

    # How long an authoring artifact must have existed before the reaper will
    # touch it. The reaper does NOT hold the orchestrator's per-request advisory
    # lock, so if a request goes terminal in one process while another is still
    # assembling its template, age is the only thing separating a dead artifact
    # from one mid-authoring. Generous on purpose: reaping late costs a row,
    # reaping early destroys live work.
    ORPHAN_TEMPLATE_GRACE = 30.minutes

    def self.run!(account:)
      new(account: account).run!
    end

    def initialize(account:)
      @account = account
      @summary = { advanced: 0, reached_ready: 0, failed: 0, waiting: 0,
                   requests_expired: 0, instances_reaped: 0, orphan_templates_reaped: 0,
                   errored: 0 }
    end

    def run!
      # Gates FIRST, and deliberately over the WHOLE sweep — bookkeeping expiry
      # included. This sweep terminates instances, destroys templates, and
      # applies live templates every 60s. Deferring the reap steps is NOT free
      # under a long halt (lease-expired task-scoped instances keep running —
      # and billing — for the halt's full duration); that bounded cost is
      # accepted in exchange for one uniformly-gated actuation surface, because
      # a split gated/ungated sweep is exactly the complexity that grows a
      # bypass. Kill-switch outranks the dual-plane fence as the reported
      # reason (same order as every fenced reconciler). The worker controller's
      # aggregate() sums counter keys with to_i, so these counter-less guard
      # results aggregate safely to zeros.
      return halted_tick_result if kill_switch_engaged?
      return standby_tick_result unless control_plane_active?

      advance_open!
      reap_expired!
      reap_orphan_templates!
      @summary
    end

    private

    def advance_open!
      ::System::FulfillmentRequest.for_account(@account).advanceable.find_each do |request|
        result = ::System::FulfillmentAdvanceOrchestrator.advance!(request: request)
        # Another advance (the operator approve endpoint, or an overlapping
        # tick) holds this request's advisory lock. Nothing happened here, so
        # counting it as `advanced` would overstate the tick — skip it and
        # pick the row up next tick.
        next if result.already_advancing

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

    # (3) Authoring artifacts no request can reclaim.
    #
    # A process KILL between NodeTemplate.create and record_template! leaves a
    # stamped, incompletely-assigned template behind — no exception ran, so none
    # of the orchestrator's rescue-cleanup did either.
    # FulfillmentAdvanceOrchestrator#reclaim_abandoned_template! recovers one
    # for a request that can still resume onto it, but that path is triggered by
    # a NAME COLLISION inside the owning request's own next author_template!.
    # Once that request is TERMINAL or gone, nothing re-enters it and the
    # artifact is unreachable forever — the orchestrator's own comment defers
    # this to "a separate sweep". This is it.
    #
    # DESTROY rather than mark, matching how the codebase already treats this
    # exact artifact in all three places it can reach one: the author rescue
    # (`template.destroy!`), rollback! step 3, and the reclaim itself. A marked
    # template would still hold its per-account unique NAME, which is the actual
    # durable harm — an operator-chosen execution.template_name stays squatted,
    # so every later request asking for that name fails loud forever.
    #
    # The evidence required is reclaim_abandoned_template?'s, minus the clause
    # that made it request-specific and plus a grace period. Every clause is
    # load-bearing; the guards in the spec pin them one at a time.
    def reap_orphan_templates!
      ::System::NodeTemplate
        .where(account_id: @account.id)
        .where("created_at < ?", ORPHAN_TEMPLATE_GRACE.ago)
        .where("config->>'fulfillment_request_id' IS NOT NULL")
        .find_each do |template|
        next unless reapable_orphan?(template)

        # destroy! (not destroy): `has_many :nodes, dependent: :restrict_with_error`
        # returns false rather than raising, which would count a reap that did
        # not happen. Best-effort per row, mirroring terminate_instance — one
        # undestroyable template must not abort the tick.
        template.destroy!
        @summary[:orphan_templates_reaped] += 1
        Rails.logger.info(
          "[FulfillmentRequestSweep] reaped orphan authoring template #{template.id} " \
          "(#{template.name}) left by an interrupted run for request " \
          "#{template.config['fulfillment_request_id']}"
        )
      rescue StandardError => e
        Rails.logger.warn("[FulfillmentRequestSweep] orphan template #{template.id} reap failed: #{e.message}")
        @summary[:errored] += 1
      end
    end

    def reapable_orphan?(template)
      config = template.config
      return false unless config.is_a?(Hash)

      request_id = config["fulfillment_request_id"]
      return false if request_id.blank?

      request = ::System::FulfillmentRequest.where(account_id: @account.id).find_by(id: request_id)

      if request
        # Still able to resume onto it — that is the self-heal's artifact, not
        # an orphan. Reaping here would race the very run that owns it.
        return false unless request.terminal?
        # Anti-forgery, as in reclaim_abandoned_template?: an operator's
        # system_update_template REPLACES config wholesale, so a stamp older
        # than the request's own templated_at did not come from its authoring.
        return false if request.templated_at.blank?
        return false if template.created_at < request.templated_at
      end
      # request nil: the stamp names no request in this account, so nothing can
      # ever resume onto it. The remaining clauses are what license the destroy.

      return false if template.nodes.exists?

      # A template a run recorded on success is that run's live artifact.
      !::System::FulfillmentRequest.where(template_id: template.id).exists?
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
