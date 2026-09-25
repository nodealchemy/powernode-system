# frozen_string_literal: true

module System
  # Compares each service row's stored `capabilities` with its module's
  # stored manifest (NodeModule#manifest_yaml) on key PRESENCE (IMP-caef5c00d63f).
  #
  # Before the presence-preserving import (IMP-074fcd68284f) a row held []
  # both for "never declared" (inherit the module ceiling) and for a declared
  # [] (grant nothing). The per-service resolver on the agent zeroes a
  # declared [] only for a module carrying the service_capabilities_presence
  # marker, which the node-api serializer emits only when every row of the
  # module is flagged capabilities_presence_recorded. This check is read-only:
  # it is what an operator runs before promoting an agent that carries the
  # resolver (`rake system:service_capabilities:drift`).
  module ServiceCapabilitiesProvenance
    module_function

    # [state, value] for one service entry of a stored manifest:
    #   :absent      key absent or null  -> value nil (inherit the ceiling)
    #   :empty       declared []         -> value []
    #   :list        declared non-empty  -> value the list
    #   :invalid     declared, not an array of strings
    #   :missing     the manifest parsed but has no service with this name
    #   :unparseable blank, not YAML, or not a mapping
    def classify(manifest_yaml, service_name)
      manifest = parse(manifest_yaml)
      return [ :unparseable, nil ] if manifest.nil?

      entry = Array(manifest["services"]).find { |s| s.is_a?(Hash) && s["name"] == service_name }
      return [ :missing, nil ] if entry.nil?

      caps = entry["capabilities"]
      return [ :absent, nil ] if caps.nil?
      return [ :invalid, caps ] unless caps.is_a?(Array) && caps.all?(String)

      caps.empty? ? [ :empty, [] ] : [ :list, caps ]
    end

    def parse(manifest_yaml)
      return nil if manifest_yaml.blank?

      parsed = YAML.safe_load(manifest_yaml, permitted_classes: [ Symbol, Date, Time ], aliases: true)
      parsed.is_a?(Hash) ? parsed : nil
    rescue Psych::Exception
      nil
    end

    # {
    #   checked:              number of service rows compared,
    #   drift:                rows whose stored capabilities disagree with the
    #                         stored manifest (presence or value),
    #   legacy_empty_modules: modules left unmarked because a row's manifest
    #                         declares [] and no real import has flagged it
    #                         (republish them from the swept manifest),
    #   unvouched_modules:    modules with a row the manifest cannot vouch for
    #                         (unparseable manifest, service missing, invalid value),
    #   marked_module_ids:    modules whose every row is flagged (the agent
    #                         receives the marker)
    # }
    def drift_report(scope = ::System::NodeModule.all)
      report = { checked: 0, drift: [], legacy_empty_modules: [], unvouched_modules: [], marked_module_ids: [] }

      scope.includes(:module_services).find_each do |mod|
        rows = mod.module_services.to_a
        next if rows.empty?

        legacy_empty = []
        unvouched = []
        rows.each do |svc|
          report[:checked] += 1
          state, value = classify(mod.manifest_yaml, svc.name)

          case state
          when :unparseable, :missing, :invalid
            unvouched << { service: svc.name, reason: state }
          else
            if svc.capabilities != value
              report[:drift] << {
                module_id: mod.id, module: mod.name, service: svc.name,
                manifest: state, stored: svc.capabilities
              }
            end
            legacy_empty << svc.name if state == :empty && !svc.capabilities_presence_recorded
          end
        end

        report[:legacy_empty_modules] << { module_id: mod.id, module: mod.name, services: legacy_empty } if legacy_empty.any?
        report[:unvouched_modules] << { module_id: mod.id, module: mod.name, services: unvouched } if unvouched.any?
        report[:marked_module_ids] << mod.id if rows.all?(&:capabilities_presence_recorded)
      end

      report
    end
  end
end
