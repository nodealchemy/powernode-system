# frozen_string_literal: true

module System
  module Ai
    module Skills
      # THE on-demand vertical slice (campaign 019f6084), refactored to a DURABLE
      # STATE MACHINE (inc-M). This skill no longer executes the build/provision
      # inline — it COMPOSES a plan and hands it to System::FulfillmentRequest,
      # whose System::FulfillmentAdvanceOrchestrator drives it to a running,
      # leased instance.
      #
      # WHAT THIS SKILL DOES NOW (it shrank on purpose):
      #   1. module_compose (semantic) → modules that already cover the request.
      #   2. gap detection → the packages to materialize for the uncovered part;
      #      gaps with NO materializable package (author_module / transient
      #      discovery_unavailable) become `unresolved_gaps` on the plan (never
      #      dropped), block autonomous inline approval, and are parked on the
      #      row so the trail survives.
      #   3. resolve region/type + build a consolidated approval plan, FREEZING a
      #      replayable `execution` context inside it.
      #   4. CREATE a System::FulfillmentRequest (state: composed) with the plan
      #      frozen on the row.
      #   5. return { plan, fulfillment_request_id, state }.
      #
      # THE TOCTOU FIX: approval is now the out-of-band `composed → approved`
      # transition on the PERSISTED row, not the in-band `approved:` boolean
      # re-invocation that RE-COMPOSED the plan. What executes is the frozen
      # plan["execution"] — the approved plan and the executed plan are the same
      # bytes, always. (`approved: true` is retained for autonomous callers with
      # decision authority: it transitions the row composed→approved and drives
      # the FIRST advance inline; interactive callers approve out-of-band and the
      # sweep — System::FulfillmentRequestSweepService — carries it the rest of
      # the way, resuming across the async module-build barrier without sleeping.)
      #
      # Everything downstream (materialize, build-barrier WAIT, template author,
      # provision, task-scoped lease, smoke, rollback-on-failure, budget +
      # rate-limit gate) lives in the orchestrator — see its class doc.
      class FulfillCapabilityRequestExecutor < BaseSkillExecutor
        DEFAULT_BASE_OS_MODULE_NAME = "base-os-ubuntu-noble"

        # Fallback defaults ONLY — every one is overridable via SiteSetting so
        # no operator-facing cap is a bare constant.
        DEFAULT_COUNT             = 1
        DEFAULT_MAX_INSTANCES     = 5        # system.fulfill.max_instances
        DEFAULT_LEASE_TTL_SECONDS = 4 * 3600 # system.fulfill.lease_ttl_seconds

        skill_descriptor(
          name: "fulfill_capability_request",
          description: "On-demand: turn an NL capability request into a running, leased instance. Composes a plan and creates a DURABLE System::FulfillmentRequest (state machine); approval is an out-of-band transition on the persisted, frozen plan.",
          category: "devops",
          inputs: {
            request: { type: "string", required: true,
                       description: "Free-form capability request, e.g. 'give me a running memcached instance'" },
            count: { type: "integer", required: false, default: DEFAULT_COUNT,
                     description: "Instances to provision (default 1; capped by SiteSetting system.fulfill.max_instances)" },
            approved: { type: "boolean", required: false, default: false,
                        description: "false (default) → create the request in `composed` and return the plan + id for OUT-OF-BAND approval. true (autonomous callers) → also transition composed→approved and drive the first advance inline." },
            base_os_module_name: { type: "string", required: false, default: DEFAULT_BASE_OS_MODULE_NAME },
            platform_id: { type: "string", required: false,
                           description: "Restrict module composition to a NodePlatform (defaults to the base-os module's platform)" },
            provider_region_id: { type: "string", required: false,
                                  description: "Override region for provisioning (defaults to account's first enabled region / SiteSetting)" },
            provider_instance_type_id: { type: "string", required: false,
                                         description: "Override instance type (defaults to account's cheapest / SiteSetting)" }
          },
          outputs: {
            fulfillment_request_id: :string,
            state: :string,
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
            parked: [ :object ],
            unresolved_gaps: [ :object ],
            approval_withheld_reason: :string
          },
          requires_approval: true,
          blast_radius: :high
        )

        # System Concierge = the NL surface; Fleet Autonomy = policy-gated
        # autonomous fulfillment.
        binds_to "concierge", "Fleet Autonomy"

        protected

        def perform(request:, count: DEFAULT_COUNT, approved: false,
                    base_os_module_name: DEFAULT_BASE_OS_MODULE_NAME, platform_id: nil,
                    provider_region_id: nil, provider_instance_type_id: nil, **_extras)
          return failure("request is required") if request.to_s.strip.empty?

          count = resolve_count(count)

          base_os = @account.system_node_modules.find_by(name: base_os_module_name)
          return failure("base-os module not found: #{base_os_module_name}") unless base_os

          # --- compose (read-only) ---
          compose = executor(ModuleComposeExecutor)
                      .execute(description: request, platform_id: platform_id)
          return failure("module_compose failed: #{compose[:error]}") unless compose[:success]

          reused     = Array(compose.dig(:data, :draft_template, :modules))
          all_gaps   = Array(compose.dig(:data, :gaps))
          gaps       = all_gaps.select { |g| g[:action] == "materialize" }
          # "A human must author this" (author_module) and "discovery was down"
          # (discovery_unavailable) are conclusions, not noise: every gap the
          # composer could not resolve to a materializable package rides the
          # frozen plan — with its action intact — so the approver decides about
          # the partial closure.
          unresolved = all_gaps - gaps

          region = resolve_region(provider_region_id)
          type   = resolve_instance_type(provider_instance_type_id)

          plan = build_plan(request:, base_os:, reused:, gaps:, unresolved:, count:, region:, type:, platform_id:)

          # --- CREATE the durable request with the plan FROZEN ---
          fr = ::System::FulfillmentRequest.create_composed!(
            account: @account,
            request: request,
            plan: plan,
            cost_estimate: plan["cost_estimate"],
            reused_modules: reused.map { |m| m[:name] },
            lease_ttl_seconds: lease_ttl_seconds,
            requested_by_user: effective_user
          )

          # Autonomous caller with decision authority: approve the FROZEN plan
          # out-of-band and drive the first advance inline (no re-compose, no
          # sleep — if the build barrier isn't done it returns in `building` and
          # the sweep resumes it).
          approval_withheld_reason = nil
          if approved
            if unresolved.any?
              # A plan with unresolved gaps is a PARTIAL closure — autonomous
              # callers may not accept that silently; it stays `composed` for a
              # human decision. The message reports what the gaps actually are
              # (authoring vs transient discovery outage), and the decision is
              # parked on the ROW so the trail survives the return value.
              by_action = unresolved.group_by { |g| g[:action].to_s }
                                    .map { |a, gs| "#{gs.size} #{a}" }.join(", ")
              reasons = unresolved.filter_map { |g| g[:reason] }.uniq.first(3).join("; ")
              approval_withheld_reason =
                "plan has #{unresolved.size} unresolved gap(s) (#{by_action}) — " \
                "autonomous approval withheld; a partial closure needs a human decision. #{reasons}"
              fr.add_park!(step: "autonomous_approval", reason: approval_withheld_reason)
            else
              # No operator in this path — approve_by! records that fact (and
              # emits the approval event) rather than leaving the decision
              # untraceable, same as the operator endpoint.
              fr.approve_by!(user: nil, source: "autonomous_executor")
              ::System::FulfillmentAdvanceOrchestrator.advance!(request: fr)
              fr.reload
            end
          end

          success(result_payload(fr, reused, approval_withheld_reason:))
        end

        private

        def result_payload(fr, reused, approval_withheld_reason: nil)
          leases = fr.lease_summaries
          {
            fulfillment_request_id: fr.id,
            state: fr.state,
            plan: fr.plan,
            executed: fr.ready?,
            requires_approval: true,
            reused_modules: reused.map { |m| m[:name] },
            materialized_modules: Array(fr.materialized_modules),
            build_batch_id: fr.build_batch_id,
            template_id: fr.template_id,
            instance_id: Array(fr.node_instance_ids).first,
            instance_ids: Array(fr.node_instance_ids),
            lease: leases.first,
            leases: leases,
            smoke: fr.smoke,
            parked: Array(fr.parked),
            unresolved_gaps: Array(fr.plan["unresolved_gaps"]),
            approval_withheld_reason: approval_withheld_reason
          }
        end

        # ================= plan (frozen, string-keyed for jsonb round-trip) =================

        # Consolidated approval payload PLUS a replayable `execution` context. The
        # execution block is what the orchestrator replays — it is the frozen plan.
        # String keys throughout so read (post-jsonb) == write.
        def build_plan(request:, base_os:, reused:, gaps:, unresolved:, count:, region:, type:, platform_id:)
          module_names = ([ base_os.name ] +
                          reused.map { |m| m[:name] } +
                          gaps.map { |g| "materialize:#{g[:package]}" }).compact.uniq

          # fulfill always takes the NEW-template path (low blast radius); record
          # the classification so the consolidated approval is the single audited
          # decision (no separate template gate fires).
          mutation = TemplateApprovalPolicy.for(template: nil)
          template_name = template_name_for(request)

          {
            "request" => request,
            "template" => {
              "name_suggestion" => template_name,
              "modules_added" => module_names,
              "new_template" => mutation.new_template,
              "mutation_requires_approval" => mutation.requires_approval?,
              "mutation_reason" => mutation.reason
            },
            "closure" => closure_enumeration(module_names, unresolved_count: unresolved.size),
            "instances" => { "count" => count, "max" => max_instances, "default" => DEFAULT_COUNT },
            "reused" => reused.map { |m| m[:name] },
            "materialize" => gaps.map { |g| { "package" => g[:package], "repository_id" => g[:repository_id], "reason" => g[:reason] } },
            "unresolved_gaps" => unresolved.map { |g| { "capability" => g[:capability], "action" => g[:action], "reason" => g[:reason] } },
            "cost_estimate" => cost_estimate(region:, type:, count:),
            "lease_ttl_seconds" => lease_ttl_seconds,
            "requires_approval" => true,
            # --- FROZEN, replayable execution context (the TOCTOU fix) ---
            "execution" => {
              "base_os_module_id" => base_os.id,
              "base_os_module_name" => base_os.name,
              "reused_modules" => reused.map { |m| { "id" => m[:id], "name" => m[:name] } },
              "gaps" => gaps.map { |g| { "package" => g[:package], "repository_id" => g[:repository_id], "reason" => g[:reason], "action" => g[:action] } },
              "count" => count,
              "provider_region_id" => region&.id,
              "provider_instance_type_id" => type&.id,
              "platform_id" => (platform_id.presence || base_os.node_platform_id),
              "template_name" => template_name
            }
          }
        end

        # Bulk-op safety enumeration: "state the count N; show first 3 + last 1".
        # `unresolved` rides alongside so the approver reading this block can see
        # that gaps exist even though they never enter total/first/last/all —
        # those four stay a pure enumeration of the names actually in the
        # closure (base-os + reused + materialize); an unresolved capability
        # never joins that set because nothing will be built for it.
        def closure_enumeration(names, unresolved_count: 0)
          { "total" => names.size, "first" => names.first(3), "last" => names.last, "all" => names,
            "unresolved" => unresolved_count }
        end

        def cost_estimate(region:, type:, count:)
          unless type
            return { "estimated" => false, "reason" => "no resolvable instance type — provision will be parked" }
          end

          hourly = type.try(:hourly_price)
          {
            "estimated" => hourly.present?,
            "count" => count,
            "provider_region_id" => region&.id,
            "provider_instance_type_id" => type.id,
            "hourly_price" => hourly,
            "hourly_total" => hourly.present? ? (hourly.to_f * count).round(4) : nil,
            "currency" => "USD"
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
