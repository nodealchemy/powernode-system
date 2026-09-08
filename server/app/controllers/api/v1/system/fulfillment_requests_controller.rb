# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator approval surface for System::FulfillmentRequest (campaign
      # 019f6084 inc-M).
      #
      # WHY APPROVE IS THE ONLY MUTATION HERE: a fulfillment request is composed with
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
        # Permission BEFORE lookup. With the lookup first, an unprivileged
        # same-account user got 403 for a real id and 404 for a made-up one —
        # an existence oracle over infrastructure-plan ids. Checking the
        # permission first makes both answers 403.
        before_action -> { require_permission("system.fulfillment_requests.read") },
                      only: %i[index show]
        before_action -> { require_permission("system.fulfillment_requests.approve") },
                      only: %i[approve]
        before_action :set_fulfillment_request, only: %i[show approve]

        # GET /api/v1/system/fulfillment_requests
        #
        # The list the operator decides FROM. Newest first, optionally filtered
        # by state so `composed` — the only state waiting on a human — can be
        # isolated. Rows are summaries: the frozen plan is deliberately NOT in
        # the list, both because it is large and because approving is a
        # per-request act of reading one plan, not scanning many.
        #
        # `awaiting_approval_count` is the number of composed requests, so the
        # hub can badge the tab without a second round trip.
        def index
          requests = account_requests.recent
          requests = requests.by_state(params[:state]) if params[:state].present?
          requests = paginate(requests)

          render_success(
            fulfillment_requests: requests.map(&:summary),
            awaiting_approval_count: account_requests.by_state("composed").count,
            meta: pagination_meta
          )
        end

        # GET /api/v1/system/fulfillment_requests/:id
        #
        # Returns the FROZEN plan verbatim, plus its digest. This is the whole
        # point of the read surface: approve releases `plan` as-is, so the
        # operator must be able to see those exact bytes — including
        # `unresolved_gaps` and the `parked` trail — before releasing them. The
        # digest is the same one the approval FleetEvent carries, so an auditor
        # can match what was shown to what was approved.
        def show
          render_success(
            fulfillment_request: @fulfillment_request.summary.merge(
              plan: @fulfillment_request.plan,
              plan_digest: @fulfillment_request.plan_digest,
              cost_estimate: @fulfillment_request.cost_estimate
            )
          )
        end

        # POST /api/v1/system/fulfillment_requests/:id/approve
        #
        # Transitions composed → approved and drives ONE advance inline so the
        # operator gets immediate feedback (the budget + rate-limit gate lives on
        # the approved → materializing edge, so a capped request reports back as
        # parked right here instead of silently waiting a tick). The sweep
        # carries it the rest of the way.
        def approve
          unless @fulfillment_request.composed?
            return render_error(
              "fulfillment request is #{@fulfillment_request.state}, not composed",
              :unprocessable_entity
            )
          end

          @fulfillment_request.approve_by!(user: current_user, source: "operator_ui")
          # operator: true — an explicit human approval is exempt from the
          # kill-switch (which suspends AI activity), though never from the
          # dual-plane fence (IMP-f90858fd9b5b).
          result = ::System::FulfillmentAdvanceOrchestrator.advance!(request: @fulfillment_request, operator: true)

          render_success(
            fulfillment_request: @fulfillment_request.reload.summary,
            advance: advance_payload(result)
          )
        end

        private

        def account_requests
          ::System::FulfillmentRequest.where(account: current_account)
        end

        def set_fulfillment_request
          @fulfillment_request = account_requests.find(params[:id])
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
            error: result.error,
            already_advancing: result.already_advancing
          }
        end
      end
    end
  end
end
