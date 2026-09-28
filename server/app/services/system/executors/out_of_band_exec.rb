# frozen_string_literal: true

module System
  module Executors
    # IMP-9ce0ed39c557 — the executor Ai::AutonomyGate dispatches to for
    # system.instance.out_of_band_exec, on the REST operator door
    # (mirrors System::NodeInstanceGating#gate_or_execute) and the MCP verb
    # alike (via Ai::Executors::DeferredToolCall from
    # Ai::Tools::SystemFleetTool) — one gated primitive behind both surfaces.
    #
    # A thin wrapper: every actual refusal check, audit write and bounded
    # SSH call lives in System::OutOfBandExecService. This class's only job
    # is the standard executor contract (account-anchored instance
    # resolution, the approval-card preview) plus threading through the
    # caller-supplied `pinned_ip` and `call_origin`, and the operation's own
    # `ai_agent_id`/`id` for the audit trail.
    class OutOfBandExec < ::System::Executors::Base
      ACTION_CATEGORIES = [ ::System::OutOfBandExecService::ACTION_CATEGORY ].freeze

      protected

      def perform
        instance = resolve_scoped(::System::NodeInstance, params[:instance_id])

        ::System::OutOfBandExecService.execute!(
          instance: instance,
          command: params[:command].to_s,
          sudo: sudo_param,
          pinned_ip: params[:pinned_ip],
          agent_id: deferred_operation&.ai_agent_id,
          # The REAL operation object (review finding S4), not its id — the
          # service asserts on its status/approval_request before running
          # anything. See OutOfBandExecService::execute!'s own header.
          deferred_operation: deferred_operation,
          call_origin: params[:call_origin]
        )
      end

      def summarize
        instance = scoped_label_record(::System::NodeInstance, params[:instance_id])
        instance ? "Run an out-of-band command on '#{instance.name}'" : "Run an out-of-band command on instance #{params[:instance_id]}"
      end

      # COMMAND TEXT DECISION (security review, corrected 2026-09-28 — the
      # comment this replaced was wrong on both halves of its own claim).
      # This IMPACT LINE's prose deliberately does not embed the command
      # text — it stays a fixed, generic sentence so the approval card's
      # headline is skimmable regardless of command length or shape. That is
      # NOT the same as "the command is hidden": Ai::DeferredOperation#params
      # (params[:command] here) is stored and surfaced to the approver by the
      # approval-request/card machinery same as every other executor's
      # params — an approver reviewing this request DOES see the literal
      # command before deciding, which is the whole point of a human
      # confirming it (human_only: true, security review S1). The ONE guard
      # on the command is System::OutOfBandExecService#refusal's
      # secret-shaped-command check, which refuses BEFORE parking rather than
      # showing an approver (or storing) a command that itself carries
      # inline secret material.
      #
      # What is actually true of the audit trail (the previous comment's
      # second, also-wrong claim): STARTED/FINISHED AuditLog rows NEVER
      # carry the command text, in either direction — "see the audit log
      # once it has run" was never true; the audit rows are deliberately
      # command-free (crypto-safety / docs/design/out-of-band-exec.md).
      def impact
        "Runs one shell command on the instance over SSH, from the control plane, " \
          "without its agent. The command is shown on this approval request and is " \
          "never written to the audit trail."
      end

      # `sudo:` defaults true (matches SshExecutionService#execute and the
      # unrouted-controller reference behavior); explicit false must be
      # honored. Params arrive from JSONB, so a caller may have written the
      # string "false" as easily as the boolean.
      def sudo_param
        return true unless params.key?(:sudo)

        ActiveModel::Type::Boolean.new.cast(params[:sudo])
      end
    end
  end
end
