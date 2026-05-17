# frozen_string_literal: true

module Api
  module V1
    module System
      module Federation
        # Operator-admin endpoint for initiating a subscription to a
        # remote peer's service. Orchestrates two steps:
        #
        #   1. POST to the peer's federation_api/subscriptions
        #      (operator-side ServiceCatalogService issues a
        #      FederationGrant + returns connection details)
        #
        #   2. Invoke Federation::SubscriptionLifecycleService locally
        #      (creates ServiceSubscription, issues ACME cert, writes
        #      Traefik route, transitions to active)
        #
        # POST /api/v1/system/federation/peers/:peer_id/subscriptions
        #   Body: { slug, local_hostname, ttl_days?, dns_credential_id? }
        #   Auth: operator JWT + permission system.service_subscriptions.subscribe
        #
        # Plan reference: Decentralized Federation §L + P4.6.8.
        class PeerSubscriptionsController < ApplicationController
          REQUIRED_FIELDS = %w[slug local_hostname].freeze

          def create
            return render_error("Forbidden", status: :forbidden) unless
              current_user&.has_permission?("system.service_subscriptions.subscribe")
            return unless validate_payload!
            peer = find_peer
            return unless peer

            client = ::Federation::PeerClient.new(peer: peer)
            operator_response = client.post_subscription(
              slug: params[:slug].to_s,
              local_hostname: params[:local_hostname].to_s,
              ttl_days: params[:ttl_days]
            )

            result = ::Federation::SubscriptionLifecycleService.activate!(
              account: current_account,
              federation_peer: peer,
              offering_slug: params[:slug].to_s,
              local_hostname: params[:local_hostname].to_s,
              operator_response: operator_response,
              dns_credential: dns_credential_for(params[:dns_credential_id])
            )

            if result.ok?
              render_success(
                { subscription: serialize_subscription(result.subscription) },
                status: :created
              )
            else
              render_error("Local subscription activation failed: #{result.error}",
                           status: :unprocessable_entity)
            end
          rescue ::Federation::PeerClient::HttpError => e
            render_error("Remote peer rejected subscription: #{e.message}",
                         status: :bad_gateway)
          rescue ::Federation::PeerClient::ConnectionError => e
            render_error("Could not reach peer: #{e.message}",
                         status: :service_unavailable)
          end

          private

          def find_peer
            peer = ::System::FederationPeer.find_by(
              id: params[:peer_id],
              account: current_account
            )
            unless peer
              render_error("Peer not found", status: :not_found)
              return nil
            end
            peer
          end


          def validate_payload!
            missing = REQUIRED_FIELDS.reject { |f| params[f].present? }
            return true if missing.empty?
            render_error("Missing required fields: #{missing.join(', ')}", status: :bad_request)
            false
          end

          def dns_credential_for(id)
            return nil if id.blank?
            ::System::AcmeDnsCredential.find_by(id: id, account: current_account)
          end

          def serialize_subscription(sub)
            {
              id: sub.id,
              service_offering_slug: sub.service_offering_slug,
              local_hostname: sub.local_hostname,
              protocol: sub.protocol,
              backend_port: sub.backend_port,
              status: sub.status,
              federation_peer_id: sub.federation_peer_id,
              activated_at: sub.activated_at&.iso8601
            }
          end
        end
      end
    end
  end
end
