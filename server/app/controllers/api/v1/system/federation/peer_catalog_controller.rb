# frozen_string_literal: true

module Api
  module V1
    module System
      module Federation
        # Operator-admin endpoint that proxies to a remote peer's
        # federation_api/service_catalog. The dashboard's per-peer
        # catalog browser hits this to show what services the peer
        # offers.
        #
        # GET /api/v1/system/federation/peers/:peer_id/catalog
        #   Auth: operator JWT + permission system.service_subscriptions.read
        #   Response: { data: { catalog: { offerings: [...], generated_at } } }
        #   Errors:
        #     401/403 — auth failure
        #     404     — unknown peer
        #     502     — remote peer returned 4xx
        #     503     — could not reach remote peer
        #
        # Plan reference: Decentralized Federation §L.7 + P4.6.8.
        class PeerCatalogController < ApplicationController
          def show
            return render_error("Forbidden", status: :forbidden) unless
              current_user&.has_permission?("system.service_subscriptions.read")

            peer = find_peer
            return unless peer

            client = ::Federation::PeerClient.new(peer: peer)
            catalog = client.fetch_catalog
            render_success(catalog: catalog, peer_id: peer.id)
          rescue ::Federation::PeerClient::HttpError => e
            render_error("Remote peer returned error: #{e.message}",
                         status: :bad_gateway)
          rescue ::Federation::PeerClient::ConnectionError => e
            render_error("Could not reach peer: #{e.message}",
                         status: :service_unavailable)
          rescue ::Federation::PeerClient::ClientError => e
            render_error(e.message, status: :unprocessable_entity)
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

        end
      end
    end
  end
end
