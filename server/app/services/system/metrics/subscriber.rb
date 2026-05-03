# frozen_string_literal: true

module System
  module Metrics
    # Boot-time AS::Notifications subscriber. Listens for the system
    # extension's namespaced events and forwards them into Aggregator
    # as counter increments.
    #
    # Subscribe! is idempotent — Rails reloader can call it repeatedly
    # in dev without registering N redundant subscriptions.
    #
    # Reference: comprehensive stabilization sweep Phase 10.5.
    class Subscriber
      # Namespaces we currently observe. Each entry is a regex matching
      # AS::Notifications event names. Add new namespaces here when new
      # `instrument` call sites are introduced.
      WATCHED_PATTERNS = [
        /\Asystem\.dispatch\./,
        /\Asystem\.fleet\.event\z/,
        /\Asystem\.cloud_sync\./
      ].freeze

      class << self
        # Wires up subscriptions; safe to call multiple times.
        def subscribe!
          unsubscribe! # cleans up prior handles before re-subscribing
          @handles = WATCHED_PATTERNS.map do |pattern|
            ActiveSupport::Notifications.subscribe(pattern) do |name, _started, _finished, _id, payload|
              handle_event(name, payload)
            end
          end
          true
        end

        def unsubscribe!
          Array(@handles).each { |h| ActiveSupport::Notifications.unsubscribe(h) }
          @handles = []
        end

        def subscribed?
          Array(@handles).any?
        end

        private

        def handle_event(name, payload)
          payload = {} unless payload.is_a?(Hash)
          account_id = payload[:account_id] || payload["account_id"]
          Aggregator.record(metric_name: name, account_id: account_id)
        rescue StandardError => e
          Rails.logger.warn("[Metrics::Subscriber] event handler failed: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
