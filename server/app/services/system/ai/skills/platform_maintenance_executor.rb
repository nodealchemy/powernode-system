# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill: ongoing platform maintenance.
      #
      # Action-discriminated executor — the operator (or autonomous agent)
      # picks a sub-action and the executor routes to the right wrapped
      # service. Each branch is intentionally a thin layer over an
      # existing service so the skill stays composable: any branch can
      # be invoked directly via its underlying API/MCP tool too.
      #
      # Sub-actions:
      #
      #   - "cert_status"   → list certs with renewal urgency (expires_at,
      #                       days_until_expiry, needs_renewal_now)
      #   - "cert_rotate"   → trigger renewal of a specific cert OR every
      #                       cert past its renewal window
      #   - "drift_check"   → return module drift for the deployment's
      #                       active instances — what each agent reports
      #                       mounted vs the current version of the modules
      #                       its node is assigned (read-only)
      #   - "health_check"  → COMPOSITE platform health, delegated whole to
      #                       System::Platform::CompositeHealthProbe. Every
      #                       subsystem it declares gets its own entry with its
      #                       own status, and a subsystem that could not be
      #                       observed reports `not_measured` rather than "ok".
      #                       See that class for the oracle rule and ranking.
      #
      # Plan reference: chat-driven platform deployment + maintenance
      # (D2-ext.1).
      class PlatformMaintenanceExecutor < BaseSkillExecutor
        ACTIONS = %w[cert_status cert_rotate drift_check health_check].freeze

        skill_descriptor(
          name: "platform_maintenance",
          description: "Routine platform maintenance — certificate renewal, drift checks, health snapshots. Use this skill when the operator asks about (a) which certs are expiring soon, (b) whether they should rotate something, (c) the current platform health, or (d) whether any instances have drifted from the modules their node is assigned.",
          category: "devops",
          inputs: {
            action: { type: "string", required: true,
                      description: "One of: cert_status, cert_rotate, drift_check, health_check" },
            certificate_id: { type: "string", required: false,
                              description: "Cert id (only for cert_rotate of a specific row; omit to rotate all expiring)" },
            deployment_id: { type: "string", required: false,
                             description: "PlatformDeployment id (for drift_check; omit to scan all deployments)" },
            renewal_window_days: { type: "integer", required: false, default: 30,
                                   description: "How many days ahead to consider a cert 'expiring soon' (cert_status / cert_rotate)" }
          },
          outputs: {
            action: :string,
            data: :object,
            recommendations: [ :string ]
          }
        )

        binds_to "concierge"

        protected

        def perform(action:, **params)
          unless ACTIONS.include?(action.to_s)
            return failure("Unknown action: #{action.inspect}; allowed: #{ACTIONS.inspect}")
          end

          case action.to_s
          when "cert_status"  then cert_status(params)
          when "cert_rotate"  then cert_rotate(params)
          when "drift_check"  then drift_check(params)
          when "health_check" then health_check
          end
        end

        private

        # ── cert_status: read-only cert health summary ────────────────────
        def cert_status(params)
          window_days = (params[:renewal_window_days] || 30).to_i
          certs = ::System::AcmeCertificate.where(account_id: @account.id)
          rows = certs.map do |c|
            days = c.expires_at ? ((c.expires_at - Time.current) / 86_400).round : nil
            {
              id: c.id,
              common_name: c.common_name,
              status: c.status,
              issuer: c.issuer,
              expires_at: c.expires_at&.iso8601,
              days_until_expiry: days,
              needs_renewal_now: c.status == "valid" && days && days <= window_days
            }
          end
          needs_renewal = rows.count { |r| r[:needs_renewal_now] }
          recs = []
          recs << "Renew #{needs_renewal} cert#{needs_renewal == 1 ? '' : 's'} expiring within #{window_days}d — call this skill again with action=cert_rotate." if needs_renewal.positive?
          recs << "All certs are current — no rotation needed." if rows.any? && needs_renewal.zero?
          success(
            action: "cert_status",
            data: {
              total: rows.size,
              needs_renewal_count: needs_renewal,
              renewal_window_days: window_days,
              certificates: rows
            },
            recommendations: recs
          )
        end

        # ── cert_rotate: trigger renewal for one cert or all expiring ────
        def cert_rotate(params)
          window_days = (params[:renewal_window_days] || 30).to_i
          target_id = params[:certificate_id]

          targets =
            if target_id.present?
              cert = ::System::AcmeCertificate.find_by(id: target_id, account: @account)
              return failure("Certificate not found: #{target_id}") unless cert
              return failure("Certificate status=#{cert.status} — cannot rotate (must be valid)") unless cert.status == "valid"
              [ cert ]
            else
              ::System::AcmeCertificate.where(account: @account).needs_renewal(window_days.days).to_a
            end

          return success(action: "cert_rotate", data: { rotated: [], skipped_count: 0 },
                         recommendations: [ "No certs need renewal." ]) if targets.empty?

          rotated = []
          failures = []
          targets.each do |cert|
            begin
              # CertificateManager#renew! ships from P2.5.7a. The skill
              # is intentionally fire-and-forget — actual ACME work runs
              # async via the renewal sweep.
              ::Acme::CertificateManager.renew!(cert) if ::Acme::CertificateManager.respond_to?(:renew!)
              rotated << { id: cert.id, common_name: cert.common_name }
            rescue StandardError => e
              failures << { id: cert.id, error: e.message }
            end
          end

          recs = [ "Renewal queued for #{rotated.size} cert(s); rotation runs async via the next renewal sweep tick." ]
          recs << "#{failures.size} renewal trigger(s) errored — check audit log for details." if failures.any?
          success(
            action: "cert_rotate",
            data: { rotated: rotated, failures: failures },
            recommendations: recs
          )
        end

        # ── drift_check: read NodeInstance drift state ───────────────────
        def drift_check(params)
          deployment_id = params[:deployment_id]
          deployments =
            if deployment_id.present?
              dep = ::System::PlatformDeployment.find_by(id: deployment_id, account: @account)
              return failure("Deployment not found: #{deployment_id}") unless dep
              [ dep ]
            else
              ::System::PlatformDeployment.where(account: @account).to_a
            end

          summaries = deployments.map { |d| drift_summary_for(d) }
          drifted_total = summaries.sum { |s| s[:drift_count] }
          silent_total = summaries.sum { |s| s[:not_reporting_count] }
          unassessed = summaries.flat_map { |s| s[:not_assessed_instances] }
          unassessed_total = unassessed.size

          recs = []
          recs << "No deployments declared — drift check is a no-op." if deployments.empty?
          recs << "#{drifted_total} instance(s) drifted from their assigned modules — call system_refresh_instance_modules per instance to remediate." if drifted_total.positive?
          recs << "#{silent_total} instance(s) have never heartbeated — drift is UNKNOWN for them, not clear." if silent_total.positive?
          if unassessed_total.positive?
            breakdown = unassessed.group_by { |i| i[:status] }.transform_values(&:size)
                                  .sort.map { |status, n| "#{status}: #{n}" }.join(", ")
            recs << "#{unassessed_total} instance(s) are mid-lifecycle or errored (#{breakdown}) — drift was NOT assessed for them; re-run once they settle."
          end
          if deployments.any? && drifted_total.zero? && silent_total.zero? && unassessed_total.zero?
            recs << "All reporting instances match their assigned modules — nothing to remediate."
          end

          success(action: "drift_check", data: { deployments: summaries }, recommendations: recs)
        end

        # No nil-template branch: node_template_id is a required belongs_to on a
        # NOT NULL column, so the guard that used to stand here could not run —
        # and what it returned was an all-clear row.
        def drift_summary_for(deployment)
          # Find instances tied to this deployment's template (mirrors
          # the Scaling panel's compute_actual_replicas logic — uses the
          # actual table_name, not the association alias).
          #
          # Scoped to every NON-TERMINATED instance, not `NodeInstance.active`.
          # `active` omits `starting`/`stopping`/`rebooting`/`error`, and those
          # instances used to reach neither count with nothing in the payload
          # disclosing the filter — a deployment with one instance wedged in
          # `error` and one mid-`rebooting` rendered as "0 drifted, 0 unknown"
          # (IMP-351be1c674e0). Two of those states are what the platform's own
          # remediation produces (FleetDecisionEngine#reboot_silent_instance
          # issues reboot/start), so they are not rare. `terminated` stays out:
          # that replica is gone, not unassessed.
          instances = ::System::NodeInstance
                        .joins(:node)
                        .includes(node: { node_modules: :current_version })
                        .where(system_nodes: { node_template_id: deployment.node_template_id,
                                               account_id: @account.id })
                        .where.not(status: "terminated")

          # An instance that has never heartbeated has not drifted — it has not
          # ANSWERED yet. Counting "everything assigned is missing" as drift
          # there would bury real drift under provisioning noise, so those are
          # reported in their own bucket instead of being silently dropped.
          #
          # The discriminator is last_heartbeat_at, NOT an empty digest map:
          # #record_heartbeat! writes running_module_digests unconditionally, so
          # a live agent that has mounted nothing persists `{}`. That is drift —
          # ModuleDriftSensor emits system.module_drift for exactly that row
          # (spec/services/system/fleet/sensors_spec.rb) and drift_report calls
          # it drift — and keying off emptiness here would have made this verb
          # the one consumer that reported it clean.
          #
          # The widened scope is partitioned BEFORE the drift question is asked:
          # a mid-reboot digest map is not evidence of anything, so an instance
          # outside `active` gets its own disclosed bucket rather than an answer
          # the operator would have to discount. Same reasoning as the
          # not_reporting bucket above — a state that cannot be answered is
          # named, never folded into the yes/no and never dropped.
          all_instances = instances.to_a
          assessable, unassessed =
            all_instances.partition { |inst| ::System::NodeInstance::ACTIVE_STATUSES.include?(inst.status) }
          reporting, silent = assessable.partition { |inst| inst.last_heartbeat_at.present? }
          drifted = reporting.select(&:module_drifted?)

          base_drift_row(deployment, all_instances.size, drifted, silent, unassessed)
        end

        # `instance_count` is the DENOMINATOR the three buckets are read
        # against: without it a reader cannot tell "every instance was assessed
        # and none needed remediation" from "a whole status class was filtered
        # out of the question", which is precisely how IMP-351be1c674e0 hid.
        # The buckets name only the instances that need attention, so the
        # identity is drift + not_reporting + not_assessed + converged =
        # instance_count — the converged remainder is not enumerated.
        def base_drift_row(deployment, instance_count, drifted, silent, unassessed)
          {
            deployment_id: deployment.id,
            deployment_name: deployment.name,
            template: deployment.node_template&.name,
            instance_count: instance_count,
            drift_count: drifted.size,
            drifted_instances: drifted.map { |i| instance_row(i).merge(drift: i.module_drift) },
            not_reporting_count: silent.size,
            not_reporting_instances: silent.map { |i| instance_row(i) },
            not_assessed_count: unassessed.size,
            not_assessed_instances: unassessed.map { |i| instance_row(i) }
          }
        end

        def instance_row(instance)
          { id: instance.id, status: instance.status, name: instance.name }
        end

        # ── health_check: THE composite platform-health answer ───────────
        #
        # Delegated whole to System::Platform::CompositeHealthProbe. This used
        # to build four subsystem entries here — rails, postgres, acme,
        # federation — with `rails_health` returning the literal
        # `{ status: "ok" }`, under a comment claiming the method "mirrors
        # PlatformHealthController". No class of that name exists in either
        # repository. The comment was pointing, inexactly, at
        # Api::V1::System::Platform::HealthController, which is a REAL and
        # SEPARATE fourth health surface: it feeds the compute/platform health
        # dashboard, carries its own copy of these probes, has the same
        # constant-"ok" rails entry, and likewise has no fleet-instance
        # subsystem. Delegating this verb does not fix that one. See the
        # increment report: the controller is the remaining divergent producer
        # and should be re-pointed at CompositeHealthProbe.
        #
        # The cost of that shape was measured. Live 2026-09-05 04:48Z this verb
        # returned overall "ok" while `platform_resilience op=failover_check`
        # returned 11 (now 12) NodeInstances in status "error" in the same
        # minute — health_check had no fleet subsystem to see them with, and
        # the constant "ok" carried the aggregate.
        #
        # The probe persists every run, so "show me health over the last hour"
        # is answerable from System::PlatformHealthSnapshot afterwards.
        def health_check
          probe = ::System::Platform::CompositeHealthProbe.new(
            account: @account, source: "platform_maintenance.health_check"
          )
          result = probe.call_and_persist!

          success(
            action: "health_check",
            data: result,
            recommendations: health_recommendations(result)
          )
        end

        # Recommendations name the SPECIFIC subsystems, and they never claim
        # everything is fine while something went unobserved — a run carrying
        # `not_measured` gets told what it could not see, not reassurance.
        def health_recommendations(result)
          recs = []

          if result[:down].any?
            recs << "DOWN: #{result[:down].join(', ')} — observed failing; investigate before anything else."
          end
          if result[:degraded].any?
            recs << "DEGRADED: #{result[:degraded].join(', ')}."
          end
          if result[:not_measured].any?
            recs << "NOT MEASURED: #{result[:not_measured].join(', ')} — these were not observed and are " \
                    "NOT known to be healthy. Configure or reach them before treating this run as complete."
          end

          fleet = result.dig(:subsystems, :fleet_instances) || {}
          if fleet[:error_count].to_i.positive?
            recs << "#{fleet[:error_count]} node instance(s) in status=error — call platform_resilience " \
                    "with action=failover_check for the per-instance detail."
          end

          recs << "All subsystems observed healthy." if result[:overall] == "ok"
          recs
        end
      end
    end
  end
end
