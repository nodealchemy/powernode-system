# frozen_string_literal: true

module System
  module Status
    # B4: plugs the fleet into the four core remediation seams, from the
    # engine's to_prepare (pull: core never names the fleet).
    #
    #   lanes          Platform::Remediation::Registry, one lane per bound kind
    #   signal source  Platform::Status::SignalSources
    #   runbooks       Platform::Runbook::Registry (config/runbooks.yml)
    #   mirror         Platform::Status::Emitters, by name
    #
    # IDEMPOTENT ACROSS RELOADS. to_prepare re-runs on every code reload, and
    # two of the four registries dedupe by OBJECT, so re-registering a fresh
    # object would stack a second source beside the stale one — and the stale
    # one, registered first, would keep answering. Each step therefore removes
    # whatever it registered before, found by class NAME (which survives a
    # reload when the class object does not), and a lane registered for a kind
    # that is no longer bound is withdrawn.
    #
    # Each step runs even if another fails. Failures are logged, kept in
    # last_result, and raised together so the engine's rescue logs one line.
    module RemediationWiring
      STEPS = %i[register_lanes! register_signal_source! register_runbook_source! register_mirror!].freeze

      class << self
        attr_reader :last_result

        def register_all!
          errors = {}
          STEPS.each do |step|
            send(step)
          rescue StandardError => e
            Rails.logger.error("[System::Status::RemediationWiring] #{step} failed: #{e.class}: #{e.message}")
            errors[step] = "#{e.class}: #{e.message}"
          end
          @last_result = { registered_at: Time.current, errors: errors }
          raise "remediation wiring failed: #{errors.keys.join(', ')}" if errors.any?

          @last_result
        end

        private

        def register_lanes!
          registry = ::Platform::Remediation::Registry
          bound = ::System::Fleet::DecisionEngine::SIGNAL_BINDINGS.keys
          registry.lanes.each do |kind, lane|
            registry.unregister(kind) if ours?(lane, FleetRemediationLane) && !bound.include?(kind)
          end

          lane = FleetRemediationLane.new
          bound.each { |kind| registry.register_lane(kind, lane) }
        end

        def register_signal_source!
          sources = ::Platform::Status::SignalSources
          sources.sources.each { |source| sources.unregister(source) if ours?(source, FleetSignalSource) }
          sources.register(FleetSignalSource.new)
        end

        def register_runbook_source!
          registry = ::Platform::Runbook::Registry
          registry.registered_sources.each do |source|
            registry.unregister_source(source) if ours?(source, ::System::Runbooks::Catalog)
          end
          registry.register_source(::System::Runbooks::Catalog.load)
        end

        # By name, so a reload REPLACES the emitter. The block resolves the
        # mirror class at call time, so it always runs the reloaded code.
        def register_mirror!
          ::Platform::Status::Emitters.register(FleetFeedMirror::NAME) do |transition:, events:|
            ::System::Status::FleetFeedMirror.call(transition: transition, events: events)
          end
        end

        def ours?(object, klass)
          object.class.name == klass.name
        end
      end
    end
  end
end
