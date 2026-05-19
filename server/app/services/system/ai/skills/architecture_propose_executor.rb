# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Propose a new architecture for the platform-wide catalog.
      #
      # Routes through Ai::AgentProposal — the architecture is NOT
      # materialized until an operator clicks "Approve & Apply" in the
      # proposals UI. This is the path for agents with
      # system.architectures.propose but not system.architectures.manage,
      # and is the auto-approved intervention policy at the autonomy
      # layer (the proposal itself is the gate, not the policy).
      #
      # Reference: i-would-like-to-zesty-glade.md Tier 1 — T1.A.
      class ArchitectureProposeExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "architecture_propose",
          description: "Propose adding a new architecture to the platform-wide catalog (creates an Ai::AgentProposal for human review).",
          category: "fleet",
          inputs: {
            name:          { type: "string",  required: true,  description: "Canonical lowercase name (e.g. loongarch64, mips64el)" },
            family:        { type: "string",  required: true,  description: "One of: x86, arm, power, z, risc-v, mips, other" },
            apt_name:      { type: "string",  required: false, description: "apt-style name (e.g. amd64 for x86_64)" },
            rpm_name:      { type: "string",  required: false, description: "rpm-style name (matches `name` for most arches)" },
            display_name:  { type: "string",  required: false },
            description:   { type: "string",  required: false },
            justification: { type: "string",  required: false, description: "Why this arch is needed — surfaces in the approval UI" }
          },
          outputs: {
            proposal_id:     :string,
            status:          :string,
            review_deadline: :datetime
          }
        )

        binds_to "Fleet Autonomy"

        protected

        def perform(name:, family:, apt_name: nil, rpm_name: nil, display_name: nil, description: nil, justification: nil)
          result = tool(::Ai::Tools::SystemArchitectureCatalogTool).execute(params: {
            action: "system_propose_architecture",
            name: name, family: family,
            apt_name: apt_name, rpm_name: rpm_name,
            display_name: display_name, description: description,
            justification: justification
          })

          result[:success] ? success(result[:data]) : failure(result[:error])
        end
      end
    end
  end
end
