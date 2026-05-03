# frozen_string_literal: true

module System
  module Fleet
    # Persists a FleetEvent row + broadcasts it on the SystemFleetChannel.
    # The persistence is the durable record (compliance + replay); the
    # broadcast is the live-UI surface. Both happen in one call so callers
    # don't need to think about ordering.
    #
    # Best-effort: persistence failures log + return nil; broadcast
    # failures log + are ignored. The autonomy/decision flow is never
    # blocked by an observability hiccup.
    #
    # Reference: Golden Eclipse plan M7 observability layer + Track F-12 boot replay.
    class EventBroadcaster
      class << self
        # Emit an event. Returns the persisted FleetEvent or nil on failure.
        #
        # @param account [Account]
        # @param kind [String] event kind (e.g. "system.module_drift", "decision.proceeded")
        # @param severity [Symbol|String] :low|:medium|:high|:critical
        # @param payload [Hash] free-form event payload
        # @param source [String] emitter identifier ("decision_engine", "instance_status_sensor", ...)
        # @param correlation_id [String, nil] groups events from the same logical operation
        # @param **refs Resource ids — node_id:, node_instance_id:, node_module_id:,
        #               node_module_version_id:, certificate_id:, cve_id:
        def emit!(account:, kind:, severity: :low, payload: {}, source: nil,
                  correlation_id: nil, **refs)
          return nil unless account
          severity_str = severity.to_s

          # Resource refs precedence: explicit kwargs > payload-derived.
          # When a caller passes neither, the column stays nil.
          payload_refs = resource_refs_from_payload(payload)
          merged_refs = payload_refs.merge(
            refs.slice(:node_id, :node_instance_id, :node_module_id,
                       :node_module_version_id, :certificate_id, :cve_id).compact
          )

          event = ::System::FleetEvent.create!(
            account: account,
            kind: kind,
            severity: severity_str,
            payload: payload.respond_to?(:deep_stringify_keys) ? payload.deep_stringify_keys : payload,
            source: source,
            correlation_id: correlation_id,
            **merged_refs
          )

          broadcast!(event)
          # Surface to AS::Notifications so System::Metrics::Subscriber can
          # aggregate fleet event counts alongside dispatch metrics. Cheap +
          # in-process; no external dependency. (Phase 10.5.)
          ActiveSupport::Notifications.instrument(
            "system.fleet.event",
            account_id: account.id, kind: kind, severity: severity_str, source: source
          )
          event
        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.warn("[FleetEventBroadcaster] persist failed: #{e.message}")
          nil
        rescue StandardError => e
          Rails.logger.warn("[FleetEventBroadcaster] unexpected: #{e.class}: #{e.message}")
          nil
        end

        # Emit a Signal as both an observation event and (later) a decision event.
        # The two-event split is intentional: dashboards filter by phase.
        def emit_signal!(account:, signal:, source: nil, correlation_id: nil)
          emit!(
            account: account,
            kind: signal.kind,
            severity: signal.severity,
            payload: { fingerprint: signal.fingerprint }.merge(signal.payload || {}),
            source: source || "sensor",
            correlation_id: correlation_id,
            **resource_refs_from_payload(signal.payload)
          )
        end

        # Emit a decision event. Decision class is :proceeded|:pending|:blocked|:deduped|:skipped.
        def emit_decision!(account:, decision:, signal:, correlation_id: nil)
          decision_kind = "decision.#{decision[:decision]}"
          emit!(
            account: account,
            kind: decision_kind,
            severity: signal.severity,
            payload: {
              source_signal_kind: signal.kind,
              source_signal_fingerprint: signal.fingerprint,
              action_category: decision[:action_category],
              gate: decision[:gate]
            },
            source: "decision_engine",
            correlation_id: correlation_id || signal.fingerprint,
            **resource_refs_from_payload(signal.payload)
          )
        end

        private

        def broadcast!(event)
          # ActionCable broadcast is best-effort. SystemFleetChannel
          # subscribes per-account; broadcasts to "system_fleet:#{account_id}".
          if defined?(::ActionCable) && ::ActionCable.respond_to?(:server)
            ::ActionCable.server.broadcast(
              "system_fleet:#{event.account_id}",
              event.as_broadcast
            )
          end
        rescue StandardError => e
          Rails.logger.debug("[FleetEventBroadcaster] broadcast skipped: #{e.message}")
        end

        # Map signal payload into FleetEvent resource ref columns. The
        # column allow-list is enforced in the caller via slice; this just
        # extracts the canonical names from the payload.
        def resource_refs_from_payload(payload)
          return {} unless payload.is_a?(Hash)

          {
            node_id: payload["node_id"] || payload[:node_id],
            node_instance_id: payload["instance_id"] || payload[:instance_id],
            node_module_id: payload["module_id"] || payload[:module_id],
            node_module_version_id: payload["module_version_id"] || payload[:module_version_id],
            certificate_id: payload["certificate_id"] || payload[:certificate_id],
            cve_id: payload["cve_id"] || payload[:cve_id]
          }.compact
        end
      end
    end
  end
end
