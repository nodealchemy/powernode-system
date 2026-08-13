# frozen_string_literal: true

module System
  module Executors
    # Executor wired into AutonomyGate when System::Task#before_create gates
    # the dispatch. After approval (or auto-approval) lands, this executor
    # actually inserts the task and lets the existing
    # `System::Task#enqueue_execution` after_commit hook push the job.
    #
    # Why an executor instead of inline create? It keeps every gated
    # operation symmetrical — the audit row, the status flow, and the
    # approval chain all behave identically across SDWAN, Runtime, and
    # Task domains.
    class ExecuteTask < Base
      protected

      def perform
        attrs = params[:task_attributes] || params[:attributes] || params
        attrs = attrs.respond_to?(:to_unsafe_h) ? attrs.to_unsafe_h : attrs.to_h
        attrs = attrs.symbolize_keys.slice(
          :command, :description, :scheduled_at, :exclusive,
          :operable_type, :operable_id, :idempotency_key, :options,
          :initiated_by_id
        )

        operable = resolve_operable(attrs.delete(:operable_type), attrs.delete(:operable_id))

        task = ::System::Task.new(attrs)
        task.account = account
        task.operable = operable if operable
        task.initiated_by_id ||= deferred_operation&.requested_by_id
        task.save!

        {
          task_id: task.id,
          status: task.status,
          command: task.command
        }
      end

      # The operable arrives as a caller-supplied type/id pair that the gate
      # stored verbatim and replays at approval time with no re-validation, and
      # System::Task's polymorphic belongs_to is `optional: true` with no
      # ownership check — so mass-assigning the pair let a caller attach another
      # account's record to a task executing under their own account.
      #
      # Two independent refusals: the allowlist decides WHAT may be an operable
      # (System::Task validates it too, but constantizing an arbitrary
      # caller-supplied string to reach that validation is itself the thing to
      # avoid), and resolve_scoped decides WHOSE row it may be. The resolved
      # record — not the raw pair — is what gets attached, so the check and the
      # assignment cannot drift apart.
      def resolve_operable(type, id)
        return nil if type.blank? || id.blank?

        unless ::System::Task::OPERABLE_TYPES.include?(type)
          raise ::System::Task::BadOperableType,
                "#{type} is not a valid task operable"
        end

        resolve_scoped(type.constantize, id)
      end

      def summarize
        "Execute system task: #{params[:command]}"
      end

      def impact
        operable = params[:operable_type] && params[:operable_id] ? "#{params[:operable_type]}##{params[:operable_id]}" : "system"
        "#{params[:command]} on #{operable}"
      end
    end
  end
end
