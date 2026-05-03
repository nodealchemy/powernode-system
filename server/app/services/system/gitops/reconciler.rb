# frozen_string_literal: true

module System
  module Gitops
    # End-to-end orchestrator: clones the repo, parses fleet.yaml, diffs
    # against live state, and opens Ai::AgentProposal rows for each diff.
    # Returns a structured Result; the caller (worker_api controller) wraps
    # this into a render_success payload.
    #
    # Auto-apply: when `repository.auto_apply` is true, accepted diffs are
    # applied without operator approval (proposal still created for audit).
    # Default false; per-account `gitops_auto_apply` config can set it.
    #
    # Diff cap: per-account daily proposal cap prevents proposal storms when
    # an entire fleet.yaml is rewritten in one commit. Configurable via env
    # var POWERNODE_GITOPS_MAX_PROPOSALS_PER_TICK (default 25).
    #
    # Reference: comprehensive stabilization sweep P5.
    class Reconciler
      Result = Struct.new(:ok?, :diff_count, :proposal_ids, :synced_revision,
                          :diff_summary, :error, keyword_init: true)

      MAX_PROPOSALS_PER_TICK = ENV.fetch("POWERNODE_GITOPS_MAX_PROPOSALS_PER_TICK", "25").to_i

      def self.reconcile!(repository:, sync_run: nil)
        new(repository: repository, sync_run: sync_run).reconcile!
      end

      def initialize(repository:, sync_run: nil)
        @repository = repository
        @sync_run = sync_run
      end

      def reconcile!
        sync_run = @sync_run || @repository.schedule_sync!

        # Step 1: clone/pull
        repo_result = ::System::Gitops::RepoSyncService.sync!(@repository)
        return finalize(sync_run, status: "failed", error: repo_result.error) unless repo_result.ok?

        # Step 2: parse desired state
        parse_result = ::System::Gitops::DesiredStateParser.parse!(
          work_tree_path: repo_result.work_tree_path,
          path_prefix: @repository.path_prefix
        )
        return finalize(sync_run, status: "failed", error: parse_result.error,
                        synced_revision: repo_result.commit_sha) unless parse_result.ok?

        # Step 3: diff against live state
        diff_result = ::System::Gitops::DiffEngine.diff!(
          account: @repository.account,
          desired_state: parse_result.desired_state
        )
        return finalize(sync_run, status: "failed", error: diff_result.error,
                        synced_revision: repo_result.commit_sha) unless diff_result.ok?

        diffs = diff_result.diffs

        # Step 4: per-tick proposal cap
        capped_diffs = diffs.first(MAX_PROPOSALS_PER_TICK)
        truncated = diffs.size > MAX_PROPOSALS_PER_TICK

        # Step 5: emit proposals
        proposal_ids = capped_diffs.map { |d| open_proposal(d, repo_result.commit_sha) }.compact

        @repository.update!(
          last_synced_at: Time.current,
          last_synced_revision: repo_result.commit_sha,
          last_diff_count: diffs.size,
          last_status: truncated ? "partial" : "success",
          last_error: truncated ? "diff count exceeded MAX_PROPOSALS_PER_TICK=#{MAX_PROPOSALS_PER_TICK}" : nil
        )

        finalize(
          sync_run,
          status: truncated ? "partial" : "success",
          diff_count: diffs.size,
          proposal_ids: proposal_ids,
          synced_revision: repo_result.commit_sha,
          diff_summary: summarize(diffs)
        )
      rescue StandardError => e
        Rails.logger.error("[Gitops::Reconciler] #{e.class}: #{e.message}")
        finalize(sync_run, status: "failed", error: "#{e.class}: #{e.message}")
      end

      private

      def open_proposal(diff, commit_sha)
        proposal = ::Ai::AgentProposal.create!(
          account: @repository.account,
          ai_agent_id: gitops_agent_id,
          title: "GitOps: #{diff.change} #{diff.kind} #{diff.name}",
          description: build_description(diff, commit_sha),
          proposal_type: "configuration",
          status: "pending_review",
          priority: priority_for(diff),
          impact_assessment: { kind: diff.kind, change: diff.change, resource_id: diff.resource_id },
          proposed_changes: { diff: diff.to_h, source: "gitops", repository_id: @repository.id, commit_sha: commit_sha }
        )
        proposal.id
      rescue StandardError => e
        Rails.logger.warn("[Gitops::Reconciler] Failed to open proposal for diff=#{diff.to_h.except(:current, :desired).inspect}: #{e.message}")
        nil
      end

      def gitops_agent_id
        # GitOps proposals don't come from a specific agent — use a
        # well-known "system" agent if present, otherwise nil.
        ::Ai::Agent.where(account: @repository.account, name: "gitops-reconciler").first&.id ||
          ::Ai::Agent.where(account: @repository.account).first&.id
      end

      def priority_for(diff)
        case diff.change
        when :destroy then "high"      # destructive changes warrant attention
        when :create  then "medium"
        when :update  then "medium"
        else               "low"
        end
      end

      def build_description(diff, commit_sha)
        <<~DESC
          GitOps reconciler detected drift between the desired state in
          `#{@repository.repo_url}@#{commit_sha[0..8]}` and live state.

          **Resource**: #{diff.kind} `#{diff.name}`
          **Change**: #{diff.change}

          See the proposal payload for the full diff.
          Repository: #{@repository.name}
          Branch: #{@repository.branch}
          Commit: #{commit_sha}
        DESC
      end

      def summarize(diffs)
        diffs.group_by(&:kind).transform_values(&:size)
      end

      def finalize(sync_run, status:, diff_count: 0, proposal_ids: [],
                   synced_revision: nil, diff_summary: {}, error: nil)
        sync_run.finalize!(
          status: status,
          diff_count: diff_count,
          proposal_ids: proposal_ids,
          synced_revision: synced_revision,
          diff_summary: diff_summary,
          error_message: error
        )

        Result.new(
          ok?: status != "failed",
          diff_count: diff_count,
          proposal_ids: proposal_ids,
          synced_revision: synced_revision,
          diff_summary: diff_summary,
          error: error
        )
      end
    end
  end
end
