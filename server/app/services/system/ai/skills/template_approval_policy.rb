# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Classifies whether an agent-driven TEMPLATE mutation needs a human in
      # the loop (campaign 019f6084 inc3, Deliverable 2).
      #
      # The distinction is blast-radius, not novelty:
      #   - Creating a NEW template (target: nil) — or assigning modules to an
      #     existing template that has NOTHING provisioned — is LOW-RISK: a
      #     fresh manifest touches no running node, so agents do it by default
      #     (it rides whatever consolidated approval the calling skill already
      #     holds; no separate gate).
      #   - Assigning/removing modules on an existing template THAT HAS
      #     PROVISIONED NODES REQUIRES approval: a manifest change propagates to
      #     every node on that template's next apply (TemplateApplyService),
      #     so it can reconfigure live fleet.
      #
      # Design choice (documented per the deliverable): the gate is expressed as
      # a *classification* a caller consults, not a hard raise. fulfill_capability_request
      # always takes the NEW-template path, so its consolidated plan approval is
      # the single audited decision; a caller that mutates an EXISTING provisioned
      # template routes the change through Ai::AgentProposal (architecture_propose
      # pattern) or its own consolidated approval, keyed off `requires_approval?`
      # here. Kept as a small reusable PORO so both paths share one definition of
      # "provisioned" rather than re-deriving it.
      class TemplateApprovalPolicy
        Classification = Struct.new(:requires_approval, :new_template, :provisioned_node_count, :reason,
                                    keyword_init: true) do
          def requires_approval?
            requires_approval
          end
        end

        # A node counts as "provisioned" when it carries a non-terminated
        # NodeInstance — i.e., live fleet a manifest change would reach.
        # `rebooting` is included deliberately: it's a live, non-terminated
        # status (System::NodeInstance::STATUSES) and reboots are exactly
        # when a fleet is mid-upgrade — the worst moment to skip approval.
        LIVE_INSTANCE_SCOPE = { system_node_instances: { status: %w[pending provisioning starting running stopping stopped rebooting error] } }.freeze

        def self.for(template:)
          new(template: template).classify
        end

        def initialize(template:)
          @template = template
        end

        def classify
          if @template.nil?
            return Classification.new(
              requires_approval: false, new_template: true,
              provisioned_node_count: 0,
              reason: "new template — nothing provisioned, low blast radius"
            )
          end

          count = provisioned_node_count
          if count.zero?
            Classification.new(
              requires_approval: false, new_template: false, provisioned_node_count: 0,
              reason: "existing template has no provisioned nodes — low blast radius"
            )
          else
            Classification.new(
              requires_approval: true, new_template: false, provisioned_node_count: count,
              reason: "existing template has #{count} provisioned node(s) — a manifest change propagates to live fleet on next apply"
            )
          end
        end

        private

        def provisioned_node_count
          @template.nodes
                   .joins(:node_instances)
                   .where(LIVE_INSTANCE_SCOPE)
                   .distinct
                   .count
        end
      end
    end
  end
end
