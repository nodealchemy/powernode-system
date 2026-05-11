# frozen_string_literal: true

module System
  # Operator-facing CRUD over `Ai::InterventionPolicy` rows scoped to the
  # System extension's domains. Powers the System Settings → Autonomy modal
  # where operators configure per-action policy + approval chain assignment
  # for each of the 5 system agents (Fleet Autonomy, SDWAN Manager, CVE
  # Responder, Disk Image Manager, Runtime Manager) plus Manual Operations.
  #
  # The frontend pivots whichever way it wants — this concern returns the
  # full payload with three views: by_domain, by_agent, by_action.
  module AutonomyActions
    extend ActiveSupport::Concern

    SYSTEM_AGENT_NAMES = [
      "Fleet Autonomy",
      "SDWAN Manager",
      "CVE Responder",
      "Disk Image Manager",
      "Runtime Manager"
    ].freeze

    DOMAIN_PREFIXES = {
      "node_lifecycle"  => %w[system.cert_ system.module_ system.instance_ system.fleet_ system.region_ system.capacity_ system.observation system.task.],
      "sdwan"           => %w[system.sdwan_ sdwan.],
      "container_runtime" => %w[system.runtime_],
      "disk_image"      => %w[system.disk_image_],
      "instance_pool"   => %w[system.instance_pool_],
      "cve"             => %w[system.cve_]
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
      @system_agents ||= ::Ai::Agent.where(account: current_account, name: SYSTEM_AGENT_NAMES).index_by(&:name)
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
      ::Ai::ApprovalChain.where(account: current_account, status: "active").map do |c|
        { id: c.id, name: c.name, step_count: c.step_count, is_sequential: c.is_sequential }
      end
    end

    def all_policies
      ::Ai::InterventionPolicy.where(account: current_account).includes(:agent, :approval_chain)
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
        bucket = if p.scope == "agent" && p.agent
                   p.agent.name
                 else
                   "Manual Operations"
                 end
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
