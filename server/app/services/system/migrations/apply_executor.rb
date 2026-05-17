# frozen_string_literal: true

module System
  module Migrations
    # Receives a Migration in `transferring` state with populated
    # plan_steps and applies them transactionally to the local DB.
    # The destination side of the cross-peer migration handshake.
    #
    # Contract:
    #   - One transaction wraps every step. Migration is either fully
    #     applied or fully rolled back — no partial-apply state.
    #   - Steps applied in step_order ascending (dependency order
    #     established by PlanComposer).
    #   - Any logic-level failure (unknown kind, missing link target,
    #     conflict with policy=fail, save validation error) raises
    #     ApplyError which triggers ActiveRecord rollback. Migration
    #     transitions to `failed` with the error captured.
    #   - Intentional operator policies (conflict_policy=skip_if_exists
    #     or overwrite, action=skip) record their outcome on the step
    #     and continue. The migration completes in `completed` state.
    #
    # Payload normalization at the destination:
    #   - account_id rewritten to migration.account_id (records land in
    #     the destination's tenant scope, not the source's)
    #   - created_at/updated_at stripped (let Rails set destination-local
    #     timestamps)
    #   - UUIDv7 primary key preserved (the entire point of portable IDs)
    #
    # Plan reference: Decentralized Federation §F + P5.7.
    class ApplyExecutor
      class ApplyError < StandardError; end

      Result = Struct.new(:ok?, :error, :migration, :applied_count,
                          :skipped_count, :failed_count, keyword_init: true)

      class << self
        def apply!(**args)
          new.apply!(**args)
        end
      end

      def apply!(migration:)
        unless migration.can_transition_to?("applying")
          return failure(migration, "migration in #{migration.status}; cannot apply")
        end

        migration.transition_to!(
          "applying",
          audit_entry: { "event" => "apply_started", "step_count" => migration.plan_steps.count }
        )

        begin
          ActiveRecord::Base.transaction do
            migration.plan_steps.ordered.find_each do |step|
              apply_step!(step, migration)
            end
          end
        rescue ApplyError => e
          fail_migration!(migration, e.message)
          return failure(migration, e.message)
        rescue StandardError => e
          Rails.logger.error("[ApplyExecutor] unexpected: #{e.class}: #{e.message}")
          fail_migration!(migration, "#{e.class}: #{e.message}")
          return failure(migration, e.message)
        end

        applied, skipped = success_counts(migration)
        migration.transition_to!(
          "completed",
          audit_entry: { "event" => "apply_completed", "applied" => applied, "skipped" => skipped }
        )

        Result.new(
          ok?: true,
          migration: migration,
          applied_count: applied,
          skipped_count: skipped,
          failed_count: 0
        )
      end

      private

      def apply_step!(step, migration)
        case step.action
        when "create"     then create_step!(step, migration)
        when "link_local" then link_local_step!(step)
        when "skip"       then skip_step!(step)
        else
          raise ApplyError, "unknown action #{step.action.inspect} on step #{step.id}"
        end
      end

      def create_step!(step, migration)
        model = resolve_model(step.resource_kind)
        raise ApplyError, "create: unknown resource_kind #{step.resource_kind.inspect}" unless model

        attrs = normalize_attrs(step.payload, migration)
        existing = model.find_by(id: step.resource_id)

        if existing
          # LD #14: `duplicate` plans should never PK-collide — the
          # composer generates a fresh UUIDv7 at each step. A collision
          # here means the composer mis-emitted a preserved UUID and is
          # treated as a hard error, NOT a conflict-policy case.
          # Conflict policies only apply to `migrate` (where the same
          # UUID can legitimately have been received by this destination
          # in a prior round).
          if migration.operation == "duplicate"
            raise ApplyError, "duplicate plan step PK-collided at " \
                              "#{step.resource_kind}:#{step.resource_id} — composer should have " \
                              "emitted a fresh UUID (LD #14)"
          end
          resolve_conflict!(step, existing, attrs)
        else
          record = model.new(attrs)
          unless record.save
            raise ApplyError, "save failed for #{step.resource_kind}:#{step.resource_id}: " \
                              "#{record.errors.full_messages.join('; ')}"
          end
          step.mark_applied!
        end
      end

      def resolve_conflict!(step, existing, attrs)
        case step.conflict_policy
        when "skip_if_exists"
          mark_skipped!(step, "exists; policy=skip_if_exists")
        when "overwrite"
          unless existing.update(attrs)
            raise ApplyError, "overwrite failed for #{step.resource_kind}:#{step.resource_id}: " \
                              "#{existing.errors.full_messages.join('; ')}"
          end
          step.mark_applied!
        when "fail"
          raise ApplyError, "conflict on #{step.resource_kind}:#{step.resource_id}; policy=fail"
        when "rename_with_suffix"
          raise ApplyError, "rename_with_suffix not implemented in v1 " \
                            "(#{step.resource_kind}:#{step.resource_id})"
        else
          raise ApplyError, "unknown conflict_policy #{step.conflict_policy.inspect}"
        end
      end

      def link_local_step!(step)
        model = resolve_model(step.resource_kind)
        raise ApplyError, "link_local: unknown resource_kind #{step.resource_kind.inspect}" unless model

        unless model.exists?(id: step.resource_id)
          raise ApplyError, "link_local target missing: #{step.resource_kind}:#{step.resource_id}"
        end
        step.mark_applied!
      end

      def skip_step!(step)
        mark_skipped!(step, "explicit skip")
      end

      def mark_skipped!(step, reason)
        step.update!(
          applied_at: nil,
          error_message: nil,
          metadata: step.metadata.merge("skipped" => reason)
        )
      end

      # Strip source-only fields from the payload before destination
      # save. account_id specifically must be rewritten — records land
      # in the destination's tenant, not the source's.
      def normalize_attrs(payload, migration)
        attrs = (payload || {}).dup
        attrs["account_id"] = migration.account_id if attrs.key?("account_id")
        attrs.delete("created_at")
        attrs.delete("updated_at")
        attrs
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

      def success_counts(migration)
        steps = migration.plan_steps
        applied = steps.applied.count
        skipped = steps.count - applied
        [ applied, skipped ]
      end

      def fail_migration!(migration, message)
        migration.transition_to!(
          "failed",
          error_message: message.to_s[0, 1000],
          audit_entry: { "event" => "apply_failed", "reason" => message.to_s[0, 1000] }
        )
      end

      def failure(migration, message)
        Result.new(ok?: false, migration: migration, error: message)
      end
    end
  end
end
