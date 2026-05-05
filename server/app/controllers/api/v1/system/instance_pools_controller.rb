# frozen_string_literal: true

module Api
  module V1
    module System
      # Slice 7 — REST surface for instance pool management.
      #
      # Operator-facing reads + the worker reaper's replenish/drain
      # endpoints. Mutating actions (create, drain, replenish) require
      # the same permissions as the equivalent MCP actions
      # (system.instances.create / .control).
      #
      # The MCP tool surface (system_*_instance_pool) is the primary
      # operator UI; this REST controller exists primarily so the
      # worker's InstancePoolReplenisherJob can drive periodic
      # replenishment without going through the MCP execution layer.
      class InstancePoolsController < ApplicationController
        before_action :authenticate_user_or_service!
        before_action :set_pool, only: [:show, :update, :destroy, :replenish, :drain, :recycle_stale]

        # GET /api/v1/system/instance_pools
        def index
          authorize_read!
          pools = ::System::InstancePool.for_account(current_account).order(:name)
          pools = pools.where(status: params[:status].split(",")) if params[:status].present?
          render_success(pools: pools.map(&:to_summary), count: pools.count)
        end

        # GET /api/v1/system/instance_pools/:id
        def show
          authorize_read!
          render_success(pool: @pool.to_summary)
        end

        # POST /api/v1/system/instance_pools
        def create
          authorize_write!
          pool = ::System::InstancePool.create!(create_params.merge(account: current_account))
          render_success({ pool: pool.to_summary }, status: :created)
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation failed: #{e.message}", :unprocessable_entity)
        end

        # PATCH /api/v1/system/instance_pools/:id
        def update
          authorize_write!
          @pool.update!(update_params)
          render_success(pool: @pool.to_summary)
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation failed: #{e.message}", :unprocessable_entity)
        end

        # DELETE /api/v1/system/instance_pools/:id
        def destroy
          authorize_write!
          @pool.update!(status: "archived")
          render_success(pool: @pool.to_summary)
        end

        # POST /api/v1/system/instance_pools/:id/replenish
        def replenish
          authorize_write!
          result = ::System::InstancePoolService.replenish!(pool: @pool)
          render_success(pool: @pool.reload.to_summary, replenish_result: result)
        rescue ::System::InstancePoolService::PoolError => e
          render_error(e.message, :unprocessable_entity)
        end

        # POST /api/v1/system/instance_pools/:id/drain
        def drain
          authorize_write!
          result = ::System::InstancePoolService.drain!(pool: @pool)
          render_success(pool: @pool.reload.to_summary, drain_result: result)
        end

        # POST /api/v1/system/instance_pools/:id/recycle_stale
        # Worker reaper calls this between replenish ticks to age out
        # stuck warming members + ready members past TTL.
        def recycle_stale
          authorize_write!
          result = ::System::InstancePoolService.recycle_stale_members!(pool: @pool)
          render_success(pool: @pool.reload.to_summary, recycle_result: result)
        end

        private

        def set_pool
          @pool = ::System::InstancePool.for_account(current_account).find(params[:id])
        end

        def create_params
          params.require(:pool).permit(
            :name, :description, :node_template_id, :target_size, :min_size,
            :max_size, :lifecycle_class, :provider_region_id, :provider_instance_type_id,
            metadata: {}
          )
        end

        def update_params
          params.require(:pool).permit(
            :description, :target_size, :min_size, :max_size, :status,
            :provider_region_id, :provider_instance_type_id, metadata: {}
          )
        end

        def authorize_read!
          unless current_user.has_permission?("system.node_instances.read") ||
                 current_user&.service_account?
            render_error("permission denied: system.node_instances.read", :forbidden) and return
          end
        end

        def authorize_write!
          unless current_user.has_permission?("system.instances.create") ||
                 current_user.has_permission?("system.instances.control") ||
                 current_user&.service_account?
            render_error("permission denied: system.instances.create or .control", :forbidden) and return
          end
        end
      end
    end
  end
end
