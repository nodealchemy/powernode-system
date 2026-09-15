# frozen_string_literal: true

module System
  module Executors
    module DiskImage
      # Multi-action executor for disk image webhooks. Backs three deferred
      # operations the operator surface raises through AutonomyGate:
      #
      #   action: "trigger"        — manual re-fire marker (no-op today; the
      #                              concrete dispatch lives in the receiver).
      #   action: "revoke"         — soft-revoke the webhook (status flip).
      #   action: "rotate_secret"  — mint a fresh HMAC secret + invalidate
      #                              the prior; returns plaintext exactly once.
      #
      # THIS EXECUTOR IS THE SOLE AUTHORITY, AND IT RUNS EXACTLY ONCE PER
      # OPERATION. Ai::AutonomyGate calls DeferredOperation#execute_now! on
      # every branch that resolves to :proceed — auto_approve,
      # notify_and_proceed, AND require_approval in core mode, where no
      # Ai::ApprovalChain is loaded and the gate auto-proceeds
      # (autonomy_gate.rb#require_approval_or_proceed). On a require_approval
      # that actually parks, it runs once at approval time instead. The
      # controller's `on_proceed:` closure only renders what it returns.
      #
      # This comment used to say the opposite: that the controller closure did
      # the work on the inline branch, implying this executor did not. It ran
      # on BOTH, and so did the closure, so a rotation minted two secrets and
      # emitted two fleet events (IMP-4de09f201a0f). The closures now only
      # render what this returns.
      class TriggerWebhook < ::System::Executors::Base
        protected

        def perform
          webhook = resolve_scoped(::System::DiskImageWebhook, params[:webhook_id])
          case params[:action].to_s
          when "revoke"
            webhook.update!(status: "revoked") if webhook.status != "revoked"
            { webhook_id: webhook.id, action: "revoke", status: webhook.status }
          when "rotate_secret"
            new_secret = webhook.rotate_secret!
            emit_rotated_event(webhook)
            # webhook_url, like the controller's inline branch. An operator
            # whose rotation was approved asynchronously needs the URL just as
            # much as one whose policy proceeded inline — omitting it here left
            # the approval path handing back a secret with nothing to paste it
            # beside.
            {
              webhook_id: webhook.id,
              action: "rotate_secret",
              secret_plaintext: new_secret,
              webhook_url: webhook.webhook_url
            }
          else
            # "trigger" (or missing) — manual re-fire marker; the actual
            # dispatch is the receiver's responsibility.
            { webhook_id: webhook.id, action: "trigger", triggered_at: Time.current.iso8601 }
          end
        end

        def summarize
          action = params[:action].to_s.presence || "trigger"
          "#{action.capitalize} disk image webhook #{params[:webhook_id]}"
        end

        private

        # THE ONLY emitter of this event. The controller carried a second copy
        # for its inline branch, which is why one rotation produced two events;
        # that copy is gone. It attributed the rotation to a user, so the
        # attribution is carried here rather than dropped. `requesting_user`
        # resolves the REQUESTER (deferred_operation.requested_by) — not the
        # approver — on both branches, so an approved rotation now names who
        # asked for it, which the controller's copy could never do because it
        # never ran on that branch. `deferred_operation_id` points at the audit row, from
        # which the branch is recoverable via its approval_request.
        def emit_rotated_event(webhook)
          return unless defined?(::System::Fleet::EventBroadcaster)

          ::System::Fleet::EventBroadcaster.emit!(
            account:  webhook.account,
            kind:     "system.disk_image_webhook_secret_rotated",
            severity: :medium,
            source:   "autonomy_executor",
            payload:  {
              webhook_id: webhook.id,
              label: webhook.label,
              by_user_id: requesting_user&.id,
              deferred_operation_id: deferred_operation&.id
            }
          )
        rescue StandardError => e
          Rails.logger.warn "[DiskImage::TriggerWebhook] rotated event emit failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
