# frozen_string_literal: true

module System
  module Gitops
    # End-to-end orchestrator: clones the repo, parses fleet.yaml, diffs
    # against live state, and opens Ai::AgentProposal rows for each diff.
    # Returns a structured Result; the caller (worker_api controller) wraps
    # this into a render_success payload.
    #
    # Auto-apply (WIRED): when `repository.auto_apply` is true the reconciler
    # auto-approves + applies each eligible proposal via ApplyService — no
    # operator review. The audit proposal is ALWAYS created first (so every
    # change has a record), then transitioned to `approved` (reviewed_by nil,
    # impact_assessment flagged auto_applied) and applied. A proposal is
    # eligible ONLY when ALL FOUR safety gates hold:
    #
    #   1. @repository.auto_apply == true.
    #   2. The diff is NON-DESTRUCTIVE — change is :create or :update. A
    #      :destroy ALWAYS stays pending_review for manual approval (even
    #      assignment destroys, which ApplyService would otherwise allow).
    #   3. The account is NOT halted — the platform kill-switch / emergency-halt
    #      (Ai::Autonomy::KillSwitchService#halted?, backed by account.ai_suspended?)
    #      must be clear. If halted, auto-apply is skipped (proposal stays
    #      pending_review) and the skip is logged.
    #   4. Only the per-tick-capped diff set (capped_diffs) is eligible.
    #
    # Apply failures (stale conflict, validation) are logged and skipped — the
    # proposal stays non-implemented and the reconcile continues; one failure
    # never aborts the loop. Applied / failed proposal IDs are surfaced on the
    # Result.
    #
    # Diff cap: per-tick proposal cap prevents proposal storms when an entire
    # fleet.yaml is rewritten in one commit. Configurable via env var
    # POWERNODE_GITOPS_MAX_PROPOSALS_PER_TICK (default 25).
    #
    # Reference: comprehensive stabilization sweep P5; GitOps auto-apply.
    class Reconciler
      Result = Struct.new(:ok?, :diff_count, :proposal_ids, :synced_revision,
                          :diff_summary, :error, :applied_proposal_ids,
                          :failed_proposal_ids, keyword_init: true)

      MAX_PROPOSALS_PER_TICK = ENV.fetch("POWERNODE_GITOPS_MAX_PROPOSALS_PER_TICK", "25").to_i

      def self.reconcile!(repository:, sync_run: nil)
        new(repository: repository, sync_run: sync_run).reconcile!
      end

      def initialize(repository:, sync_run: nil)
        @repository = repository
        @sync_run = sync_run
      end

      def reconcile!
        # Dual-plane fence (IMP-0ad117c2feb8): on the standby plane this
        # reconciler does NOTHING — not even clone/diff/propose. Unlike the
        # kill-switch (Gate 3 below, auto-apply only, so proposals keep
        # flowing for operator visibility under a halt), standby stands the
        # WHOLE pass down: the active plane produces the identical proposals,
        # and a standby plane that keeps reconciling both duplicates proposal
        # rows and auto-applies live changes on its own 5-minute cron — the
        # split-brain ControlPlaneRole exists to prevent. Runs before
        # schedule_sync! so a standby pass writes no sync-run state either.
        unless ::System::Autonomy::ControlPlaneRole.active?
          Rails.logger.info(
            "[Gitops::Reconciler] standby control plane — skipping reconcile for repository #{@repository.id}"
          )
          # A caller-created run (sync_now REST, anything passing sync_run:)
          # must not strand at "running" on the timeline — finalize it as a
          # success carrying the skip note. The internal cron path creates no
          # run at all on standby (this fence runs before schedule_sync!).
          @sync_run&.finalize!(
            status: "success", diff_count: 0, proposal_ids: [],
            synced_revision: nil,
            diff_summary: { "skipped" => "standby control plane" },
            error_message: nil
          )
          return Result.new(
            ok?: true, diff_count: 0, proposal_ids: [],
            applied_proposal_ids: [], failed_proposal_ids: [],
            diff_summary: "skipped: standby control plane"
          )
        end

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

        # Step 5: emit proposals (audit record is ALWAYS created first), then
        # auto-apply each eligible one when the repository opts in. Gate 3
        # (kill-switch) is evaluated once per tick — a halt mid-tick is rare
        # and the check is account-wide, so a single read is sufficient.
        proposal_ids = []
        applied_proposal_ids = []
        failed_proposal_ids = []
        auto_apply_allowed = @repository.auto_apply && !account_halted?

        capped_diffs.each do |diff|
          proposal_id = open_proposal(diff, repo_result.commit_sha)
          next if proposal_id.nil?

          proposal_ids << proposal_id
          next unless auto_apply_allowed && auto_appliable_diff?(diff)

          if auto_apply_proposal(proposal_id)
            applied_proposal_ids << proposal_id
          else
            failed_proposal_ids << proposal_id
          end
        end

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
          diff_summary: summarize(diffs),
          applied_proposal_ids: applied_proposal_ids,
          failed_proposal_ids: failed_proposal_ids
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

      # Gate 3: is the account's AI activity halted (kill-switch /
      # emergency-halt)? Backed by account.ai_suspended? — the same source of
      # truth the kill_switch_status / emergency_halt MCP tools use.
      def account_halted?
        halted = ::Ai::Autonomy::KillSwitchService.new(account: @repository.account).halted?
        if halted
          Rails.logger.info(
            "[Gitops::Reconciler] account #{@repository.account_id} is halted (kill-switch active) — " \
            "skipping GitOps auto-apply; proposals left pending_review"
          )
        end
        halted
      end

      # Gate 2: only non-destructive diffs are auto-appliable. Destroys ALWAYS
      # stay pending_review for manual approval — even assignment destroys,
      # which ApplyService would otherwise allow on operator approval.
      def auto_appliable_diff?(diff)
        %i[create update].include?(diff.change)
      end

      # Auto-approve (mirroring AgentProposal#approve! but with no human
      # reviewer + audit metadata flagging the source) then apply via
      # ApplyService. Returns true on a successful apply, false otherwise.
      # Apply failures (stale conflict, validation) are logged and swallowed
      # so one failure never aborts the reconcile loop.
      def auto_apply_proposal(proposal_id)
        proposal = ::Ai::AgentProposal.find_by(id: proposal_id)
        return false if proposal.nil?

        # Mirror the operator approval flow (proposal.approve!(user)) but
        # record that no human reviewed it — gitops auto-apply approved it.
        proposal.update!(
          status: "approved",
          reviewed_by: nil,
          reviewed_at: Time.current,
          impact_assessment: (proposal.impact_assessment || {}).merge(
            "auto_applied" => true,
            "approved_by" => "gitops_auto_apply",
            "auto_approved_at" => Time.current.iso8601
          )
        )

        result = ::System::Gitops::ApplyService.apply!(proposal: proposal)
        unless result.ok?
          Rails.logger.warn(
            "[Gitops::Reconciler] auto-apply failed for proposal=#{proposal_id} " \
            "stale_conflict=#{!!result.stale_conflict} error=#{result.error}"
          )
          # Revert to pending_review so the conflict surfaces to an operator
          # exactly as it would on the non-auto path — never leave a stuck
          # "approved" gitops proposal that could be re-applied or look
          # human-reviewed. Stash the failure reason for the operator.
          revert_failed_auto_apply(proposal, result)
        end
        result.ok?
      rescue StandardError => e
        Rails.logger.warn("[Gitops::Reconciler] auto-apply raised for proposal=#{proposal_id}: #{e.class}: #{e.message}")
        false
      end

      def revert_failed_auto_apply(proposal, result)
        proposal.update!(
          status: "pending_review",
          reviewed_at: nil,
          impact_assessment: (proposal.impact_assessment || {}).merge(
            "auto_apply_failed" => true,
            "auto_apply_error" => result.error,
            "auto_apply_stale_conflict" => !!result.stale_conflict,
            "auto_apply_failed_at" => Time.current.iso8601
          )
        )
      rescue StandardError => e
        Rails.logger.warn("[Gitops::Reconciler] failed to revert proposal=#{proposal.id} after auto-apply failure: #{e.message}")
      end

      def gitops_agent_id
        # Attribute GitOps proposals to the dedicated "GitOps Reconciler" agent
        # (seeded by db/seeds/system_gitops_reconciler_agent.rb). Falls back to
        # an arbitrary account agent only if the seed hasn't run — preferable to
        # a nil author, but the seed should make the fallback unreachable.
        ::Ai::Agent.resolve_for(@repository.account_id, name: "GitOps Reconciler", agent_type: "monitor")&.id ||
          ::Ai::Agent.for_account(@repository.account_id).first&.id
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
                   synced_revision: nil, diff_summary: {}, error: nil,
                   applied_proposal_ids: [], failed_proposal_ids: [])
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
          error: error,
          applied_proposal_ids: applied_proposal_ids,
          failed_proposal_ids: failed_proposal_ids
        )
      end
    end
  end
end
