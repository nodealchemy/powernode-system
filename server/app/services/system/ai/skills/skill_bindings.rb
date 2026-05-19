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

        # The skill catalog uses canonical agent names; aliases let executor
        # authors refer to them via short slugs without typos.
        AGENT_ALIASES = {
          "concierge"          => "System Concierge",
          "fleet_autonomy"     => "Fleet Autonomy",
          "runtime_manager"    => "Runtime Manager",
          "cve_responder"      => "CVE Responder",
          "sdwan_manager"      => "SDWAN Manager",
          "disk_image_manager" => "Disk Image Manager",
          "topology_designer"  => "System Topology Designer"
        }.freeze

        class << self
          # Register an executor's intended agent bindings. Idempotent and
          # reload-safe: dedupes by executor class *name* (not object identity)
          # so dev-mode class reloads don't create phantom duplicate entries.
          def register(executor_class, agents:)
            agent_names = Array(agents).flatten.map { |a| AGENT_ALIASES.fetch(a.to_s, a.to_s) }
            existing = @registrations.find { |r| r[:executor].name == executor_class.name }
            if existing
              existing[:executor] = executor_class
              existing[:agents]   = (existing[:agents] + agent_names).uniq
            else
              @registrations << { executor: executor_class, agents: agent_names.uniq }
            end
            self
          end

          # All currently-registered (executor, agents) pairs. Returns a
          # frozen array to discourage out-of-band mutation.
          def all
            @registrations.map { |r| r.dup.freeze }.freeze
          end

          # Discovery projection: each registration emits one entry per
          # (skill_slug, agent_name) pair so the seed can iterate flatly.
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
              reg[:agents].map do |agent_name|
                {
                  executor:   reg[:executor],
                  skill_slug: slug,
                  agent_name: agent_name
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

          # Test / dev helper: clear the registry. Production seed code must
          # never call this — the registry is populated at class-load time
          # and clearing it would orphan all existing bindings until the
          # executor files reload.
          def reset!
            @registrations.clear
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
