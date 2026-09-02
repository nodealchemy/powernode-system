# frozen_string_literal: true

module System
  module Ai
    module Skills
      # The step ledger the DR replace lane (APO-4 / DR-1) is keyed on, shared
      # by the two executors that make up one replace:
      # ReplaceInstanceExecutor (the additive half) and ReapInstanceExecutor
      # (the terminate, gated on its own action_category).
      #
      # WHY A SHARED MODULE. The two halves are separate CLASSES precisely so
      # they gate separately — BaseSkillExecutor resolves one action_category
      # per class — but they are one operation, and an operator reading
      # FleetEvent#by_correlation must see the reap on the same correlation_id
      # as the acquire that preceded it. Duplicating the ledger writer in both
      # classes would let the two spellings drift apart, which is the one thing
      # an idempotency ledger cannot survive.
      module InstanceReplacementLedger
        # Event kind prefix — one kind per step, all sharing the payload's
        # `operation_id`, so a whole replace reads off FleetEvent by
        # correlation as well as step by step. It stays
        # "system.instance_replace" for the reap too: the reap is a step OF a
        # replace, not a separate operation, and re-prefixing it would hide it
        # from the correlation read.
        EVENT_PREFIX = "system.instance_replace"

        # The recorded step for this operation, or nil. The presence of the
        # event is the whole idempotency decision — a step whose event exists
        # is skipped and its payload replayed.
        def replayed_step(step, operation_id)
          ::System::FleetEvent
            .where(account_id: @account.id, kind: "#{EVENT_PREFIX}.#{step}")
            .where("payload->>'operation_id' = ?", operation_id.to_s)
            .order(emitted_at: :desc)
            .first
        end

        # DELIBERATELY UNRESCUED. PlatformResilienceExecutor#emit_event!
        # swallows a failed emit because nothing depends on it; here the event
        # IS the ledger, so a step that applied and was not recorded would be
        # re-applied on the next drive.
        #
        # The raise BOUNDS a run; it cannot un-apply the step it failed to
        # record. Where that distinction matters — the pool acquire, which
        # commits a claim of its own — the caller wraps the step and this write
        # in ONE transaction so the two roll back together. Everywhere else the
        # leg is idempotent by its own query and a re-drive repairs it.
        def record_step!(step:, operation_id:, payload:, failed:, reason:, severity: "low",
                         instance_id: nil)
          ::System::FleetEvent.create!(
            account_id: @account.id,
            kind: "#{EVENT_PREFIX}.#{step}",
            severity: severity,
            correlation_id: operation_id.to_s,
            payload: payload.merge(
              "operation_id" => operation_id.to_s,
              "step" => step,
              "failed_instance_id" => failed.id,
              "reason" => reason
            ),
            node_instance_id: instance_id || failed.id,
            emitted_at: Time.current
          )
        end

        # Account-scoped instance lookup, joined through the node because that
        # is where the account lives — a NodeInstance id alone is not proof the
        # caller may act on it.
        def find_instance(id)
          return nil if id.blank?

          ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { account_id: @account.id })
            .find_by(id: id)
        end
      end
    end
  end
end
