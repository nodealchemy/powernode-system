# frozen_string_literal: true

module System
  module Governance
    # Declares and reconciles the system extension's AGENT HIERARCHY (HIER-P1):
    # System Concierge is the root, and every domain agent is its child — one
    # active Ai::AgentLineage edge each (spawn_reason "seed") plus one
    # Ai::DelegationPolicy row per agent, all written through
    # Ai::Agents::HierarchyWriter, the same seam the runtime creation paths use.
    #
    # ONE FOREST (operator ruling 2026-09-03: "System Concierge coordinates
    # both hierarchies"). The CORE concierge — Powernode Assistant, the root
    # of the core canonical forest that db/seeds/ai_agent_hierarchy_seed.rb
    # builds — is attached here as a child of System Concierge, so an install
    # carrying this extension has a single rooted forest instead of two
    # disjoint ones. Core purity forbids the core seed reaching for a system
    # agent, and this seed runs after it, so this is the only place that edge
    # can be written. It is SKIPPED (never invented) when the core concierge
    # is absent.
    #
    # WHY THE DELEGATION COLUMNS ARE WRITTEN IN THE CONSUMER'S VOCABULARY.
    # `allowed_delegate_types` is compared against `Ai::Agent#agent_type` by
    # every reader — Ai::DelegationPolicy#allows_delegate_type?, called from
    # Ai::Autonomy::DelegationAuthorityService#validate_delegation and
    # Ai::Routing::AgentRouterService#route (which filters its candidate pool
    # with it) — and `delegatable_actions` is compared against a task's
    # `action_type` (Ai::Tools::AgentManagementTool#spawn_task passes
    # "execute"). Skill slugs (System::Ai::Skills::SkillBindings) and
    # PolicyDeclarations category names are NEITHER vocabulary: writing them
    # into these columns would not scope delegation, it would REFUSE every
    # delegation from every agent that got a row and empty every router pool,
    # while leaving the agents with no bindings unrestricted — the authority
    # inverted rather than tightened. So:
    #
    #   * the Concierge's "may delegate to any system agent" is written as the
    #     agent_typeS the declared system agents actually carry, and
    #   * a domain agent is a LEAF here (it has no declared children), so its
    #     delegate types stay empty and `max_depth` 2 is the operative brake.
    #
    # The declaration-derived category/executor lists are still the truth about
    # what an agent may DO — they are just not what these two columns mean;
    # binding them needs a translation from the autonomy category vocabulary to
    # the delegation action_type vocabulary that does not exist yet.
    #
    # Operator ruling 2026-09-03: domain agents `conservative`, max_depth 2;
    # the Concierge `moderate`, max_depth 3, may delegate to any system agent.
    #
    # Same shape as PolicyReconciler: `reconcile!` writes, `drift` is read-only
    # and reports missing edges / missing policies / skipped agents, and a
    # SKIPPED agent (not seeded) is drift, not a neutral outcome — the
    # governance rake can print `drifted?`.
    #
    # NOTE on the canonical rule: agents are resolved among GLOBAL rows only.
    # The hierarchy is a property of the seeded canonicals; an account's clone
    # of a system agent gets its own lineage at clone time
    # (AgentManagementTool#create_agent), not a seat in this forest.
    class HierarchyReconciler
      ROOT_KEY = "system-concierge"
      ROOT_IDENTITY = { name: "System Concierge", agent_type: "assistant" }.freeze

      # PolicyDeclarations keys the six policy-carrying agents; the Topology
      # Designer carries skills but no policy set, so it is declared here.
      CHILD_IDENTITIES = PolicyDeclarations::AGENT_IDENTITIES.merge(
        "system-topology-designer" => { name: "System Topology Designer", agent_type: "assistant" }
      ).freeze

      # The core forest's root, attached under System Concierge. It keeps the
      # delegation policy the CORE seed gives it (none today) — this reconciler
      # only owns the edge, so it is not reported as a missing policy.
      CORE_ROOT_KEY = "core-concierge"
      CORE_ROOT_SLUG = "powernode-assistant"

      ROOT_DELEGATION  = { inheritance_policy: "moderate",     max_depth: 3 }.freeze
      CHILD_DELEGATION = { inheritance_policy: "conservative", max_depth: 2,
                           allowed_delegate_types: [], allowed_actions: [] }.freeze
      SPAWN_REASON = "seed"

      Result = Struct.new(:attached, :policies_written, :skipped, keyword_init: true) do
        def changed? = attached.positive? || policies_written.positive?
      end

      DriftReport = Struct.new(:missing_edges, :missing_policies, :present, :skipped, keyword_init: true) do
        def drifted? = missing_edges.any? || missing_policies.any? || skipped.any?
      end

      class << self
        # The agent types the declared system agents carry — the vocabulary
        # `allows_delegate_type?` checks, and therefore how "any system agent"
        # is expressed. Derived from the identities so a new system agent of a
        # new type widens the Concierge's reach without a second edit.
        def system_agent_types
          (CHILD_IDENTITIES.values + [ ROOT_IDENTITY ]).map { |identity| identity[:agent_type] }.uniq.sort
        end

        def root_delegation
          ROOT_DELEGATION.merge(allowed_delegate_types: system_agent_types, allowed_actions: [])
        end

        def child_delegation(_agent_key)
          CHILD_DELEGATION
        end
      end

      def initialize(account:, logger: Rails.logger)
        @account = account
        @logger = logger
      end

      # Attach every present child under the root and upsert every policy.
      # Idempotent: a second call on an unchanged database changes nothing
      # (the seam reuses the edge and saves a policy only when it changed).
      def reconcile!
        root = resolve_root
        return Result.new(attached: 0, policies_written: 0, skipped: [ "#{ROOT_KEY}(agent absent)" ]) unless root

        writer = ::Ai::Agents::HierarchyWriter.new(account: @account)
        attached = 0
        policies = 0
        skipped = []

        policies += 1 if write_policy(writer, root, self.class.root_delegation)

        CHILD_IDENTITIES.each do |key, identity|
          agent = resolve_agent(key, identity)
          unless agent
            skipped << "#{key}(agent absent)"
            next
          end

          writer.attach!(child: agent, parent: root, spawn_reason: SPAWN_REASON, metadata: { "agent_key" => key })
          attached += 1
          policies += 1 if write_policy(writer, agent, self.class.child_delegation(key))
        end

        core_root = resolve_core_root
        if core_root
          writer.attach!(child: core_root, parent: root, spawn_reason: SPAWN_REASON,
                         metadata: { "agent_key" => CORE_ROOT_KEY })
          attached += 1
        else
          skipped << "#{CORE_ROOT_KEY}(agent absent)"
        end

        if attached.positive? || policies.positive?
          @logger.info("[HierarchyReconciler] attached #{attached} agent(s) under #{root.name}, " \
                       "#{policies} delegation policy write(s), skipped #{skipped.size}")
        end

        Result.new(attached: attached, policies_written: policies, skipped: skipped)
      end

      # Read-only: which declared edges/policies the database lacks.
      def drift
        root = resolve_root
        unless root
          absent = CHILD_IDENTITIES.keys.map { |k| "#{k}(root absent)" } + [ "#{CORE_ROOT_KEY}(root absent)" ]
          return DriftReport.new(missing_edges: [], missing_policies: [], present: [],
                                 skipped: [ "#{ROOT_KEY}(agent absent)" ] + absent)
        end

        missing_edges = []
        missing_policies = []
        present = []
        skipped = []

        missing_policies << ROOT_KEY unless policy_present?(root)

        CHILD_IDENTITIES.each do |key, identity|
          agent = resolve_agent(key, identity)
          unless agent
            skipped << "#{key}(agent absent)"
            next
          end

          if attached?(agent, root)
            present << "#{ROOT_KEY}/#{key}"
          else
            missing_edges << "#{ROOT_KEY}/#{key}"
          end
          missing_policies << key unless policy_present?(agent)
        end

        core_root = resolve_core_root
        if core_root.nil?
          skipped << "#{CORE_ROOT_KEY}(agent absent)"
        elsif attached?(core_root, root)
          present << "#{ROOT_KEY}/#{CORE_ROOT_KEY}"
        else
          missing_edges << "#{ROOT_KEY}/#{CORE_ROOT_KEY}"
        end

        DriftReport.new(missing_edges: missing_edges, missing_policies: missing_policies,
                        present: present.sort, skipped: skipped)
      end

      private

      # True when the seam actually saved (it skips an unchanged row, whose
      # saved_changes are then empty).
      def write_policy(writer, agent, attrs)
        writer.ensure_delegation_policy!(agent: agent, **attrs).saved_changes.any?
      end

      def attached?(agent, root)
        ::Ai::AgentLineage.for_child(agent.id).active.exists?(parent_agent_id: root.id)
      end

      def policy_present?(agent)
        ::Ai::DelegationPolicy.resolve_for(agent_id: agent.id, account_id: @account.id).present?
      end

      def resolve_root
        resolve_agent(ROOT_KEY, ROOT_IDENTITY)
      end

      def resolve_core_root
        ::Ai::Agent.global.find_by(slug: CORE_ROOT_SLUG)
      end

      # Global canonicals only — source_key first (the seed-managed identity),
      # then the (name, type) the seeds create them with.
      def resolve_agent(key, identity)
        ::Ai::Agent.global.find_by(source_key: key) ||
          ::Ai::Agent.global.find_by(name: identity[:name], agent_type: identity[:agent_type])
      end
    end
  end
end
