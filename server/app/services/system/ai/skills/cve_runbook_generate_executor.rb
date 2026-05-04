# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Generates a per-CVE remediation runbook (Markdown) for an operator
      # working through a published CVE against the local fleet.
      #
      # Differs from RunbookGenerateExecutor (which targets a NodeTemplate)
      # by being CVE-focused: walks System::CveExposure rows for the given
      # cve_id + account and renders affected packages, exposed modules,
      # remediation plan, and verification steps as a single Markdown doc
      # the operator can read or share via Pages.
      #
      # Reference: comprehensive stabilization sweep Phase 10.7.
      class CveRunbookGenerateExecutor
        def self.descriptor
          {
            name: "cve_runbook_generate",
            description: "Generate a markdown remediation runbook for a CVE — exposed modules, recommended steps, verification commands",
            category: "security",
            inputs: {
              cve_id: { type: "string", required: true,
                        description: "Canonical CVE id, e.g. CVE-2026-12345" },
              persist_as_page: { type: "boolean", required: false, default: false,
                                 description: "Save the runbook as a Pages document so it's reachable via list_pages" }
            },
            outputs: {
              runbook_markdown: :string,
              cve_id: :string,
              exposed_module_count: :integer,
              exposed_instance_count: :integer,
              risk_score: :integer,
              requires_approval: :boolean,
              persisted_page_id: :string
            }
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(cve_id:, persist_as_page: false)
          cve = ::System::Cve.find_by(cve_id: cve_id)
          return failure("CVE #{cve_id} not found in DB; ingest via CveOps::FeedIngestService first") unless cve

          exposures = load_exposures_for(cve)
          exposed_modules = group_exposures_by_module(exposures)
          exposed_instance_count = exposed_modules.sum { |m| m[:assignment_count].to_i }
          risk_score = compute_risk_score(cve.severity, exposed_modules.size, exposed_instance_count)

          sections = [
            build_header(cve),
            build_summary_section(cve, exposed_modules.size, exposed_instance_count, risk_score),
            build_affected_packages_section(cve),
            build_exposed_modules_section(exposed_modules),
            build_remediation_plan_section(exposed_modules, cve.severity),
            build_approval_gate_section(cve.severity, risk_score),
            build_verification_section(cve)
          ].compact

          markdown = sections.join("\n\n---\n\n")

          persisted_page_id = persist_runbook_page(cve, markdown) if persist_as_page

          success(
            runbook_markdown: markdown,
            cve_id: cve.cve_id,
            severity: cve.severity,
            exposed_module_count: exposed_modules.size,
            exposed_instance_count: exposed_instance_count,
            risk_score: risk_score,
            requires_approval: gate_for(cve.severity, risk_score),
            persisted_page_id: persisted_page_id
          )
        rescue StandardError => e
          Rails.logger.error("[CveRunbookGenerateExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        private

        def load_exposures_for(cve)
          ::System::CveExposure
            .where(cve: cve, state: %w[open remediating])
            .joins(node_module_version: :node_module)
            .where(system_node_modules: { account_id: @account.id })
            .includes(node_module_version: :node_module)
        end

        def group_exposures_by_module(exposures)
          exposures.group_by { |e| e.node_module_version.node_module }.map do |mod, exps|
            assignments = mod.respond_to?(:node_module_assignments) ? mod.node_module_assignments.count : 0
            {
              module_id: mod.id,
              name: mod.name,
              matched_packages: exps.map(&:package_name).uniq,
              affected_versions: exps.map { |e| e.package_version.to_s }.compact_blank.uniq,
              assignment_count: assignments,
              current_version_id: mod.respond_to?(:current_version_id) ? mod.current_version_id : nil,
              exposure_ids: exps.map(&:id)
            }
          end
        end

        def compute_risk_score(severity, module_count, instance_count)
          return 0 if module_count.zero?
          weight = ::System::Ai::Skills::CveResponseExecutor::SEVERITY_WEIGHT[severity.to_s] || 0
          multiplier = 1 + Math.log10([ instance_count, 1 ].max + 1)
          (weight * multiplier).round
        end

        def gate_for(severity, risk_score)
          return true if %w[critical high].include?(severity.to_s)
          risk_score >= ::System::Ai::Skills::CveResponseExecutor::AUTO_GATE_RISK_THRESHOLD
        end

        def build_header(cve)
          published = cve.respond_to?(:published_at) && cve.published_at ? cve.published_at.iso8601 : "unknown"
          <<~MD
            # Remediation Runbook: #{cve.cve_id}

            > Severity: **#{cve.severity}** · Published: #{published} · Generated: #{Time.current.iso8601}
            > Account: #{@account.id}
          MD
        end

        def build_summary_section(cve, module_count, instance_count, risk_score)
          summary_text = cve.respond_to?(:summary) ? cve.summary.to_s : ""
          <<~MD
            ## Summary

            #{summary_text.empty? ? '_(no summary available — see CVE source for details)_' : summary_text}

            **Local impact:** #{module_count} exposed module(s) across #{instance_count} active assignment(s).
            **Risk score:** #{risk_score} (severity weight × instance fan-out)
          MD
        end

        def build_affected_packages_section(cve)
          packages = cve.normalized_affected_packages
          return nil if packages.empty?

          rows = packages.map do |p|
            ecosystem = p["ecosystem"].to_s.empty? ? "—" : p["ecosystem"]
            constraint = p["version"].to_s.empty? ? "any" : p["version"]
            "  - **#{p['name']}** (#{ecosystem}) — affected: `#{constraint}`"
          end

          <<~MD
            ## Affected Packages

            CVE feed lists the following package + version-range constraints:

            #{rows.join("\n")}
          MD
        end

        def build_exposed_modules_section(exposed_modules)
          if exposed_modules.empty?
            <<~MD
              ## Exposed Modules

              No active exposures detected for this account. Either no module SBOM
              matches the CVE, or the SBOM cache hasn't been refreshed since
              ingestion. Run `system_drift_report` or rebuild module CI to
              repopulate SBOMs if you suspect false negatives.
            MD
          else
            rows = exposed_modules.map do |m|
              versions = m[:affected_versions].any? ? m[:affected_versions].join(", ") : "(unknown — see SBOM)"
              packages = m[:matched_packages].join(", ")
              <<~MOD
                ### #{m[:name]}

                - **Module ID:** `#{m[:module_id]}`
                - **Matched packages:** #{packages}
                - **Affected versions:** #{versions}
                - **Active assignments:** #{m[:assignment_count]}
                - **Exposure IDs:** #{m[:exposure_ids].size} row(s)
              MOD
            end

            "## Exposed Modules\n\n" + rows.join("\n")
          end
        end

        def build_remediation_plan_section(exposed_modules, severity)
          if exposed_modules.empty?
            <<~MD
              ## Remediation Plan

              No remediation required — no active exposures detected.
            MD
          else
            module_ids = exposed_modules.map { |m| m[:module_id] }
            batch_pct = severity.to_s == "critical" ? 25 : 10
            <<~MD
              ## Remediation Plan

              **Sequential steps:**

              1. **Rebuild affected modules** — trigger module CI (`workflow_dispatch`)
                 for each exposed module to produce a patched OCI artifact:
                 #{module_ids.map { |id| "    - `#{id}`" }.join("\n")}

              2. **Bless new versions** — once SBOMs ingest the patched packages,
                 the next CVE matching tick will mark exposures as `remediating`.

              3. **Rolling upgrade** — once new versions are blessed, dispatch
                 `system_promote_module_version` for each module, then trigger
                 `rolling_module_upgrade` with batch_pct=#{batch_pct}.
            MD
          end
        end

        def build_approval_gate_section(severity, risk_score)
          gated = gate_for(severity, risk_score)
          if gated
            <<~MD
              ## Approval Gate

              This remediation **requires operator approval** before any
              state-changing action dispatches. Severity=#{severity}, risk_score=#{risk_score}.
              Approval requests appear in the Fleet Approval queue; reviewer
              should confirm the rolling_upgrade batch_pct is appropriate
              for the current fleet load.
            MD
          else
            <<~MD
              ## Approval Gate

              Severity=#{severity}, risk_score=#{risk_score} — below the
              auto-gate threshold (#{::System::Ai::Skills::CveResponseExecutor::AUTO_GATE_RISK_THRESHOLD}).
              Remediation can proceed under the standard `system.module_promote_to_live`
              policy without an explicit per-CVE approval.
            MD
          end
        end

        def build_verification_section(cve)
          <<~MD
            ## Verification

            After remediation completes, verify exposure closes via:

            ```
            mcp__powernode__platform_system_drift_report(instance_id: "<instance>")
            mcp__powernode__platform_system_cve_triage(cve_id: "#{cve.cve_id}", severity: "#{cve.severity}", affected_packages: ...)
            ```

            CveExposure rows transition to `remediated` once the patched
            module version replaces the exposed one on every assignment.
            Re-run this runbook to confirm `exposed_module_count == 0`.
          MD
        end

        def persist_runbook_page(cve, markdown)
          return nil unless defined?(::Page)
          # `pages.author_id` is NOT NULL — without a user we can't persist.
          # Caller invoked `persist_as_page: true` without supplying `user:`
          # at executor init; log + return nil instead of swallowing silently.
          unless @user&.id
            Rails.logger.info("[CveRunbookGenerateExecutor] persist_as_page skipped — no user context")
            return nil
          end

          # Page schema has no `tags` column — stash classifiers under metadata.
          # Slug is NOT NULL + unique; build a deterministic one from cve_id.
          page = ::Page.create!(
            account: @account,
            author_id: @user.id,
            title: "CVE Runbook: #{cve.cve_id}",
            slug: "cve-runbook-#{cve.cve_id.downcase}-#{SecureRandom.hex(4)}",
            content: markdown,
            status: "published",
            metadata: { "tags" => [ "runbook", "cve", "cve:#{cve.cve_id}", "severity:#{cve.severity}" ] }
          )
          page.id
        rescue StandardError => e
          Rails.logger.warn("[CveRunbookGenerateExecutor] page persist failed: #{e.message}")
          nil
        end

        def success(payload)
          { success: true, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end
      end
    end
  end
end
