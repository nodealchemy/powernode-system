# frozen_string_literal: true

module System
  # Operator-facing CRUD over `Ai::InterventionPolicy` rows scoped to the
  # System extension's domains. Powers the System Settings → Autonomy modal
  # where operators configure per-action policy + approval chain assignment
  # for each of the 5 system agents (Fleet Autonomy, SDWAN Manager, CVE
  # Responder, Disk Image Manager, Runtime Manager) plus Manual Operations.
  #
  # This concern returns the full payload with three views: by_domain,
  # by_agent, by_action.
  #
  # `by_domain` is no longer a spare view. Since IMP-0874acd5b50c the Settings
  # modal builds its sections AND its per-action rows from it; it used to render
  # a list literal-ed into SystemSettingsPanel.tsx, which is how it came to omit
  # 28 of the 119 seeded categories and to show one control whose seed had been
  # deleted. So a category reaches an operator only through THIS payload — an
  # addition here is visible with no frontend change, and a row that lands in
  # the "other" catch-all now surfaces as an "Other" section rather than
  # disappearing.
  module AutonomyActions
    extend ActiveSupport::Concern

    SYSTEM_AGENT_NAMES = [
      "Fleet Autonomy",
      "SDWAN Manager",
      "CVE Responder",
      "Disk Image Manager",
      "Runtime Manager"
    ].freeze

    # ORDER IS SIGNIFICANT. `by_domain_pivot` resolves with `find`, so the FIRST
    # matching entry wins and any prefix that EXTENDS another entry's prefix has
    # to be declared before it. Two such pairs exist today:
    #
    #   system.instance_pool_           ⊂ system.instance_  (node_lifecycle)
    #   system.module_critical_upgrade_ ⊂ system.module_    (node_lifecycle)
    #
    # Both were mis-filed until this map was ordered specific-first: the whole
    # `instance_pool` domain was unreachable, and the CVE Responder's
    # `system.module_critical_upgrade_ready` landed under node_lifecycle. Note
    # that category is NOT prefixed `system.cve_`, so moving "cve" ahead of
    # "node_lifecycle" does not on its own file it correctly — the specific
    # prefix has to be listed too.
    #
    # Every category the extension's agent seeds create a policy row for must
    # match some entry here; "other" is the catch-all for rows seeded outside
    # this extension. spec/controllers/api/v1/system/autonomy_domain_pivot_spec.rb
    # pins both properties (nothing seeded reaches "other"; no declared domain is
    # left unreachable) so a new family or a reorder cannot regress silently.
    DOMAIN_PREFIXES = {
      "instance_pool"     => %w[system.instance_pool_],
      "cve"               => %w[system.cve_ system.module_critical_upgrade_],
      "sdwan"             => %w[system.sdwan_ sdwan. system.federation_peer_],
      "container_runtime" => %w[system.runtime_],
      "disk_image"        => %w[system.disk_image_],
      "gitops"            => %w[system.gitops_],
      "packages"          => %w[system.package_module. system.package_repository.],
      "architecture"      => %w[system.architecture.],
      "storage"           => %w[system.storage_],
      "project"           => %w[project.],
      "node_lifecycle"    => %w[system.cert_ system.acme_cert_ system.module_ system.instance_ system.fleet_ system.region_ system.capacity_ system.capability_gap_ system.observation system.task. system.template_closure_ system.node_boot_image_]
    }.freeze

    # GET /api/v1/system/autonomy
    def show
      payload = {
        agents: serialize_agents,
        chains: serialize_chains,
        policies: {
          by_action:  by_action_pivot,
          by_agent:   by_agent_pivot,
          by_domain:  by_domain_pivot
        }
      }
      render_success(data: payload)
    end

    # PATCH /api/v1/system/autonomy
    # body: { updates: [{action_category, policy, approval_chain_id, agent_id (or null), scope}, ...] }
    def update
      updates = Array(params[:updates] || params.dig(:autonomy, :updates))
      return render_error("updates array required", status: :bad_request) if updates.empty?

      changed_count = 0
      errors = []

      updates.each_with_index do |raw, idx|
        attrs = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
        attrs = attrs.with_indifferent_access

        action_category = attrs[:action_category]
        next errors << "[#{idx}] action_category required" if action_category.blank?
        next errors << "[#{idx}] unknown category #{action_category}" unless ::Ai::InterventionPolicy.category_registered?(action_category)

        policy_value = attrs[:policy]
        next errors << "[#{idx}] policy required" if policy_value.blank?
        next errors << "[#{idx}] invalid policy #{policy_value}" unless ::Ai::InterventionPolicy::POLICIES.include?(policy_value)

        scope = attrs[:scope].presence || (attrs[:agent_id].present? ? "agent" : "global")

        policy = ::Ai::InterventionPolicy.find_or_initialize_by(
          account: current_account,
          action_category: action_category,
          scope: scope,
          ai_agent_id: attrs[:agent_id],
          user_id: nil
        )
        policy.policy = policy_value
        policy.priority = attrs[:priority] || (scope == "agent" ? 10 : 5)
        policy.is_active = attrs[:is_active].nil? ? true : ActiveModel::Type::Boolean.new.cast(attrs[:is_active])
        policy.preferred_channels = Array(attrs[:preferred_channels]).presence || %w[notification]
        policy.conditions = attrs[:conditions].presence || policy.conditions || {}
        policy.approval_chain_id = attrs[:approval_chain_id]

        if policy.save
          changed_count += 1
        else
          errors << "[#{idx}] #{policy.errors.full_messages.join(', ')}"
        end
      end

      if errors.any?
        render_error("Some updates failed", status: :unprocessable_content,
                     details: { errors: errors, changed: changed_count })
      else
        render_success(data: { changed: changed_count, message: "#{changed_count} policies updated" })
      end
    end

    private

    def system_agents
      # Override-aware: an account override wins over the global default per name.
      @system_agents ||= SYSTEM_AGENT_NAMES.filter_map { |n| a = ::Ai::Agent.resolve_for(current_account.id, name: n); [ n, a ] if a }.to_h
    end

    def serialize_agents
      system_agents.values.map do |agent|
        trust = ::Ai::AgentTrustScore.find_by(agent_id: agent.id)
        {
          id: agent.id, name: agent.name, status: agent.status,
          trust_tier: trust&.tier, overall_score: trust&.overall_score,
          autonomy_config: agent.autonomy_config
        }
      end
    end

    def serialize_chains
      # Ai::ApprovalChain lives in the business extension. In core mode the
      # admin UI surfaces the autonomy/policy machinery without the chain
      # configuration table — empty array is the right empty-state.
      return [] unless defined?(::Ai::ApprovalChain)
      ::Ai::ApprovalChain.where(account: current_account, status: "active").map do |c|
        { id: c.id, name: c.name, step_count: c.step_count, is_sequential: c.is_sequential }
      end
    end

    def all_policies
      ::Ai::InterventionPolicy.where(account: current_account).includes(:agent, :approval_chain)
    end

    # The by_agent bucket a row belongs to. Single authority: `by_agent_pivot`
    # groups by it, and `serialize_policy` ships it, so a client rendering from
    # ANY pivot can key a policy the same way the by_agent view did without
    # re-deriving the rule (scope + agent presence) in its own language. Note
    # `by_agent_pivot` then drops rows whose bucket is not a SYSTEM_AGENT_NAMES
    # entry — this value is still correct for those, which is what lets a
    # by_domain-driven client show them.
    def agent_bucket_for(policy)
      policy.scope == "agent" && policy.agent ? policy.agent.name : "Manual Operations"
    end

    def serialize_policy(p)
      {
        id: p.id,
        action_category: p.action_category,
        scope: p.scope,
        policy: p.policy,
        priority: p.priority,
        is_active: p.is_active,
        agent_id: p.ai_agent_id,
        agent_name: p.agent&.name,
        agent_bucket: agent_bucket_for(p),
        approval_chain_id: p.approval_chain_id,
        approval_chain_name: p.approval_chain&.name,
        conditions: p.conditions,
        preferred_channels: p.preferred_channels
      }
    end

    def by_action_pivot
      all_policies.each_with_object({}) do |p, hash|
        (hash[p.action_category] ||= []) << serialize_policy(p)
      end
    end

    def by_agent_pivot
      result = system_agents.each_value.with_object({}) { |a, h| h[a.name] = [] }
      result["Manual Operations"] = []

      all_policies.each do |p|
        bucket = agent_bucket_for(p)
        next unless result.key?(bucket)
        result[bucket] << serialize_policy(p)
      end
      result
    end

    def by_domain_pivot
      result = DOMAIN_PREFIXES.keys.index_with { [] }
      result["other"] = []

      all_policies.each do |p|
        domain = DOMAIN_PREFIXES.find { |_d, prefixes| prefixes.any? { |pre| p.action_category.start_with?(pre) } }&.first || "other"
        result[domain] << serialize_policy(p)
      end
      result
    end
  end
end
