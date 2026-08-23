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
      # Shared by the agent-scoped and operator-path upserts.
      # InterventionPolicyService#resolve never lets an agent caller land on a
      # scope-"action_type" row (IMP-cb36021d4094), and every row this module
      # writes agent-less is that scope, so the primary reason to keep this ONE
      # value (a demoted agent falling through to the weaker row) is
      # structurally closed. It stays shared as defense in depth: if the
      # resolution-level audience split ever regresses, two drifted copies
      # would silently hand a demoted agent the weaker policy again.
      # See `upsert_operator_policies!` for the full argument.
      DEFAULT_TRUST_CONDITIONS = { "trust_tier_minimum" => "monitored" }.freeze

      # The action_category namespaces this extension answers for, and the ONLY
      # namespaces `clean_unregistered_policies!` will delete inside
      # (IMP-0a3ff97f6fbb).
      #
      # `system.` and `sdwan.` are the extension's own — every category
      # lib/powernode_system/engine.rb registers falls under one of them.
      #
      # `project.` is CORE's namespace, claimed here because this extension
      # seeds rows into it: system_provisioning_intervention_policies.rb writes
      # the six `project.*` verbs onto Fleet Autonomy. Whoever creates a row has
      # to be able to collect it, or that row is orphaned by construction — the
      # defect this constant exists to close. Claiming it cannot reap a live core
      # row either: `project.*` are `Ai::InterventionPolicy::STATIC_CATEGORIES`,
      # compiled into the class body, so they are registered wherever the class
      # is loaded and the sweep can only fire there if core itself deregistered
      # one — in which case collecting the row is the correct answer anyway.
      #
      # autonomy_policy_ownership_spec.rb pins this against the seed files in
      # both directions: a future seed writing rows in an unclaimed namespace
      # fails that example rather than quietly opening a new orphan class.
      OWNED_CATEGORY_NAMESPACES = %w[system. sdwan. project.].freeze

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
        account = admin_account(account_name: account_name)
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

      # The account every agent seed writes its policy rows to.
      #
      # Extracted from `bootstrap_admin_context!` so a seed that needs the
      # account WITHOUT its user/provider preconditions resolves it the same way
      # (IMP-0a3ff97f6fbb). `system_autonomy_orphan_cleanup.rb` is the caller
      # that matters: a sweep keyed on a different account than the six agent
      # seeds write to would miss the rows it exists to collect and operate on
      # somebody else's. The shape-keyed policy seeds still use a bare
      # `Account.first`, which agrees with this whenever "Powernode Admin"
      # is absent OR is itself first — but agreeing by coincidence is what this
      # removes for the sweep.
      #
      # @return [Account, nil] nil when no account exists at all
      def admin_account(account_name: "Powernode Admin")
        Account.find_by(name: account_name) || Account.first
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
      # A row of THIS shape is operator-only by resolution contract, and the
      # load-bearing part of the shape is `scope: "action_type"`, not the nil
      # ai_agent_id (IMP-cb36021d4094): `agent_matches?` still admits it for any
      # caller, but `InterventionPolicyService#resolve` drops the
      # scope-"action_type" audience when an agent is present — an agent with no
      # matching row falls to the require_approval default rather than catching
      # this one. Before that cut (IMP-bfbf8052e179), any agent WITHOUT its own
      # row for a category (Fleet Autonomy, Concierge, Topology Designer on
      # sdwan.*) inherited these rows' laxer verbs — human intent silently
      # widening agent autonomy.
      #
      # Do NOT re-seed this set at scope "global" to "cover both audiences":
      # that scope is the account-wide floor and DOES bind agent callers, so it
      # would reinstate exactly the widening this shape exists to prevent.
      #
      # The row still carries the same trust_tier_minimum condition as
      # `upsert_policies!` even though the operator path never evaluates it
      # (`conditions_met?` skips the tier check when agent_record is nil), and
      # its priority stays lower than the agent set's. Both are defense in depth
      # for the same regression: if the resolution-level audience split is ever
      # removed, the shared condition keeps an emergency-demoted agent
      # escalating to require_approval instead of landing here, and the ranking
      # keeps an agent's own row winning over this one.
      #
      # The ranking half no longer DEPENDS on that priority gap.
      # `Ai::InterventionPolicy#specificity_key` is lexicographic, so an
      # agent-scoped row out-ranks this one at any priority either carries
      # (IMP-6430e3a8c4a1). Until then the key was an additive score giving an
      # agent-scoped row a mere +5, so 5-vs-10 was doing real work here: an
      # operator raising this set's priority by 6 would have inverted the
      # ranking. Keep the gap anyway — it costs nothing and it states the
      # intent — but the guarantee now rests on the tier, not on the numbers.
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

      # Destroy every policy row in an owned namespace whose action_category is
      # no longer REGISTERED — whatever shape that row has (IMP-0a3ff97f6fbb).
      #
      # WHO OWNS AN OPERATOR-AUTHORED POLICY ROW. Until this helper, nothing
      # did, because collectability was keyed on a row's SHAPE and each sweep
      # enumerated a different one: `clean_stale_policies!` takes
      # (ai_agent_id: agent.id, scope "agent"), `clean_stale_operator_policies!`
      # takes (ai_agent_id: nil, scope "action_type"), and
      # system_manual_operation_policies.rb takes (scope "global", both ids nil)
      # narrowed to `system.task.%`. Two live producers write outside all three:
      # `System::AutonomyActions#update` mints scope "global" with a nil
      # ai_agent_id for any update whose row identity the panel could not
      # recover (useAutonomyConfig.ts `save()` degrades to category + verb), and
      # system_instance_pool_policies.rb seeds that same shape for
      # `system.instance_pool_*` with no sweep at all. A row in that gap whose
      # category is later deregistered is a ghost: the by_domain pivot still
      # renders it (prefix match over rows, not the registry), every save 422s
      # on the unknown category, and no seed re-run clears it.
      #
      # THE RULE: a row is collectable exactly when the write path would refuse
      # to create it. `#update` gates on `category_registered?`, so this gates
      # on the same predicate and nothing else. Registration is the ONE axis, so
      # a sixth row shape cannot open a fifth orphan class — the rule never
      # names a shape. It is also the exact complement of the invariant
      # spec/lib/powernode_system/autonomy_categories_registration_spec.rb
      # already pins (everything seeded is registered): together they give
      # rendered ⇒ registered ⇒ saveable, with no third state left.
      #
      # It also cannot eat legitimate operator tuning. An operator editing a
      # REGISTERED category — including the 33 rows the manual-operations and
      # instance-pool seeds write at the very scope-"global"/nil-agent shape the
      # ghost wears — is never in the relation, because the predicate reads the
      # category and not the row. Deleting by that shape instead was the
      # tempting fix and is strictly worse than the ghost.
      #
      # WHAT THIS DOES NOT REACH, stated so the boundary is not mistaken for
      # coverage: ownership is bounded by NAMESPACE, and `#update` is not.
      # That endpoint gates on `category_registered?` alone, so an operator can
      # mint a row for any registered category anywhere — `dev.merge`,
      # `approval`, another extension's — and `agent_bucket_for` renders every
      # non-agent-scoped row in the modal's "Manual Operations" bucket whatever
      # its namespace. A row minted outside these prefixes is collectable only
      # by whoever owns that namespace. Widening the prefixes is NOT the answer
      # (an extension must not reap core's rows); either the endpoint stops
      # minting outside what it owns, or core sweeps its own. Tracked
      # separately — this helper deliberately does not decide it.
      #
      # ORDER-INDEPENDENT, unlike the keep_keys sweeps: the predicate is the
      # boot registry, not the calling seed's declarations, so this may run
      # before or after any upsert.
      #
      # TWO REFUSALS, because this deletes on the ABSENCE of a registration and
      # absence has two ways to lie. An unbounded `owned_prefixes` would let one
      # extension reap another's rows on the strength of a registry it does not
      # populate. And an empty registry LOOKS exactly like "every category was
      # deregistered", so a namespace holding no registered category at all
      # means the registry is not trustworthy here, not that everything under it
      # is garbage. Both raise: a seed that silently swept nothing reads
      # identically to one that swept correctly, and this is the wrong place to
      # be quiet.
      #
      # THE SECOND REFUSAL IS PER PREFIX, and that is the whole of its value.
      # Asking whether ANY owned prefix has a registered category would make it
      # permanently dead here: `project.*` are `STATIC_CATEGORIES`, set in the
      # model's class body, so that question answers "yes" whenever the class
      # loads — including in the exact state the guard exists to catch. That
      # state is reachable, not theoretical: engine.rb registers all ~137
      # categories in ONE `register_categories!` call and swallows any raise
      # from that block into a `Rails.logger.warn`, so a single bad line there
      # leaves the registry holding core's statics alone. Under a union check
      # this sweep would then answer "every system.* and sdwan.* row is an
      # orphan" and delete the account's entire policy floor, printing a
      # collected-N line that reads like success. Per prefix, `system.` is
      # empty, and the seed fails loudly instead.
      #
      # A magnitude ceiling was considered as a second net and left out: the
      # only reachable partial-registry path is that all-or-nothing call, which
      # per-prefix already catches, and any threshold would also refuse a
      # legitimate bulk deregistration — a hardcoded budget standing between an
      # operator and a correct sweep. The seed states the count and the distinct
      # categories BEFORE destroying instead, so an unexpected magnitude is
      # visible in the seed log rather than inferred from it.
      #
      # @param account [Account]
      # @param owned_prefixes [Array<String>] REQUIRED — namespaces to sweep
      # @param excluded_prefixes [Array<String>] carve-outs inside owned
      # @return [Integer] number of rows destroyed
      def clean_unregistered_policies!(account:, owned_prefixes:, excluded_prefixes: [])
        owned = Array(owned_prefixes).reject(&:blank?)
        if owned.empty?
          raise ArgumentError,
                "clean_unregistered_policies! requires owned_prefixes — an account-wide sweep " \
                "would reap categories this extension does not register"
        end

        registered = ::Ai::InterventionPolicy.registered_categories
        dead = owned.reject { |prefix| registered.any? { |cat| cat.start_with?(prefix) } }
        if dead.any?
          raise ArgumentError,
                "the category registry holds nothing under #{dead.join(', ')} — refusing to treat " \
                "an unpopulated registry as proof that every row there is an orphan"
        end

        stale = ::Ai::InterventionPolicy
          .where(account: account)
          .where.not(action_category: registered)
        stale = restrict_to_prefixes(stale, owned, excluded_prefixes)

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
