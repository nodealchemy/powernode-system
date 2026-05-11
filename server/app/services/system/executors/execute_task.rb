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

        task = ::System::Task.new(attrs)
        task.account = account
        task.initiated_by_id ||= deferred_operation&.requested_by_id
        task.save!

        {
          task_id: task.id,
          status: task.status,
          command: task.command
        }
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
