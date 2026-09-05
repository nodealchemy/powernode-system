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
      class CveRunbookGenerateExecutor < BaseSkillExecutor
        skill_descriptor(
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
        )

        binds_to "concierge", "CVE Responder"

        protected

        def perform(cve_id:, persist_as_page: false)
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
            build_verification_section(cve),
            # Audit plan P2.9b — operator needs a clear "what if this breaks
            # production" plan before greenlighting a fleet-wide rolling
            # upgrade. Spells out exact MCP commands to revert.
            build_rollback_section(exposed_modules),
            # P2.9b — audit/governance sign-off checklist. Closing a CVE
            # remediation needs both security + ops attestation, not just
            # "I ran the script and it succeeded."
            build_sign_off_checklist_section(cve)
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
            <<~MD
              ## Remediation Plan

              **Sequential steps:**

              1. **Rebuild affected modules** — trigger module CI (`workflow_dispatch`)
                 for each exposed module to produce a patched OCI artifact:
                 #{module_ids.map { |id| "    - `#{id}`" }.join("\n")}

              2. **Bless new versions** — once SBOMs ingest the patched packages,
                 a CVE matching tick will mark exposures as `remediating` only
                 once remediation is actually dispatched for the module; a tick
                 that plans nothing now leaves them `open` (IMP-9b8d774298d5).

              3. **Rolling upgrade** — once new versions are blessed, dispatch
                 `system_promote_module_version` for each module, then trigger
                 `rolling_module_upgrade`. This upgrade is **FLEET-ATOMIC**:
                 the served version resolves from a per-module pointer
                 (`NodeModule#current_version_id`), so every instance carrying
                 the module converges together. There is no batch size to
                 choose. If this fleet needs a staged rollout, stage the
                 *scope* instead — an instance pool, or a second NodeModule
                 row with its own pointer.
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
              Approval requests appear in the Fleet Approval queue. The
              rolling_upgrade step is FLEET-ATOMIC, so the reviewer is
              approving a move of the whole affected population at once —
              there is no batch size to tune down for current fleet load.
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

        # Audit plan P2.9b — Rollback section. Operator-actionable plan for
        # reverting if a CVE remediation breaks production. Spells out exact
        # MCP commands per module rather than leaving it as an exercise.
        def build_rollback_section(exposed_modules)
          if exposed_modules.empty?
            <<~MD
              ## Rollback Plan

              No remediation was applied; nothing to roll back.
            MD
          else
            module_lines = exposed_modules.map do |m|
              # current_version_id captures the version that was live BEFORE
              # the remediation kicked off — the id to revert to.
              prev_id = m[:current_version_id] || "(unknown — check NodeModuleVersion history)"
              "  - **#{m[:name]}** → previous NodeModuleVersion id: `#{prev_id}`"
            end

            <<~MD
              ## Rollback Plan

              If the remediation produces operational regressions (services failing
              to start, unexpected restart loops, new error spikes), revert each
              affected module to its pre-remediation version:

              #{module_lines.join("\n")}

              **Per-module rollback commands:**

              ```
              # For each module above, repoint current_version_id at the
              # previous version. This is the ONE call that reverts what the
              # fleet serves; there is no second "redrive" step.
              mcp__powernode__platform_system_rollback_module_version(
                module_id:  "<module_id>",
                version_id: "<previous_version_id>",
                reason:     "reverting CVE remediation"
              )
              ```

              Two things this rollback is NOT, both of which earlier revisions
              of this runbook asserted:

              - It is **not** `system_promote_module_version`. That advances a
                version's `promotion_state` label and does not move
                `current_version_id`, so repromoting the old version leaves the
                fleet running the bad one.
              - It is **not** pace-able. The rollback is **FLEET-ATOMIC** for
                the same reason the upgrade was: `current_version_id` is a
                per-module pointer. Every instance carrying the module reverts
                together at its own next reconcile. Omitting `version_id`
                auto-selects the most recent version with a mountable
                artifact, which is usually what you want in an emergency.

              **Verification of rollback:** poll the instances directly —
              nothing emits a per-node version-change event, so there is no
              event stream to watch:

              ```
              mcp__powernode__platform_system_get_instance(instance_id: "<id>")
              # → running_module_digests, keyed by node_module_id. Compare
              #   against the target version's oci_digest.
              ```

              This is a per-instance check and you must repeat it across the
              instances you care about. If a node still reports the (broken)
              new version after 5 min, drain + reprovision via
              `system_provision_instance` against the prior NodePlatform disk
              image.
            MD
          end
        end

        # Audit plan P2.9b — Sign-Off Checklist. Closing a CVE remediation
        # properly needs both security + ops attestation; this section gives
        # the reviewer a copy-pasteable checklist plus the exact MCP queries
        # to verify each item.
        def build_sign_off_checklist_section(cve)
          <<~MD
            ## Sign-Off Checklist

            Audit + governance evidence — both sign-offs are required to mark
            the CVE responder workflow as closed.

            **Security review (required):**

            - [ ] All listed exposed modules are now reporting `state: remediated`
              in `System::CveExposure` (run `system_get_cve_exposure(cve_id: "#{cve.cve_id}")`)
            - [ ] No new CveExposure rows have appeared for this CVE in the
              48h post-remediation window (check via `query_learnings` or the
              CVE Responder dashboard)
            - [ ] Cosign signatures + SBOM attestations on the patched module
              versions verified

            **Operations attestation (required):**

            - [ ] Fleet decision audit trail captured — the `system.cve_critical_published`
              signal, the `cve_responder.inline_dispatch` event for `system.cve_remediate`,
              and the rolling upgrade's `skill.execute_finished` event, read with
              `system_recent_signals` (the fleet-event reader; `platform.recent_events`
              reads agent execution events, not fleet events)
            - [ ] Per-instance heartbeat continuity confirmed — no instance
              dropped heartbeat for >180s during the upgrade window
            - [ ] SLO impact assessed — `latency_p99_ms` + `error_rate_pct`
              for affected modules within target through the 30-min window
              after rolling upgrade completion

            **Sign-offs:**

            - Security reviewer: `_________________` (name) `_______` (date) `__:__` (UTC)
            - Operations reviewer: `_________________` (name) `_______` (date) `__:__` (UTC)
            - Optional: link to incident ticket / Slack thread: `_____________`
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
      end
    end
  end
end
