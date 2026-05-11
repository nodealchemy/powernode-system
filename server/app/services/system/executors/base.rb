# frozen_string_literal: true

module System
  module Executors
    # Convenience base for executor classes — concrete subclasses override
    # `perform` (and optionally `summarize`/`impact`) instead of the bare
    # `execute`/`preview` contract. Keeps the dispatcher signature identical
    # while providing helpers (lookup helpers, error translation, etc.) that
    # most concrete executors share.
    #
    # The contract Ai::AutonomyGate expects:
    #
    #   ExecutorClass.execute(params, deferred_operation:) → { success:, data: }
    #   ExecutorClass.preview(params)                       → { summary:, impact: }
    #
    # Subclasses normally only override `perform` and `summarize`.
    class Base
      class << self
        def execute(params, deferred_operation:)
          new(params, deferred_operation: deferred_operation).call
        end

        def preview(params)
          new(params, deferred_operation: nil).preview_payload
        end
      end

      attr_reader :params, :deferred_operation

      def initialize(params, deferred_operation:)
        @params = (params || {}).with_indifferent_access
        @deferred_operation = deferred_operation
      end

      def call
        result = perform
        { success: true, data: result }
      rescue StandardError => e
        Rails.logger.error("[#{self.class.name}] failed: #{e.class}: #{e.message}")
        raise
      end

      def preview_payload
        {
          summary: summarize,
          impact: impact
        }
      end

      protected

      # Subclasses override these
      def perform
        raise NotImplementedError, "#{self.class.name} must implement #perform"
      end

      def summarize
        self.class.name.demodulize.underscore.humanize
      end

      def impact
        nil
      end

      def account
        deferred_operation&.account
      end

      def initiator
        deferred_operation&.requested_by || deferred_operation&.ai_agent
      end
    end
  end
end
