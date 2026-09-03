# frozen_string_literal: true

module System
  module Ai
    module Skills
      # GitOps Reconciler skill (HIER-P2F): sync one registered repository —
      # mint a System::GitopsSyncRun and hand it to System::Gitops::Reconciler,
      # exactly as the system_gitops_sync_repository MCP verb and the REST
      # sync_now action do, so the run id the operator later reads back is the
      # one the reconcile finalized.
      #
      # Refuses on a standby control plane BEFORE any run exists
      # (IMP-8ce4d88499a0): the reconciler's own fence performs nothing there
      # and returns ok?: true — the shape of a fully in-sync repository — so
      # asking ControlPlaneRole first is what keeps a "success" run from being
      # minted for a reconcile that never happened.
      #
      # Gated on the agent's own declared row, `system.gitops_sync_repository`
      # (auto_approve: the read side — refresh the diff, open proposals, apply
      # nothing).
      class GitopsSyncRepositoryExecutor < BaseSkillExecutor
        skill_descriptor(
          name:        "gitops_sync_repository",
          description: "Sync one registered GitOps repository now: clone/fast-forward it, diff its desired fleet state against the live fleet and open one Ai::AgentProposal per drifted resource; returns the finalized sync run handle. Applies nothing",
          category:    "devops",
          requires_approval: true,
          action_category:   "system.gitops_sync_repository",
          blast_radius: :low,
          inputs: {
            repository_id: { type: "string", required: true,
                             description: "System::GitopsRepository.id" }
          },
          outputs: {
            repository_id:   :string,
            sync_run_id:     :string,
            diff_count:      :integer,
            proposal_ids:    :array,
            synced_revision: :string,
            diff_summary:    :object
          }
        )

        binds_to "gitops_reconciler"

        protected

        # ADMISSION BEFORE THE GATE. BaseSkillExecutor#execute runs
        # #validate_inputs! ahead of #gate_action!, so resolving the repository
        # in this account happens here — an unknown id can only ever fail and
        # must not park an approval. The STANDBY refusal below deliberately
        # stays in #perform: which control plane is elected can change between
        # parking and replay, so it is not decidable from the inputs.
        def validate_inputs!(inputs)
          super

          @repo = ::System::GitopsRepository.where(account_id: @account.id).find_by(id: inputs[:repository_id])
          return if @repo

          raise ArgumentError, "GitopsRepository #{inputs[:repository_id]} not found in this account"
        end

        def perform(repository_id:)
          # Resolved and admitted in #validate_inputs! above, before the gate.
          repo = @repo

          unless ::System::Autonomy::ControlPlaneRole.active?
            return failure(
              "standby control plane — this plane is not permitted to reconcile repository #{repo.id} " \
              "(not elected, or the quorum gate itself errored); reconcile not performed",
              refusal_code: "standby_control_plane", retryable: false, repository_id: repo.id
            )
          end

          run = repo.schedule_sync!
          result = ::System::Gitops::Reconciler.reconcile!(repository: repo, sync_run: run)

          payload = {
            repository_id:   repo.id,
            sync_run_id:     run.id,
            diff_count:      result.diff_count,
            proposal_ids:    result.proposal_ids,
            synced_revision: result.synced_revision,
            diff_summary:    result.diff_summary
          }

          # A reconcile that FAILED is a failure (IMP-8ce4d88499a0): the reason
          # rides `error`, the run id stays on the envelope so the operator can
          # read the finalized run back.
          return failure(result.error.presence || "reconcile failed", **payload) unless result.ok?

          success(**payload, error: result.error)
        end
      end
    end
  end
end
