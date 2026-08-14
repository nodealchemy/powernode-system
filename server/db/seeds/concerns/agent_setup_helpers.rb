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
      # Shared by the agent-scoped and operator-path upserts. Since
      # IMP-bfbf8052e179, InterventionPolicyService#resolve never lets an agent
      # caller land on an agent-less row at all, so the primary reason to keep
      # this ONE value (a demoted agent falling through to the weaker row) is
      # structurally closed. It stays shared as defense in depth: if the
      # resolution-level audience split ever regresses, two drifted copies
      # would silently hand a demoted agent the weaker policy again.
      # See `upsert_operator_policies!` for the full argument.
      DEFAULT_TRUST_CONDITIONS = { "trust_tier_minimum" => "monitored" }.freeze

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

      # Find-or-initialize a GLOBAL (account_id nil) fundamental system agent.
      #
      # Fundamental core/system agents are platform-provided DEFAULTS shared
      # across accounts (account_id nil, seed-managed by source_key); an account
      # can override one with its own copy via Ai::Agent#clone_to_account, and
      # resolution prefers the account's row (Ai::Agent.resolve_for).
      #
      # Converts a pre-globalization ACCOUNT-scoped row of the same name in
      # place (account_id → nil) rather than creating a duplicate — the id stays
      # stable, so the agent's trust score, intervention policies, and skill
      # bindings (all keyed by ai_agent_id) keep pointing at it. The caller
      # assigns the rest of the attributes and saves.
      #
      # NOTE: a global agent has no account of its own — its operational config
      # (trust score, intervention policies, approval chain) is still seeded
      # per-account (the admin account here), since that is where the autonomy
      # tick gates actions. The DEFINITION (name, prompt, type, model
      # requirements, skill bindings) is global; the POLICY is per-account.
      def find_or_initialize_global_agent(name:, agent_type:, source_key:)
        agent = ::Ai::Agent.find_by(account_id: nil, name: name, agent_type: agent_type) ||
                ::Ai::Agent.where(name: name, agent_type: agent_type).where.not(account_id: nil).first ||
                ::Ai::Agent.new(name: name, agent_type: agent_type)
        agent.account_id = nil
        agent.source_key = source_key
        agent.is_system  = true
        agent
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
      def upsert_policies!(account:, agent:, definitions:, conditions: DEFAULT_TRUST_CONDITIONS,
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

      # Idempotent upsert for OPERATOR-path (agent-less) intervention policies.
      #
      # `Ai::GatedActions#gate!` passes no `agent:`, so an operator HTTP request
      # resolves with `agent = nil`, and `Ai::InterventionPolicy#agent_matches?`
      # is `return true if ai_agent_id.nil?; agent_record && ...` — an
      # agent-SCOPED row can never match an agent-less caller. Without a row of
      # this shape every gated operator request falls through
      # `Ai::InterventionPolicyService` to its require_approval default, no
      # matter what the agent-scoped seed recorded for the same verb.
      #
      # Seeded with `scope: "action_type"` and a nil ai_agent_id, so this set and
      # the agent-scoped set are disjoint by construction and each seed's stale
      # cleanup can only reach its own rows.
      #
      # An agent-less row IS operator-only by resolution contract
      # (IMP-bfbf8052e179): `agent_matches?` still admits it for any caller,
      # but `InterventionPolicyService#resolve` considers ONLY agent-scoped
      # rows when an agent is present — an agent with no matching scoped row
      # falls to the require_approval default rather than catching this row.
      # Before that cut, any agent WITHOUT its own row for a category (Fleet
      # Autonomy, Concierge, Topology Designer on sdwan.*) inherited these
      # rows' laxer verbs — human intent silently widening agent autonomy.
      #
      # The row still carries the same trust_tier_minimum condition as
      # `upsert_policies!` even though the operator path never evaluates it
      # (`conditions_met?` skips the tier check when agent_record is nil), and
      # its priority stays lower than the agent set's (`specificity_score`
      # already gives an agent-scoped row +5). Both are defense in depth for
      # the same regression: if the resolution-level audience split is ever
      # removed, the shared condition keeps an emergency-demoted agent
      # escalating to require_approval instead of landing here, and the
      # ranking keeps an agent's own row winning over this one.
      #
      # WARNING before adding a condition key here: the two paths do not see the
      # same keys, and "trust_tier_minimum" is not the only asymmetric one.
      # "max_daily_notifications" is guarded on `user`, not `agent`
      # (InterventionPolicyService#notification_limit_reached?), so it is the
      # MIRROR of this case — near-inert for agent dispatch, live on the operator
      # path, which always carries a requested_by. Since IMP-73dff8186c1e it no
      # longer DENIES: exhausting the budget degrades the verb only as far as
      # require_approval, a 202 park. Until that fix it rewrote resolution to
      # "silent", which Ai::AutonomyGate folds into its "block" branch, so
      # setting it here would have turned "stop emailing me about this" into a
      # hard 422 refusal of every operator write in the category for the rest of
      # the day.
      #
      # It still does not do what its name promises ON THIS PATH, so read the
      # rest before setting it. The suppression half of that fix reaches
      # Ai::AgentOutreachService only; parking emits an approval notification of
      # its own — one per approver, and the default chain's ["*"] resolves to
      # every active user. Setting this key on an operator row therefore does
      # not reduce notification volume in the category, it INCREASES it, while
      # the healthy under-cap path emits none. Nothing sets it today; still
      # check the guard's operand — the asymmetry above is unchanged — before
      # adding any key.
      #
      # "quiet_hours" fails the OTHER way, and belongs beside max_daily so a
      # human tuning conditions sees both directions: conditions_met? returns
      # false while the current hour is inside the window, so the row stops
      # matching and resolution falls to the require_approval default — 202,
      # MORE approval friction, never max_daily's hard 422 denial.
      #
      # @param account [Account]
      # @param definitions [Hash{String=>String}] action_category → policy verb
      # @return [Integer] number of rows created or updated
      def upsert_operator_policies!(account:, definitions:,
                                    conditions: DEFAULT_TRUST_CONDITIONS,
                                    channels: %w[notification], priority: 5)
        changed = 0
        definitions.each do |action_category, policy_verb|
          policy = ::Ai::InterventionPolicy.find_or_initialize_by(
            account: account,
            action_category: action_category,
            scope: "action_type",
            ai_agent_id: nil
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

      # Destroy operator-path (agent-less) policies whose action_category is no
      # longer declared. The mirror of `clean_stale_policies!` for the set
      # `upsert_operator_policies!` owns; `owned_prefixes` is what stops one
      # extension's operator seed from reaping another's.
      #
      # @return [Integer] number of rows destroyed
      def clean_stale_operator_policies!(account:, keep_keys:, owned_prefixes: nil,
                                         excluded_prefixes: [])
        stale = ::Ai::InterventionPolicy
          .where(account: account, ai_agent_id: nil, scope: "action_type")
          .where.not(action_category: keep_keys)
        stale = restrict_to_prefixes(stale, owned_prefixes, excluded_prefixes)

        count = stale.count
        stale.destroy_all if count.positive?
        count
      end

      # Destroy agent-scoped intervention policies whose action_category is
      # not in the current seed's definitions. Idempotent — destroy_all
      # returns 0 rows after the first run.
      #
      # F3-10: an agent may be SHARED between seed files (Fleet Autonomy
      # also carries project.* and system.instance_pool_* policies from
      # sibling seeds). Pass owned_prefixes/excluded_prefixes so a seed
      # only cleans the namespace it owns — otherwise a targeted re-run
      # destroys the sibling seeds' policies.
      #
      # @param account [Account]
      # @param agent [Ai::Agent]
      # @param keep_keys [Array<String>] action_category values to retain
      # @param owned_prefixes [Array<String>, nil] restrict cleanup to
      #   categories starting with one of these prefixes (nil = whole agent)
      # @param excluded_prefixes [Array<String>] never destroy categories
      #   starting with one of these prefixes (carve-outs inside owned)
      # @return [Integer] number of rows destroyed
      def clean_stale_policies!(account:, agent:, keep_keys:, owned_prefixes: nil, excluded_prefixes: [])
        return 0 unless agent

        stale = ::Ai::InterventionPolicy
          .where(account: account, ai_agent_id: agent.id, scope: "agent")
          .where.not(action_category: keep_keys)
        stale = restrict_to_prefixes(stale, owned_prefixes, excluded_prefixes)

        count = stale.count
        stale.destroy_all if count.positive?
        count
      end

      # Narrow a stale-policy relation to an owned action_category namespace,
      # minus any carve-outs. Shared by the agent-scoped and operator-path
      # cleanups so both answer namespace ownership the same way.
      def restrict_to_prefixes(relation, owned_prefixes, excluded_prefixes)
        if owned_prefixes.present?
          owned = Array(owned_prefixes)
          relation = relation.where(
            owned.map { "action_category LIKE ?" }.join(" OR "),
            *owned.map { |p| "#{::Ai::InterventionPolicy.sanitize_sql_like(p)}%" }
          )
        end

        Array(excluded_prefixes).each do |prefix|
          relation = relation.where.not(
            "action_category LIKE ?", "#{::Ai::InterventionPolicy.sanitize_sql_like(prefix)}%"
          )
        end

        relation
      end
    end
  end
end
