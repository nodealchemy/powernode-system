# frozen_string_literal: true

module System
  module Compliance
    # Generates a complete compliance snapshot for an account: every node,
    # every running instance, every module digest, every certificate, every
    # CVE exposure, every drift report. Output is a structured Hash that
    # can be serialized to PDF/JSON for SOC2 / ISO27001 / HIPAA evidence.
    #
    # Reference: Golden Eclipse plan M-D2-1.
    #
    # Snapshots are *immutable point-in-time records*. Once generated, the
    # caller should persist the JSON document via add_document so the
    # snapshot can be retrieved months later for audit defense.
    class ComplianceSnapshotService
      Result = Struct.new(:ok?, :snapshot, :generated_at, :error, keyword_init: true)

      def self.snapshot!(account:, scope: :all)
        new.snapshot!(account: account, scope: scope)
      end

      def snapshot!(account:, scope:)
        raise ArgumentError, "account required" unless account

        snapshot = {
          metadata: snapshot_metadata(account, scope),
          nodes: collect_nodes(account),
          instances: collect_instances(account),
          modules: collect_modules(account),
          certificates: collect_certificates(account),
          cve_exposures: collect_cve_exposures(account),
          drift_summary: collect_drift_summary(account),
          fleet_decisions: collect_recent_decisions(account),
          rcp_invariants: collect_rcp_invariants(account),
          counts: counts(account)
        }

        Result.new(ok?: true, snapshot: snapshot, generated_at: Time.current)
      rescue StandardError => e
        Rails.logger.error("[ComplianceSnapshotService] #{e.class}: #{e.message}")
        Result.new(ok?: false, error: e.message)
      end

      private

      def snapshot_metadata(account, scope)
        {
          schema_version: 1,
          account_id: account.id,
          account_name: account.name,
          generated_at: Time.current.iso8601,
          scope: scope.to_s,
          generator: "System::Compliance::ComplianceSnapshotService",
          generator_commit: ENV["POWERNODE_GIT_SHA"] || "unknown"
        }
      end

      def collect_nodes(account)
        ::System::Node.where(account: account).includes(:node_template).map do |node|
          {
            id: node.id,
            name: node.name,
            template: node.node_template&.name,
            instance_count: node.node_instances.count,
            ssh_key_fingerprint: node.respond_to?(:ssh_key_fingerprint) ? node.ssh_key_fingerprint : nil,
            created_at: node.created_at.iso8601
          }
        end
      end

      def collect_instances(account)
        ::System::NodeInstance
          .joins(:node)
          .where(system_nodes: { account_id: account.id })
          .find_each.map do |i|
          {
            id: i.id,
            node_id: i.node_id,
            status: i.status,
            architecture: i.architecture,
            agent_version: i.respond_to?(:agent_version) ? i.agent_version : nil,
            mtls_subject: i.respond_to?(:mtls_subject) ? i.mtls_subject : nil,
            last_heartbeat_at: i.respond_to?(:last_heartbeat_at) ? i.last_heartbeat_at&.iso8601 : nil,
            running_module_digests: i.respond_to?(:running_module_digests) ? i.running_module_digests : nil
          }
        end
      end

      def collect_modules(account)
        ::System::NodeModule.where(account: account).includes(:current_version).map do |m|
          version = m.current_version
          {
            id: m.id,
            name: m.name,
            variety: m.variety,
            cosign_identity_regexp: m.cosign_identity_regexp,
            cosign_issuer_regexp: m.cosign_issuer_regexp,
            current_version: version&.then { |v|
              {
                id: v.id,
                version_number: v.version_number,
                promotion_state: v.promotion_state,
                oci_digest: v.oci_digest,
                fsverity_root_hash: v.respond_to?(:fsverity_root_hash) ? v.fsverity_root_hash : nil
              }
            }
          }
        end
      end

      def collect_certificates(account)
        return [] unless defined?(::System::NodeCertificate)
        ::System::NodeCertificate
          .joins(node_instance: :node)
          .where(system_nodes: { account_id: account.id })
          .map do |c|
          {
            id: c.id,
            instance_id: c.node_instance_id,
            serial: c.serial,
            subject: c.subject,
            not_after: c.not_after.iso8601,
            revoked_at: c.revoked_at&.iso8601,
            days_remaining: c.not_after && c.not_after > Time.current ? ((c.not_after - Time.current) / 86_400.0).round(1) : 0
          }
        end
      end

      def collect_cve_exposures(account)
        return [] unless defined?(::System::CveExposure)
        ::System::CveExposure
          .joins(node_module_version: :node_module)
          .where(system_node_modules: { account_id: account.id })
          .where(state: %w[open remediating])
          .includes(:cve)
          .map do |e|
          {
            id: e.id,
            cve_id: e.cve.cve_id,
            severity: e.cve.severity,
            module_version_id: e.node_module_version_id,
            package_name: e.package_name,
            state: e.state,
            detected_at: e.detected_at.iso8601
          }
        end
      end

      def collect_drift_summary(account)
        # Compute a fleet-wide drift summary: how many instances carry drift,
        # how many are reconciled, and — the part an audit reader cannot do
        # without — how many instances those two counts actually COVER.
        #
        # Scoped to every NON-TERMINATED instance, not `running`.
        # `System::NodeInstance::ACTIVE_STATUSES` omits
        # `starting`/`stopping`/`rebooting`/`error`, and those instances used
        # to reach neither count with nothing in the section disclosing the
        # filter (IMP-f28b393916f3) — an evidence document that reports "0
        # drifted, 100% reconciled" for a fleet with a node wedged in `error`
        # is answering a narrower question than the one it appears to answer.
        # `terminated` stays out: that replica is gone, not unassessed.
        #
        # The walked population is ACTIVE_STATUSES, matching drift_check
        # (PlatformMaintenanceExecutor#drift_summary_for). The compliance
        # document and the maintenance verb must not disagree about the same
        # fleet, so the boundary is the model's one definition rather than a
        # second literal here — INCLUDING drift_check's second cut, the
        # reporting/silent split applied below.
        #
        # `.to_a`, not `find_each`: the population must be PARTITIONED before
        # the drift question is asked, and a partition needs the whole set. The
        # trade is the non-terminated fleet in memory for the length of one
        # snapshot — the same trade drift_check already makes
        # (PlatformMaintenanceExecutor#drift_summary_for does `instances.to_a`).
        #
        # `:node` only. Preloading `node_modules` here would be dead weight:
        # #module_drift builds `node.node_modules.includes(:current_version)`,
        # a FRESH relation, so it re-queries whatever was preloaded. The node
        # itself is read straight off the association and is worth preloading.
        all_instances = ::System::NodeInstance
                        .joins(:node)
                        .includes(:node)
                        .where(system_nodes: { account_id: account.id })
                        .where.not(status: "terminated")
                        .to_a

        assessable, unassessed =
          all_instances.partition { |i| ::System::NodeInstance::ACTIVE_STATUSES.include?(i.status) }

        # Drift is decided by System::NodeInstance#module_drifted?, the one
        # definition — NOT by a local copy. The copy that used to live here
        # compared KEY SETS only (missing/extra), so an instance mounting a
        # stale digest of every module it is assigned was counted
        # `reconciled` and the evidence document reported 0% drift for a
        # fleet that had entirely failed to converge (IMP-29b38f6f48b2).
        # The shared method adds the `mismatched` limb that catches it.
        # SECOND CUT, and the one that keeps this honest. ACTIVE_STATUSES
        # includes `pending` and `provisioning` — rows no agent has ever
        # reported for. `running_module_digests` is `{}` NOT NULL by DEFAULT,
        # so #module_drift calls every assigned module "missing" for them; that
        # is the column's default, not an observation, and counting it as drift
        # in an evidence document would bury real drift under provisioning
        # noise. drift_check draws exactly this line
        # (`reporting, silent = assessable.partition { .. last_heartbeat_at }`).
        #
        # `running` is exempt on purpose: #record_heartbeat! writes
        # running_module_digests unconditionally, so a live agent that has
        # mounted nothing persists `{}` — the platform already calls that drift
        # (ModuleDriftSensor emits for it, drift_report reports it), and
        # narrowing it here would make this document the one consumer that
        # reported it clean.
        reporting, silent = assessable.partition { |i| answers_drift?(i) }

        drifted, reconciled = reporting.partition(&:module_drifted?)

        {
          # The DENOMINATOR the buckets are read against. Without it a reader
          # cannot tell "every instance was assessed and none drifted" from
          # "a whole status class was filtered out of the question".
          # Identity: assessed + not_reporting + not_assessed == instance_count,
          # and drifted + reconciled == assessed.
          instance_count: all_instances.size,
          assessed_count: reporting.size,
          drifted_count: drifted.size,
          reconciled_count: reconciled.size,
          not_reporting_count: silent.size,
          not_reporting_instances: silent.map { |i| instance_row(i) },
          not_assessed_count: unassessed.size,
          not_assessed_instances: unassessed.map { |i| instance_row(i) },
          # Ratio over the ASSESSED population, not the whole fleet: it is the
          # share of instances the question was answered for, and widening its
          # denominator to include instances that were never asked would move
          # the number without anything having converged.
          drift_ratio_pct: reporting.empty? ? 0 : ((drifted.size * 100.0) / reporting.size).round(1)
        }
      end

      def instance_row(instance)
        { id: instance.id, status: instance.status, name: instance.name }
      end

      # See the reporting/silent comment in #collect_drift_summary. Kept as one
      # predicate so the sensor's copy and this one can be diffed against each
      # other and against drift_check's split.
      def answers_drift?(instance)
        instance.last_heartbeat_at.present? || instance.status == "running"
      end

      def collect_recent_decisions(account)
        return [] unless defined?(::Ai::ApprovalRequest)
        ::Ai::ApprovalRequest
          .where(account: account, source_type: "system_fleet")
          .order(created_at: :desc).limit(50)
          .map do |req|
          {
            id: req.id,
            action_category: req.request_data&.dig("action_category"),
            status: req.status,
            description: req.description.to_s.truncate(200),
            created_at: req.created_at.iso8601,
            completed_at: req.completed_at&.iso8601
          }
        end
      end

      # RCP v2 (campaign 019f9250, increment p0c) — INV-1/2/6 fleet-wide scan,
      # folded into the existing compliance-snapshot seam rather than a
      # parallel report format (Reuse First). Static (live: false) here —
      # a compliance snapshot must stay a cheap, pure DB read; a live
      # Proxmox-verified INV-6 pass is available separately via
      # System::Compliance::RcpInvariantScanner.scan(account:, live: true)
      # (see rcp:invariant_scan rake task) for contexts with real
      # provider credentials.
      def collect_rcp_invariants(account)
        result = ::System::Compliance::RcpInvariantScanner.scan(account: account, live: false)
        {
          scanned_at: result.scanned_at.iso8601,
          live_verified: result.live,
          inv1_self_management: result.inv1,
          inv2_boot_network_dependency: result.inv2,
          inv6_storage_locality: result.inv6,
          violation_count: result.violations.size
        }
      rescue StandardError => e
        Rails.logger.error("[ComplianceSnapshotService] rcp_invariants scan failed: #{e.class}: #{e.message}")
        { error: e.message }
      end

      def counts(account)
        {
          nodes: ::System::Node.where(account: account).count,
          instances: ::System::NodeInstance.where(account_id: account.id).count,
          running_instances: ::System::NodeInstance.where(account_id: account.id, status: "running").count,
          modules: ::System::NodeModule.where(account: account).count,
          live_module_versions: ::System::NodeModuleVersion.joins(:node_module).where(system_node_modules: { account_id: account.id }, promotion_state: "live").count,
          retired_module_versions: ::System::NodeModuleVersion.joins(:node_module).where(system_node_modules: { account_id: account.id }, promotion_state: "retired").count,
          active_certificates: defined?(::System::NodeCertificate) ? ::System::NodeCertificate.joins(node_instance: :node).where(system_nodes: { account_id: account.id }).where(revoked_at: nil).count : 0,
          open_cve_exposures: defined?(::System::CveExposure) ? ::System::CveExposure.joins(node_module_version: :node_module).where(system_node_modules: { account_id: account.id }).where(state: %w[open remediating]).count : 0
        }
      end
    end
  end
end
