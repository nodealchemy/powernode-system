# frozen_string_literal: true

# Shared helpers for system-extension agent seed files.
#
# The 7 system agent seeds (Fleet Autonomy, System Concierge, Runtime Manager,
# CVE Responder, SDWAN Manager, Disk Image Manager, Topology Designer) all
# repeat the same four operations:
#
#   1. Resolve admin account + admin user + a provider
#   2. Bootstrap an `Ai::AgentTrustScore` row for the agent
#   3. Upsert a set of `Ai::InterventionPolicy` rows
#   4. Delete stale `Ai::InterventionPolicy` rows the seed no longer declares
#
# This module centralizes those operations so every agent seed gets identical
# behavior — including the previously-missing stale-policy cleanup that
# Fleet Autonomy + Runtime Manager had but the other 5 did not.
#
# Usage from a seed file:
#
#   require_relative "concerns/agent_setup_helpers"
#
#   ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
#     preferred_provider_types: ["anthropic", "openai"]
#   )
#   agent = ctx[:account].ai_agents.find_or_initialize_by(...)
#   ...
#   System::Seeds::AgentSetupHelpers.ensure_trust_score!(
#     account: ctx[:account], agent: agent,
#     tier: "trusted", overall: 0.80,
#     dimensions: { safety: 0.92, quality: 0.80, ... }
#   )
#
# All helpers are strict — they raise on missing prerequisites rather than
# logging a warning and skipping. Clean implementations only: a seed that
# can't satisfy its preconditions should fail loudly, not produce partial state.
module System
  module Seeds
    module AgentSetupHelpers
      module_function

      # Resolve the admin account, admin user, and a provider for agent
      # seed files. Raises if any prerequisite is missing.
      #
      # @param preferred_provider_types [Array<String>] ordered list of
      #   provider_type slugs to try (e.g. ["anthropic", "openai"]). Falls
      #   back to the first available provider only after exhausting the
      #   preference list.
      # @param account_name [String] preferred account name (defaults to
      #   "Powernode Admin"). Falls back to Account.first if not found.
      # @return [Hash] { account:, creator:, provider: }
      def bootstrap_admin_context!(preferred_provider_types: [], account_name: "Powernode Admin")
        account = Account.find_by(name: account_name) || Account.first
        raise "agent_setup_helpers: no Account exists — seed accounts first" unless account

        creator = account.users.find_by(email: "admin@powernode.org") || account.users.first
        raise "agent_setup_helpers: account #{account.id} has no users — seed users first" unless creator

        provider = preferred_provider_types
          .map(&:to_s)
          .filter_map { |pt| ::Ai::Provider.where(provider_type: pt).order(priority_order: :asc).first }
          .first
        provider ||= ::Ai::Provider.where(is_active: true).order(priority_order: :asc).first
        provider ||= ::Ai::Provider.first
        raise "agent_setup_helpers: no Ai::Provider exists — seed ai providers first " \
              "(preferred=#{preferred_provider_types.inspect})" unless provider

        { account: account, creator: creator, provider: provider }
      end

      # Idempotent upsert for an agent's trust score. Differentiates the
      # initial baseline per agent risk profile.
      #
      # @param account [Account] owning account
      # @param agent [Ai::Agent] the agent
      # @param tier [String] one of "supervised", "monitored", "trusted", "autonomous"
      # @param overall [Float] aggregate trust score [0.0, 1.0]
      # @param dimensions [Hash{Symbol=>Float}] per-dimension scores —
      #   keys: :reliability, :cost_efficiency, :safety, :quality, :speed
      def ensure_trust_score!(account:, agent:, tier:, overall:, dimensions: {})
        defaults = { reliability: 0.70, cost_efficiency: 0.70, safety: 0.85, quality: 0.70, speed: 0.70 }
        merged = defaults.merge(dimensions)

        score = ::Ai::AgentTrustScore.find_or_initialize_by(agent_id: agent.id)
        score.assign_attributes(
          account:         account,
          tier:            tier,
          overall_score:   overall,
          reliability:     merged[:reliability],
          cost_efficiency: merged[:cost_efficiency],
          safety:          merged[:safety],
          quality:         merged[:quality],
          speed:           merged[:speed]
        )
        score.save! if score.new_record? || score.changed?
        score
      end

      # Idempotent upsert for a set of agent-scoped intervention policies.
      #
      # @param account [Account]
      # @param agent [Ai::Agent]
      # @param definitions [Hash{String=>String}] map of action_category → policy verb
      #   (e.g. "system.cert_rotate" → "auto_approve")
      # @param conditions [Hash] policy-level conditions JSON (e.g.
      #   { "trust_tier_minimum" => "monitored" })
      # @param channels [Array<String>] preferred_channels (default ["notification"])
      # @param priority [Integer] policy priority (default 10)
      # @return [Integer] number of rows created or updated
      def upsert_policies!(account:, agent:, definitions:, conditions: { "trust_tier_minimum" => "monitored" },
                            channels: %w[notification], priority: 10)
        return 0 unless agent

        changed = 0
        definitions.each do |action_category, policy_verb|
          policy = ::Ai::InterventionPolicy.find_or_initialize_by(
            account: account,
            action_category: action_category,
            scope: "agent",
            ai_agent_id: agent.id
          )
          policy.assign_attributes(
            policy:             policy_verb,
            priority:           priority,
            is_active:          true,
            conditions:         conditions,
            preferred_channels: channels
          )
          if policy.new_record? || policy.changed?
            policy.save!
            changed += 1
          end
        end
        changed
      end

      # Destroy agent-scoped intervention policies whose action_category is
      # not in the current seed's definitions. Idempotent — destroy_all
      # returns 0 rows after the first run.
      #
      # @param account [Account]
      # @param agent [Ai::Agent]
      # @param keep_keys [Array<String>] action_category values to retain
      # @return [Integer] number of rows destroyed
      def clean_stale_policies!(account:, agent:, keep_keys:)
        return 0 unless agent

        stale = ::Ai::InterventionPolicy
          .where(account: account, ai_agent_id: agent.id, scope: "agent")
          .where.not(action_category: keep_keys)
        count = stale.count
        stale.destroy_all if count.positive?
        count
      end
    end
  end
end
