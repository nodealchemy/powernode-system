# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing fleet observability + attribution endpoints.
      # Distinct from `worker_api/fleet_controller` (which is worker-token
      # auth and runs the reconcile tick). This is JWT-authenticated and
      # backs the M-FE-3 Fleet Dashboard.
      class FleetController < BaseController
        before_action :authenticate_request

        # POST /api/v1/system/fleet/signals
        # Body: { limit?, kind?, correlation_id?, since? }
        def signals
          require_permission("system.fleet.autonomy")

          scope = ::System::FleetEvent.where(account: current_user.account).recent
          scope = scope.by_correlation(params[:correlation_id]) if params[:correlation_id].present?
          scope = scope.by_kind(params[:kind]) if params[:kind].present?
          if (since = parse_iso(params[:since]))
            scope = scope.since(since)
          end
          limit = (params[:limit] || 50).to_i.clamp(1, 200)
          events = scope.limit(limit)

          render_success(
            events: events.map(&:as_broadcast),
            count: events.size,
            channel: "system_fleet:#{current_user.account.id}"
          )
        end

        # POST /api/v1/system/fleet/attribute_failure
        # Body: { instance_id, lookback_hours? }
        def attribute_failure
          require_permission("system.node_instances.read")

          executor = ::System::Ai::Skills::AttributeFailureExecutor.new(account: current_user.account)
          result = executor.execute(
            instance_id: params[:instance_id],
            lookback_hours: params[:lookback_hours] || 24
          )

          if result[:success]
            render_success(result[:data])
          else
            render_error(result[:error], status: :unprocessable_entity)
          end
        end

        # POST /api/v1/system/fleet/attribution_feedback
        # Body: { instance_id, candidate_id, confirmed: true|false, note? }
        # Persists operator's confirm/reject of an attribution as a Learning
        # so future calls can boost the candidate's pattern recognition.
        def attribution_feedback
          require_permission("system.node_instances.read")

          service = ::System::Fleet::AttributionFeedbackService.new(account: current_user.account)
          result = service.record!(
            instance_id: params[:instance_id],
            candidate_module_id: params[:candidate_module_id],
            candidate_kind: params[:candidate_kind],
            confirmed: params[:confirmed],
            note: params[:note]
          )

          if result[:ok]
            render_success(learning_id: result[:learning_id])
          else
            render_error(result[:error], status: :unprocessable_entity)
          end
        end

        private

        def parse_iso(str)
          return nil if str.blank?
          Time.iso8601(str)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
