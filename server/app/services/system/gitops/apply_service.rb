# frozen_string_literal: true

module System
  module Gitops
    # Applies an approved GitOps Proposal — converts the diff payload into
    # actual DB changes (creates Templates, Modules, Assignments per the
    # proposal's desired state).
    #
    # The Reconciler creates proposals; this service consumes them after
    # operator approval. Together they form the GitOps reconciliation cycle:
    #
    #   git commit
    #     → Reconciler.reconcile! diffs desired vs live
    #     → opens Ai::AgentProposal per diff
    #     → operator approves in /app/approvals
    #     → ApplyService.apply!(proposal:) executes the diff
    #     → marks proposal.status = "implemented"
    #
    # Conflict semantics: the apply path re-checks live state at apply time.
    # If the resource has been touched between proposal creation and
    # apply (manually via MCP or another GitOps run), the apply is rejected
    # with a stale-conflict error. Operator must re-sync to get a fresh
    # proposal reflecting current reality.
    #
    # v1 scope: handles template/module/assignment kinds. Destroy + provider
    # config + advanced module features (versions, file_spec) ship as
    # follow-up slices — explicit error returns guide operators.
    #
    # Reference: extensions/system/docs/plans/missing-features.md (Phase 6b).
    class ApplyService
      Result = Struct.new(:ok?, :applied_action, :resource_id, :error,
                          :stale_conflict, keyword_init: true)

      class StaleConflictError < StandardError; end
      class UnsupportedDiffError < StandardError; end

      def self.apply!(proposal:)
        new(proposal: proposal).apply!
      end

      def initialize(proposal:)
        @proposal = proposal
      end

      def apply!
        return failure("proposal status is #{@proposal.status.inspect}; only 'approved' proposals can be applied") unless @proposal.status == "approved"
        return failure("proposal source is not 'gitops'") unless gitops_source?

        diff = @proposal.proposed_changes.dig("diff") || @proposal.proposed_changes[:diff]
        return failure("proposal has no diff payload") if diff.blank?

        kind = diff["kind"] || diff[:kind]
        change = (diff["change"] || diff[:change]).to_s

        ::ActiveRecord::Base.transaction do
          result = apply_diff(kind: kind, change: change, diff: diff)
          mark_implemented! if result.success?
          result
        end
      rescue StaleConflictError => e
        Result.new(ok?: false, error: e.message, stale_conflict: true)
      rescue UnsupportedDiffError => e
        Result.new(ok?: false, error: e.message)
      rescue ::ActiveRecord::RecordInvalid => e
        Result.new(ok?: false, error: "validation: #{e.record.errors.full_messages.join('; ')}")
      end

      private

      def gitops_source?
        source = @proposal.proposed_changes.dig("source") || @proposal.proposed_changes[:source]
        source == "gitops"
      end

      def apply_diff(kind:, change:, diff:)
        return apply_template(change: change, diff: diff)   if kind == "template"
        return apply_module(change: change, diff: diff)     if kind == "module"
        return apply_assignment(change: change, diff: diff) if kind == "assignment"
        return informational(diff: diff)                    if kind == "provider_config" || change == "informational"

        raise UnsupportedDiffError, "unsupported diff kind=#{kind.inspect}"
      end

      def apply_template(change:, diff:)
        case change
        when "create"
          desired = diff["desired"] || diff[:desired] || {}
          platform_name = desired["node_platform"] || desired[:node_platform]
          unless platform_name.present?
            raise UnsupportedDiffError,
                  "template create requires desired.node_platform — fleet.yaml line missing the platform reference"
          end

          platform = ::System::NodePlatform.find_by(account_id: @proposal.account_id, name: platform_name)
          raise StaleConflictError, "node_platform #{platform_name.inspect} not found in this account" unless platform

          tmpl = ::System::NodeTemplate.create!(
            account: @proposal.account,
            node_platform: platform,
            name: diff["name"] || diff[:name]
          )
          Result.new(ok?: true, applied_action: "created template", resource_id: tmpl.id)
        when "update"
          tmpl = ::System::NodeTemplate
                 .where(account_id: @proposal.account_id)
                 .find_by(id: diff["resource_id"] || diff[:resource_id])
          raise StaleConflictError, "template #{diff[:resource_id]} no longer exists" unless tmpl

          # v1: only update the name (other fields like node_platform_id are
          # required at creation time + rare to GitOps-rotate). Future slice:
          # full attribute set.
          desired_name = (diff["desired"] || diff[:desired])&.dig("name") || (diff["desired"] || diff[:desired])&.dig(:name)
          tmpl.update!(name: desired_name) if desired_name.present?
          Result.new(ok?: true, applied_action: "updated template", resource_id: tmpl.id)
        when "destroy"
          raise UnsupportedDiffError,
                "template destroy not yet implemented (v1 conservative — destructive ops require manual confirmation; expected in Phase 6c)"
        else
          raise UnsupportedDiffError, "unsupported template change=#{change.inspect}"
        end
      end

      def apply_module(change:, diff:)
        case change
        when "create"
          mod = ::System::NodeModule.create!(
            account: @proposal.account,
            name: diff["name"] || diff[:name],
            variety: ((diff["desired"] || diff[:desired])&.dig("variety") ||
                      (diff["desired"] || diff[:desired])&.dig(:variety) || "subscription"),
            category: default_module_category
          )
          Result.new(ok?: true, applied_action: "created module", resource_id: mod.id)
        when "update"
          mod = ::System::NodeModule
                .where(account_id: @proposal.account_id)
                .find_by(id: diff["resource_id"] || diff[:resource_id])
          raise StaleConflictError, "module #{diff[:resource_id]} no longer exists" unless mod

          attrs = (diff["desired"] || diff[:desired]) || {}
          updates = attrs.slice("description", :description, "variety", :variety).symbolize_keys
          mod.update!(updates) if updates.any?
          Result.new(ok?: true, applied_action: "updated module", resource_id: mod.id)
        when "destroy"
          raise UnsupportedDiffError,
                "module destroy not yet implemented (v1 conservative — destructive ops require manual confirmation)"
        else
          raise UnsupportedDiffError, "unsupported module change=#{change.inspect}"
        end
      end

      def apply_assignment(change:, diff:)
        case change
        when "create"
          desired = diff["desired"] || diff[:desired] || {}
          template_name = desired["template"] || desired[:template]
          module_name = desired["module"] || desired[:module]

          tmpl = ::System::NodeTemplate.find_by(account_id: @proposal.account_id, name: template_name)
          mod = ::System::NodeModule.find_by(account_id: @proposal.account_id, name: module_name)

          raise StaleConflictError, "template #{template_name.inspect} not found" unless tmpl
          raise StaleConflictError, "module #{module_name.inspect} not found" unless mod

          join = ::System::TemplateModule.find_or_create_by!(node_template: tmpl, node_module: mod)
          Result.new(ok?: true, applied_action: "created assignment", resource_id: join.id)
        when "destroy"
          # Assignments are safer to destroy via GitOps than templates/modules
          # — operator removed the line from fleet.yaml deliberately.
          tmpl_id = (diff["current"] || diff[:current])&.dig("template_id") ||
                    (diff["current"] || diff[:current])&.dig(:template_id)
          mod_id = (diff["current"] || diff[:current])&.dig("module_id") ||
                   (diff["current"] || diff[:current])&.dig(:module_id)

          tmpl = ::System::NodeTemplate.where(account_id: @proposal.account_id).find_by(id: tmpl_id)
          mod = ::System::NodeModule.where(account_id: @proposal.account_id).find_by(id: mod_id)

          if tmpl && mod
            ::System::TemplateModule.where(node_template: tmpl, node_module: mod).destroy_all
            Result.new(ok?: true, applied_action: "destroyed assignment")
          else
            # Idempotent — already gone
            Result.new(ok?: true, applied_action: "assignment already absent")
          end
        when "update"
          # Assignments don't have updateable fields in v1; treat as no-op.
          Result.new(ok?: true, applied_action: "assignment update — no-op (v1)")
        else
          raise UnsupportedDiffError, "unsupported assignment change=#{change.inspect}"
        end
      end

      def informational(diff:)
        Rails.logger.info(
          "[Gitops::ApplyService] informational diff (no action) " \
          "kind=#{diff['kind']} name=#{diff['name']}"
        )
        Result.new(ok?: true, applied_action: "informational — no action taken")
      end

      def default_module_category
        ::System::NodeModuleCategory.find_or_create_by!(account: @proposal.account, name: "Userland") do |c|
          c.position = 90
          c.variety = "subscription"
        end
      end

      def mark_implemented!
        # AgentProposal table has status + reviewed_at but no implemented_at /
        # implementation_notes columns. Stash apply-time metadata in
        # impact_assessment (a JSONB field operator UI already renders).
        @proposal.update!(
          status: "implemented",
          impact_assessment: (@proposal.impact_assessment || {}).merge(
            "applied_at" => Time.current.iso8601,
            "apply_service_version" => "v1"
          )
        )
      end

      def failure(message)
        Result.new(ok?: false, error: message)
      end
    end
  end
end
