# frozen_string_literal: true

# Shared helpers for system-extension agent seed files.
#
# Every system agent seed (Fleet Autonomy, System Concierge, Runtime Manager,
# CVE Responder, SDWAN Manager, Disk Image Manager, Topology Designer, GitOps
# Reconciler and the four operations managers) repeats the same operations:
#
#   1. Resolve admin account + admin user + a provider
#   2. Find-or-initialize the GLOBAL canonical agent (never adopt a stray)
#   3. Bootstrap an `Ai::AgentTrustScore` row for the agent
#
# What is deliberately NOT here any more (proposal §5 ruling 7,
# IMP-10e4f6c3bcd2): the intervention-policy upserts and their stale-row
# sweeps (`upsert_policies!`, `upsert_operator_policies!`,
# `clean_stale_policies!`, `clean_stale_operator_policies!`).
# System::Governance::PolicyReconciler is the SINGLE WRITER of declared policy
# rows — it creates absence only, against the account's acting principal, on
# every boot — and a seed writes identity, prompt, chain, trust, tool access
# and skills only. spec/db/seeds/policy_single_writer_spec pins that no seed
# writes a row. The one sweep that remains, `clean_unregistered_policies!`,
# DELETES rows for DEREGISTERED categories and writes nothing.
#
# Usage from a seed file:
#
#   require_relative "concerns/agent_setup_helpers"
#
#   ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
#     preferred_provider_types: ["anthropic", "openai"]
#   )
#   agent = System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent(...)
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
      # The action_category namespaces this extension answers for, and the ONLY
      # namespaces `clean_unregistered_policies!` will delete inside
      # (IMP-0a3ff97f6fbb).
      #
      # `system.` and `sdwan.` are the extension's own — every category
      # lib/powernode_system/engine.rb registers falls under one of them.
      #
      # `project.` is CORE's namespace, claimed here because this extension
      # writes rows into it: PolicyReconciler writes the six `project.*` verbs
      # of CAPACITY_MANAGER_POLICIES onto the Capacity Manager (onto Fleet
      # Autonomy before HIER-P2B). Whoever creates a row has
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

      # Raised when a seed's canonical agent collides with an ACCOUNT-scoped
      # row of the same name and type. Names the row so the operator can
      # decide (rename the account agent, or delete it) — the seed never does.
      class CanonicalAgentConflict < StandardError; end

      # Find-or-initialize a GLOBAL (account_id nil) fundamental system agent.
      #
      # Fundamental core/system agents are platform-provided DEFAULTS shared
      # across accounts (account_id nil, seed-managed by source_key); an account
      # can override one with its own copy via Ai::Agent#clone_to_account, and
      # resolution prefers the account's row (Ai::Agent.resolve_for).
      #
      # CANONICAL RULE (HIER-P1, operator ruling 2026-09-03 §5): a seed NEVER
      # adopts a stray account-scoped agent. This helper used to convert an
      # account row of the same name in place (account_id → nil) as a
      # pre-globalization migration — which also silently turned an operator's
      # own clone into the canonical, taking its prompt, trust score and
      # bindings with it. Now: no global row + an account row of the same
      # (name, agent_type) ⇒ CanonicalAgentConflict naming that row. Once the
      # global row exists, account rows of the same name are the expected
      # override shape and are left alone. The caller assigns the rest of the
      # attributes and saves.
      #
      # NOTE: a global agent has no account of its own — its operational config
      # (trust score, approval chain) is still seeded per-account (the admin
      # account here), and its intervention-policy rows are written per-account
      # by PolicyReconciler against the account's acting principal (HIER-P2I),
      # since that is where the autonomy tick gates actions. The DEFINITION
      # (name, prompt, type, model requirements, skill bindings) is global; the
      # POLICY is per-account.
      def find_or_initialize_global_agent(name:, agent_type:, source_key:)
        agent = ::Ai::Agent.find_by(account_id: nil, name: name, agent_type: agent_type)

        unless agent
          stray = ::Ai::Agent.where(name: name, agent_type: agent_type).where.not(account_id: nil).first
          if stray
            raise CanonicalAgentConflict,
                  "refusing to seed canonical #{source_key.inspect}: an ACCOUNT-scoped agent " \
                  "#{name.inspect} (#{agent_type}) already exists — id=#{stray.id} " \
                  "account_id=#{stray.account_id}. Seeds never adopt an account agent as the " \
                  "canonical; rename or remove that row, then re-run the seed."
          end

          agent = ::Ai::Agent.new(name: name, agent_type: agent_type)
        end

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

      # Destroy every policy row in an owned namespace whose action_category is
      # no longer REGISTERED — whatever shape that row has (IMP-0a3ff97f6fbb).
      #
      # WHO OWNS AN OPERATOR-AUTHORED POLICY ROW. Until this helper, nothing
      # did, because collectability was keyed on a row's SHAPE and each sweep
      # enumerated a different one: the since-retired `clean_stale_policies!`
      # took (ai_agent_id: agent.id, scope "agent"), the since-retired
      # `clean_stale_operator_policies!` took (ai_agent_id: nil, scope
      # "action_type"), and the since-retired inline sweep in
      # system_manual_operation_policies.rb took (scope "global", both ids nil)
      # narrowed to `system.task.%` (IMP-28cccf7cee28). Two producers wrote
      # outside all three: `System::AutonomyActions#update` mints scope "global"
      # with a nil ai_agent_id for any update whose row identity the panel could
      # not recover (useAutonomyConfig.ts `save()` degrades to category + verb),
      # and the since-deleted system_instance_pool_policies.rb seeded that same
      # shape for `system.instance_pool_*` with no sweep at all (PolicyReconciler
      # writes that operator set at the same shape today). A row in that gap
      # whose category is later deregistered is a ghost: the by_domain pivot
      # still renders it (prefix match over rows, not the registry), every save
      # 422s on the unknown category, and no seed re-run clears it.
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
      # REGISTERED category — including the 26 rows the manual-operations and
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
      # minus any carve-outs.
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
