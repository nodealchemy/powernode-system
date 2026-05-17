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

            # P9.3 — Schema version negotiation. Stamp peer.platform_version
            # from the heartbeat payload + consult the compatibility
            # matrix. Result feeds the governance scanner; controller
            # surfaces the outcome so the caller can see whether
            # capability sync will resume next tick.
            negotiation = negotiate_schema_version!(peer)

            # P9.4 — Stamp peer.data_residency from the heartbeat
            # payload (Social Contract #8). Operator-supplied string;
            # no normalization beyond whitespace trimming.
            stamp_residency!(peer)

            render_success(
              data: {
                status: peer.status,
                last_heartbeat_at: peer.last_heartbeat_at&.iso8601,
                our_endpoints: our_endpoints_for(peer),
                schema_compatibility: {
                  status: negotiation.status,
                  source: negotiation.source,
                  local_version:  ::Federation::SchemaVersionNegotiator.current_platform_version,
                  remote_version: peer.platform_version,
                  notes:          negotiation.notes
                }
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

          # P9.3 — pull remote platform_version off the heartbeat payload,
          # stamp the peer, negotiate compatibility. Always returns a
          # Result, even when the remote didn't report a version (the
          # result.status will be "incompatible" so the operator notices).
          def negotiate_schema_version!(peer)
            remote_version = params[:platform_version].to_s.strip
            if remote_version.present? && remote_version != peer.platform_version
              peer.update!(platform_version: remote_version)
            end
            ::Federation::SchemaVersionNegotiator.negotiate(
              remote_version: peer.platform_version
            )
          end

          # P9.4 — record peer's declared data_residency from heartbeat.
          # Free-form string (ISO code, region group, "global"); the
          # ResidencyEnforcer doesn't normalize beyond exact match, so
          # operators must declare consistently.
          def stamp_residency!(peer)
            raw = params[:data_residency].to_s.strip
            return if raw.blank?
            return if raw == peer.data_residency
            peer.update!(data_residency: raw)
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
