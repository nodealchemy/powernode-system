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

        # The two PATCH transitions #update routes through Ai::AutonomyGate
        # (IMP-24daa05e7a22), and the size columns a "raise" is measured on.
        # Both categories are declared in
        # System::Governance::PolicyDeclarations::INSTANCE_POOL_POLICIES, which
        # is also what registers them for the Autonomy modal
        # (lib/powernode_system/engine.rb derives the registry from it) — a
        # category gated here and undeclared there would be a control an
        # operator can see and cannot save.
        GATED_UPDATE_CATEGORIES = {
          ceiling_raise: "system.instance_pool_ceiling_raise",
          archive: "system.instance_pool_archive"
        }.freeze

        CEILING_ATTRIBUTES = %w[target_size max_size].freeze

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
        #
        # IMP-24daa05e7a22 — PARTIALLY gated, and which part is gated is the
        # point. This action used to be a bare `@pool.update!(update_params)`,
        # and update_params permit :target_size, :max_size and :status. So the
        # SPEND CEILING that bounds the deliberately-ungated replenish tick
        # (see #replenish below) could be raised with no approval by anyone
        # holding system.instances.control, and `status: "archived"` reached
        # through here exactly the state the GATED #destroy's on_proceed
        # writes.
        #
        # Two transitions are gated, each under its own category so an operator
        # relaxing one does not relax the other:
        #
        #   * a target_size / max_size INCREASE — system.instance_pool_ceiling_raise
        #   * status -> "archived"             — system.instance_pool_archive
        #
        # Everything else is applied inline, by operator direction: DECREASES
        # (they remove spend), min_size, description, regions, metadata, and
        # status "paused"/"draining". `paused` is the one status replenish!
        # refuses, so pausing is a brake, not a commitment; `draining` is left
        # ungated because #drain itself is (its declared require_approval row
        # has no gate site — a separately tracked gap, censused in
        # spec/lint/instance_pool_replenish_gating_spec.rb).
        #
        # The gate covers the WHOLE payload, not just the ceiling field: the
        # executor replays `attributes`, so a raise parks its travelling
        # companions with it rather than half-applying them. "Replays" is
        # bounded by UpdatePool's replay_baseline_attributes, stamped below —
        # an approval that lands after the ceiling moved is refused, not
        # written, because the decrease that moved it needed no approval of
        # its own and so the two can interleave with nobody deciding.
        def update
          authorize_write!
          attrs = update_params.to_h
          categories = gated_update_categories(attrs)

          if categories.size > 1
            return render_error(
              "this PATCH crosses two approval gates (#{categories.join(', ')}) — " \
              "send the ceiling change and the archive as separate requests",
              :unprocessable_content
            )
          end

          return ungated_update!(attrs) if categories.empty?

          gate_update!(
            record: @pool,
            attributes: attrs,
            response_key: :pool,
            serializer: ->(p) { p.to_summary },
            action_category: categories.first,
            executor_class: "System::Executors::InstancePool::UpdatePool",
            # IMP-391525770512 seam: stamp the request-time value of the
            # replay-sensitive attributes THIS request names, so the executor
            # can refuse a replay whose premise expired. It has to be: a raise
            # parks, a DECREASE is applied inline with no approval, and the
            # later approval would otherwise write the old high ceiling back
            # over the reduction. @pool is persisted here — every argument is
            # evaluated before gate_update!'s in-memory assign_attributes.
            params: {
              pool_id: @pool.id,
              attributes: attrs,
              replay_baseline: ::System::Executors::InstancePool::UpdatePool
                                 .replay_baseline(@pool, attrs)
            },
            source_type: "System::InstancePool",
            source_id: @pool.id,
            description: gated_update_description(categories.first, attrs)
          )
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
        #
        # DELIBERATELY UNGATED — IMP-714ab7da6b9c. #create and #destroy above
        # route through gate_create!/gate!; this does not, and that asymmetry
        # is the recorded decision rather than an omission. Note which way
        # round it runs: the two verbs that ARE gated are pool creation and
        # teardown, while the verb that actually provisions VMs is not.
        # (#drain, #recycle_stale and the acquire path are ungated too, as is
        # every #update transition except the two IMP-24daa05e7a22 gated;
        # replenish is the one this note is about.)
        #
        # The reason is in PolicyDeclarations::INSTANCE_POOL_POLICIES, which
        # already declares "system.instance_pool_replenish" => "auto_approve"
        # ("tops up to target — routine") next to
        # "system.instance_pool_create" => "require_approval". A tick is
        # idempotent and bounded twice over (target_size, then the max_size
        # headroom cap in InstancePoolService#replenish!), so it cannot exceed
        # the capacity ceiling standing on the pool.
        #
        # STATE THE LIMITS OF THAT ARGUMENT rather than glossing them — the
        # "spend was already approved when the pool was created" half is the
        # weakest part of it, in two separate ways:
        #
        #   1. The ceiling is not immutable behind the gated verb — it is
        #      gated on the OPERATOR DOORS, which is a smaller claim. #update
        #      permits :target_size, :max_size and :status, and until
        #      IMP-24daa05e7a22 applied all three inline: anyone holding
        #      system.instances.control could raise the ceiling with no
        #      approval and let the next tick spend up to it, or PATCH
        #      "archived" and reproduce the GATED destroy. Increases and the
        #      archive transition now gate under
        #      system.instance_pool_ceiling_raise /
        #      system.instance_pool_archive, and since IMP-067f39468350 the MCP
        #      twin system_update_instance_pool resolves the SAME two
        #      categories through Ai::Executors::DeferredToolCall — so this is
        #      gated on BOTH the REST route and the MCP verb. Still ungated on
        #      BOTH doors: DECREASES, min_size, and status
        #      "paused"/"draining" — none of which raise what a tick may
        #      spend. Still ungated ELSEWHERE, and censused by file and count
        #      in spec/lint/instance_pool_replenish_gating_spec.rb rather than
        #      left to a reader's memory: System::Gitops::ApplyService#apply!
        #      (POOL_SCALAR_KEYS carries target_size/max_size/status) and
        #      System::CiRunnerLeaseService. The gate narrows who can raise a
        #      ceiling unattended; it does not make the column immutable.
        #   2. #create is gated on both doors too, as of IMP-067f39468350: the
        #      MCP verb system_create_instance_pool used to call
        #      System::InstancePool.create! directly, so a pool minted over MCP
        #      never had an approved ceiling at all. It now declares
        #      action_category/executor_class/gate_context/on_proceed and parks
        #      under system.instance_pool_create like this route. GitOps apply
        #      and the CI-runner lease can still mint or raise without one.
        #
        # WHAT A GATE HERE WOULD COST. This is the route
        # System::InstancePoolReplenisherJob
        # (worker/app/jobs/system/instance_pool_replenisher_job.rb) POSTs on a
        # 60 s Sidekiq cron for every pool it lists (status=active,draining): a
        # require_approval gate here would park one approval per pool per
        # minute and stall replenishment fleet-wide, which is an availability
        # decision, not a control. Note also that authorize_write! below
        # short-circuits on worker_authenticated?, so that cron clears the
        # permission check as well as the (absent) gate.
        #
        # System::Executors::InstancePool::ReplenishPool is the executor that
        # WOULD gate this. It is complete and tested but has no producer, on
        # purpose — see the rationale in that file before wiring or deleting
        # it. Both halves are pinned by
        # spec/lint/instance_pool_replenish_gating_spec.rb, so gating this
        # action reds that guard and forces the prose to move with the code.
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

        # Categories this payload has to clear before it may be written, in a
        # stable order. Empty ⇒ the write is applied inline; more than one ⇒
        # #update refuses the request rather than letting one category's
        # verdict carry the other transition through.
        def gated_update_categories(attrs)
          categories = []
          categories << GATED_UPDATE_CATEGORIES[:ceiling_raise] if raises_ceiling?(attrs)
          if attrs["status"].to_s == "archived" && @pool.status != "archived"
            categories << GATED_UPDATE_CATEGORIES[:archive]
          end
          categories
        end

        # Measured against the PERSISTED row: re-sending the standing value is
        # not a raise, and a decrease never gates. A size that is absent, null
        # or non-numeric is not a raise either — it is an invalid payload, and
        # the inline path answers it with the same field-level 422 it always
        # did rather than parking an operation that could never run.
        def raises_ceiling?(attrs)
          CEILING_ATTRIBUTES.any? do |field|
            requested = coerce_size(attrs[field])
            requested.present? && requested > @pool.public_send(field).to_i
          end
        end

        def coerce_size(value)
          Integer(value.to_s, 10)
        rescue ArgumentError, TypeError
          nil
        end

        def ungated_update!(attrs)
          @pool.update!(attrs)
          render_success(pool: @pool.to_summary)
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation failed: #{e.message}", :unprocessable_content)
        end

        # The approval card's headline. Reads the PRE-change row deliberately —
        # gate_update! has not assigned anything when this is evaluated, so the
        # card can say what the ceiling is being moved FROM.
        def gated_update_description(category, attrs)
          return "Archive instance pool '#{@pool.name}'" if category == GATED_UPDATE_CATEGORIES[:archive]

          moves = CEILING_ATTRIBUTES.filter_map do |field|
            requested = coerce_size(attrs[field])
            current = @pool.public_send(field).to_i
            next if requested.blank? || requested <= current

            "#{field} #{current} -> #{requested}"
          end

          "Raise instance pool '#{@pool.name}' ceiling (#{moves.join(', ')})"
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
