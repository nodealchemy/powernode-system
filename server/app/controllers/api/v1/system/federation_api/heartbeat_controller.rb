# frozen_string_literal: true

module Api
  module V1
    module System
      module FederationApi
        # Periodic heartbeat from a federated peer. mTLS-authenticated
        # against the peer's node_certificate.
        #
        # POST /api/v1/system/federation_api/heartbeat
        # Body:
        #   capabilities:    object (latest capability snapshot)
        #   endpoints:       array of { url, scope, priority, cidr_hint? }
        #   sync_cursor:     object (per-table { last_synced_at, last_id })
        #   extension_slugs: array of strings
        # Returns:
        #   { status, last_heartbeat_at, our_endpoints }
        #
        # Side effect: calls peer.record_heartbeat! which transitions
        # enrolled → active or degraded → active and refreshes
        # last_heartbeat_at. Capability + endpoint + cursor are merged.
        class HeartbeatController < BaseController
          def create
            peer = current_federation_peer

            peer.record_heartbeat!(
              capabilities: capabilities_param,
              endpoints: endpoints_param,
              sync_cursor: sync_cursor_param
            )

            # Optionally update extension_slugs if the caller declared
            # a new set. Doing this outside record_heartbeat! to avoid
            # bundling unrelated concerns.
            if (slugs = extension_slugs_param)
              peer.update!(extension_slugs: slugs) if slugs != peer.extension_slugs
            end

            render_success(
              data: {
                status: peer.status,
                last_heartbeat_at: peer.last_heartbeat_at&.iso8601,
                our_endpoints: our_endpoints_for(peer)
              }
            )
          end

          private

          def capabilities_param
            value = params[:capabilities]
            return nil if value.blank?
            value.is_a?(ActionController::Parameters) ? value.to_unsafe_h : value.to_h
          end

          def endpoints_param
            return nil if params[:endpoints].blank?
            Array(params[:endpoints]).map do |entry|
              entry.is_a?(ActionController::Parameters) ? entry.to_unsafe_h : entry.to_h
            end
          end

          def sync_cursor_param
            value = params[:sync_cursor]
            return nil if value.blank?
            value.is_a?(ActionController::Parameters) ? value.to_unsafe_h : value.to_h
          end

          def extension_slugs_param
            return nil if params[:extension_slugs].blank?
            Array(params[:extension_slugs]).map(&:to_s).reject(&:blank?)
          end

          # Return THIS platform's own endpoint advertisement back to the
          # peer so they can update their dial map. v1: returns the
          # account's primary PlatformDeployment for the api role.
          def our_endpoints_for(peer)
            api_deployment = ::System::PlatformDeployment
              .where(account: peer.account, service_role: "api")
              .for_mainline
              .first
            return [] unless api_deployment

            api_deployment.dial_candidates(port: 443)
          end
        end
      end
    end
  end
end
