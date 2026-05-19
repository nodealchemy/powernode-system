# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Registry pattern (per audit plan P3.3) replacing the hardcoded
      # slug-list bindings in agent seeds. Each executor declares its
      # agent bindings via:
      #
      #   System::Ai::Skills::SkillBindings.register(
      #     self, agents: ["Fleet Autonomy", "CVE Responder"]
      #   )
      #
      # at the bottom of its file. At seed time, `system_skill_bindings_seed.rb`
      # walks the registry and binds each (agent, skill) pair via
      # `Ai::AgentSkill.find_or_initialize_by`.
      #
      # Why a module-level registry instead of a base class?
      # - Executors don't currently inherit from a common base; adding one
      #   would require touching 40 class declarations.
      # - A registry is opt-in: executors can migrate incrementally, and
      #   non-migrated executors keep working via the existing hardcoded
      #   blocks (dual-mode for one release per audit plan).
      # - The registry survives class reloads (Rails dev autoload) because
      #   re-registering with the same class is a no-op (deduplicated).
      module SkillBindings
        # In-memory registry. Each entry:
        #   { executor: <Class>, agents: <Array<String>> }
        @registrations = []

        # The skill catalog ships well-known agent names; aliases let
        # executor authors refer to them via short slugs without typos.
        AGENT_ALIASES = {
          "concierge"           => "System Concierge",
          "fleet_autonomy"      => "Fleet Autonomy",
          "runtime_manager"     => "Runtime Manager",
          "cve_responder"       => "CVE Responder",
          "sdwan_manager"       => "SDWAN Manager",
          "disk_image_manager"  => "Disk Image Manager",
          "topology_designer"   => "System Topology Designer"
        }.freeze

        class << self
          # Register an executor's intended agent bindings. Safe to call
          # multiple times (deduplicates on executor class identity).
          def register(executor_class, agents:)
            agent_names = Array(agents).map { |a| AGENT_ALIASES.fetch(a.to_s, a.to_s) }
            existing = @registrations.find { |r| r[:executor] == executor_class }
            if existing
              existing[:agents] = (existing[:agents] + agent_names).uniq
            else
              @registrations << { executor: executor_class, agents: agent_names }
            end
            self
          end

          # All currently-registered (executor, agents) pairs. Returns a
          # frozen array to discourage callers from mutating registry
          # state out-of-band.
          def all
            @registrations.map { |r| r.dup.freeze }.freeze
          end

          # Discovery output suitable for the seed file: each entry has
          # the canonical skill_slug (derived from the executor class
          # name) plus the agent names to bind to.
          #
          # The slug derivation mirrors what system_skills_seed.rb uses
          # for `Ai::Skill.slug`: take the executor class name minus the
          # `_executor` suffix, demodulized + dasherized + prefixed with
          # "system-". Examples:
          #   CveResponseExecutor       → "system-cve-response"
          #   FleetReconcileExecutor    → "system-fleet-reconcile"
          def discover
            @registrations.map do |reg|
              slug_base = reg[:executor].name.demodulize.underscore.sub(/_executor$/, "")
              { skill_slug: "system-#{slug_base.dasherize}",
                agents:     reg[:agents],
                executor:   reg[:executor] }
            end
          end

          # Test / dev helper: clear the registry. Production seed code
          # MUST NOT call this — the registry is populated by class-load
          # order, and clearing it requires re-loading the executor files.
          def reset!
            @registrations.clear
          end
        end
      end
    end
  end
end
