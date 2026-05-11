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
        include ::System::GatedActions

        # ApplicationController.include Authentication already runs
        # authenticate_request as a global before_action — operator JWT auth
        # is covered. Worker-callable replenish/drain go through the
        # worker_api namespace (which has its own worker-token auth);
        # there's no dual-auth path on this operator-facing controller.
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
        # Pool create is gated — committing capacity is operator-initiated and
        # high-blast (instances begin pre-provisioning to target size).
        def create
          authorize_write!
          attrs = create_params.to_h
          gate!(
            action_category: "system.instance_pool_create",
            executor_class: "System::Executors::InstancePool::CreatePool",
            params: { attributes: attrs },
            description: "Create instance pool '#{attrs['name']}'",
            on_proceed: ->(result) {
              pool_id = result.result&.dig(:data, :pool_id)
              pool = ::System::InstancePool.find_by(id: pool_id)
              if pool
                render_success({ pool: pool.to_summary }, status: :created)
              else
                render_error("Pool created but row not found", status: :internal_server_error)
              end
            }
          )
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
        # Gated — destroying a pool removes all warm instances + halts
        # replenishment. Default policy is require_approval.
        def destroy
          authorize_write!
          id = @pool.id
          name = @pool.name
          gate!(
            action_category: "system.instance_pool_delete",
            executor_class: "System::Executors::InstancePool::DeletePool",
            params: { pool_id: id },
            source_type: "System::InstancePool",
            source_id: id,
            description: "Delete instance pool '#{name}'",
            on_proceed: ->(_r) {
              @pool.update!(status: "archived") if @pool.persisted?
              render_success(pool: @pool.reload.to_summary)
            }
          )
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

        # No service-account branch — service accounts call the worker_api
        # namespace, never this operator-facing controller. The phantom
        # `service_account?` method on User was undefined and would 500 on
        # any non-permission-holder request.
        def authorize_read!
          unless current_user.has_permission?("system.node_instances.read")
            render_error("permission denied: system.node_instances.read", :forbidden) and return
          end
        end

        def authorize_write!
          unless current_user.has_permission?("system.instances.create") ||
                 current_user.has_permission?("system.instances.control")
            render_error("permission denied: system.instances.create or .control", :forbidden) and return
          end
        end
      end
    end
  end
end
