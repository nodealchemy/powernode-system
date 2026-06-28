# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Generates an operational runbook for a NodeTemplate as markdown.
      # Walks: each module's name + description + manifest, related compound
      # learnings (tagged with module names or fleet signals touching this
      # template), and KG anchor neighbors of FleetSignal / RemediationOutcome.
      #
      # The runbook is *advisory*; the operator-confirmed flow uses
      # `/api/v1/system/audit/...` for compliance-grade snapshots. This is
      # the "first 5 minutes of an outage" companion document.
      #
      # Reference: Golden Eclipse plan F-16 AI-Generated Runbooks.
      class RunbookGenerateExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "runbook_generate",
          description: "Generate a markdown operational runbook for a NodeTemplate — boot order, common failure modes, recovery procedures",
          category: "documentation",
          inputs: {
            template_id: { type: "string", required: true },
            persist_as_page: { type: "boolean", required: false, default: false,
                               description: "Save the result as a Pages document so it's reachable via list_pages" }
          },
          outputs: {
            runbook_markdown: :string,
            section_count: :integer,
            persisted_page_id: :string,
            source_artifacts: :object
          }
        )

        binds_to "System Concierge"

        protected

        def perform(template_id:, persist_as_page: false)
          tmpl_resp = tool(::Ai::Tools::SystemFleetTool).execute(params: { action: "system_get_template", template_id: template_id })
          return failure("template lookup failed: #{tmpl_resp[:error]}") unless tmpl_resp[:success]

          template = tmpl_resp[:data][:template]
          modules = Array(template[:modules])

          sections = []
          sections << build_header(template, modules)
          sections << build_overview_section(template, modules)
          sections << build_boot_order_section(modules)
          sections << build_modules_section(modules)
          sections << build_failure_modes_section(template, modules)
          sections << build_recovery_section(template)
          sections << build_appendix_section(template)

          markdown = sections.compact.join("\n\n---\n\n")

          persisted_page_id = nil
          persisted_page_id = persist_runbook_page(template, markdown) if persist_as_page

          success(
            runbook_markdown: markdown,
            section_count: sections.compact.size,
            persisted_page_id: persisted_page_id,
            source_artifacts: {
              template_id: template_id,
              module_count: modules.size,
              learning_count: relevant_learnings(modules).size,
              kg_anchor_count: kg_anchors_count
            }
          )
        end

        private

        def build_header(template, modules)
          <<~MD
            # Runbook: #{template[:name]}

            > Auto-generated #{Time.current.iso8601}. Modules: #{modules.size}.
            > This runbook is advisory — for compliance-grade evidence, run
            > `system_compliance_snapshot`.
          MD
        end

        def build_overview_section(template, modules)
          <<~MD
            ## Overview

            Template `#{template[:name]}` runs across #{instance_count_for(template[:id])} active instance(s)
            in account #{@account.id}. The composition includes #{modules.size} module(s)
            assembled in priority-ordered composefs lower stack.

            **Architecture:** #{template[:architecture_id] || "unspecified"}
            **Platform:** #{template[:platform_id]}
          MD
        end

        def build_boot_order_section(modules)
          ordered = modules.sort_by { |m| -priority_for_module(m[:id]) }
          rows = ordered.each_with_index.map do |m, i|
            "  #{i + 1}. **#{m[:name]}** (variety: #{m[:variety]})"
          end.join("\n")

          <<~MD
            ## Boot Order

            Modules attach in descending priority order (highest priority on top of the
            overlay stack):

            #{rows}
          MD
        end

        def build_modules_section(modules)
          rows = modules.map do |m|
            mod_record = ::System::NodeModule.where(account: @account).find_by(id: m[:id])
            assignment_count = mod_record&.node_module_assignments&.count.to_i

            <<~MD
              ### #{m[:name]}

              - **Variety:** #{m[:variety]}
              - **Active assignments:** #{assignment_count}
              - **Cosign identity pin:** `#{mod_record&.cosign_identity_regexp || 'not set'}`
              - **Repository:** #{mod_record&.gitea_repo_full_name || '—'}
            MD
          end

          <<~MD
            ## Modules

            #{rows.join("\n")}
          MD
        end

        def build_failure_modes_section(template, modules)
          learnings = relevant_learnings(modules)
          if learnings.empty?
            <<~MD
              ## Common Failure Modes

              No fleet learnings tagged with these modules yet. As autonomy
              decisions accumulate, the LearningExtractor will populate this
              section with observed failure patterns.
            MD
          else
            rows = learnings.first(8).map do |l|
              tag_str = Array(l.tags).select { |t| !t.start_with?("module:") }.join(", ")
              "  - **#{l.title}** _(#{tag_str})_ — #{l.content.to_s.truncate(160)}"
            end.join("\n")

            <<~MD
              ## Common Failure Modes

              Patterns observed by FleetAutonomyService for modules in this template:

              #{rows}
            MD
          end
        end

        def build_recovery_section(template)
          <<~MD
            ## Recovery Procedures

            ### Instance silent (no heartbeat ≥ 3 min)

            1. Check `system_get_instance` for status + last_heartbeat_at
            2. If `system.instance_silent` ApprovalRequest is pending, review the autonomy
               plan in the trading approval queue (filter `source_type:system_fleet`)
            3. If the cause is identifiable from heartbeat events (`/api/v1/system/tasks/.../events`),
               approve the proposed reprovision. Otherwise, manually inspect via
               console (libvirt) or SSH (cloud).

            ### Module drift detected

            1. Run `system_drift_report` for the affected instance
            2. Review the planned actions returned by the `drift_remediate` skill
            3. Auto-applies if disruption_pct ≤ 20; otherwise approves through the
               `system.module_assign` policy

            ### Certificate near expiry

            FleetAutonomyService auto-rotates at 75% lifetime via `system.cert_rotate`
            (default `auto_approve`). If rotation has been failing, escalate via
            `escalate` MCP action with severity=high.
          MD
        end

        def build_appendix_section(template)
          <<~MD
            ## Appendix: Useful MCP Calls

            ```
            mcp__powernode__platform_system_get_template(template_id: "#{template[:id]}")
            mcp__powernode__platform_system_list_instances(template_id: "#{template[:id]}")
            mcp__powernode__platform_system_drift_report(instance_id: "<instance-id>")
            ```
          MD
        end

        def instance_count_for(template_id)
          ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { node_template_id: template_id })
            .where(status: %w[running starting])
            .count
        end

        def priority_for_module(module_id)
          mod = ::System::NodeModule.where(account: @account).find_by(id: module_id)
          mod&.respond_to?(:effective_priority) ? mod.effective_priority : (mod&.priority || 0)
        end

        def relevant_learnings(modules)
          return [] unless defined?(::Ai::CompoundLearning)

          module_names = modules.map { |m| m[:name].to_s.downcase }.compact_blank
          ::Ai::CompoundLearning
            .where(account_id: @account.id, status: "active")
            .where(
              module_names.map { "tags @> ?" }.join(" OR "),
              *module_names.map { |n| [ n ].to_json }
            )
            .order(importance_score: :desc)
            .limit(20)
        rescue StandardError
          []
        end

        def kg_anchors_count
          return 0 unless defined?(::Ai::KnowledgeGraphNode)
          ::Ai::KnowledgeGraphNode
            .where(account: @account, name: %w[FleetSignal RemediationOutcome ModuleProvenance])
            .count
        end

        def persist_runbook_page(template, markdown)
          return nil unless defined?(::Page)
          # `pages.author_id` is NOT NULL — without a user we can't persist.
          # `pages.tags` is not a column — stash classifiers under metadata.
          # `pages.slug` is NOT NULL + unique — build a deterministic slug.
          # Same fix pattern as CveRunbookGenerateExecutor (Phase 10.7).
          unless @user&.id
            Rails.logger.info("[RunbookGenerateExecutor] persist_as_page skipped — no user context")
            return nil
          end

          page = ::Page.create!(
            account: @account,
            author_id: @user.id,
            title: "Runbook: #{template[:name]}",
            slug: "runbook-#{template[:id]}-#{SecureRandom.hex(4)}",
            content: markdown,
            status: "published",
            metadata: { "tags" => [ "runbook", "fleet", "template:#{template[:id]}" ] }
          )
          page.id
        rescue StandardError => e
          Rails.logger.warn("[RunbookGenerateExecutor] page persist failed: #{e.message}")
          nil
        end
      end
    end
  end
end
