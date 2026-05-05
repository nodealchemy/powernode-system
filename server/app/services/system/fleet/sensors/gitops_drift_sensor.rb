# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects GitOps drift — repositories whose latest sync run found
      # diffs that haven't been resolved (proposals not yet applied).
      #
      # Pure read-side: looks at the last completed GitopsSyncRun per enabled
      # repository. Emits one signal per repo with unresolved drift, so
      # the DecisionEngine can surface in the operator dashboard via
      # FleetEvent + alert.
      #
      # Conservative: ignores running syncs (still reconciling); only
      # alerts when a completed sync_run reported diff_count > 0 AND
      # those diffs haven't been auto-applied (proposal_ids may be
      # implemented status — but for v1 we just count diffs).
      #
      # Reference: extensions/system/docs/plans/missing-features.md (Phase 6c).
      class GitopsDriftSensor < BaseSensor
        # Don't alert if the latest sync is older than this — the data is
        # stale; operator should re-sync first to get fresh signal.
        STALE_THRESHOLD = 24.hours

        def sense
          ::System::GitopsRepository
            .where(account_id: account.id)
            .where(enabled: true)
            .find_each.flat_map { |repo| sense_repo(repo) }
            .compact
        end

        private

        def sense_repo(repo)
          run = repo.last_run
          return nil unless run
          return nil if run.status == "running" # still syncing
          return nil if run.completed_at.nil?
          return nil if run.completed_at < STALE_THRESHOLD.ago # too stale to be actionable
          return nil unless run.diff_count.to_i.positive?

          [
            {
              kind: "system.gitops.drift_detected",
              severity: severity_for(run),
              payload: {
                repository_id: repo.id,
                repository_name: repo.name,
                branch: repo.branch,
                synced_revision: run.synced_revision,
                last_sync_at: run.completed_at&.iso8601,
                diff_count: run.diff_count,
                diff_summary: run.diff_summary,
                pending_proposal_count: pending_proposal_count(run)
              },
              fingerprint: "gitops_drift:#{repo.id}:#{run.synced_revision}"
            }
          ]
        end

        # severity = high if many diffs (>10) or any destroy-class change;
        # medium otherwise.
        def severity_for(run)
          summary = run.diff_summary || {}
          return :high if run.diff_count.to_i > 10
          return :high if summary["destroy"].to_i.positive?
          :medium
        end

        # How many of this run's proposals are still pending review (vs
        # already approved/implemented). Helps operators prioritize.
        def pending_proposal_count(run)
          return 0 if run.proposal_ids.blank?

          ::Ai::AgentProposal
            .where(id: run.proposal_ids, status: %w[pending_review approved])
            .count
        end
      end
    end
  end
end
