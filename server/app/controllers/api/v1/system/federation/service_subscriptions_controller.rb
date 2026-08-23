# frozen_string_literal: true

module Api
  module V1
    module System
      module Federation
        # Subscriber-side admin endpoints for managing the platform's
        # own ServiceSubscription rows (the services this platform
        # consumes from federated peers). The subscriber's view of
        # "what am I subscribed to?"
        #
        # Routes:
        #   GET    /api/v1/system/federation/service_subscriptions
        #   GET    /api/v1/system/federation/service_subscriptions/:id
        #   POST   /api/v1/system/federation/service_subscriptions/:id/cancel
        #
        # NOTE: Create-subscription is initiated from the per-peer
        # catalog browser (which calls the REMOTE peer's
        # federation_api/subscriptions endpoint, then materializes
        # the ServiceSubscription via SubscriptionLifecycleService).
        # That orchestration is exposed by a higher-level controller
        # (the "subscribe to remote offering" action), not this one.
        # This controller is read + cancel only.
        #
        # Permissions:
        #   system.service_subscriptions.read   — list + show
        #   system.service_subscriptions.cancel — cancel
        #
        # Plan reference: Decentralized Federation §L.7 + P4.6.8.
        class ServiceSubscriptionsController < ApplicationController
          before_action :set_subscription, only: %i[show cancel]

          def index
            authorize_read!
            subs = ::System::Federation::ServiceSubscription
                     .where(account: current_account)
                     .order(subscribed_at: :desc)
            subs = subs.where(status: params[:status].split(",")) if params[:status].present?
            subs = subs.where(federation_peer_id: params[:peer_id]) if params[:peer_id].present?
            render_success(
              subscriptions: subs.map { |s| serialize(s) },
              count: subs.count
            )
          end

          def show
            authorize_read!
            render_success(subscription: serialize(@subscription, full: true))
          end

          def cancel
            authorize_cancel!
            if @subscription.terminal?
              return render_error("Subscription already #{@subscription.status}",
                                  status: :conflict)
            end

            if @subscription.cancel!(reason: params[:reason] || "operator-initiated")
              render_success(subscription: serialize(@subscription.reload, full: true))
            else
              render_error("Cannot cancel from status=#{@subscription.status}",
                           status: :unprocessable_content)
            end
          end

          private

          def set_subscription
            @subscription = ::System::Federation::ServiceSubscription.find_by(
              id: params[:id], account: current_account
            )
            render_error("Subscription not found", status: :not_found) unless @subscription
          end

          # IMP-563999967998 — these RAISE rather than render, for the same
          # reason as ServiceOfferingsController's pair (see the long note
          # there). Both are called INLINE from the actions — authorize_read!
          # from index/show, authorize_cancel! from #cancel — never as
          # before_actions, so the bare `render_error(...)` did not halt
          # anything: #cancel rendered the 403 and then ran on into
          # `@subscription.cancel!`, really cancelling the subscription for a
          # caller with no system.service_subscriptions.cancel permission. The
          # follow-up render_success raised DoubleRenderError, which ApiResponse
          # swallows via `unless performed?`, leaving the caller a clean 403 over
          # a committed state transition.
          #
          # Authentication::PermissionDenied inherits Exception (NOT
          # StandardError) so it survives every `rescue StandardError` and the
          # global rescue_from; its dedicated rescue_from renders the canonical
          # 403 and unwinds the action. Predicate unchanged, status unchanged,
          # message byte-identical (the rescue_from path adds `code: "FORBIDDEN"`).
          def authorize_read!
            return if current_user&.has_permission?("system.service_subscriptions.read")

            raise ::Authentication::PermissionDenied.new(
              "Forbidden", permission: "system.service_subscriptions.read"
            )
          end

          def authorize_cancel!
            return if current_user&.has_permission?("system.service_subscriptions.cancel")

            raise ::Authentication::PermissionDenied.new(
              "Forbidden", permission: "system.service_subscriptions.cancel"
            )
          end

          def serialize(sub, full: false)
            base = {
              id: sub.id,
              service_offering_slug: sub.service_offering_slug,
              service_offering_id: sub.service_offering_id,
              federation_peer_id: sub.federation_peer_id,
              local_hostname: sub.local_hostname,
              protocol: sub.protocol,
              backend_port: sub.backend_port,
              status: sub.status,
              site_local: sub.site_local?,
              subscribed_at: sub.subscribed_at&.iso8601,
              activated_at: sub.activated_at&.iso8601
            }
            return base unless full
            base.merge(
              backend_vip: sub.backend_vip,
              federation_grant_id: sub.federation_grant_id,
              acme_certificate_id: sub.acme_certificate_id,
              suspended_at: sub.suspended_at&.iso8601,
              cancelled_at: sub.cancelled_at&.iso8601,
              metadata: sub.metadata
            )
          end
        end
      end
    end
  end
end
