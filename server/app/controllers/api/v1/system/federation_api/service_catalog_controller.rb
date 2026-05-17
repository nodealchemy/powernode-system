# frozen_string_literal: true

module Api
  module V1
    module System
      module FederationApi
        # Operator-side catalog browse endpoint. Lists the operator's
        # active + deprecated service offerings, visible to any
        # mTLS-authenticated federation peer.
        #
        # Authorization model: **peering itself is the credential** for
        # catalog visibility. No FederationGrant is required to browse;
        # peers see exactly what the operator chose to publish. The
        # subscribe step (SubscriptionsController#create) is what issues
        # the actual grant.
        #
        # GET /api/v1/system/federation_api/service_catalog
        # Returns:
        #   { data: { offerings: [{ slug, name, description_markdown,
        #     protocol, backend_port, capacity_metadata, latency_metadata,
        #     subscription_terms_markdown, default_grant_ttl_days,
        #     default_grant_scopes, status }, ...] } }
        #
        # `backend_host` / `backend_vip` are NOT exposed in the catalog —
        # subscribers learn the backend address only via a successful
        # subscribe call, which authorizes the connection.
        #
        # Plan reference: Decentralized Federation §L.3 + P4.6.5.
        class ServiceCatalogController < BaseController
          def index
            offerings = ::Federation::ServiceCatalogService.list_active_offerings(
              account: current_federation_peer.account
            )
            render json: {
              data: {
                offerings: offerings.map { |o| serialize_offering(o) },
                generated_at: Time.current.iso8601
              }
            }
          end

          private

          def serialize_offering(offering)
            {
              slug: offering.slug,
              name: offering.name,
              description_markdown: offering.description_markdown,
              protocol: offering.protocol,
              backend_port: offering.backend_port,
              capacity_metadata: offering.capacity_metadata,
              latency_metadata: offering.latency_metadata,
              subscription_terms_markdown: offering.subscription_terms_markdown,
              default_grant_ttl_days: offering.default_grant_ttl_days,
              default_grant_scopes: offering.default_grant_scopes,
              status: offering.status,
              accepting_new_subscriptions: offering.accepting_subscriptions?
            }
          end
        end
      end
    end
  end
end
