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
    # proposal reflecting current reality. An assignment that would introduce
    # an error-severity COMPOSITION conflict is rejected the same way — see
    # #apply_assignment.
    #
    # v1 scope: handles template/module/assignment/pool/platform kinds.
    # Create + update are applied; destroys stay conservative (a destroy is
    # never auto-applied — the Reconciler leaves it pending_review — and for
    # templates/modules/pools/platforms an approved destroy still returns an
    # explicit "not yet implemented" error so a live pool / platform
    # deployment is never torn down without a deliberate follow-up). Provider
    # config + advanced module features (versions, file_spec) ship as
    # follow-up slices — explicit error returns guide operators.
    #
    # Reference: extensions/system/docs/plans/missing-features.md (Phase 6b);
    # GitOps instance/pool/platform kinds (campaign increment 17).
    class ApplyService
      Result = Struct.new(:ok?, :applied_action, :resource_id, :error,
                          :stale_conflict, keyword_init: true)

      class StaleConflictError < StandardError; end
      class UnsupportedDiffError < StandardError; end
      class CompositionConflictError < StandardError; end

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
          # Result = Struct.new(:ok?, ...) — accessor is `ok?`, not `success?`.
          mark_implemented! if result.ok?
          result
        end
      rescue StaleConflictError => e
        Result.new(ok?: false, error: e.message, stale_conflict: true)
      rescue CompositionConflictError => e
        Result.new(ok?: false, error: e.message)
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
        return apply_pool(change: change, diff: diff)       if kind == "pool"
        return apply_platform(change: change, diff: diff)   if kind == "platform"
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

          existing = ::System::TemplateModule.find_by(node_template: tmpl, node_module: mod)
          return Result.new(ok?: true, applied_action: "created assignment", resource_id: existing.id) if existing

          # GitOps apply is AUTHORING — fleet.yaml is the desired state and the
          # operator approved this line — so an error-severity conflict is
          # refused rather than warned about, the same way a stale conflict is.
          # It rejects exactly the one line that breaks composition, leaving
          # the rest of the repository applied and the fix where it belongs.
          # Delta semantics as everywhere else: a template that already
          # collides still accepts unrelated fleet.yaml lines, or one bad line
          # would wedge the whole repository. The existence check above runs
          # first so a re-applied line stays the no-op find_or_create_by! made
          # it, even on a template that has since started colliding.
          verdict = ::System::TemplateCompositionAnalysis
                    .new(@proposal.account)
                    .assignment_verdict(template: tmpl, node_module: mod)
          raise CompositionConflictError, verdict.message if verdict.blocked?

          join = ::System::TemplateModule.create!(node_template: tmpl, node_module: mod)
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

      POOL_SCALAR_KEYS = %w[target_size min_size max_size lifecycle_class status].freeze

      # Declarative instance topology → System::InstancePool. Create binds the
      # pool to a NodeTemplate by name (create-time only) and sets the desired
      # sizes/lifecycle/status; update rotates only those scalar knobs. Destroy
      # is conservative (never torn down without manual confirmation) —
      # consistent with template/module and the Reconciler's destroy gate.
      def apply_pool(change:, diff:)
        case change
        when "create"
          desired = desired_hash(diff)
          template = resolve_node_template!(desired["node_template"] || desired[:node_template], kind: "pool")
          pool = ::System::InstancePool.create!(
            {
              account: @proposal.account,
              name: diff["name"] || diff[:name],
              node_template: template
            }.merge(pool_scalar_attrs(desired))
          )
          Result.new(ok?: true, applied_action: "created pool", resource_id: pool.id)
        when "update"
          pool = ::System::InstancePool
                 .where(account_id: @proposal.account_id)
                 .find_by(id: diff["resource_id"] || diff[:resource_id])
          raise StaleConflictError, "instance pool #{(diff['resource_id'] || diff[:resource_id]).inspect} no longer exists" unless pool

          updates = pool_scalar_attrs(desired_hash(diff))
          pool.update!(updates) if updates.any?
          Result.new(ok?: true, applied_action: "updated pool", resource_id: pool.id)
        when "destroy"
          raise UnsupportedDiffError,
                "pool destroy not yet implemented (v1 conservative — tearing down an instance pool terminates its warm members; requires manual confirmation)"
        else
          raise UnsupportedDiffError, "unsupported pool change=#{change.inspect}"
        end
      end

      # PlatformDeployment.target_replicas bridge. Create requires a
      # service_role + a NodeTemplate binding; update rotates the desired
      # replica count (and service_role). Destroy is conservative — removing a
      # deployment row breaks federation peer discovery.
      def apply_platform(change:, diff:)
        case change
        when "create"
          desired = desired_hash(diff)
          service_role = desired["service_role"] || desired[:service_role]
          if service_role.blank?
            raise UnsupportedDiffError,
                  "platform create requires desired.service_role (one of #{::System::PlatformDeployment::SERVICE_ROLES.join('|')})"
          end
          template = resolve_node_template!(desired["node_template"] || desired[:node_template], kind: "platform")

          attrs = {
            account: @proposal.account,
            name: diff["name"] || diff[:name],
            node_template: template,
            service_role: service_role
          }
          target_replicas = desired["target_replicas"] || desired[:target_replicas]
          attrs[:target_replicas] = target_replicas unless target_replicas.nil?

          dep = ::System::PlatformDeployment.create!(attrs)
          Result.new(ok?: true, applied_action: "created platform deployment", resource_id: dep.id)
        when "update"
          dep = ::System::PlatformDeployment
                .where(account_id: @proposal.account_id)
                .find_by(id: diff["resource_id"] || diff[:resource_id])
          raise StaleConflictError, "platform deployment #{(diff['resource_id'] || diff[:resource_id]).inspect} no longer exists" unless dep

          updates = desired_hash(diff)
                    .slice("service_role", :service_role, "target_replicas", :target_replicas)
                    .symbolize_keys
          dep.update!(updates) if updates.any?
          Result.new(ok?: true, applied_action: "updated platform deployment", resource_id: dep.id)
        when "destroy"
          raise UnsupportedDiffError,
                "platform destroy not yet implemented (v1 conservative — removing a PlatformDeployment breaks federation peer discovery; requires manual confirmation)"
        else
          raise UnsupportedDiffError, "unsupported platform change=#{change.inspect}"
        end
      end

      def desired_hash(diff)
        (diff["desired"] || diff[:desired]) || {}
      end

      def pool_scalar_attrs(desired)
        desired
          .slice(*POOL_SCALAR_KEYS, *POOL_SCALAR_KEYS.map(&:to_sym))
          .symbolize_keys
      end

      # Resolve a NodeTemplate binding referenced by name in a create diff.
      # Mirrors apply_template's node_platform resolution: a missing reference
      # is an authoring error (UnsupportedDiffError); a name that resolves to
      # nothing live is a StaleConflictError (operator must re-sync).
      def resolve_node_template!(name, kind:)
        if name.blank?
          raise UnsupportedDiffError,
                "#{kind} create requires desired.node_template — fleet.yaml entry missing the template reference"
        end
        template = ::System::NodeTemplate.find_by(account_id: @proposal.account_id, name: name)
        raise StaleConflictError, "node_template #{name.inspect} not found in this account" unless template
        template
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
