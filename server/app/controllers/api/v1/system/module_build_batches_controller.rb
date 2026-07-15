# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing read API for System::ModuleBuildBatch (campaign
      # 019f6084 inc2-A) — the agent-pollable build-completion barrier over
      # both platform module builds (trigger push/manual/cve) and on-demand
      # package-closure builds (trigger "package", created by
      # System::PackageClosureBuildBridge). Read-only: dispatch itself stays
      # worker/webhook-gated (system.module_builds.dispatch) — this
      # controller only lists/shows what's already been dispatched.
      #
      # index returns SUMMARY rows (list-shape); show returns the FULL
      # per-module breakdown (AASM timestamp ladder + member task/lease/
      # artifact/parity state) inc3's fulfill flow and the frontend Module
      # Builds tab (inc5) poll against.
      class ModuleBuildBatchesController < BaseController
        before_action :set_batch, only: %i[show]

        # GET /api/v1/system/module_build_batches
        # Filters (query params): status (by_status), trigger (by_trigger,
        # e.g. "package"), shadow ("true"/"false").
        def index
          require_permission("system.module_builds.read")

          batches = account_batches.recent
          batches = apply_filters(batches)
          batches = paginate(batches)

          render_success(
            module_build_batches: batches.map { |b| ::System::ModuleBuildBatchSerializer.new(b).as_summary },
            meta: pagination_meta
          )
        end

        # GET /api/v1/system/module_build_batches/:id
        def show
          require_permission("system.module_builds.read")
          render_success(module_build_batch: ::System::ModuleBuildBatchSerializer.new(@batch).as_full)
        end

        private

        def account_batches
          ::System::ModuleBuildBatch.where(account: current_account)
        end

        def set_batch
          @batch = account_batches.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("ModuleBuildBatch")
        end

        def apply_filters(scope)
          scope = scope.by_status(params[:status]) if params[:status].present?
          scope = scope.by_trigger(params[:trigger]) if params[:trigger].present?
          if params[:shadow].present?
            scope = scope.where(shadow: ActiveModel::Type::Boolean.new.cast(params[:shadow]))
          end
          scope
        end
      end
    end
  end
end
