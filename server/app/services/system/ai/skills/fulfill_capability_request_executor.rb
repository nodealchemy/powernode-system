# frozen_string_literal: true

module System
  module Ai
    module Skills
      # THE on-demand vertical slice (campaign 019f6084 inc3): turn a
      # natural-language capability request ("give me a running memcached
      # instance") into a RUNNING, leased instance by COMPOSING the seams that
      # already exist — nothing here re-implements materialize / build / provision
      # / smoke; it orchestrates them behind ONE consolidated plan approval.
      #
      # Composed flow (each step delegates to an existing service/skill):
      #   1. module_compose (semantic)         → modules that already cover the request
      #   2. discover_packages_by_intent       → package for each uncovered capability
      #      + PackageModuleMaterializer       → materialize it (baseline-excluded, inc2-B)
      #      + PackageClosureBuildBridge        → ModuleBuildBatch(trigger:"package")   (via the materializer)
      #   3. poll the ModuleBuildBatch to a terminal state (inc2-A read surface)  [LIVE PARKED]
      #   4. system_create_template + system_assign_module_to_template
      #                                        → NEW template = [base-os, resolved+materialized]
      #   5. TemplateApplyService.apply!(dry_run:true) → assert the closure resolves + includes base-os (inc1)
      #   6. FRESH provision (ProvisionFullStackExecutor) — the primary path — or,
      #      when an operator designates a SCOPED fulfillment pool, a re-templated
      #      pool member; every returned instance is leased + carries the fulfill
      #      template's modules (ensure_template_applied!)                        [LIVE PARKED]
      #   7. module_smoke_verify the leased instance IN PLACE (instance_id)       [PROBE PARKED]
      #   8. structured fulfillment report (reused vs materialized, batch/template/instance ids, lease, smoke)
      #
      # APPROVAL — ONE consolidated, audited decision. Without `approved: true`
      # the skill returns the PLAN (closure enumeration per the bulk-op safety
      # rule: count N + first 3 / last 1, template diff, instance count, cost
      # estimate) and performs ZERO side effects — the gate BLOCKS. The single
      # approval covers the whole plan; the transitive materialization closure
      # rides it (package_module_create is designed to), so materialize +
      # template + provision are never prompted separately.
      #
      # PARKED live steps (reported honestly, not silently skipped): the actual
      # native build (no builder fleet in this env — PackageClosureBuildBridge
      # doc) and the live cloud provision (no ready pool / no cloud provider in
      # dev) are WIRED but cannot execute here; the smoke health probe is parked
      # platform-wide (no remote-exec primitive — ModuleSmokeProbe doc; campaign
      # decision gate-remote-exec-smoke-primitive). Specs mock those seams.
      class FulfillCapabilityRequestExecutor < BaseSkillExecutor
        DEFAULT_BASE_OS_MODULE_NAME = "base-os-ubuntu-noble"

        # Fallback defaults ONLY — every one is overridable via SiteSetting so
        # no operator-facing cap is a bare constant.
        DEFAULT_COUNT               = 1
        DEFAULT_MAX_INSTANCES       = 5        # system.fulfill.max_instances
        DEFAULT_LEASE_TTL_SECONDS   = 4 * 3600 # system.fulfill.lease_ttl_seconds
        DEFAULT_BUILD_POLL_ATTEMPTS = 60       # system.fulfill.build_poll_attempts
        DEFAULT_BUILD_POLL_INTERVAL = 5        # system.fulfill.build_poll_interval_seconds

        skill_descriptor(
          name: "fulfill_capability_request",
          description: "On-demand: turn an NL capability request into a running, leased instance — compose/materialize modules, build, author a template, provision, smoke-verify. ONE consolidated plan approval.",
          category: "devops",
          inputs: {
            request: { type: "string", required: true,
                       description: "Free-form capability request, e.g. 'give me a running memcached instance'" },
            count: { type: "integer", required: false, default: DEFAULT_COUNT,
                     description: "Instances to provision (default 1; capped by SiteSetting system.fulfill.max_instances)" },
            approved: { type: "boolean", required: false, default: false,
                        description: "Consolidated plan approval. false → return the plan + requires_approval and perform NO side effects (the gate)." },
            base_os_module_name: { type: "string", required: false, default: DEFAULT_BASE_OS_MODULE_NAME },
            platform_id: { type: "string", required: false,
                           description: "Restrict module composition to a NodePlatform (defaults to the base-os module's platform)" },
            provider_region_id: { type: "string", required: false,
                                  description: "Override region for provisioning (defaults to account's first enabled region / SiteSetting)" },
            provider_instance_type_id: { type: "string", required: false,
                                         description: "Override instance type (defaults to account's cheapest / SiteSetting)" }
          },
          outputs: {
            plan: :object,
            executed: :boolean,
            requires_approval: :boolean,
            reused_modules: [ :string ],
            materialized_modules: [ :string ],
            build_batch_id: :string,
            template_id: :string,
            instance_id: :string,
            instance_ids: [ :string ],
            lease: :object,
            leases: [ :object ],
            smoke: :object,
            parked: [ :object ]
          },
          requires_approval: true,
          blast_radius: :high
        )

        # System Concierge = the NL surface; Fleet Autonomy = policy-gated
        # autonomous fulfillment.
        binds_to "System Concierge", "Fleet Autonomy"

        protected

        def perform(request:, count: DEFAULT_COUNT, approved: false,
                    base_os_module_name: DEFAULT_BASE_OS_MODULE_NAME, platform_id: nil,
                    provider_region_id: nil, provider_instance_type_id: nil, **_extras)
          return failure("request is required") if request.to_s.strip.empty?

          count = resolve_count(count)

          base_os = @account.system_node_modules.find_by(name: base_os_module_name)
          return failure("base-os module not found: #{base_os_module_name}") unless base_os

          # --- Step 1: compose (read-only) ---
          compose = ModuleComposeExecutor
                    .new(account: @account, agent: @agent, user: @user)
                    .execute(description: request, platform_id: platform_id)
          return failure("module_compose failed: #{compose[:error]}") unless compose[:success]

          reused = Array(compose.dig(:data, :draft_template, :modules))
          gaps   = Array(compose.dig(:data, :gaps)).select { |g| g[:action] == "materialize" }

          region = resolve_region(provider_region_id)
          type   = resolve_instance_type(provider_instance_type_id)

          plan = build_plan(request:, base_os:, reused:, gaps:, count:, region:, type:)

          # --- APPROVAL GATE ---
          unless approved
            return success(
              plan: plan,
              executed: false,
              requires_approval: true,
              reused_modules: reused.map { |m| m[:name] },
              materialized_modules: [],
              parked: []
            )
          end

          execute_plan(request:, base_os:, reused:, gaps:, count:, platform_id:,
                       region:, type:, plan:)
        end

        private

        # ================= EXECUTE (approved replay) =================
        def execute_plan(request:, base_os:, reused:, gaps:, count:, platform_id:, region:, type:, plan:)
          parked = []

          materialized, build_batch = materialize_gaps(gaps: gaps, base_os: base_os, parked: parked)

          # Step 3 — await the build barrier. On a NON-terminal batch (timeout /
          # no builder fleet) we STOP HERE: authoring a template + provisioning
          # from a module with no built artifact means real cloud spend on a
          # broken instance. Return a non-executed, parked result BEFORE any
          # template create or provision.
          if build_batch && !await_build_batch(build_batch)
            return success(
              plan: plan,
              executed: false,
              requires_approval: true,
              reused_modules: reused.map { |m| m[:name] },
              materialized_modules: materialized.map(&:name),
              build_batch_id: build_batch.id,
              instance_ids: [],
              leases: [],
              parked: parked + [ {
                step: "module_build",
                batch_id: build_batch.id,
                reason: "build batch did not reach a terminal state within the poll window " \
                        "(status=#{build_batch.reload.status}) — STOPPING before template/provision " \
                        "(will not provision from an unbuilt module)"
              } ]
            )
          end

          # Step 4 — NEW template = [base-os, reused, materialized].
          module_ids = (reused.map { |m| m[:id] } + materialized.map(&:id)).uniq
          template = create_template!(request: request, base_os: base_os,
                                      module_ids: module_ids, platform_id: platform_id)

          # Step 5 — dry-run apply: assert the closure resolves + includes base-os.
          closure = assert_closure!(template: template, base_os: base_os)
          return closure if closure.is_a?(Hash) && closure[:success] == false

          # Step 6 — provision + lease N instances, each carrying the fulfill
          # template's modules. LIVE PARKED (mocked in specs).
          instances, leases = provision_leased_instance(
            template: template, count: count, region: region, type: type,
            request: request, parked: parked
          )
          instance = instances.first
          lease    = leases.first

          # Step 7 — smoke-verify the representative instance IN PLACE (no second
          # pool acquire, no terminate of the leased instance). PROBE PARKED.
          smoke = instance ? run_smoke(instance: instance, template: template,
                                       module_name: primary_module_name(materialized, reused),
                                       base_os: base_os, parked: parked) : nil

          success(
            plan: plan,
            executed: true,
            requires_approval: true,
            reused_modules: reused.map { |m| m[:name] },
            materialized_modules: materialized.map(&:name),
            build_batch_id: build_batch&.id,
            template_id: template.id,
            instance_id: instance&.id,
            instance_ids: instances.map(&:id),
            lease: lease,
            leases: leases,
            smoke: smoke,
            parked: parked
          )
        end

        # ---- Step 2: materialize gaps via the package_module_create path ----
        # Calls the materializer DIRECTLY (not the package_module_create skill)
        # so its separate approval is NOT re-prompted — the consolidated
        # fulfill approval already covers this closure. baseline-excluded
        # (inc2-B) + native build_mode routes through PackageClosureBuildBridge.
        # Returns [materialized_modules, first_build_batch].
        def materialize_gaps(gaps:, base_os:, parked:)
          materialized = []
          build_batch = nil

          gaps.each do |gap|
            repo = ::System::PackageRepository.accessible_to(@account).find_by(id: gap[:repository_id])
            unless repo
              parked << { step: "materialize", package: gap[:package],
                          reason: "repository #{gap[:repository_id]} not accessible" }
              next
            end

            result = ::System::PackageModuleMaterializer.call(
              repository:          repo,
              package_name:        gap[:package],
              architectures:       Array(repo.architectures).presence || [ "amd64" ],
              account:             @account,
              requested_by_user:   effective_user,
              include_baseline:    false,
              base_os_module_name: base_os.name,
              dispatch_build:      true,
              build_mode:          :native
            )
            raise "materialize failed for #{gap[:package]}: #{result.errors.join('; ')}" unless result.success?

            materialized << result.top_level_module
            build_batch ||= result.build_batch
          end

          [ materialized, build_batch ]
        end

        # ---- Step 3: bounded poll of the build-completion barrier ----
        # Returns true when the batch finished, false when the bounded window
        # elapsed without a terminal state (the LIVE-PARKED case here).
        def await_build_batch(batch)
          attempts = int_setting("system.fulfill.build_poll_attempts", DEFAULT_BUILD_POLL_ATTEMPTS)
          interval = int_setting("system.fulfill.build_poll_interval_seconds", DEFAULT_BUILD_POLL_INTERVAL)

          attempts.times do
            return true if batch.reload.finished?

            sleep(interval) if interval.positive?
          end
          batch.reload.finished?
        end

        # ---- Step 4: author the NEW template (system_create_template +
        # system_assign_module_to_template — the MCP seam, reused) ----
        def create_template!(request:, base_os:, module_ids:, platform_id:)
          fleet = tool(::Ai::Tools::SystemFleetTool)
          resolved_platform_id = platform_id.presence || base_os.node_platform_id

          create = fleet.execute(params: {
            action: "system_create_template",
            name: template_name_for(request),
            description: "On-demand fulfillment: #{request}".truncate(280),
            node_platform_id: resolved_platform_id
          })
          raise "template create failed: #{create[:error]}" unless create[:success]

          template = ::System::NodeTemplate.where(account_id: @account.id).find(create.dig(:data, :template, :id))

          ([ base_os.id ] + module_ids).uniq.each do |mid|
            assign = fleet.execute(params: {
              action: "system_assign_module_to_template",
              template_id: template.id, module_id: mid
            })
            raise "assign module #{mid} failed: #{assign[:error]}" unless assign[:success]
          end

          template
        end

        # ---- Step 5: closure dry-run. A transient (unsaved) Node carries the
        # template through TemplateApplyService without persisting a throwaway
        # node — we only need the closure preview. ----
        def assert_closure!(template:, base_os:)
          node = ::System::Node.new(account: @account, node_template: template)
          result = ::System::TemplateApplyService.new(node).apply!(dry_run: true)
          return failure("closure dry-run failed: #{result.errors.join('; ')}") unless result.ok?

          closure_names = result.created.map { |c| c.node_module.name }
          unless closure_names.include?(base_os.name)
            return failure("closure does not resolve base-os (#{base_os.name}) — inc1 guarantee unmet")
          end

          closure_names
        end

        # ---- Step 6: provision + lease N instances that ACTUALLY carry the
        # fulfill template's modules. FRESH provision is the primary path.
        #
        # A SCOPED fulfillment pool is an optional fast path: only used when an
        # operator has designated one (by name or lifecycle_class via
        # SiteSetting) — otherwise fulfill NEVER touches a pool, so an unscoped
        # acquire can't starve ci-native-builders. Any acquired member is
        # RE-TEMPLATED onto the fulfill template (never handed back generic).
        #
        # Every returned instance is run through ensure_template_applied! so it
        # carries the fulfill template's module closure + has a queued on-node
        # sync. LIVE PARKED here (no cloud provider) — specs mock the seams.
        # Returns [instances, leases] (parallel arrays, size == number leased).
        def provision_leased_instance(template:, count:, region:, type:, request:, parked:)
          instances = []
          leases    = []

          # (1) Optional scoped-pool fast path — acquire up to `count` members.
          count.times do
            member = acquire_from_fulfillment_pool
            break unless member

            ensure_template_applied!(instance: member, template: template)
            instances << member
            leases    << apply_fulfillment_lease!(member, request: request)
          end

          # (2) Fresh-provision the remainder (the PRIMARY path). Each fresh
          # instance is authored on the fulfill template by ProvisionFullStack;
          # ensure_template_applied! makes the assignment closure explicit.
          remaining = count - instances.size
          if remaining.positive?
            if region && type
              fresh_provision(template: template, count: remaining, region: region, type: type, parked: parked).each do |inst|
                ensure_template_applied!(instance: inst, template: template)
                instances << inst
                leases    << apply_fulfillment_lease!(inst, request: request)
              end
            elsif instances.empty?
              parked << { step: "provision", reason: "no resolvable provider_region / provider_instance_type — provision parked" }
            else
              parked << { step: "provision",
                          reason: "requested #{count}, leased #{instances.size} from the fulfillment pool; " \
                                  "remainder parked (no resolvable provider_region / provider_instance_type)" }
            end
          end

          [ instances, leases ]
        end

        # Acquire ONE member from a fulfillment-SCOPED pool, or nil. Returns nil
        # (skipping pools entirely) unless an operator has designated a
        # fulfillment pool via SiteSetting — this is the guard that stops an
        # unscoped acquire from grabbing an unrelated pool's member (e.g.
        # ci-native-builders).
        def acquire_from_fulfillment_pool
          pool_name = ::SiteSetting.get("system.fulfill.pool_name").presence
          lifecycle = ::SiteSetting.get("system.fulfill.pool_lifecycle_class").presence
          return nil unless pool_name || lifecycle

          ::System::InstancePoolService.acquire!(
            account: @account, pool_name: pool_name, lifecycle_class: lifecycle
          )
        rescue ::System::InstancePoolService::PoolError
          # Scoped pool absent / empty — caller fresh-provisions the shortfall.
          nil
        end

        # Fresh full-stack provision of `count` instances on the fulfill
        # template. Returns the created NodeInstance records (empty on a parked /
        # failed provision, with a park note appended).
        def fresh_provision(template:, count:, region:, type:, parked:)
          prov = ProvisionFullStackExecutor
                 .new(account: @account, agent: @agent, user: @user)
                 .execute(template_id: template.id, count: count,
                          provider_region_id: region.id, provider_instance_type_id: type.id)

          ids = Array(prov.dig(:data, :outputs, :node_instance_ids))
          unless prov[:success] && ids.any?
            parked << { step: "provision", reason: "live provision unavailable in this env (#{prov[:error] || 'no instances created'})" }
            return []
          end

          ::System::NodeInstance.where(account_id: @account.id, id: ids).to_a
        end

        # Guarantees `instance` carries the fulfill template's module closure:
        # rebind its node onto the fulfill template (a no-op for a fresh instance
        # already authored on it; the actual re-template for a re-used pool
        # member), materialize the assignment closure via TemplateApplyService,
        # and queue a sync_modules Task so the on-node agent applies it. This
        # repoints THIS node only — it never widens a shared/pool template, so
        # other pool members are untouched.
        def ensure_template_applied!(instance:, template:)
          node = instance.node
          return unless node

          node.update!(node_template: template) unless node.node_template_id == template.id
          ::System::TemplateApplyService.new(node).apply!(dry_run: false)

          ::System::Task.create!(
            account: @account, operable: instance, command: "sync_modules", status: "pending",
            options: { "source" => "fulfill_capability_request", "template_id" => template.id }
          )
        end

        # Task-scoped lease tag so on-demand creation can't accrete zombie
        # fleet. Reuses the pool-slot lease anchor (pool_acquired_at) governed
        # by the pool reaper's claimed_ttl; the config lease documents the
        # task-scoped TTL for BOTH pooled and fresh instances.
        def apply_fulfillment_lease!(instance, request:)
          ttl = lease_ttl_seconds
          now = Time.current
          lease = {
            "source"      => "fulfill_capability_request",
            "request"     => request.to_s.truncate(200),
            "acquired_at" => now.iso8601,
            "ttl_seconds" => ttl,
            "expires_at"  => (now + ttl).iso8601,
            "task_scoped" => true
          }
          instance.update!(config: (instance.config || {}).merge("fulfillment_lease" => lease))

          lease.merge(
            "instance_id"      => instance.id,
            "pool_state"       => instance.try(:pool_state),
            "pool_acquired_at" => instance.try(:pool_acquired_at)&.iso8601,
            "reaper_governed"  => instance.respond_to?(:pool_claimed?) && instance.pool_claimed?
          )
        end

        # ---- Step 7: smoke-verify the LEASED instance in place (probe PARKED —
        # mocked in specs). Passing instance_id keeps smoke on THIS instance: it
        # does not acquire a second pool member, and it does not release/
        # terminate the leased instance. ----
        def run_smoke(instance:, template:, module_name:, base_os:, parked:)
          return nil if module_name.blank?

          result = ModuleSmokeVerifyExecutor
                   .new(account: @account, agent: @agent, user: @user)
                   .execute(module_name: module_name, base_os_module_name: base_os.name,
                            template_id: template.id, instance_id: instance.id)
          parked << { step: "smoke_probe", reason: "health probe parked platform-wide (no remote-exec primitive)" }
          result[:success] ? result[:data] : { ok: false, error: result[:error] }
        end

        # ================= plan + helpers =================

        # Consolidated approval payload. Enumerates the full template closure
        # per the bulk-op safety rule (count N + first 3 / last 1), the template
        # diff (modules added), the instance count, and a best-effort cost
        # estimate.
        def build_plan(request:, base_os:, reused:, gaps:, count:, region:, type:)
          module_names = [ base_os.name ] +
                         reused.map { |m| m[:name] } +
                         gaps.map { |g| "materialize:#{g[:package]}" }
          module_names = module_names.compact.uniq

          # fulfill always takes the NEW-template path (low blast radius); the
          # policy records that classification so the consolidated approval is
          # the single audited decision and no separate template gate fires.
          mutation = TemplateApprovalPolicy.for(template: nil)

          {
            request: request,
            template: {
              name_suggestion: template_name_for(request),
              modules_added: module_names,
              new_template: mutation.new_template,
              mutation_requires_approval: mutation.requires_approval?,
              mutation_reason: mutation.reason
            },
            closure: closure_enumeration(module_names),
            instances: {
              count: count,
              max: max_instances,
              default: DEFAULT_COUNT
            },
            reused: reused.map { |m| m[:name] },
            materialize: gaps.map { |g| { package: g[:package], repository_id: g[:repository_id], reason: g[:reason] } },
            cost_estimate: cost_estimate(region: region, type: type, count: count),
            lease_ttl_seconds: lease_ttl_seconds,
            requires_approval: true
          }
        end

        # Bulk-op safety enumeration: "state the count N; show first 3 + last 1".
        def closure_enumeration(names)
          {
            total: names.size,
            first: names.first(3),
            last: names.last,
            all: names
          }
        end

        def cost_estimate(region:, type:, count:)
          unless type
            return { estimated: false, reason: "no resolvable instance type — provision will be parked" }
          end

          hourly = type.try(:hourly_price)
          {
            estimated: hourly.present?,
            count: count,
            provider_region_id: region&.id,
            provider_instance_type_id: type.id,
            hourly_price: hourly,
            hourly_total: hourly.present? ? (hourly.to_f * count).round(4) : nil,
            currency: "USD"
          }
        end

        def resolve_count(count)
          n = count.nil? ? DEFAULT_COUNT : count.to_i
          n = DEFAULT_COUNT if n < 1
          [ n, max_instances ].min
        end

        def resolve_region(explicit_id)
          if explicit_id.present?
            return ::System::ProviderRegion.where(account_id: @account.id).find_by(id: explicit_id)
          end
          if (sid = ::SiteSetting.get("system.fulfill.default_region_id")).present?
            found = ::System::ProviderRegion.where(account_id: @account.id).find_by(id: sid)
            return found if found
          end
          ::System::ProviderRegion.where(account_id: @account.id, enabled: true).order(:created_at).first
        end

        def resolve_instance_type(explicit_id)
          if explicit_id.present?
            return ::System::ProviderInstanceType.where(account_id: @account.id).find_by(id: explicit_id)
          end
          if (sid = ::SiteSetting.get("system.fulfill.default_instance_type_id")).present?
            found = ::System::ProviderInstanceType.where(account_id: @account.id).find_by(id: sid)
            return found if found
          end
          ::System::ProviderInstanceType.where(account_id: @account.id).order(Arel.sql("hourly_price NULLS LAST")).first
        end

        def primary_module_name(materialized, reused)
          materialized.first&.name || reused.first&.dig(:name)
        end

        def template_name_for(request)
          base = request.to_s.downcase.scan(/[a-z0-9]+/)
                        .reject { |t| ModuleComposeExecutor::STOPWORDS.include?(t) }
                        .first(3)
          slug = base.empty? ? "capability" : base.join("-")
          "fulfill-#{slug}-#{Time.current.strftime('%Y%m%d%H%M%S')}"
        end

        def effective_user
          @user || @account.users.where(account_id: @account.id).first
        end

        def max_instances
          int_setting("system.fulfill.max_instances", DEFAULT_MAX_INSTANCES)
        end

        def lease_ttl_seconds
          int_setting("system.fulfill.lease_ttl_seconds", DEFAULT_LEASE_TTL_SECONDS)
        end

        def int_setting(key, default)
          raw = ::SiteSetting.get(key)
          val = raw.nil? ? default : raw.to_i
          val.positive? ? val : default
        end
      end
    end
  end
end
