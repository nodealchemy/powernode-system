# frozen_string_literal: true

module Api
  module V1
    module System
      module FederationApi
        # Operator-side subscribe/unsubscribe endpoints.
        #
        # POST /api/v1/system/federation_api/subscriptions
        #   Body: { slug, local_hostname, ttl_days? }
        #   Auth: mTLS-authenticated peer; NO grant required (this is
        #         how peers acquire grants for service consumption).
        #   Response (201): { data: { grant_id, backend_host,
        #         backend_port, protocol, expires_at, ttl_seconds } }
        #   Errors:
        #     400 Bad Request — malformed body (missing slug or hostname)
        #     404 Not Found   — unknown offering slug
        #     409 Conflict    — offering not accepting (deprecated/retired) or at capacity
        #
        # DELETE /api/v1/system/federation_api/subscriptions/:id
        #   The :id is the FederationGrant.id the operator issued
        #   (subscribers store this from the POST response).
        #   Revokes the grant; operator-side cleanup of any
        #   bookkeeping happens via FederationManager (P4.8).
        #   Response (200): { data: { revoked: true, grant_id } }
        #   Errors:
        #     404 Not Found — no matching grant for this peer
        #
        # Plan reference: Decentralized Federation §L.3 + P4.6.5.
        class SubscriptionsController < BaseController
          REQUIRED_CREATE_FIELDS = %w[slug local_hostname].freeze

          def create
            return unless validate_create_payload!

            result = ::Federation::ServiceCatalogService.issue_subscription!(
              account: current_federation_peer.account,
              offering_slug: params[:slug].to_s,
              requesting_peer: current_federation_peer,
              local_hostname: params[:local_hostname].to_s,
              ttl_days: params[:ttl_days]
            )

            if result.ok?
              render json: { data: result.connection.merge(
                service_offering_id: result.offering.id
              ) }, status: :created
            else
              render json: { error: result.error }, status: status_for_error(result.error)
            end
          end

          def destroy
            grant = find_subscription_grant(params[:id].to_s)
            return render json: { error: "Subscription not found" }, status: :not_found unless grant

            grant.revoke!(reason: "subscriber-initiated cancellation")
            render json: { data: { revoked: true, grant_id: grant.id } }
          end

          private

          def validate_create_payload!
            missing = REQUIRED_CREATE_FIELDS.reject { |f| params[f].present? }
            if missing.any?
              render json: { error: "Missing required fields: #{missing.join(', ')}" },
                     status: :bad_request
              return false
            end
            true
          end

          # Look up a grant by id, scoped to:
          #   - current_federation_peer (so peers can't revoke each other's grants)
          #   - resource_kind = "service_offering" (so peers can't use this endpoint
          #     to revoke non-subscription grants)
          def find_subscription_grant(grant_id)
            ::System::FederationGrant.find_by(
              id: grant_id,
              federation_peer_id: current_federation_peer.id,
              resource_kind: "service_offering"
            )
          end

          def status_for_error(error_message)
            case error_message.to_s
            when /Unknown offering/  then :not_found
            when /not accepting/, /at capacity/ then :conflict
            else :unprocessable_entity
            end
          end
        end
      end
    end
  end
end
