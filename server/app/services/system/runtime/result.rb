# frozen_string_literal: true

module System
  module Runtime
    # Uniform return value for every runtime service. Jobs read `success?`
    # to decide whether to transition the operation to complete or failed,
    # `error` to populate the operation's error_message, and `events` to
    # append to the operation's audit trail.
    Result = Struct.new(:success, :data, :error, :events, keyword_init: true) do
      def self.ok(data: {}, events: [])
        new(success: true, data: data, error: nil, events: events)
      end

      def self.err(error:, data: {}, events: [])
        new(success: false, data: data, error: error, events: events)
      end

      def success?
        success == true
      end

      def failure?
        !success?
      end

      def to_h
        super.compact
      end
    end
  end
end
