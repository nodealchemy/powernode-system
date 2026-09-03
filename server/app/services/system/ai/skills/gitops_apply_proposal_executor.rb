# frozen_string_literal: true

module System
  module Ai
    module Skills
      # GitOps Reconciler skill (HIER-P2F): apply one approved GitOps proposal
      # to live fleet state through System::Gitops::ApplyService — the same
      # service the system_gitops_apply_proposal MCP verb replays after its
      # gate releases (IMP-0b4f18ae4384).
      #
      # Gated on the agent's own declared row, `system.gitops_apply_proposal`
      # (require_approval), which is ALSO the category that MCP verb parks
      # under — the skill door and the MCP door are one operator control.
      #
      # ApplyService's own preconditions (proposal status, gitops source, diff
      # shape) are evaluated at apply time, never re-derived here: a refusal
      # comes back as a failure with the service's reason, `stale_conflict`
      # flagged when reality drifted under the proposal (IMP-4a3a45df69bc —
      # that is the case an autonomous caller must STOP on, so it must never
      # ride the success channel).
      class GitopsApplyProposalExecutor < BaseSkillExecutor
        skill_descriptor(
          name:        "gitops_apply_proposal",
          description: "Apply one approved GitOps drift proposal to live fleet state (template / module / assignment / pool / platform diffs) and mark it implemented; a stale-conflict or unsupported diff is refused with the reason",
          category:    "devops",
          requires_approval: true,
          action_category:   "system.gitops_apply_proposal",
          blast_radius: :high,
          inputs: {
            proposal_id: { type: "string", required: true,
                           description: "Ai::AgentProposal.id — an approved proposal with source gitops" }
          },
          outputs: {
            applied:         :boolean,
            applied_action:  :string,
            resource_id:     :string,
            proposal_id:     :string,
            proposal_status: :string
          }
        )

        binds_to "gitops_reconciler"

        protected

        # ADMISSION BEFORE THE GATE. BaseSkillExecutor#execute runs
        # #validate_inputs! ahead of #gate_action!: a proposal that is not in
        # this account can only ever fail, so it is refused before an approval
        # is parked rather than after.
        def validate_inputs!(inputs)
          super

          @proposal = ::Ai::AgentProposal.where(account_id: @account.id).find_by(id: inputs[:proposal_id])
          return if @proposal

          raise ArgumentError, "AgentProposal #{inputs[:proposal_id]} not found in this account"
        end

        def perform(proposal_id:)
          # Resolved and admitted in #validate_inputs! above, before the gate.
          proposal = @proposal

          result = ::System::Gitops::ApplyService.apply!(proposal: proposal)

          unless result.ok?
            extra = { applied: false, proposal_id: proposal.id }
            extra[:stale_conflict] = true if result.stale_conflict
            return failure(result.error.presence || "apply failed", **extra)
          end

          success(
            applied:         true,
            applied_action:  result.applied_action,
            resource_id:     result.resource_id,
            proposal_id:     proposal.id,
            proposal_status: proposal.reload.status
          )
        end
      end
    end
  end
end
