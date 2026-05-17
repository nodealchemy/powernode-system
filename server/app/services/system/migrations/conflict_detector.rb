# frozen_string_literal: true

module System
  module Migrations
    # Scans destination DB for non-UUID unique-constraint conflicts on
    # each planned MigrationPlanStep. Returns a list of conflicts with
    # the suggested policy resolution.
    #
    # The "non-UUID" qualifier matters: UUIDv7 PKs are globally unique by
    # construction, so a PK collision is astronomically rare. But other
    # unique constraints (User.email, NodeModule.name-per-account, etc.)
    # commonly collide when migrating Accounts between peers.
    #
    # v1 scope:
    #   - For each step with action="create", introspect destination
    #     model for unique indices (other than the PK)
    #   - Check each unique index's columns against the step's payload
    #   - Append findings to migration.conflict_log
    #
    # Deferred:
    #   - Per-kind conflict_policy resolution (currently defaults to "fail")
    #   - Composite unique indices with case-insensitive columns
    #   - JSONB-embedded uniqueness (rare; defer)
    #
    # Plan reference: Decentralized Federation §F + P5.5.
    class ConflictDetector
      Result = Struct.new(:ok?, :conflict_count, :conflicts, keyword_init: true)

      class << self
        def scan!(migration:)
          new.scan!(migration: migration)
        end
      end

      def scan!(migration:)
        conflicts = []

        migration.plan_steps.where(action: "create").find_each do |step|
          conflicts.concat(detect_for_step(step))
        end

        if conflicts.any?
          migration.update!(conflict_log: migration.conflict_log + conflicts)
          migration.append_audit!("event" => "conflicts_detected", "count" => conflicts.size)
        end

        Result.new(
          ok?: true,
          conflict_count: conflicts.size,
          conflicts: conflicts
        )
      end

      private

      def detect_for_step(step)
        model = resolve_model(step.resource_kind)
        return [] unless model

        payload = step.payload || {}
        return [] if payload.empty?

        unique_indices_for(model).flat_map do |idx|
          # Pull values from payload using AR-style column names.
          values = idx.columns.map { |col| payload[col.to_s] }
          next [] if values.any?(&:nil?)

          # Skip if any column is the PK (UUID collisions are not what
          # we're scanning for).
          next [] if idx.columns.include?(model.primary_key)

          where_clause = idx.columns.zip(values).to_h
          existing = model.where(where_clause).where.not(id: step.resource_id).first
          next [] unless existing

          [ {
              "step_id" => step.id,
              "resource_kind" => step.resource_kind,
              "resource_id" => step.resource_id,
              "constraint" => idx.name,
              "columns" => idx.columns,
              "conflicting_record_id" => existing.id,
              "suggested_policy" => step.conflict_policy
            } ]
        end
      end

      def unique_indices_for(model)
        ::ActiveRecord::Base.connection.indexes(model.table_name).select(&:unique)
      end

      def resolve_model(kind)
        try_constantize("::System::#{kind.to_s.camelize}") ||
          try_constantize("::Ai::#{kind.to_s.camelize}") ||
          try_constantize("::#{kind.to_s.camelize}")
      end

      def try_constantize(name)
        name.constantize
      rescue NameError
        nil
      end
    end
  end
end
