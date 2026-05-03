# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing read-only endpoint for system extension metrics
      # aggregated by `System::Metrics::Aggregator`.
      #
      # Reference: comprehensive stabilization sweep Phase 10.5.
      class MetricsController < BaseController
        before_action :set_account

        # GET /api/v1/system/metrics/dispatch
        #
        # Action method named `index` (not `dispatch`) because `dispatch` is
        # a reserved method on ActionController::Metal — overriding it
        # silently breaks the request entrypoint.
        #
        # Query params:
        #   window  — seconds (default 300, max 3600)
        #
        # Response:
        #   {
        #     "window_seconds": 300,
        #     "metrics": {
        #       "system.dispatch.claimed":    { count, rate_per_sec, buckets: [...] },
        #       "system.dispatch.completed":  { ... },
        #       "system.dispatch.failed":     { ... },
        #       "system.fleet.event":         { ... }
        #     }
        #   }
        def index
          require_permission("system.metrics.read")

          window = parse_window
          stats = ::System::Metrics::Aggregator.stats_for_names(
            tracked_metric_names,
            account_id: @account.id,
            window: window
          )

          render_success(window_seconds: window.to_i, metrics: stats)
        end

        private

        def set_account
          @account = current_user.account
        end

        def parse_window
          requested = params[:window].to_i
          requested = 300 if requested <= 0  # default 5min
          [ requested, 3600 ].min.seconds
        end

        # The metric names this endpoint surfaces. Adding a new metric name
        # here makes it visible to the operator UI without requiring frontend
        # changes — the dashboard renders one tile per entry.
        def tracked_metric_names
          %w[
            system.dispatch.claimed
            system.dispatch.started
            system.dispatch.completed
            system.dispatch.failed
            system.fleet.event
          ]
        end
      end
    end
  end
end
