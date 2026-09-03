# frozen_string_literal: true

module System
  module Ai
    module Skills
      # GitOps Reconciler skill (HIER-P2F): register a Git repository as a
      # declarative source of fleet state. Inserts the SAME attribute shape the
      # system_gitops_register_repository MCP verb does
      # (SystemFleetTool#gitops_repository_attributes) — branch defaults to
      # main, path_prefix to "", auto_apply to false, last_status pending —
      # and surfaces a model validation (duplicate name, missing URL) as a
      # failure rather than a raise.
      #
      # Gated on the agent's own declared row,
      # `system.gitops_register_repository` (require_approval: a new source
      # of truth the reconciler will sync every five minutes). The repository
      # URL is the one input that can carry userinfo; it is never echoed back
      # in the envelope.
      class GitopsRegisterRepositoryExecutor < BaseSkillExecutor
        skill_descriptor(
          name:        "gitops_register_repository",
          description: "Register a Git repository as a declarative source of fleet state the GitOps Reconciler syncs every 5 minutes (branch, path prefix, Vault credential path, auto_apply); the first sync runs on the next reconcile tick",
          category:    "devops",
          requires_approval: true,
          action_category:   "system.gitops_register_repository",
          blast_radius: :medium,
          inputs: {
            name:                  { type: "string",  required: true,
                                     description: "Display name, unique within the account (<= 64 chars)" },
            repo_url:              { type: "string",  required: true,
                                     description: "Clone URL (https or ssh); never put credentials in it — use vault_credential_path" },
            branch:                { type: "string",  required: false, description: "Branch to track (default main)" },
            vault_credential_path: { type: "string",  required: false,
                                     description: "Vault path holding the clone credentials" },
            path_prefix:           { type: "string",  required: false,
                                     description: "Directory inside the repo holding fleet.yaml (default repo root)" },
            auto_apply:            { type: "boolean", required: false,
                                     description: "Apply non-destructive drift without operator review (default false)" }
          },
          outputs: {
            repository_id: :string,
            name:          :string,
            branch:        :string,
            path_prefix:   :string,
            auto_apply:    :boolean,
            last_status:   :string
          }
        )

        binds_to "gitops_reconciler"

        protected

        # ADMISSION BEFORE THE GATE. BaseSkillExecutor#execute runs
        # #validate_inputs! ahead of #gate_action!, and the MCP door
        # pre-validates the candidate for the same reason
        # (SystemFleetTool#gitops_register_repository_gate_context): a duplicate
        # name or a malformed URL can only ever fail, so an operator must not be
        # asked to approve it. The candidate row is BUILT here (unsaved) and
        # saved in #perform, so the two doors cannot drift on attribute shape.
        def validate_inputs!(inputs)
          super

          @candidate = ::System::GitopsRepository.new(
            account:               @account,
            name:                  inputs[:name],
            repo_url:              inputs[:repo_url],
            branch:                inputs[:branch].presence || "main",
            vault_credential_path: inputs[:vault_credential_path],
            path_prefix:           inputs[:path_prefix].presence || "",
            auto_apply:            ::ActiveModel::Type::Boolean.new.cast(inputs[:auto_apply]) == true,
            last_status:           "pending"
          )
          return if @candidate.valid?

          raise ArgumentError,
                "gitops repository validation failed: #{@candidate.errors.full_messages.to_sentence}"
        end

        def perform(name:, repo_url:, branch: nil, vault_credential_path: nil, path_prefix: nil, auto_apply: false)
          # Built and admitted in #validate_inputs! above, before the gate. The
          # rescue stays as a race backstop: a name can be taken between the
          # admission check and this insert.
          repo = @candidate
          repo.save!

          success(
            repository_id: repo.id,
            name:          repo.name,
            branch:        repo.branch,
            path_prefix:   repo.path_prefix,
            auto_apply:    repo.auto_apply,
            last_status:   repo.last_status
          )
        rescue ::ActiveRecord::RecordInvalid => e
          failure("gitops repository validation failed: #{e.record.errors.full_messages.to_sentence}")
        end
      end
    end
  end
end
