# frozen_string_literal: true

module Ai
  module Tools
    # MCP surface for the platform-wide architecture catalog. Provides
    # 1:1 parity with the operator UI — every Catalog → Architectures
    # action is also reachable here. Agents with system.architectures.manage
    # do direct CRUD; agents with the broader system.architectures.propose
    # route through Ai::AgentProposal for human review.
    #
    # Canonical rows (is_canonical=true) are immutable via the API regardless
    # of permission — the seven seeded architectures only evolve via
    # migration. This is enforced both here and at the model layer (belt
    # and suspenders).
    #
    # Reference: i-would-like-to-zesty-glade.md Tier 1 — T1.A.
    class SystemArchitectureCatalogTool < BaseTool
      REQUIRED_PERMISSION = "system.architectures.read"

      ACTION_PERMISSIONS = {
        "system_list_architectures"    => "system.architectures.read",
        "system_get_architecture"      => "system.architectures.read",
        "system_create_architecture"   => "system.architectures.manage",
        "system_update_architecture"   => "system.architectures.manage",
        "system_delete_architecture"   => "system.architectures.manage",
        "system_propose_architecture"  => "system.architectures.propose"
      }.freeze

      # Generic top-level definition used by BaseTool#validate_params!.
      # Per-action schemas are in #action_definitions below.
      def self.definition
        {
          name: "system_architecture_catalog",
          description: "Platform-wide architecture catalog — list, get, create, update, delete, propose",
          parameters: {
            action:          { type: "string",  required: true, description: "One of: system_list_architectures, system_get_architecture, system_create_architecture, system_update_architecture, system_delete_architecture, system_propose_architecture" },
            architecture_id: { type: "string",  required: false },
            attributes:      { type: "object",  required: false },
            name:            { type: "string",  required: false },
            family:          { type: "string",  required: false },
            apt_name:        { type: "string",  required: false },
            rpm_name:        { type: "string",  required: false },
            display_name:    { type: "string",  required: false },
            description:     { type: "string",  required: false },
            kernel_options:  { type: "string",  required: false },
            aliases:         { type: "array",   required: false },
            enabled:         { type: "boolean", required: false },
            public:          { type: "boolean", required: false },
            is_canonical:    { type: "boolean", required: false },
            justification:   { type: "string",  required: false }
          }
        }
      end

      def self.action_definitions
        {
          "system_list_architectures" => {
            description: "List the platform-wide architecture catalog. Returns canonical + custom rows with usage counts.",
            parameters: {
              family:        { type: "string",  required: false, description: "Filter by family (x86, arm, power, z, risc-v, mips, other)" },
              is_canonical:  { type: "boolean", required: false, description: "Filter by canonical vs operator-created custom rows" },
              enabled:       { type: "boolean", required: false, description: "Filter by enabled (true) vs disabled (false) architectures" }
            }
          },
          "system_get_architecture" => {
            description: "Fetch a single architecture by id with full catalog metadata + usage counts",
            parameters: {
              architecture_id: { type: "string", required: true, description: "UUID of the architecture to fetch" }
            }
          },
          "system_create_architecture" => {
            description: "Create a custom (non-canonical) architecture. Requires system.architectures.manage. Use system_propose_architecture if you only have system.architectures.propose.",
            parameters: {
              name:         { type: "string",  required: true, description: "Canonical architecture name (e.g. amd64, arm64)" },
              family:       { type: "string",  required: true, description: "One of: x86, arm, power, z, risc-v, mips, other" },
              apt_name:     { type: "string",  required: false, description: "Debian/APT arch label for this architecture (e.g. amd64)" },
              rpm_name:     { type: "string",  required: false, description: "RPM/DNF arch label for this architecture (e.g. x86_64)" },
              display_name: { type: "string",  required: false, description: "Human-friendly display label for the catalog UI" },
              description:  { type: "string",  required: false, description: "Optional free-text description of the architecture" },
              kernel_options: { type: "string", required: false, description: "Default kernel boot options associated with this architecture" },
              aliases:      { type: "array", required: false, description: "Alternate names this architecture is known by (e.g. [\"x86_64\"] for amd64) — stored lowercased and deduplicated, and consulted when matching an arch string" },
              enabled:      { type: "boolean", required: false, description: "Whether the architecture is enabled for use (default true)" },
              public:       { type: "boolean", required: false, description: "Whether the architecture is publicly visible (default true)" }
            }
          },
          "system_update_architecture" => {
            description: "Update a non-canonical custom architecture. Rejects canonical rows with 403-equivalent error.",
            parameters: {
              architecture_id: { type: "string", required: true, description: "UUID of the custom architecture to update" },
              attributes:      { type: "object", required: true,
                                  description: "Allowed: name, family, apt_name, rpm_name, display_name, description, kernel_options, aliases, enabled, public" }
            }
          },
          "system_delete_architecture" => {
            description: "Delete a non-canonical custom architecture. Rejects canonical rows. Will fail if any NodePlatform references it.",
            parameters: {
              architecture_id: { type: "string", required: true, description: "UUID of the custom architecture to delete" }
            }
          },
          "system_propose_architecture" => {
            description: "Propose a new architecture for human review. Creates an Ai::AgentProposal row — no architecture is materialized until the human approver clicks 'Approve & Apply' in the proposals UI. Use this when the calling agent only has system.architectures.propose.",
            parameters: {
              name:         { type: "string",  required: true, description: "Canonical architecture name to propose (e.g. loongarch64)" },
              family:       { type: "string",  required: true, description: "Architecture family: x86, arm, power, z, risc-v, mips, other" },
              apt_name:     { type: "string",  required: false, description: "Debian/APT arch label for the proposed architecture" },
              rpm_name:     { type: "string",  required: false, description: "RPM/DNF arch label for the proposed architecture" },
              display_name: { type: "string",  required: false, description: "Human-friendly display label for the catalog UI" },
              description:  { type: "string",  required: false, description: "Optional free-text description of the proposed architecture" },
              aliases:      { type: "array",   required: false, description: "Alternate names for the proposed architecture — carried into the proposal so approval materializes the same row a direct create would" },
              justification: { type: "string", required: false, description: "Why this architecture should be added — surfaces in the approval UI" }
            }
          }
        }
      end

      protected

      def call(params)
        action = params[:action]
        return error_result("permission denied: #{required_perm_for(action)} required") unless action_permitted?(action)

        case action
        when "system_list_architectures"   then list_architectures(params)
        when "system_get_architecture"     then get_architecture(params)
        when "system_create_architecture"  then create_architecture(params)
        when "system_update_architecture"  then update_architecture(params)
        when "system_delete_architecture"  then delete_architecture(params)
        when "system_propose_architecture" then propose_architecture(params)
        else error_result("Unknown action: #{action}")
        end
      rescue ActiveRecord::RecordNotFound => e
        error_result(e.message)
      rescue ActiveRecord::RecordInvalid => e
        error_result(e.record.errors.full_messages.join("; "))
      rescue ActiveRecord::DeleteRestrictionError => e
        error_result("Cannot delete: #{e.message}")
      end

      private

      # === Permission gating ===
      # Two bypasses, both EXPLICIT (IMP-54bf2643f542, sibling of the
      # SystemFleetTool fix IMP-9030413bc292 — its ladder carries the full note):
      #
      #   internal?            in-process system callers (autonomy reconcilers,
      #                        skill executors running without a user) that
      #                        opted in with `internal: true`.
      #   instance_authorized? an MCP instance principal (mTLS node cert, no
      #                        User) whose specific tool name already cleared
      #                        Mcp::Principal#may_invoke? — that per-tool grant
      #                        stands in for authorization. It is NAME-scoped
      #                        while this tool runs the action the caller
      #                        supplies, so treat it as provenance, not a fence.
      #
      # This used to be one implicit `@user.nil?` bypass, whose premise — that
      # MCP callers always carry a user — predates instance principals and is
      # false for them, so an instance skipped this map entirely. A nil user
      # with neither flag now fails CLOSED.
      def required_perm_for(action)
        ACTION_PERMISSIONS[action] || REQUIRED_PERMISSION
      end

      def action_permitted?(action)
        return true if internal?
        return true if instance_authorized?
        return false if @user.nil?
        return true unless @user.respond_to?(:has_permission?)

        @user.has_permission?(required_perm_for(action))
      end

      # ── List / Get ───────────────────────────────────────────────────

      def list_architectures(params)
        scope = ::System::NodeArchitecture.all
        scope = scope.by_family(params[:family]) if params[:family].present?
        unless params[:is_canonical].nil?
          scope = bool(params[:is_canonical]) ? scope.canonical : scope.custom
        end
        unless params[:enabled].nil?
          scope = bool(params[:enabled]) ? scope.enabled : scope.disabled
        end
        success_result(architectures: scope.ordered.map { |a| serialize(a) })
      end

      def get_architecture(params)
        arch = ::System::NodeArchitecture.find(params[:architecture_id])
        success_result(architecture: serialize(arch))
      end

      # ── Create / Update / Delete (CRUD) ──────────────────────────────

      def create_architecture(params)
        arch = ::System::NodeArchitecture.new(create_attrs(params))
        arch.is_canonical = false # agents can't fabricate canonicals

        if arch.save
          success_result(architecture: serialize(arch))
        else
          error_result(arch.errors.full_messages.join("; "))
        end
      end

      def update_architecture(params)
        arch = ::System::NodeArchitecture.find(params[:architecture_id])
        return error_result("permission denied: canonical architectures are immutable via the API") if arch.protected_canonical?

        attrs = update_attrs(params[:attributes] || {})
        if arch.update(attrs)
          success_result(architecture: serialize(arch))
        else
          error_result(arch.errors.full_messages.join("; "))
        end
      end

      def delete_architecture(params)
        arch = ::System::NodeArchitecture.find(params[:architecture_id])
        return error_result("permission denied: canonical architectures are immutable via the API") if arch.protected_canonical?

        if arch.destroy
          success_result(deleted: true, architecture_id: arch.id)
        else
          error_result(arch.errors.full_messages.join("; "))
        end
      end

      # ── Propose (unprivileged-agent path) ────────────────────────────

      def propose_architecture(params)
        return error_result("Ai::AgentProposal not available in this environment") unless defined?(::Ai::AgentProposal)

        proposing_agent = @agent || default_proposal_agent
        return error_result("No agent context available to attribute the proposal to — pass agent: when constructing the tool, or seed a Fleet Autonomy agent for the account.") unless proposing_agent

        title = "Add architecture: #{params[:name]}"

        # aliases rides the proposal (IMP-77a46f475912): the slice previously
        # dropped it, so an approved proposal materialized a DIFFERENT row
        # than the same arguments passed to create_architecture would.
        proposed = create_attrs(params).merge(is_canonical: false).slice(
          :name, :family, :apt_name, :rpm_name, :display_name, :description, :aliases
        )

        proposal = ::Ai::AgentProposal.new(
          account: @user&.account || proposing_agent.account,
          ai_agent_id: proposing_agent.id,
          title: title,
          description: build_proposal_description(params),
          proposal_type: "configuration",
          status: "pending_review",
          priority: "medium",
          proposed_changes: {
            "resource"   => "system.node_architecture",
            "action"     => "create",
            "attributes" => proposed
          },
          impact_assessment: {
            "scope"          => "platform_wide",
            "reversibility"  => "destroy_if_unreferenced",
            "blast_radius"   => "every account using the catalog gains a new available architecture"
          }
        )

        if proposal.save
          success_result(
            proposal_id: proposal.id,
            status: proposal.status,
            review_deadline: proposal.review_deadline,
            note: "Proposal pending review — approval materializes the architecture."
          )
        else
          error_result(proposal.errors.full_messages.join("; "))
        end
      end

      # ── Helpers ──────────────────────────────────────────────────────

      def create_attrs(params)
        {
          name:           params[:name],
          family:         params[:family],
          apt_name:       params[:apt_name],
          rpm_name:       params[:rpm_name],
          display_name:   params[:display_name],
          description:    params[:description],
          kernel_options: params[:kernel_options],
          aliases:        params[:aliases],
          enabled:        params.key?(:enabled) ? bool(params[:enabled]) : true,
          public:         params.key?(:public) ? bool(params[:public]) : true
        }.compact
      end

      ALLOWED_UPDATE_KEYS = %w[name family apt_name rpm_name display_name description kernel_options aliases enabled public].freeze

      def update_attrs(raw)
        raw.to_h.transform_keys(&:to_s).slice(*ALLOWED_UPDATE_KEYS)
      end

      def build_proposal_description(params)
        parts = []
        parts << "Architecture name: #{params[:name]}"
        parts << "Family: #{params[:family]}"
        parts << "apt_name: #{params[:apt_name]}" if params[:apt_name].present?
        parts << "rpm_name: #{params[:rpm_name]}" if params[:rpm_name].present?
        parts << "display_name: #{params[:display_name]}" if params[:display_name].present?
        parts << ""
        parts << "Justification: #{params[:justification].presence || '(none provided)'}"
        parts.join("\n")
      end

      # When propose_architecture is called outside of an MCP session
      # (e.g. via Rails runner) there's no @agent. Fall back to the
      # account's Fleet Autonomy agent — it owns the architecture
      # intervention policies anyway, so attributing proposals to it
      # is semantically correct.
      def default_proposal_agent
        return nil unless @user&.account && defined?(::Ai::Agent)

        ::Ai::Agent.resolve_for(@user.account.id, name: "Fleet Autonomy", agent_type: "monitor")
      end

      def bool(v)
        return v if [ true, false ].include?(v)
        v.to_s.casecmp("true").zero? || v.to_s == "1"
      end

      def serialize(arch)
        {
          id: arch.id,
          name: arch.name,
          apt_name: arch.apt_name,
          rpm_name: arch.rpm_name,
          display_name: arch.display_name,
          family: arch.family,
          description: arch.description,
          kernel_options: arch.kernel_options,
          aliases: Array(arch.aliases),
          enabled: arch.enabled,
          public: arch.public,
          is_canonical: arch.is_canonical,
          usage: {
            node_platforms: arch.node_platform_count,
            package_repositories: arch.package_repository_count,
            packages: arch.package_count
          },
          created_at: arch.created_at,
          updated_at: arch.updated_at
        }
      end
    end
  end
end
