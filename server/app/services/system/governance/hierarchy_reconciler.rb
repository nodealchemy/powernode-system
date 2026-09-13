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
      # NOTE the precedence in #resolve_agent: ROOT_KEY (a source_key) is tried
      # FIRST and this name is only the fallback, which is why renaming the
      # agent to "Infrastructure Generalist" did not move the root of the
      # forest. The name is kept current so the fallback still resolves an
      # install whose canonical predates source_key being set.
      ROOT_IDENTITY = { name: "Infrastructure Generalist", agent_type: "assistant" }.freeze

      # THE ATTACH LIST. Every agent PolicyDeclarations declares an identity
      # for is a child of the Concierge — the six original policy-carrying
      # agents, the System Topology Designer (declared there since
      # HIER-P2DECL, when it took the topology set; before that it was merged
      # in here by hand under the key "system-topology-designer" — HIER-P2F
      # aligned the SEED's source_key to the declared key "topology-designer",
      # so the source_key fallback resolves it too, not just the name+type
      # primary path; the edge is the same edge) and the four operations
      # managers (Capacity / Storage / Ingress / Supply Chain — declared in
      # wave 1, seeded in wave 2 by HIER-P2B/P2C/P2D/P2E). An absent child is
      # a "<key>(agent absent)" line in `skipped` — reported as drift by
      # `drift`, never an error — which is how an identity declared ahead of
      # its seed gets its lineage + delegation rows on the first seed run
      # after that seed lands, with no edit here.
      # Delegation defaults are the P1 ruling for every child: conservative,
      # max_depth 2, no delegate types (a leaf).
      #
      # MINUS the core canonicals (HIER-P3, PolicyDeclarations::CORE_CANONICAL_KEYS):
      # the Platform Architect is declared as an owner so the governance-gap
      # lane gates under it, but core seeds it, core writes its delegation
      # policy (moderate, depth 3 — db/seeds/ai_agent_hierarchy_seed.rb) and
      # the extension seed attaches only its EDGE under System Concierge.
      # Writing the leaf delegation here would flap that policy on every boot.
      CHILD_IDENTITIES = PolicyDeclarations::AGENT_IDENTITIES
                           .except(*PolicyDeclarations::CORE_CANONICAL_KEYS)
                           .freeze

      # The core forest's root, attached under System Concierge. It keeps the
      # delegation policy the CORE seed gives it (none today) — this reconciler
      # only owns the edge, so it is not reported as a missing policy.
      CORE_ROOT_KEY = "core-concierge"
      CORE_ROOT_SLUG = "powernode-assistant"

      # EDGE-ONLY SUBJECTS (IMP-01a06aee). Agents whose EDGE under the root is
      # this reconciler's and whose DELEGATION POLICY is not — the core root
      # above, plus every PolicyDeclarations::CORE_CANONICAL_KEYS canonical
      # (the Platform Architect today).
      #
      # CHILD_IDENTITIES excludes the core canonicals so a leaf policy is not
      # written for them — core seeds those agents and owns their policies, and
      # writing one here would flap it on every boot. That exclusion took the
      # EDGE with the policy: `reconcile!` did not attach it and `drift` came
      # back with missing_edges EMPTY while the edge was absent, so the only
      # writers were db/seeds/system_agent_hierarchy.rb's inline block (and
      # `db:seed` is FIRST-BOOT ONLY) and the governance-gap materialization
      # lane. GovernanceGapSensor re-implemented the check privately because
      # this drift could not answer it — one rule with two implementations, the
      # second of them subject to the sensor's per-tick budget.
      #
      # Both halves matter and they are separable: attach the edge, never the
      # policy. #edge_only_subjects is the one list; reconcile! and drift both
      # walk it, and neither calls write_policy for it.

      ROOT_DELEGATION  = { inheritance_policy: "moderate",     max_depth: 3 }.freeze
      # allowed_delegate_types is filled in by .child_delegation, not here: core
      # E4 made an EMPTY list mean NONE rather than "unrestricted", and an empty
      # literal here is what began refusing sibling delegation.
      # allowed_actions likewise: an empty list means NONE since core
      # IMP-d2873a16567e, so the action a delegation is checked as is named.
      # Spelled here rather than read from Ai::DelegationPolicy::DELEGATABLE_ACTIONS
      # so this class body still loads against a core that predates the
      # constant (extension and core can land out of step); the seed specs
      # assert the two are equal.
      DELEGATED_ACTIONS = %w[execute].freeze
      CHILD_DELEGATION = { inheritance_policy: "conservative", max_depth: 2,
                           allowed_actions: DELEGATED_ACTIONS }.freeze
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
          ROOT_DELEGATION.merge(allowed_delegate_types: system_agent_types, allowed_actions: DELEGATED_ACTIONS)
        end

        # A system domain agent may delegate to its SIBLINGS.
        #
        # This used to pass an empty allowed_delegate_types, which meant
        # "unrestricted" until core E4 (f4ce7fff3) gave an empty list its
        # obvious meaning: NONE. Under the new semantics the same literal
        # refused every hand-off inside the domain — a Fleet Autonomy signal
        # that needs the CVE Responder is the point of having a hierarchy, and
        # it came back "Delegate type 'monitor' not in allowed types".
        #
        # Ruled: siblings are allowed. Enumerated the same way root_delegation
        # enumerates its reach — DERIVED from system_agent_types, so a new
        # system agent of a new type widens both without a second edit and
        # without a literal list to fall out of date.
        #
        # max_depth stays 2. Widening WHO a child may hand to is not widening
        # HOW FAR the chain may run.
        def child_delegation(_agent_key)
          CHILD_DELEGATION.merge(allowed_delegate_types: system_agent_types)
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

        edge_only_subjects.each do |key, agent|
          unless agent
            skipped << "#{key}(agent absent)"
            next
          end

          # No write_policy here, deliberately — see EDGE-ONLY SUBJECTS above.
          writer.attach!(child: agent, parent: root, spawn_reason: SPAWN_REASON,
                         metadata: { "agent_key" => key })
          attached += 1
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
          absent = (CHILD_IDENTITIES.keys + edge_only_subjects.keys).map { |k| "#{k}(root absent)" }
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

        # Edges only: a core canonical's missing delegation policy is never
        # reported here, because this reconciler must never create one — a
        # drift line no reconcile can clear is a signal that never goes out.
        edge_only_subjects.each do |key, agent|
          if agent.nil?
            skipped << "#{key}(agent absent)"
          elsif attached?(agent, root)
            present << "#{ROOT_KEY}/#{key}"
          else
            missing_edges << "#{ROOT_KEY}/#{key}"
          end
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

      # key => agent (or nil when this install has not seeded it). Ordered:
      # the core root, then the declared core canonicals. The canonicals are
      # READ from PolicyDeclarations rather than restated, so one added there
      # gets its edge with no edit here — the same property CHILD_IDENTITIES
      # has. They resolve through resolve_agent (source_key first) because they
      # ARE declared identities; the core root is not, and keeps its slug
      # lookup.
      def edge_only_subjects
        subjects = { CORE_ROOT_KEY => resolve_core_root }
        PolicyDeclarations::CORE_CANONICAL_KEYS.each do |key|
          identity = PolicyDeclarations::AGENT_IDENTITIES[key]
          subjects[key] = identity && resolve_agent(key, identity)
        end
        subjects
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
