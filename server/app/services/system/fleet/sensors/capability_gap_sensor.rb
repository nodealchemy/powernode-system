# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Surfaces `capability:<tag>` requirements that no module on the
      # account can satisfy.
      #
      # WHY THIS EXISTS. ManifestImportService already computes exactly this
      # set — resolve_capability_requirement returns
      # `{capability:, constraint:, status: "unresolved"}` for every
      # requirement it cannot satisfy. But that hash is returned up through
      # ModulePublicationProcessor into a CI callback's HTTP response body
      # and then evaporates. The trigger existed only as a transient value,
      # never as state, so nothing downstream could ever act on it.
      #
      # WHY A SENSOR, NOT A HOOK IN THE IMPORTER. Filing from the import path
      # would double-file on every re-import and would carry none of the
      # fleet-autonomy machinery. Coming through the sense pass, a gap
      # inherits signal-fingerprint dedup and RemediationValidator closure
      # scoring — and, most importantly, it SELF-HEALS: when a provider
      # module publishes, the capability resolves, the sensor stops emitting,
      # and the absence closes the loop with no cleanup step. That property
      # is also why this recomputes from live state each tick rather than
      # persisting unresolved edges as rows: a stored row would need its own
      # invalidation, and system_module_dependencies cannot represent an
      # unresolved edge anyway (dependency_id is NOT NULL — it is a FK to the
      # providing module, which by definition does not exist yet).
      #
      # Deliberately advisory. Closing a capability gap means authoring a new
      # module, which must pass the human R1/R2/R3 reuse gate in
      # docs/runbooks/module-authoring.md — automation that made module
      # creation cheap would make module SPRAWL cheap. This reports; it does
      # not remediate.
      class CapabilityGapSensor < BaseSensor
        def sense
          ::System::NodeModule
            .where(account_id: account.id)
            .where.not(manifest_yaml: [ nil, "" ])
            .find_each
            .flat_map { |mod| gaps_for(mod) }
        end

        private

        def gaps_for(mod)
          required_capabilities(mod).filter_map do |tag, constraint|
            next if ::System::CapabilityResolver.resolve(
              account_id: account.id,
              tag: tag,
              constraint: constraint,
              exclude_module_id: mod.id
            )

            signal(
              kind: "system.capability_gap",
              severity: :medium,
              payload: {
                "capability" => tag,
                "constraint" => constraint,
                "module_id" => mod.id,
                "module_name" => mod.name
              },
              # Stable across ticks so a standing gap dedups, but distinct
              # per requirement so a module missing two capabilities reports
              # both. The constraint is part of the key: tightening a
              # constraint on an already-provided tag is a NEW gap.
              fingerprint: "capability_gap:#{mod.id}:#{tag}#{constraint.present? ? "@#{constraint}" : ''}"
            )
          end
        end

        # manifest_yaml is the only persisted record of what a module
        # REQUIRES. (The provides side is denormalized onto the capabilities
        # column at import; the requires side is not.)
        def required_capabilities(mod)
          requires = Array(parsed_manifest(mod).dig("dependencies", "requires"))
          requires.filter_map { |raw| ::System::CapabilityResolver.parse_requirement_string(raw) }
        end

        # A sensor runs against the whole fleet every tick, so one module with
        # a malformed manifest must not take the pass down with it: a sensor
        # that raises drops ALL of its signals, and RemediationValidator reads
        # that absence as "the problem went away" for every fingerprint it
        # owns.
        def parsed_manifest(mod)
          parsed = ::YAML.safe_load(mod.manifest_yaml, aliases: true)
          parsed.is_a?(::Hash) ? parsed : {}
        rescue ::StandardError => e
          ::Rails.logger.warn("[CapabilityGapSensor] unparseable manifest_yaml on module #{mod.id}: #{e.class}")
          {}
        end
      end
    end
  end
end
