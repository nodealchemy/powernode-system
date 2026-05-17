# frozen_string_literal: true

module Api
  module V1
    module System
      module Platform
        # Operator-side admin endpoints for the "Peers" panel in the
        # /app/system/compute/platform dashboard. Surfaces the full set of
        # *symmetric* and *child-side* federation peers — i.e. all
        # platform-kind FederationPeer rows EXCLUDING those representing
        # children this operator spawned (those have spawn_role="parent"
        # and live in the Children panel).
        #
        # Endpoints:
        #   GET    /api/v1/system/platform/peers
        #     Lists peers. Filterable by status (comma-separated) and
        #     spawn_mode. Returns a summary row per peer.
        #
        #   GET    /api/v1/system/platform/peers/:id
        #     Full detail including endpoints, capabilities snapshot,
        #     and grant/capability/bridge counts.
        #
        #   POST   /api/v1/system/platform/peers
        #     Propose a new peer. Operator supplies remote_instance_url
        #     and optional endpoint list. Server creates the row in
        #     `proposed` state with a single-use acceptance token. Token
        #     is shown ONCE in the response — operator must capture
        #     before navigating away.
        #
        #   POST   /api/v1/system/platform/peers/:id/revoke
        #     Terminal revoke. Optionally records a reason in metadata.
        #
        # Permissions:
        #   system.peers.read   — index + show
        #   system.peers.invite — create
        #   system.peers.manage — revoke
        #
        # Plan reference: Decentralized Federation §I + P7.1.
        class PeersController < ApplicationController
          before_action :authenticate_request
          before_action :set_peer, only: %i[show revoke]

          def index
            return forbidden unless current_user&.has_permission?("system.peers.read")

            peers = ::System::FederationPeer
                      .where(account: current_account, peer_kind: "platform")
                      .where.not(spawn_role: "parent") # children live in /federation/children
                      .order(created_at: :desc)
            peers = peers.where(status: params[:status].split(",")) if params[:status].present?
            peers = peers.where(spawn_mode: params[:spawn_mode]) if params[:spawn_mode].present?

            render_success(
              peers: peers.map { |p| serialize(p) },
              count: peers.count
            )
          end

          def show
            return forbidden unless current_user&.has_permission?("system.peers.read")
            render_success(peer: serialize(@peer, full: true))
          end

          def create
            return forbidden unless current_user&.has_permission?("system.peers.invite")

            url = params[:remote_instance_url].to_s.strip
            if url.blank?
              return render_error("remote_instance_url is required", status: :bad_request)
            end

            spawn_role = params[:spawn_role].presence || "symmetric"
            unless ::System::FederationPeer::SPAWN_ROLES.include?(spawn_role)
              return render_error(
                "invalid spawn_role (allowed: #{::System::FederationPeer::SPAWN_ROLES.inspect})",
                status: :bad_request
              )
            end

            spawn_mode = params[:spawn_mode].presence || "out_of_band"
            unless ::System::FederationPeer::SPAWN_MODES.include?(spawn_mode)
              return render_error(
                "invalid spawn_mode (allowed: #{::System::FederationPeer::SPAWN_MODES.inspect})",
                status: :bad_request
              )
            end

            peer = ::System::FederationPeer.new(
              account: current_account,
              remote_instance_url: url,
              peer_kind: "platform",
              spawn_mode: spawn_mode,
              spawn_role: spawn_role,
              status: "proposed",
              endpoints: sanitized_endpoints,
              metadata: { "invited_by_user_id" => current_user.id, "invited_at" => Time.current.iso8601 }
            )

            unless peer.save
              return render_error("Peer creation failed: #{peer.errors.full_messages.join(', ')}",
                                  status: :unprocessable_entity)
            end

            ttl_seconds = params[:token_ttl_seconds]&.to_i
            ttl_seconds = 7.days.to_i if ttl_seconds.nil? || ttl_seconds <= 0
            acceptance_token = peer.generate_acceptance_token!(ttl_seconds: ttl_seconds)

            render_success(
              {
                peer: serialize(peer, full: true),
                acceptance_token: acceptance_token
              },
              status: :created
            )
          rescue StandardError => e
            render_error("Peer invite failed: #{e.message}", status: :internal_server_error)
          end

          def revoke
            return forbidden unless current_user&.has_permission?("system.peers.manage")

            if @peer.status == "revoked"
              return render_error("Peer already revoked", status: :conflict)
            end

            @peer.revoke!(reason: params[:reason] || "operator-initiated")
            render_success(peer: serialize(@peer.reload, full: true))
          end

          private

          def forbidden
            render_error("Forbidden", status: :forbidden)
          end

          def set_peer
            @peer = ::System::FederationPeer.find_by(
              id: params[:id],
              account: current_account,
              peer_kind: "platform"
            )
            return if @peer && @peer.spawn_role != "parent"

            render_error("Peer not found", status: :not_found)
          end

          def sanitized_endpoints
            raw = params[:endpoints]
            return [] unless raw.is_a?(Array) || raw.respond_to?(:to_a)

            Array(raw).map do |entry|
              h = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry.to_h
              {
                "url"      => h["url"] || h[:url],
                "scope"    => (h["scope"] || h[:scope] || "wan").to_s,
                "priority" => (h["priority"] || h[:priority] || 100).to_i
              }.compact
            end.reject { |e| e["url"].blank? }
          end

          def serialize(peer, full: false)
            base = {
              id: peer.id,
              remote_instance_url: peer.remote_instance_url,
              remote_instance_id: peer.remote_instance_id,
              peer_kind: peer.peer_kind,
              spawn_role: peer.spawn_role,
              spawn_mode: peer.spawn_mode,
              status: peer.status,
              created_at: peer.created_at&.iso8601,
              last_heartbeat_at: peer.last_heartbeat_at&.iso8601,
              last_handshake_at: peer.last_handshake_at&.iso8601,
              endpoints_count: Array(peer.endpoints).size,
              acceptance_pending: peer.acceptance_token_digest.present?,
              acceptance_expires_at: peer.acceptance_token_expires_at&.iso8601
            }
            return base unless full

            base.merge(
              endpoints: Array(peer.endpoints),
              capabilities: peer.capabilities,
              extension_slugs: Array(peer.extension_slugs),
              metadata: peer.metadata,
              signed_at: peer.signed_at&.iso8601,
              contract_version_agreed: peer.contract_version_agreed,
              parent_peer_id: peer.parent_peer_id,
              allowed_transitions: ::System::FederationPeer::TRANSITIONS.fetch(peer.status, []),
              grants_count: grants_count_for(peer),
              capabilities_count: capabilities_count_for(peer),
              bridges_count: bridges_count_for(peer)
            )
          end

          def grants_count_for(peer)
            return 0 unless defined?(::System::FederationGrant)
            ::System::FederationGrant.where(federation_peer_id: peer.id).count
          rescue StandardError
            0
          end

          def capabilities_count_for(peer)
            return 0 unless defined?(::System::FederationCapability)
            ::System::FederationCapability.where(federation_peer_id: peer.id).count
          rescue StandardError
            0
          end

          def bridges_count_for(peer)
            return 0 unless defined?(::System::FederationNetworkBridge)
            ::System::FederationNetworkBridge.where(federation_peer_id: peer.id).count
          rescue StandardError
            0
          end
        end
      end
    end
  end
end
