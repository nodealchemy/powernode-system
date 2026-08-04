# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator approval surface for System::FulfillmentRequest (campaign
      # 019f6084 inc-M).
      #
      # WHY THIS IS THE ONLY ACTION HERE: a fulfillment request is composed with
      # its plan FROZEN in plan["execution"], and every later phase is driven by
      # System::FulfillmentRequestSweepService on its 60s worker tick. The one
      # thing the sweep will NOT do is leave `composed` — that state is excluded
      # from System::FulfillmentRequest::ADVANCEABLE_STATES precisely because it
      # is waiting on a human, not on the orchestrator. This controller is that
      # human decision, and nothing else.
      #
      # THE FROZEN-PLAN CONTRACT (the TOCTOU fix this whole state machine
      # exists for): approve releases the plan AS-IS. It does not re-compose, it
      # does not re-resolve modules or regions, and it does not filter
      # plan["unresolved_gaps"] or the `parked` trail the executor recorded
      # (including a withheld autonomous approval). What the operator approves
      # and what the orchestrator replays are the same bytes.
      #
      # WHAT GETS RECORDED: approve_by! stamps approved_by_user_id + approved_at
      # on the row and emits a `system.fulfillment_approved` FleetEvent carrying
      # the approver and a sha256 of the frozen plan. That FleetEvent is the
      # whole trail — this subsystem writes no AuditLog rows.
      class FulfillmentRequestsController < BaseController
        before_action :set_fulfillment_request, only: %i[approve]

        # POST /api/v1/system/fulfillment_requests/:id/approve
        #
        # Transitions composed → approved and drives ONE advance inline so the
        # operator gets immediate feedback (the budget + rate-limit gate lives on
        # the approved → materializing edge, so a capped request reports back as
        # parked right here instead of silently waiting a tick). The sweep
        # carries it the rest of the way.
        def approve
          require_permission("system.fulfillment_requests.approve")

          unless @fulfillment_request.composed?
            return render_error(
              "fulfillment request is #{@fulfillment_request.state}, not composed",
              :unprocessable_entity
            )
          end

          @fulfillment_request.approve_by!(user: current_user, source: "operator_ui")
          result = ::System::FulfillmentAdvanceOrchestrator.advance!(request: @fulfillment_request)

          render_success(
            fulfillment_request: @fulfillment_request.reload.summary,
            advance: advance_payload(result)
          )
        end

        private

        def set_fulfillment_request
          @fulfillment_request = ::System::FulfillmentRequest
                                   .where(account: current_account)
                                   .find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("FulfillmentRequest")
        end

        # The orchestrator never raises — it rescues internally and reports the
        # failure on the Result — so surface the outcome rather than a status
        # code. `ok?` is a Struct member name, hence the [] read.
        def advance_payload(result)
          {
            ok: result[:ok?],
            state: result.state,
            advanced: result.advanced,
            waiting: result.waiting,
            parked: result.parked,
            error: result.error
          }
        end
      end
    end
  end
end
