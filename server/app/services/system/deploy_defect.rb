# frozen_string_literal: true

module System
  # Tells a DEPLOY DEFECT from an ordinary runtime failure, for the rescue arms
  # that deliberately swallow the latter.
  #
  # A bookkeeping lane that must never take the fleet down rescues
  # StandardError around its write and falls back to the pre-table behaviour
  # ("emit the event, do not escalate"). That is the right posture for a
  # transient failure — a lock timeout, a deadlock, a connection blip. It is
  # the WRONG posture for a table or column that does not exist: nothing about
  # the next tick will be different, the lane is dead until someone deploys,
  # and a warn line nobody greps is the only evidence. Measured 2026-09-05:
  # System::Fleet::SignalState's table was stamped-as-applied but never created
  # on the CI checkout, and the standing-signal lane reported a healthy tick
  # for weeks while doing nothing. Same class as RoutedLaneGuard's
  # policy_missing arm — the silence was the defect, not the fallback.
  #
  # So a rescue arm asks this first and RE-RAISES a schema defect. The raise
  # surfaces where the tick already contains per-account failures
  # (FleetAutonomyService#tick! → WorkerApi::FleetController#reconcile records
  # `ok: false, error:` for that account), so a missing table now reads as a
  # FAILED tick for the account it affects — never as a healthy one — and
  # never as a crash of the sweep for every other account.
  #
  # Only the schema-shaped errors qualify. ActiveRecord::StatementInvalid also
  # wraps deadlocks, lock waits and cancelled queries (all subclasses of it),
  # and those stay swallowed: what makes an error a deploy defect is the CAUSE
  # in its chain, not the wrapper.
  module DeployDefect
    SCHEMA_CAUSE_NAMES = %w[
      PG::UndefinedTable
      PG::UndefinedColumn
      PG::UndefinedFunction
      PG::UndefinedObject
    ].freeze

    # @param error [Exception]
    # @return [Boolean] true when the error, or anything in its cause chain,
    #   says the schema this code was written against is not the schema it is
    #   running on.
    def self.schema?(error)
      cause_chain(error).any? { |e| schema_error?(e) }
    end

    def self.schema_error?(error)
      return true if error.is_a?(::ActiveModel::MissingAttributeError)
      return true if error.is_a?(::ActiveModel::UnknownAttributeError)

      schema_causes.any? { |klass| error.is_a?(klass) }
    end
    private_class_method :schema_error?

    # Resolved lazily and by name: the pg gem is a dependency here, but the
    # helper must not raise NameError in a process that has not loaded it.
    def self.schema_causes
      SCHEMA_CAUSE_NAMES.filter_map { |name| name.safe_constantize }
    end
    private_class_method :schema_causes

    def self.cause_chain(error)
      chain = []
      current = error
      while current.is_a?(Exception) && !chain.include?(current)
        chain << current
        current = current.cause
      end
      chain
    end
    private_class_method :cause_chain
  end
end
