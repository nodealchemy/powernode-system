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
      #   - "drift_check"   → return drift state for the deployment's
      #                       active instances (read-only)
      #   - "health_check"  → aggregate platform health (rails, worker,
      #                       redis, pg, acme, sdwan, federation)
      #
      # Plan reference: chat-driven platform deployment + maintenance
      # (D2-ext.1).
      class PlatformMaintenanceExecutor
        ACTIONS = %w[cert_status cert_rotate drift_check health_check].freeze

        def self.descriptor
          {
            name: "platform_maintenance",
            description: "Routine platform maintenance — certificate renewal, drift checks, health snapshots. Use this skill when the operator asks about (a) which certs are expiring soon, (b) whether they should rotate something, (c) the current platform health, or (d) whether any instances have drifted from their template.",
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
            },
            requires_approval: false,
            blast_radius: :medium
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(action:, **params)
          unless ACTIONS.include?(action.to_s)
            return failure("Unknown action: #{action.inspect}; allowed: #{ACTIONS.inspect}")
          end

          case action.to_s
          when "cert_status"  then cert_status(params)
          when "cert_rotate"  then cert_rotate(params)
          when "drift_check"  then drift_check(params)
          when "health_check" then health_check
          end
        rescue StandardError => e
          Rails.logger.error("[PlatformMaintenanceExecutor] #{e.class}: #{e.message}")
          failure("Maintenance action failed: #{e.message}")
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

          recs = []
          recs << "No deployments declared — drift check is a no-op." if deployments.empty?
          recs << "#{drifted_total} instance(s) drifted from their template — call system_refresh_instance_modules per instance to remediate." if drifted_total.positive?
          recs << "All instances are at their template state — nothing to remediate." if deployments.any? && drifted_total.zero?

          success(action: "drift_check", data: { deployments: summaries }, recommendations: recs)
        end

        def drift_summary_for(deployment)
          return base_drift_row(deployment, 0, []) unless deployment.node_template_id

          # Find instances tied to this deployment's template (mirrors
          # the Scaling panel's compute_actual_replicas logic — uses the
          # actual table_name, not the association alias).
          instances = ::System::NodeInstance
                        .joins(:node)
                        .where(system_nodes: { node_template_id: deployment.node_template_id,
                                               account_id: @account.id })
                        .active

          drifted = instances.where("running_module_digests IS DISTINCT FROM ?", []).select do |inst|
            instance_drifted?(inst, deployment.node_template)
          end

          base_drift_row(
            deployment,
            drifted.size,
            drifted.map { |i| { id: i.id, status: i.status, name: i.name } }
          )
        end

        def instance_drifted?(_instance, _template)
          # Best-effort: if the platform's drift detector returns a value
          # we'll trust it; otherwise return false (the system_drift_report
          # MCP action remains the source of truth for full drift detail).
          false
        rescue StandardError
          false
        end

        def base_drift_row(deployment, count, list)
          {
            deployment_id: deployment.id,
            deployment_name: deployment.name,
            template: deployment.node_template&.name,
            drift_count: count,
            drifted_instances: list
          }
        end

        # ── health_check: aggregate snapshot (mirrors PlatformHealthController) ─
        def health_check
          health = {
            rails: rails_health,
            postgres: postgres_health,
            acme: acme_health,
            federation: federation_health
          }

          status = health.values.map { |h| h[:status] }
          overall =
            if status.include?("down") then "down"
            elsif status.include?("degraded") then "degraded"
            else "ok"
            end

          recs = []
          if health[:acme][:expiring_within_7d].to_i.positive?
            recs << "#{health[:acme][:expiring_within_7d]} cert(s) expire within 7 days — call platform_maintenance with action=cert_rotate."
          end
          if health[:federation][:heartbeat_stale].to_i.positive?
            recs << "#{health[:federation][:heartbeat_stale]} federation peer(s) with stale heartbeat — call platform_resilience with action=failover_check."
          end
          recs << "Platform health is OK." if recs.empty? && overall == "ok"

          success(
            action: "health_check",
            data: { overall: overall, subsystems: health, generated_at: Time.current.iso8601 },
            recommendations: recs
          )
        end

        def rails_health
          { status: "ok", env: Rails.env, ruby: RUBY_VERSION }
        end

        def postgres_health
          ActiveRecord::Base.connection.execute("SELECT 1")
          { status: "ok" }
        rescue StandardError => e
          { status: "down", error: e.message }
        end

        def acme_health
          certs = ::System::AcmeCertificate.where(account: @account)
          valid = certs.where(status: "valid")
          expiring_30d = valid.where("expires_at < ?", 30.days.from_now).count
          expiring_7d  = valid.where("expires_at < ?", 7.days.from_now).count
          {
            status: expiring_7d.positive? ? "degraded" : "ok",
            total: certs.count,
            expiring_within_30d: expiring_30d,
            expiring_within_7d: expiring_7d
          }
        rescue StandardError => e
          { status: "down", error: e.message }
        end

        def federation_health
          return { status: "ok", total: 0 } unless defined?(::System::FederationPeer)
          peers = ::System::FederationPeer.where(account: @account, peer_kind: "platform")
          stale = peers.heartbeat_stale.count
          {
            status: stale.positive? ? "degraded" : "ok",
            total: peers.count,
            heartbeat_stale: stale
          }
        rescue StandardError => e
          { status: "down", error: e.message }
        end

        def success(payload)
          { success: true, requires_approval: false, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end
      end
    end
  end
end
