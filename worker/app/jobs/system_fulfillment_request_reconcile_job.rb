# frozen_string_literal: true

# Campaign 019f6084 inc-O — every-60s FulfillmentRequest sweep tick.
#
# POSTs to the server's worker_api endpoint, which invokes
# System::FulfillmentRequestSweepService (the fulfillment analog of
# System::CiRunnerLeaseSweepService) for each account in scope: it advances
# every ADVANCEABLE request via System::FulfillmentAdvanceOrchestrator
# (resuming ones parked at the build barrier / approved out-of-band) and reaps
# task-scoped instances whose lease has elapsed. The server runs no Sidekiq
# and the worker is HTTP-only, so all sweep logic lives on the server — this
# job is purely the cron tick + retry mechanism (mirrors
# System::CiRunnerLeaseReconcileJob).
class SystemFulfillmentRequestReconcileJob < BaseJob
  sidekiq_options queue: "system", retry: 1

  def execute(args = {})
    body = {}
    body[:account_id] = args["account_id"] if args.is_a?(Hash) && args["account_id"]

    response = api_client.post("/api/v1/system/worker_api/fulfillment/sweep", body)

    if response["success"]
      data = response["data"] || {}
      log_info "[FulfillmentRequestReconcileJob] sweep complete: " \
               "accounts=#{data['accounts_swept']} advanced=#{data['advanced']} " \
               "reached_ready=#{data['reached_ready']} failed=#{data['failed']} " \
               "requests_expired=#{data['requests_expired']} " \
               "instances_reaped=#{data['instances_reaped']} errored=#{data['errored']}"
      data
    else
      log_error "[FulfillmentRequestReconcileJob] sweep failed: #{response['error']}"
      raise response["error"] || "fulfillment_sweep_failed"
    end
  end
end
