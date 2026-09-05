# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Registry mapping skill executors to the agents that should be bound
      # to them. Sole source of truth for agent → skill bindings in the
      # system extension — `system_skill_bindings_seed.rb` walks `discover`
      # at seed time and creates the matching `Ai::AgentSkill` rows.
      #
      # Each executor declares its bindings via the `binds_to` DSL provided
      # by `BaseSkillExecutor`:
      #
      #   class CveResponseExecutor < BaseSkillExecutor
      #     skill_descriptor(...)
      #     binds_to "CVE Responder"
      #     ...
      #   end
      #
      # `binds_to` is a thin wrapper around `SkillBindings.register(self, ...)`.
      module SkillBindings
        @registrations = []

        # Executor-facing LABEL -> canonical SOURCE KEY.
        #
        # The values used to be DISPLAY NAMES and the reconciler looked agents
        # up by name. That made a display name a binding key: renaming an agent
        # in the UI silently orphaned every skill bound to it, and
        # Ai::Agent#generate_slug meant the rename also rewrote the slug, so
        # one edit moved two identifiers that other code addressed the agent
        # by. `source_key` is the only field on a seeded canonical that is set
        # explicitly and derived from nothing (AgentSetupHelpers
        # .find_or_initialize_global_agent), which is what makes it the right
        # key. It is the same key space System::Governance::PolicyDeclarations
        # ::AGENT_IDENTITIES is keyed on and HierarchyReconciler resolves the
        # forest root through.
        #
        # Both spellings map to the same key on purpose. The short tokens are
        # what new executors should use. The display-name spellings are LEGACY
        # LABELS kept working for executors that still write them out; a label
        # going stale is a cosmetic failure, whereas a lookup keyed on a label
        # is a correctness one, and only the lookup moved.
        AGENT_ALIASES = {
          # short tokens
          "concierge"            => "system-concierge",
          "fleet_autonomy"       => "fleet-autonomy",
          "runtime_manager"      => "runtime-manager",
          "cve_responder"        => "cve-responder",
          "sdwan_manager"        => "sdwan-manager",
          "disk_image_manager"   => "disk-image-manager",
          "gitops_reconciler"    => "gitops-reconciler",
          "topology_designer"    => "topology-designer",
          "capacity_manager"     => "capacity-manager",
          "storage_manager"      => "storage-manager",
          "ingress_manager"      => "ingress-manager",
          "supply_chain_manager" => "supply-chain-manager",
          # The Platform Architect is a CORE canonical (seeded by
          # server/db/seeds/ai_engineering_agents_seed.rb), the only one an
          # extension executor binds.
          "platform_architect"   => "platform-architect",

          # legacy display-name labels — same targets, still accepted
          "Fleet Autonomy"            => "fleet-autonomy",
          "Runtime Manager"           => "runtime-manager",
          "CVE Responder"             => "cve-responder",
          "SDWAN Manager"             => "sdwan-manager",
          "Disk Image Manager"        => "disk-image-manager",
          "GitOps Reconciler"         => "gitops-reconciler",
          "System Topology Designer"  => "topology-designer",
          "Capacity Manager"          => "capacity-manager",
          "Storage Manager"           => "storage-manager",
          "Ingress Manager"           => "ingress-manager",
          "Supply Chain Manager"      => "supply-chain-manager",
          "Platform Architect"        => "platform-architect"
          # NOTE: no "System Concierge" entry. That agent was renamed to
          # Infrastructure Generalist, and every executor that bound it by
          # display name now uses the "concierge" token, so no label here can
          # go stale against it.
        }.freeze

        class << self
          # Register an executor's intended agent bindings. Idempotent and
          # reload-safe: dedupes by executor class *name* (not object identity)
          # so dev-mode class reloads don't create phantom duplicate entries.
          def register(executor_class, agents:)
            agent_keys = Array(agents).flatten.map { |a| AGENT_ALIASES.fetch(a.to_s, a.to_s) }
            existing = @registrations.find { |r| r[:executor].name == executor_class.name }
            if existing
              existing[:executor] = executor_class
              existing[:agents]   = (existing[:agents] + agent_keys).uniq
            else
              @registrations << { executor: executor_class, agents: agent_keys.uniq }
            end
            self
          end

          # All currently-registered (executor, agents) pairs. Returns a
          # frozen array to discourage out-of-band mutation.
          def all
            @registrations.map { |r| r.dup.freeze }.freeze
          end

          # Discovery projection: each registration emits one entry per
          # (skill_slug, agent_key) pair so the seed can iterate flatly.
          # `agent_key` is a canonical source_key — see AGENT_ALIASES.
          #
          # Slug derivation mirrors `system_skills_seed.rb`'s convention for
          # `Ai::Skill.slug`: take the executor class name, demodulize,
          # underscore, strip the `_executor` suffix, dasherize, prefix with
          # "system-".
          #
          #   CveResponseExecutor      → "system-cve-response"
          #   SdwanVipFailoverExecutor → "system-sdwan-vip-failover"
          def discover
            @registrations.flat_map do |reg|
              slug = derive_slug(reg[:executor])
              reg[:agents].map do |agent_key|
                {
                  executor:   reg[:executor],
                  skill_slug: slug,
                  agent_key:  agent_key
                }
              end
            end
          end

          # Aggregated view: each unique (skill_slug, executor) once, with
          # the list of agents bound. Useful for callers that need to iterate
          # skills rather than skill-agent pairs.
          def by_skill
            @registrations.map do |reg|
              {
                executor:   reg[:executor],
                skill_slug: derive_slug(reg[:executor]),
                agents:     reg[:agents]
              }
            end
          end

          # Verify that every registered skill_slug has a matching `Ai::Skill`
          # row in the database. Raises with the full list of missing slugs
          # — single noisy failure beats per-row warnings.
          #
          # Called from `system_skill_bindings_seed.rb` before any binding
          # rows are created, so a mismatch fails the seed run cleanly
          # rather than producing partial state.
          def validate!
            missing = by_skill.filter_map do |entry|
              entry[:skill_slug] unless ::Ai::Skill.exists?(slug: entry[:skill_slug])
            end

            return :ok if missing.empty?

            raise <<~MSG.strip
              SkillBindings.validate! failed — #{missing.size} registered skill(s) have no matching Ai::Skill row:
                #{missing.join("\n  ")}

              Run `system_skills_seed.rb` before `system_skill_bindings_seed.rb`, or add the missing skill rows.
            MSG
          end

          # Test / dev helper: remove a single executor's registration by
          # class name. Use this instead of nuking the whole registry —
          # under CI's eager_load, @registrations is populated at boot
          # from every binds_to declaration, and a wholesale clear would
          # orphan every production binding for the rest of the suite
          # (which is exactly what bit crud_factory_spec when a prior
          # spec did `reset!` in its after block).
          def unregister(executor_class_name)
            name = executor_class_name.is_a?(Class) ? executor_class_name.name : executor_class_name.to_s
            @registrations.reject! { |r| r[:executor].name == name }
          end

          private

          def derive_slug(executor_class)
            base = executor_class.name.demodulize.underscore.sub(/_executor\z/, "")
            "system-#{base.dasherize}"
          end
        end
      end
    end
  end
end
