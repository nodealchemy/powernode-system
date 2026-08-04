# frozen_string_literal: true

module System
  # Campaign 019f6084 inc-M — drives a System::FulfillmentRequest forward through
  # its state machine. The module-forge analog of
  # System::NativeModuleBuildOrchestrator#advance!: idempotent, resumable, and
  # NON-BLOCKING at the one genuinely async wait (the module-build barrier).
  #
  # The old synchronous skill SLEPT in a poll loop through the build barrier and
  # then RE-COMPOSED its plan on the approved re-invocation. This orchestrator
  # does neither: it replays the FROZEN plan (request.plan["execution"]) and, when
  # it reaches `building` with a batch that hasn't finished, it simply RETURNS —
  # the sweep re-ticks it later. State persists on the row, so a mid-flight run
  # resumes from wherever the last transition landed.
  #
  # advance! drives as many phases as it can THIS tick (like the native build
  # orchestrator dispatching every ready module in one pass), stopping only at a
  # terminal state or the build-barrier wait. Each phase's work is guarded by
  # whether its output is already recorded on the row, so a re-entry after a crash
  # mid-loop picks up cleanly.
  #
  #   composed → (needs out-of-band approval; no-op here)
  #   approved → [budget + rate-limit GATE] → materializing
  #   materializing → [materialize gaps, dispatch native build] → building | templated
  #   building → [WAIT for the batch; NO sleep] → templated
  #   templated → [author NEW template + closure dry-run] → provisioning
  #   provisioning → [scoped-pool fast path / fresh provision + task-scoped lease] → smoking
  #   smoking → [ModuleSmokeVerify on the leased instance] → ready
  #
  # On ANY step exception: rollback (terminate provisioned instances via
  # ProvisionFullStackExecutor#rollback_provision_full_stack, destroy the orphan
  # template + materialized modules) then fail! the request.
  class FulfillmentAdvanceOrchestrator
    # Rate-limit fallback (overridable via SiteSetting system.fulfill.max_requests_per_hour).
    DEFAULT_MAX_REQUESTS_PER_HOUR = 20

    # Safety bound on phases advanced in one tick — the linear chain is 6
    # transitions; anything past this is a bug (a phase failing to make progress
    # without terminating), so stop rather than spin.
    MAX_STEPS_PER_TICK = 12

    Result = Struct.new(:ok?, :state, :advanced, :waiting, :parked, :error,
                        :already_advancing, keyword_init: true)

    def self.advance!(request:)
      new(request: request).advance!
    end

    # Stable 63-bit signed key from the request UUID (fits a Postgres bigint).
    # Mirrors System::PackageRepositorySyncService#advisory_lock_key.
    def self.advisory_lock_key(request_id)
      ::Digest::SHA256.hexdigest("fulfillment-advance:#{request_id}").to_i(16) % (2**63)
    end

    def initialize(request:)
      @request = request
      @account = request.account
    end

    # SERIALIZED PER REQUEST. advance! walks as far down the chain as it can in
    # one call — materialize, dispatch a build, author a template, PROVISION
    # CLOUD INSTANCES, smoke — which takes minutes, while
    # System::FulfillmentRequestSweepService re-ticks every ADVANCEABLE row
    # every 60s. Every phase guard is read-then-act (`materialized_recorded?`,
    # `@request.template_id.present?`, ...) with no row lock, no lock_version,
    # and no uniqueness constraint behind it, so two overlapping advances of the
    # SAME request each read "not provisioned yet" and each provision — real
    # duplicate cloud spend, not just wasted work.
    #
    # The lock lives HERE rather than in either caller because there are two
    # independent entrants (the operator approve endpoint and the 60s sweep) and
    # locking one excludes nothing unless the other locks on the same key.
    #
    # NON-BLOCKING on purpose: a loser returns `already_advancing` immediately
    # instead of queueing behind a multi-minute provision. The sweep just skips
    # the row and picks it up next tick — the state machine is resumable, so
    # there is nothing to wait for. Session-level (not transaction-level) so a
    # multi-minute advance never pins a DB transaction; released in an ensure so
    # a mid-phase raise cannot leak it, and a dead process's session lock is
    # dropped by Postgres automatically.
    def advance!
      return already_advancing_result unless acquire_advance_lock!

      begin
        advance_locked!
      ensure
        release_advance_lock!
      end
    end

    private

    def advance_locked!
      steps = 0
      loop do
        break if @request.terminal?
        # The ONE async wait: sit in `building` until the batch finishes. No
        # sleep — the sweep re-ticks this record; state is already persisted.
        return waiting_result if @request.building? && !build_finished?

        moved = advance_one
        break unless moved

        steps += 1
        break if steps >= MAX_STEPS_PER_TICK
      end
      result_for_state
    rescue StandardError => e
      handle_failure(e.message)
      result_for_state
    end

    # --- per-request advance serialization (see advance!) ---

    def advisory_lock_key
      self.class.advisory_lock_key(@request.id)
    end

    # Postgres session advisory locks are re-entrant WITHIN one session, so a
    # sequential re-entry on the same connection (same process) still proceeds —
    # only a genuinely concurrent holder on another connection is excluded,
    # which is exactly the sweep-vs-operator case this guards.
    def acquire_advance_lock!
      lock_connection.select_value("SELECT pg_try_advisory_lock(#{advisory_lock_key})")
    end

    def release_advance_lock!
      lock_connection.select_value("SELECT pg_advisory_unlock(#{advisory_lock_key})")
    rescue StandardError => e
      Rails.logger.warn("[FulfillmentAdvance] advisory unlock failed for ##{@request.id}: #{e.class}: #{e.message}")
    end

    def lock_connection
      ::System::FulfillmentRequest.connection
    end

    def already_advancing_result
      Rails.logger.info(
        "[FulfillmentAdvance] ##{@request.id}: another advance holds the lock — skipping duplicate"
      )
      Result.new(ok?: true, state: @request.state, advanced: false, waiting: false,
                 parked: @request.parked, error: nil, already_advancing: true)
    end

    def advance_one
      case @request.state
      when "approved"      then advance_approved
      when "materializing" then advance_materializing
      when "building"      then advance_building
      when "templated"     then advance_templated
      when "provisioning"  then advance_provisioning
      when "smoking"       then advance_smoking
      else false # composed (needs approval) / terminal
      end
    end

    # ---- approved: budget + rate-limit gate, then start materializing ----
    def advance_approved
      decision = evaluate_gate
      if decision.first == :reject
        _, step, reason = decision
        @request.park_gate!(step: step, reason: reason)
        return false # stay approved — resumable (retry next tick / next hour)
      end

      @request.start_materializing!
      true
    end

    # ---- materializing: materialize gaps + dispatch native build ----
    def advance_materializing
      materialize! unless materialized_recorded?

      if @request.build_batch_id.present?
        @request.start_building!
      else
        @request.mark_templated! # all-reused / no build needed — skip the barrier
      end
      true
    end

    def materialized_recorded?
      no_gaps? || @request.build_batch_id.present? || Array(@request.materialized_module_ids).any?
    end

    def no_gaps?
      Array(execution["gaps"]).empty?
    end

    # Materialize each gap via the package_module_create path DIRECTLY (its
    # separate approval is subsumed by the consolidated fulfillment approval).
    # baseline-excluded + native build_mode (routes through PackageClosureBuildBridge).
    def materialize!
      gaps = Array(execution["gaps"])
      return if gaps.empty?

      base_os = base_os_module!
      materialized_ids = []
      materialized_names = []
      build_batch = nil

      gaps.each do |gap|
        repo = ::System::PackageRepository.accessible_to(@account).find_by(id: gap["repository_id"])
        unless repo
          @request.add_park!(step: "materialize",
                             reason: "repository #{gap['repository_id']} not accessible (package=#{gap['package']})")
          next
        end

        result = ::System::PackageModuleMaterializer.call(
          repository:          repo,
          package_name:        gap["package"],
          architectures:       Array(repo.architectures).presence || [ "amd64" ],
          account:             @account,
          requested_by_user:   effective_user,
          include_baseline:    false,
          base_os_module_name: base_os.name,
          dispatch_build:      true,
          build_mode:          :native
        )
        raise "materialize failed for #{gap['package']}: #{result.errors.join('; ')}" unless result.success?

        materialized_ids   << result.top_level_module.id
        materialized_names << result.top_level_module.name
        build_batch ||= result.build_batch
      end

      @request.record_materialization!(module_ids: materialized_ids,
                                       module_names: materialized_names, build_batch: build_batch)
    end

    # ---- building: WAIT for the batch (no sleep); on finish, advance ----
    def advance_building
      batch = @request.build_batch
      # Reached here only once build_finished? is true. Refuse to provision from
      # anything but a fully-`complete` batch — a partial/failed batch means a
      # module in the closure has no built artifact (real cloud spend on a broken
      # instance, exactly what the old skill risked).
      if batch && !batch.reload.complete?
        raise "module build batch #{batch.id} did not complete (status=#{batch.status}) — " \
              "refusing to author a template / provision from an unbuilt closure"
      end

      @request.mark_templated!
      true
    end

    def build_finished?
      batch = @request.build_batch
      return true if batch.nil?
      batch.reload.finished?
    end

    # ---- templated: author the NEW template + closure dry-run ----
    def advance_templated
      author_template! if @request.template_id.blank?
      @request.start_provisioning!
      true
    end

    def author_template!
      exec = execution
      base_os = base_os_module!
      reused_ids = Array(exec["reused_modules"]).map { |m| m["id"] }.compact
      module_ids = (reused_ids + Array(@request.materialized_module_ids)).uniq

      # `effective_user` is best-effort ATTRIBUTION (requester, else any account
      # user), not authorization — an autonomous advance can legitimately run
      # with none. When it resolves to nobody this is an in-process system
      # caller and says so; the tool no longer reads a nil user as "internal",
      # since MCP instance principals also arrive userless. (IMP-9030413bc292)
      attributed_user = effective_user
      fleet = ::Ai::Tools::SystemFleetTool.new(
        account: @account, agent: nil, user: attributed_user, internal: attributed_user.nil?
      )
      resolved_platform_id = exec["platform_id"].presence || base_os.node_platform_id

      reclaim_abandoned_template!(template_name)

      create = fleet.execute(params: {
        action: "system_create_template",
        name: template_name,
        description: "On-demand fulfillment: #{@request.request}".truncate(280),
        node_platform_id: resolved_platform_id,
        # PROVENANCE STAMP, written in the SAME INSERT as the name — there is no
        # window in which a template this method created lacks it. It is the only
        # thing that can distinguish our own abandoned artifact from an
        # operator's same-named template (see reclaim_abandoned_template!).
        config: { "fulfillment_request_id" => @request.id }
      })
      raise "template create failed: #{create[:error]}" unless create[:success]

      template = ::System::NodeTemplate.where(account_id: @account.id).find(create.dig(:data, :template, :id))

      # @request.template_id is only recorded on FULL success (below) — it is
      # the `advance_templated` resume guard (`author_template! if
      # @request.template_id.blank?`), so setting it any earlier would make a
      # crash mid-loop (process killed, no exception) look "already authored"
      # on the next tick and send an incompletely-assigned template straight
      # into provisioning. That means the top-level rollback! (which only
      # destroys the template `if @request.template_id.present?`) can never
      # see this template on a mid-loop failure — so failure here must clean
      # up after itself instead of leaking the template + its TemplateModule
      # joins (dependent: :destroy on NodeTemplate#template_modules).
      begin
        ([ base_os.id ] + module_ids).uniq.each do |mid|
          assign = fleet.execute(params: {
            action: "system_assign_module_to_template", template_id: template.id, module_id: mid
          })
          raise "assign module #{mid} failed: #{assign[:error]}" unless assign[:success]
        end

        assert_closure!(template: template, base_os: base_os)
        # Inside the rescue's protection on purpose: record_template! is a bare
        # update! that can itself raise (connection drop, statement timeout —
        # exactly the failure class this cleanup exists for). If it raises after
        # committing, rollback!'s `template_id.present?` check finds it and its
        # find_by returns nil post-destroy below — no double-destroy either way.
        @request.record_template!(template)
      rescue StandardError => e
        begin
          # destroy! (not destroy): a blocked has_many :nodes, dependent:
          # :restrict_with_error returns false rather than raising, which would
          # skip the rescue below and leak the template SILENTLY — the opposite
          # of this cleanup's intent.
          template.destroy!
        rescue StandardError => destroy_error
          Rails.logger.warn(
            "[FulfillmentAdvanceOrchestrator] cleanup of orphan template #{template.id} after author " \
            "failure raised: #{destroy_error.class}: #{destroy_error.message}"
          )
        end
        raise e
      end
    end

    # Deterministic per request — which is what makes a re-author after a crash
    # collide, and what makes the collision AMBIGUOUS: the operator-supplied
    # form is not evidence of anything, the fallback is.
    def template_name
      execution["template_name"].presence || "fulfill-#{@request.id}"
    end

    # A process KILL — OOM, node reboot, hard stop; NOT an exception, so none of
    # the rescue-cleanup above gets to run — between the create and
    # record_template! leaves state=templated, template_id STILL BLANK, and an
    # orphaned, incompletely-assigned template holding `template_name`. The next
    # sweep tick correctly re-enters author_template! (that blank template_id is
    # the crash-recovery guard keeping a half-assigned template out of
    # provisioning), the create collides with NodeTemplate's per-account name
    # uniqueness, and handle_failure fails the request TERMINALLY. Reclaiming our
    # own abandoned artifact makes the request resumable WITHOUT weakening the
    # guard: the incomplete template is destroyed and a fresh one authored, so a
    # partially-assigned template is still never provisioned from.
    #
    # Blind destroy-by-name would be data loss — `execution["template_name"]` can
    # be operator-chosen. Reclaim requires ALL of:
    #
    #   * account scope — uniqueness is `scope: :account_id`, so a collision is
    #     always in-account. That is scoping, not evidence.
    #   * config["fulfillment_request_id"] == THIS request's id — the stamp
    #     author_template! writes atomically with the name.
    #   * created_at >= templated_at — author_template! only ever runs from the
    #     `templated` state (entered once; the transition is one-way), so
    #     anything we authored necessarily postdates it. This is what stops a
    #     stamp that arrived some other way — an operator's
    #     system_update_template REPLACES config wholesale, as does a restore —
    #     from reading as ours.
    #   * no Nodes attached — something is running on it, so whatever else it
    #     looks like it is not abandoned.
    #   * unreferenced by any FulfillmentRequest.template_id — a template a run
    #     recorded on FULL success is that run's live artifact. Redundant given
    #     the stamp; kept because it costs one indexed existence check and the
    #     failure it guards is silent data loss.
    #
    # It deliberately does NOT reclaim: an operator's template that merely shares
    # the name, another request's orphan (that request may still resume onto it),
    # or an orphan left by a run predating the stamp. Those FAIL LOUD naming the
    # conflicting template — a leaked template is recoverable by an operator, a
    # destroyed one is not. Nothing reaps unreferenced orphans yet; that is a
    # separate sweep, not this method's job.
    def reclaim_abandoned_template!(name)
      existing = ::System::NodeTemplate.where(account_id: @account.id).find_by(name: name)
      return if existing.nil?

      unless reclaimable_orphan?(existing)
        raise "template name #{name.inspect} is already taken by NodeTemplate #{existing.id}, " \
              "which is not this request's abandoned authoring artifact — refusing to destroy it. " \
              "Rename or remove that template, or set a different execution.template_name."
      end

      Rails.logger.warn(
        "[FulfillmentAdvanceOrchestrator] reclaiming abandoned template #{existing.id} (#{name}) left by " \
        "an interrupted authoring run for request #{@request.id} — re-authoring from scratch"
      )
      existing.destroy!
    end

    def reclaimable_orphan?(template)
      config = template.config
      return false unless config.is_a?(Hash) && config["fulfillment_request_id"] == @request.id
      return false if @request.templated_at.blank? || template.created_at.blank?
      return false if template.created_at < @request.templated_at
      return false if template.nodes.exists?

      !::System::FulfillmentRequest.where(template_id: template.id).exists?
    end

    # Dry-run apply on a transient node — assert the closure resolves + includes
    # base-os (the inc1 guarantee) without persisting a throwaway node.
    def assert_closure!(template:, base_os:)
      node = ::System::Node.new(account: @account, node_template: template)
      result = ::System::TemplateApplyService.new(node).apply!(dry_run: true)
      raise "closure dry-run failed: #{result.errors.join('; ')}" unless result.ok?

      closure_names = result.created.map { |c| c.node_module.name }
      unless closure_names.include?(base_os.name)
        raise "closure does not resolve base-os (#{base_os.name}) — inc1 guarantee unmet"
      end
    end

    # ---- provisioning: scoped-pool fast path / fresh provision + lease ----
    def advance_provisioning
      provision_and_lease! if Array(@request.node_instance_ids).empty?
      @request.start_smoking!
      true
    end

    def provision_and_lease!
      template = current_template!
      exec = execution
      count = exec["count"].to_i
      count = 1 if count < 1
      region = resolve_region(exec["provider_region_id"])
      type   = resolve_instance_type(exec["provider_instance_type_id"])

      instances = []

      # (1) Optional scoped-pool fast path (only when an operator designated a
      # fulfillment pool — never an unscoped acquire that could starve CI).
      count.times do
        member = acquire_from_fulfillment_pool
        break unless member
        ensure_template_applied!(instance: member, template: template)
        apply_lease!(member)
        instances << member
      end

      # (2) Fresh-provision the remainder (the PRIMARY path).
      remaining = count - instances.size
      if remaining.positive?
        if region && type
          fresh_provision(template: template, count: remaining, region: region, type: type).each do |inst|
            ensure_template_applied!(instance: inst, template: template)
            apply_lease!(inst)
            instances << inst
          end
        elsif instances.empty?
          @request.add_park!(step: "provision",
                             reason: "no resolvable provider_region / provider_instance_type — provision parked")
        else
          @request.add_park!(step: "provision",
                             reason: "leased #{instances.size}/#{count} from the fulfillment pool; " \
                                     "remainder parked (no resolvable provider_region / type)")
        end
      end

      @request.record_instances!(instances.map(&:id))
      @request.update!(expires_at: Time.current + lease_ttl) if instances.any?
    end

    def acquire_from_fulfillment_pool
      pool_name = ::SiteSetting.get("system.fulfill.pool_name").presence
      lifecycle = ::SiteSetting.get("system.fulfill.pool_lifecycle_class").presence
      return nil unless pool_name || lifecycle

      ::System::InstancePoolService.acquire!(account: @account, pool_name: pool_name, lifecycle_class: lifecycle)
    rescue ::System::InstancePoolService::PoolError
      nil
    end

    def fresh_provision(template:, count:, region:, type:)
      prov = ::System::Ai::Skills::ProvisionFullStackExecutor
             .new(account: @account, agent: nil, user: effective_user)
             .execute(template_id: template.id, count: count,
                      provider_region_id: region.id, provider_instance_type_id: type.id)

      ids = Array(prov.dig(:data, :outputs, :node_instance_ids))
      unless prov[:success] && ids.any?
        @request.add_park!(step: "provision",
                           reason: "live provision unavailable in this env (#{prov[:error] || 'no instances created'})")
        return []
      end

      ::System::NodeInstance.where(account_id: @account.id, id: ids).to_a
    end

    # Rebind the instance's node onto the fulfill template, materialize the
    # assignment closure, and queue an on-node sync — so a re-used pool member
    # actually carries the fulfill modules (never handed back generic).
    def ensure_template_applied!(instance:, template:)
      node = instance.node
      return unless node

      node.update!(node_template: template) unless node.node_template_id == template.id
      ::System::TemplateApplyService.new(node).apply!(dry_run: false)

      ::System::Task.create!(
        account: @account, operable: instance, command: "sync_modules", status: "pending",
        options: { "source" => "fulfill_capability_request",
                   "fulfillment_request_id" => @request.id, "template_id" => template.id }
      )
    end

    # Task-scoped lease. FRESH (non-pool) instances get a FIRST-CLASS
    # lifecycle_class + lease_expires_at the fulfillment reaper governs; re-used
    # pool members stay governed by the pool reaper's claimed_ttl (never
    # double-governed). The config blob is retained for operator-visible detail.
    def apply_lease!(instance)
      ttl = lease_ttl
      now = Time.current
      blob = {
        "source"                 => "fulfill_capability_request",
        "fulfillment_request_id" => @request.id,
        "request"                => @request.request.to_s.truncate(200),
        "acquired_at"            => now.iso8601,
        "ttl_seconds"            => ttl,
        "expires_at"             => (now + ttl).iso8601,
        "task_scoped"            => true
      }
      attrs = { config: (instance.config || {}).merge("fulfillment_lease" => blob) }
      unless instance.in_pool?
        attrs[:lifecycle_class]  = "task_scoped"
        attrs[:lease_expires_at] = now + ttl
      end
      instance.update!(attrs)
    end

    # ---- smoking: verify the leased instance in place ----
    def advance_smoking
      run_smoke! if @request.smoke.blank?
      @request.mark_ready!
      true
    end

    def run_smoke!
      instance = representative_instance
      unless instance
        @request.record_smoke!({ "ok" => nil, "skipped" => "no provisioned instance to smoke" })
        return
      end

      module_name = primary_module_name
      if module_name.blank?
        @request.record_smoke!({ "ok" => nil, "skipped" => "no primary module to probe" })
        return
      end

      result = ::System::Ai::Skills::ModuleSmokeVerifyExecutor
               .new(account: @account, agent: nil, user: effective_user)
               .execute(module_name: module_name, base_os_module_name: base_os_name,
                        template_id: @request.template_id, instance_id: instance.id)
      @request.add_park!(step: "smoke_probe",
                         reason: "health probe dispatched to the on-node agent — result recorded")
      @request.record_smoke!(result[:success] ? (result[:data] || {}) : { "ok" => false, "error" => result[:error] })
    end

    # ======================= failure + rollback =======================

    def handle_failure(message)
      rollback!(message)
      @request.fail!(message) if @request.may_fail?
    rescue StandardError => e
      Rails.logger.error("[FulfillmentAdvanceOrchestrator] failure handling for #{@request.id} raised: #{e.message}")
    end

    # LIFO-ish teardown of every recorded artifact so a failed run leaves no
    # zombie fleet / orphan template / dangling materialized module. Order
    # matters: terminate cloud VMs, then destroy the run's (task-scoped) node
    # rows — which cascades their instance/assignment/task rows and, crucially,
    # frees the template's `restrict_with_error` FK so the template can be
    # destroyed. Materialized modules go last (their template_modules /
    # assignments are already gone).
    def rollback!(message)
      ids = Array(@request.node_instance_ids)
      instances = ::System::NodeInstance.where(account_id: @account.id, id: ids).to_a
      node_ids  = instances.map(&:node_id).compact.uniq

      # 1. terminate the provider-side VMs (node.destroy only removes DB rows).
      if ids.any?
        ::System::Ai::Skills::ProvisionFullStackExecutor
          .new(account: @account, agent: nil, user: effective_user)
          .rollback_provision_full_stack(node_instance_ids: ids)
      end

      # 2. destroy the run's node rows (cascades node_instances + assignments +
      # tasks; unblocks the template FK). These nodes are task-scoped throwaways
      # authored for THIS fulfillment.
      ::System::Node.where(account_id: @account.id, id: node_ids).find_each do |node|
        node.destroy
      rescue StandardError => e
        Rails.logger.warn("[FulfillmentAdvanceOrchestrator] node #{node.id} cleanup failed: #{e.message}")
      end

      # 3. destroy the orphaned template (now unreferenced).
      if @request.template_id.present?
        tmpl = ::System::NodeTemplate.where(account_id: @account.id).find_by(id: @request.template_id)
        tmpl&.destroy
      end

      # 4. destroy the modules this run materialized (best-effort — a shared
      # module that other work already referenced stays, logged not raised).
      Array(@request.materialized_module_ids).each do |mid|
        mod = @account.system_node_modules.find_by(id: mid)
        mod&.destroy
      rescue StandardError => e
        Rails.logger.warn("[FulfillmentAdvanceOrchestrator] materialized-module #{mid} cleanup failed: #{e.message}")
      end

      @request.add_park!(step: "rollback", reason: "rolled back artifacts on failure: #{message}".truncate(280))
    rescue StandardError => e
      Rails.logger.warn("[FulfillmentAdvanceOrchestrator] rollback for #{@request.id} raised: #{e.message}")
    end

    # ======================= gate =======================

    # Returns [:ok] or [:reject, step, reason]. Both caps are SiteSetting-driven;
    # the budget cap is inert until a positive value is configured (mirrors
    # Ai::Campaign's cost guard), the rate limit defaults to a generous safety cap.
    def evaluate_gate
      max_hourly = ::SiteSetting.get("system.fulfill.max_hourly_cost").to_f
      if max_hourly.positive?
        hourly_total = (@request.cost_estimate || {})["hourly_total"].to_f
        if hourly_total > max_hourly
          return [ :reject, "budget_gate",
                   "estimated hourly cost #{hourly_total} exceeds cap system.fulfill.max_hourly_cost=#{max_hourly}" ]
        end
      end

      raw = ::SiteSetting.get("system.fulfill.max_requests_per_hour")
      max_per_hour = raw.nil? ? DEFAULT_MAX_REQUESTS_PER_HOUR : raw.to_i
      if max_per_hour.positive?
        started = ::System::FulfillmentRequest.for_account(@account)
                                              .where("materializing_at > ?", 1.hour.ago)
                                              .where.not(id: @request.id).count
        if started >= max_per_hour
          return [ :reject, "rate_limit_gate",
                   "account started #{started} fulfillment(s) in the last hour " \
                   "(cap system.fulfill.max_requests_per_hour=#{max_per_hour})" ]
        end
      end

      [ :ok ]
    end

    # ======================= helpers =======================

    def execution
      @request.execution
    end

    def base_os_module!
      exec = execution
      mod = @account.system_node_modules.find_by(id: exec["base_os_module_id"]) ||
            @account.system_node_modules.find_by(name: exec["base_os_module_name"])
      raise "base-os module not found (#{exec['base_os_module_name']})" unless mod
      mod
    end

    def base_os_name
      execution["base_os_module_name"]
    end

    def current_template!
      tmpl = ::System::NodeTemplate.where(account_id: @account.id).find_by(id: @request.template_id)
      raise "fulfill template #{@request.template_id} missing" unless tmpl
      tmpl
    end

    def representative_instance
      ::System::NodeInstance.where(account_id: @account.id).find_by(id: Array(@request.node_instance_ids).first)
    end

    def primary_module_name
      Array(@request.materialized_modules).first || Array(execution["reused_modules"]).first&.dig("name")
    end

    def resolve_region(id)
      return nil if id.blank?
      ::System::ProviderRegion.where(account_id: @account.id).find_by(id: id)
    end

    def resolve_instance_type(id)
      return nil if id.blank?
      ::System::ProviderInstanceType.where(account_id: @account.id).find_by(id: id)
    end

    def lease_ttl
      ttl = @request.lease_ttl_seconds.to_i
      ttl.positive? ? ttl : ::System::Ai::Skills::FulfillCapabilityRequestExecutor::DEFAULT_LEASE_TTL_SECONDS
    end

    def effective_user
      @effective_user ||= (@request.requested_by_user_id &&
        @account.users.find_by(id: @request.requested_by_user_id)) || @account.users.first
    end

    def waiting_result
      Result.new(ok?: true, state: @request.state, advanced: false, waiting: true,
                 parked: @request.parked, error: @request.error)
    end

    def result_for_state
      Result.new(ok?: @request.state != "failed", state: @request.state, advanced: true,
                 waiting: false, parked: @request.parked, error: @request.error)
    end
  end
end
