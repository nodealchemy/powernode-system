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
        # is covered.
        #
        # This controller IS dual-auth, despite what this comment used to say.
        # It claimed worker callers reach replenish/drain through the
        # worker_api namespace and that no dual-auth path exists here — both
        # false: there is no worker_api instance_pools controller, and
        # worker/app/jobs/system/instance_pool_replenisher_job.rb calls THESE
        # operator routes (:58 index, :69 replenish, :94 recycle_stale) with a
        # worker token. The `worker_authenticated?` short-circuit in
        # authorize_read!/authorize_write! is therefore load-bearing, not
        # vestigial — deleting it on the strength of the old comment would
        # break every replenishment tick.
        before_action :set_pool, only: [ :show, :update, :destroy, :replenish, :drain, :recycle_stale ]

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
        #
        # The candidate is never saved; System::Executors::InstancePool::CreatePool
        # stays the sole authority over the write. gate_create! validates it
        # BEFORE the gate (sequence + rationale: Ai::GatedActions#gate_create!),
        # so an unsaveable payload keeps its field-level 422 rather than being
        # parked as an approval that can only ever fail.
        #
        # IMP-785d60f5ec3e — what this replaces answered the SAME payload two
        # different ways depending on something the caller cannot see: 202 on an
        # account whose policy parks (the gate validated nothing, so the create!
        # failed later at approval time) and 422 on one whose policy proceeds.
        # The `rescue ActiveRecord::RecordInvalid` that used to sit here went
        # with it, and was already dead either way — Ai::AutonomyGate#evaluate
        # rescues StandardError and returns :blocked, so the executor's
        # RecordInvalid never reached this frame. The 422 it appeared to produce
        # actually came from gate!'s :blocked branch as a bare
        # "Gate evaluation failed", carrying no details.errors.
        def create
          authorize_write!
          attrs = create_params.to_h

          gate_create!(
            candidate: ::System::InstancePool.new(attrs.merge(account_id: current_account.id)),
            scope: ::System::InstancePool.for_account(current_account),
            result_key: :pool_id,
            response_key: :pool,
            serializer: ->(p) { p.to_summary },
            action_category: "system.instance_pool_create",
            executor_class: "System::Executors::InstancePool::CreatePool",
            params: { attributes: attrs },
            description: "Create instance pool '#{attrs['name']}'"
          )
        end

        # PATCH /api/v1/system/instance_pools/:id
        def update
          authorize_write!
          @pool.update!(update_params)
          render_success(pool: @pool.to_summary)
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation failed: #{e.message}", :unprocessable_content)
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
          render_error(e.message, :unprocessable_content)
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
            metadata: {}, preferred_regions: []
          )
        end

        def update_params
          params.require(:pool).permit(
            :description, :target_size, :min_size, :max_size, :status,
            :provider_region_id, :provider_instance_type_id, metadata: {},
            preferred_regions: []
          )
        end

        # Worker callers (Sidekiq InstancePoolReplenisherJob etc.) authenticate
        # via the worker JWT, which doesn't resolve a current_user — so the
        # has_permission? calls below would NoMethodError on nil. The
        # `worker_authenticated?` short-circuit is the standard carve-out
        # used across Reports/Analytics/Accounts/WebhookEvents controllers
        # for the same reason. See feedback_worker_callback_auth in MEMORY.
        # IMP-ce5d320d3e4e — these RAISE rather than render.
        #
        # Both are called INLINE from the action bodies, not as before_actions.
        # Rails halts a request when a FILTER renders (the chain checks
        # performed? between callbacks); it does not halt an action because a
        # helper the action called rendered. The previous
        # `render_error(...) and return` returned from THIS METHOD only —
        # control resumed on the next line of the action and ran straight into
        # the gated write. Ai::AutonomyGate executes inline for auto_approve
        # and notify_and_proceed, so a caller with no write permission really
        # created the pool; under require_approval it parked an
        # ApprovalRequest in the operator's queue. The follow-up
        # render_success then raised DoubleRenderError, which ApiResponse
        # swallows with `unless performed?` — so the caller saw a clean 403
        # over a committed write and nothing looked wrong.
        #
        # Authentication::PermissionDenied is the class require_permission
        # raises, and it inherits Exception (NOT StandardError) precisely so an
        # inline check survives the `rescue ActiveRecord::RecordInvalid` in
        # #update, the `rescue PoolError` in #replenish, and ApiResponse's
        # global `rescue_from StandardError`. Its dedicated rescue_from renders
        # the canonical 403 AND unwinds the action, so every present and future
        # call site halts without each one having to remember `return`.
        #
        # The predicate is deliberately unchanged (current_user.has_permission?
        # rather than the controller's delegation-aware has_permission?): this
        # commit changes only WHETHER the action halts, never WHO is allowed.
        def authorize_read!
          return if worker_authenticated?
          return if current_user.has_permission?("system.node_instances.read")

          raise ::Authentication::PermissionDenied.new(
            "permission denied: system.node_instances.read",
            permission: "system.node_instances.read"
          )
        end

        def authorize_write!
          return if worker_authenticated?
          return if current_user.has_permission?("system.instances.create") ||
                    current_user.has_permission?("system.instances.control")

          raise ::Authentication::PermissionDenied.new(
            "permission denied: system.instances.create or .control",
            permission: "system.instances.create"
          )
        end
      end
    end
  end
end
