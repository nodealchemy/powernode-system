# frozen_string_literal: true

module System
  module Fleet
    # Value object representing a fleet sensor signal. Replaces the raw
    # hash that sensors used to return; provides:
    #
    #   - severity_weight (for risk scoring + cross-signal prioritization)
    #   - to_h (back-compat with code that still expects a hash)
    #   - matches?(other) for fingerprint-based de-duplication
    #
    # Reference: Golden Eclipse Block G — improvements pass.
    class Signal
      VALID_SEVERITIES = %i[low medium high critical].freeze
      SEVERITY_WEIGHTS = { low: 1, medium: 4, high: 16, critical: 64 }.freeze

      attr_reader :kind, :severity, :payload, :fingerprint

      def initialize(kind:, severity:, payload:, fingerprint:)
        raise ArgumentError, "kind required" if kind.blank?
        raise ArgumentError, "fingerprint required" if fingerprint.blank?
        sev = severity.to_sym
        unless VALID_SEVERITIES.include?(sev)
          raise ArgumentError, "severity must be one of #{VALID_SEVERITIES.inspect}"
        end

        @kind = kind.to_s
        @severity = sev
        @payload = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
        @fingerprint = fingerprint.to_s
      end

      def severity_weight
        SEVERITY_WEIGHTS[severity]
      end

      def matches?(other)
        return false unless other.is_a?(Signal)
        kind == other.kind && fingerprint == other.fingerprint
      end

      # Hash form for back-compat with code that consumed the raw sensor
      # hash. New code should prefer accessing attributes directly.
      def to_h
        {
          kind: kind,
          severity: severity,
          payload: payload,
          fingerprint: fingerprint
        }
      end

      # Hash-form alias used by ActiveSupport's deep stringify path.
      alias_method :as_json, :to_h

      def [](key)
        case key.to_sym
        when :kind then kind
        when :severity then severity
        when :payload then payload
        when :fingerprint then fingerprint
        end
      end

      def dig(*keys)
        return nil if keys.empty?
        first = self[keys.first]
        return first if keys.size == 1
        first.respond_to?(:dig) ? first.dig(*keys[1..]) : nil
      end

      # Build a Signal from a hash (sensor compatibility shim).
      def self.from_hash(h)
        return h if h.is_a?(Signal)
        new(
          kind: h[:kind] || h["kind"],
          severity: h[:severity] || h["severity"],
          payload: h[:payload] || h["payload"] || {},
          fingerprint: h[:fingerprint] || h["fingerprint"]
        )
      end
    end
  end
end
