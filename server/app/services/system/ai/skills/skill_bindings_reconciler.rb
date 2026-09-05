# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Materialises the SkillBindings registry (every executor's `binds_to`)
      # as Ai::AgentSkill rows — the ONE writer of agent → skill bindings in
      # the system extension (HIER-P2G item 2).
      #
      # Two callers, one body:
      #   * db/seeds/system_skill_bindings_seed.rb — first boot, `strict: true`:
      #     a registered skill with no GLOBAL Ai::Skill row aborts before any
      #     binding is written, as the seed always has. The gate is the
      #     RESOLVER's own scope, not SkillBindings.validate! alone —
      #     validate! asks `Ai::Skill.exists?(slug:)` UNSCOPED, so a slug that
      #     survives only as a pre-P2G account row (the catalog seed failed, or
      #     an account override reuses the slug) passes it and would then be
      #     silently skipped here. #build_plan raises on `missing_skills`.
      #   * the boot-time governance reconcile path — governance-reconcile.rb
      #     (rails-start.sh, every boot) and `rails system:governance:reconcile`
      #     — `strict: false`: `db:seed` is FIRST-BOOT ONLY, so an executor
      #     re-bound after an install's first boot never reached that install
      #     (HIER-P2B: no boot-time reconciler re-materialised Ai::AgentSkill).
      #     At boot a missing skill row is reported and skipped, never raised.
      #
      # GLOBAL to GLOBAL. Ai::AgentSkill carries no account column (schema:
      # ai_agent_id, ai_skill_id, priority, is_active), the agents are global
      # canonicals (Ai::Agent.global by name) and, since HIER-P2G, so are the
      # skills — resolved as Ai::Skill.global by slug, never an account's
      # override that reuses the slug. A binding is therefore identical on
      # every install, which is what lets the canonical Claude Code export
      # commit it.
      #
      # DRIFT. A row on a registry-named agent whose (agent, skill) pair the
      # registry does not declare is destroyed — the registry is the source of
      # truth, and a stale binding would hand an agent a skill it no longer
      # owns. Scoped to registry-named agents so an account's own agents are
      # never touched.
      class SkillBindingsReconciler
        # The provisioning conversation's ENTRY skill has no executor (it is a
        # pure discovery + delegation front door, see
        # system_provisioning_skills_seed.rb) and so never registers through
        # `binds_to`; it is bound to the System Concierge here, and thereby
        # both upserted AND spared by the drift correction.
        # skill_slug => canonical SOURCE KEY (not a display name — see
        # SkillBindings::AGENT_ALIASES for why the key moved).
        ENTRY_SKILL_BINDINGS = { "system-provision-infrastructure" => "system-concierge" }.freeze

        EXECUTOR_GLOB = "../extensions/system/server/app/services/system/ai/skills/**/*_executor.rb"

        Result = Struct.new(:registered, :upserted, :removed, :unknown_agents, :missing_skills, :bound_by_agent,
                            :registry_empty, keyword_init: true) do
          def changed?
            upserted.positive? || removed.positive?
          end
        end

        # `missing_pairs` is the STRUCTURED form of `missing` (agent id + skill
        # id + names, one hash per pair) — what GovernanceGapSensor hands to
        # GapMaterializer so a missing binding can be applied under the
        # dev.skill_refine gate rather than only reported (HIER-P3).
        Drift = Struct.new(:missing, :missing_pairs, :stale, :unknown_agents, :missing_skills, :registry_empty,
                           keyword_init: true) do
          def drifted?
            missing.any? || stale.any?
          end
        end

        # @param strict [Boolean] raise (SkillBindings.validate!) when a
        #   registered skill has no Ai::Skill row; lenient callers skip and
        #   report instead
        def initialize(strict: false)
          @strict = strict
        end

        def reconcile!
          plan = build_plan
          upserted = 0
          plan[:desired].each_with_index do |(agent_id, skill_id), i|
            binding = ::Ai::AgentSkill.find_or_initialize_by(ai_agent_id: agent_id, ai_skill_id: skill_id)
            binding.assign_attributes(priority: 100 + i, is_active: true)
            next unless binding.new_record? || binding.changed?

            binding.save!
            upserted += 1
          end

          stale_ids = stale_bindings(plan).map(&:id)
          ::Ai::AgentSkill.where(id: stale_ids).destroy_all if stale_ids.any?

          Result.new(
            registered: plan[:registrations].size,
            upserted: upserted,
            removed: stale_ids.size,
            unknown_agents: plan[:unknown_agents],
            missing_skills: plan[:missing_skills],
            bound_by_agent: bound_by_agent(plan),
            registry_empty: plan[:registry_empty]
          )
        end

        # Read-only: what #reconcile! would create and destroy.
        def drift
          plan = build_plan
          existing = ::Ai::AgentSkill.where(ai_agent_id: plan[:registry_agent_ids]).pluck(:ai_agent_id, :ai_skill_id).to_set
          missing = plan[:desired].reject { |pair| existing.include?(pair) }
          Drift.new(
            missing: missing.map { |pair| describe_pair(plan, pair) },
            missing_pairs: missing.map do |agent_id, skill_id|
              { "agent_id" => agent_id, "agent_name" => plan[:agents_by_id][agent_id]&.name,
                "skill_id" => skill_id, "skill_slug" => plan[:skills_by_id][skill_id]&.slug }
            end,
            stale: stale_bindings(plan).map { |row| describe_pair(plan, [ row.ai_agent_id, row.ai_skill_id ]) },
            unknown_agents: plan[:unknown_agents],
            missing_skills: plan[:missing_skills],
            registry_empty: plan[:registry_empty]
          )
        end

        private

        # Desired (agent_id, skill_id) pairs from the registry plus the entry
        # bindings, with the agents and skills resolved GLOBAL, one query each.
        def build_plan
          load_executors!
          SkillBindings.validate! if @strict

          registrations = SkillBindings.discover
          # Resolved by SOURCE KEY. This lookup used to key on the agent's
          # DISPLAY NAME, which made renaming an agent in the UI silently
          # orphan every skill bound to it — the bindings did not error, they
          # simply stopped matching and the agent lost its whole skill set.
          agent_keys = (registrations.map { |e| e[:agent_key] } + ENTRY_SKILL_BINDINGS.values).uniq
          slugs = (registrations.map { |e| e[:skill_slug] } + ENTRY_SKILL_BINDINGS.keys).uniq
          agents = ::Ai::Agent.global.where(source_key: agent_keys).index_by(&:source_key)
          skills = ::Ai::Skill.global.where(slug: slugs).index_by(&:slug)

          desired = []
          unknown_agents = Hash.new(0)
          missing_skills = []
          pairs = registrations.map { |e| [ e[:skill_slug], e[:agent_key] ] } + ENTRY_SKILL_BINDINGS.to_a
          pairs.each do |slug, agent_key|
            agent = agents[agent_key]
            unless agent
              unknown_agents[agent_key] += 1
              next
            end
            skill = skills[slug]
            unless skill
              missing_skills << slug
              next
            end
            desired << [ agent.id, skill.id ]
          end

          missing_skills = missing_skills.uniq.sort
          raise missing_skills_message(missing_skills) if @strict && missing_skills.any?

          {
            registrations: registrations,
            registry_empty: registrations.empty?,
            desired: desired.uniq,
            # Drift is corrected on the agents the REGISTRY names (plus the
            # entry-skill owner), never on agents outside this extension.
            registry_agent_ids: agents.values_at(*agent_keys).compact.map(&:id),
            agents_by_id: agents.values.index_by(&:id),
            skills_by_id: skills.values.index_by(&:id),
            unknown_agents: unknown_agents.keys.sort,
            missing_skills: missing_skills
          }
        end

        def missing_skills_message(slugs)
          <<~MSG.strip
            SkillBindingsReconciler (strict): #{slugs.size} registered skill(s) have no GLOBAL Ai::Skill row:
              #{slugs.join("\n  ")}

            Run the catalog seeds (system_skills_seed.rb, system_provisioning_skills_seed.rb,
            system_dr_skills_seed.rb) before system_skill_bindings_seed.rb. A row that exists
            only account-scoped does NOT satisfy a binding: the canonical export and the router
            read Ai::Skill.global (HIER-P2G).
          MSG
        end

        # Drift deletion needs a FLOOR: an empty registry is always a load
        # failure (#load_executors! globs a path that may not resolve on a
        # deployed layout), never a legitimate "unbind everything" instruction.
        # Without it the boot path would destroy every binding on System
        # Concierge — ENTRY_SKILL_BINDINGS alone keeps it in scope — on every
        # boot, behind a non-fatal rescue.
        #
        # NEVER on a CORE canonical (HIER-P3). GovernanceGapProposeExecutor binds
        # the Platform Architect, which made it a registry-named agent — and
        # the first boot after that destroyed its four CORE bindings (Agent
        # Autonomy, AI Agent Architect, Design Agent Team From Intent, Skill
        # Management, written by the parent tree's
        # db/seeds/platform_skill_assignments_seed.rb) because this registry
        # does not declare them. The registry is the source of truth for the
        # EXTENSION's agents only; on a core canonical it upserts its own pairs
        # and leaves every other binding where core put it.
        def stale_bindings(plan)
          return [] if plan[:registry_empty] || plan[:registry_agent_ids].empty?

          owned_ids = plan[:registry_agent_ids] - core_canonical_agent_ids(plan)
          return [] if owned_ids.empty?

          desired = plan[:desired].to_set
          ::Ai::AgentSkill.where(ai_agent_id: owned_ids)
                          .reject { |row| desired.include?([ row.ai_agent_id, row.ai_skill_id ]) }
        end

        # The registry-named agents that are CORE canonicals — declared as such
        # by PolicyDeclarations::CORE_CANONICAL_KEYS, resolved by the identity
        # name the registry binds them under.
        def core_canonical_agent_ids(plan)
          declarations = ::System::Governance::PolicyDeclarations
          names = declarations::CORE_CANONICAL_KEYS.map { |key| declarations::AGENT_IDENTITIES.fetch(key)[:name] }
          plan[:agents_by_id].values.select { |agent| names.include?(agent.name) }.map(&:id)
        end

        def bound_by_agent(plan)
          return {} if plan[:registry_agent_ids].empty?

          counts = ::Ai::AgentSkill.where(ai_agent_id: plan[:registry_agent_ids]).group(:ai_agent_id).count
          plan[:agents_by_id].values.sort_by(&:name).to_h { |agent| [ agent.name, counts.fetch(agent.id, 0) ] }
        end

        def describe_pair(plan, (agent_id, skill_id))
          agent = plan[:agents_by_id][agent_id]&.name || agent_id
          skill = plan[:skills_by_id][skill_id]&.slug || ::Ai::Skill.find_by(id: skill_id)&.slug || skill_id
          "#{agent} → #{skill}"
        end

        # Force the executor files to load so each `binds_to` populates the
        # registry: at runtime they autoload on reference, and at seed time or
        # boot nothing has touched them yet.
        def load_executors!
          Dir.glob(Rails.root.join(EXECUTOR_GLOB)).sort.each { |f| require_dependency f }
        end
      end
    end
  end
end
