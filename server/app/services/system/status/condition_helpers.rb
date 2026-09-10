# frozen_string_literal: true

module System
  module Status
    # Shared condition-building for this extension's contributors (campaign
    # 01a08c9b increment B2).
    #
    # DELIBERATELY NOT IN contributors/. That directory is a registry: the
    # registrar globs it and registers whatever declares its own KIND. A helper
    # there is skipped correctly since B1's review fix, but the directory should
    # still mean one thing.
    #
    # THE RULE THIS EXISTS TO ENFORCE, in one place rather than three: a status
    # value nobody mapped is `unknown`/`UnknownStatus`, NEVER `ok`. Every model
    # here has a plain string status column with no database-level enum, so a
    # value added to a STATUSES constant without a matching branch would
    # otherwise fall through whatever the last `else` happened to be — and an
    # unmapped state reading as healthy is the exact defect the composite probe
    # was written to end.
    module ConditionHelpers
      CONDITION = ::Platform::Status::Condition
      UNKNOWN_STATUS_REASON = "UnknownStatus"

      # One condition built from a table keyed by status value.
      #
      # @param mapping [Hash] status value => {status:, reason:, severity:, message:}
      # @param value [String] the record's current status
      def enum_condition(type:, mapping:, value:, evidence: {}, observed_at: nil, now: Time.current)
        key = value.to_s
        spec = mapping[key]

        return unknown_status_condition(type, key, mapping, evidence, observed_at, now) if spec.nil?

        CONDITION.build(
          type: type,
          status: spec.fetch(:status),
          reason: spec.fetch(:reason),
          message: spec[:message],
          severity: spec[:severity],
          evidence: evidence.merge("status" => key),
          observed_at: observed_at,
          now: now
        )
      end

      # An unmapped value is a measurement we cannot interpret, so it is
      # `unknown` and it names what it saw and what it knows. It is not `ok`,
      # and it is not `degraded` either: nothing has been observed to be wrong,
      # only unread.
      def unknown_status_condition(type, value, mapping, evidence, observed_at, now)
        CONDITION.build(
          type: type,
          status: CONDITION::UNKNOWN,
          reason: UNKNOWN_STATUS_REASON,
          message: "status #{value.inspect} is not one this contributor maps; " \
                   "known values: #{mapping.keys.sort.join(', ')}",
          evidence: evidence.merge("status" => value, "known_statuses" => mapping.keys.sort),
          observed_at: observed_at,
          now: now
        )
      end

      # `Held` is operator intent and the ONLY way a component reaches the
      # `held` verdict. Nil cause means "no intent recorded", which is the
      # ordinary case and reads as ok, not as a failure.
      def held_condition(cause:, message: nil, evidence: {}, now: Time.current)
        CONDITION.build(
          type: CONDITION::HELD_TYPE,
          status: cause.present?,
          reason: cause.presence || "NotHeld",
          message: message,
          evidence: evidence,
          now: now
        )
      end

      # `Progressing` is an in-flight transition. Same shape and same reason for
      # the nil case: not provisioning is not a fault.
      def progressing_condition(cause:, message: nil, evidence: {}, now: Time.current)
        CONDITION.build(
          type: CONDITION::PROGRESSING_TYPE,
          status: cause.present?,
          reason: cause.presence || "Settled",
          message: message,
          evidence: evidence,
          now: now
        )
      end
    end
  end
end
