# frozen_string_literal: true

module Api
  module V1
    module System
      module Platform
        # Operator-side CRUD for FederationGrants scoped to a specific
        # FederationPeer. Nested under /platform/peers/:peer_id/grants
        # so the peer relationship is implicit and the URL space mirrors
        # the dashboard's drill-down (Peers → peer detail → Grants).
        #
        # Endpoints:
        #   GET    /api/v1/system/platform/peers/:peer_id/grants
        #     List ALL grants for the peer (active + expired + revoked +
        #     archived). Filterable by lifecycle state via ?state=.
        #
        #   POST   /api/v1/system/platform/peers/:peer_id/grants
        #     Issue a new grant. Body params:
        #       resource_kind (required), resource_id (optional - blank means
        #       "all of kind"), remote_subject (required), permission_scopes
        #       (default ["read"]), ttl_days (default 30, min 7, max 365),
        #       node_instance_ids/sdwan_network_ids/source_cidrs (pessimistic
        #       allowlists; default []).
        #
        #   POST   /api/v1/system/platform/peers/:peer_id/grants/:id/revoke
        #     Soft-revoke. Sets revoked_at; record persists for 90d retention
        #     before FederationGrantArchivalJob archives it.
        #
        # Permissions:
        #   system.peers.read   — index
        #   system.peers.manage — create + revoke
        #
        # Plan reference: Decentralized Federation §E + §I + P4 + P7.5.
        class PeerGrantsController < ApplicationController
          before_action :authenticate_request
          before_action :set_peer
          before_action :set_grant, only: %i[revoke]

          def index
            return forbidden unless current_user&.has_permission?("system.peers.read")

            grants = ::System::FederationGrant.where(federation_peer_id: @peer.id)
                                              .order(issued_at: :desc)
            grants =
              case params[:state]
              when "active"   then grants.active
              when "expired"  then grants.expired
              when "revoked"  then grants.revoked
              when "archived" then grants.archived
              else grants
              end

            render_success(
              grants: grants.map { |g| serialize(g) },
              count: grants.count
            )
          end

          def create
            return forbidden unless current_user&.has_permission?("system.peers.manage")

            resource_kind   = params[:resource_kind].to_s.strip
            remote_subject  = params[:remote_subject].to_s.strip
            scopes          = Array(params[:permission_scopes]).map(&:to_s).reject(&:blank?)
            scopes = %w[read] if scopes.empty?
            invalid = scopes - ::System::FederationGrant::SCOPES
            if invalid.any?
              return render_error("invalid permission_scopes: #{invalid.inspect}; allowed: #{::System::FederationGrant::SCOPES.inspect}",
                                  status: :bad_request)
            end

            if resource_kind.blank? || remote_subject.blank?
              return render_error("resource_kind and remote_subject are required",
                                  status: :bad_request)
            end

            ttl_days = params[:ttl_days]&.to_i || 30
            ttl_days = 30 if ttl_days <= 0
            ttl_days = 7   if ttl_days < 7
            ttl_days = 365 if ttl_days > 365

            issued_at  = Time.current
            expires_at = issued_at + ttl_days.days

            grant = ::System::FederationGrant.new(
              account: current_account,
              federation_peer: @peer,
              grantor_user: current_user,
              remote_subject: remote_subject,
              resource_kind: resource_kind,
              resource_id: params[:resource_id].presence,
              permission_scopes: scopes,
              issued_at: issued_at,
              expires_at: expires_at,
              node_instance_ids: sanitize_id_list(params[:node_instance_ids]),
              sdwan_network_ids: sanitize_id_list(params[:sdwan_network_ids]),
              source_cidrs:      sanitize_string_list(params[:source_cidrs]),
              metadata: { "issued_via" => "platform_dashboard" }
            )

            if grant.save
              render_success({ grant: serialize(grant) }, status: :created)
            else
              render_error("Grant creation failed: #{grant.errors.full_messages.join(', ')}",
                          status: :unprocessable_entity)
            end
          rescue StandardError => e
            render_error("Grant creation failed: #{e.message}", status: :internal_server_error)
          end

          def revoke
            return forbidden unless current_user&.has_permission?("system.peers.manage")

            if @grant.revoked?
              return render_error("Grant already revoked", status: :conflict)
            end

            @grant.revoke!(reason: params[:reason] || "operator-initiated", user: current_user)
            render_success(grant: serialize(@grant.reload))
          end

          private

          def forbidden
            render_error("Forbidden", status: :forbidden)
          end

          def set_peer
            @peer = ::System::FederationPeer.find_by(
              id: params[:peer_id],
              account: current_account,
              peer_kind: "platform"
            )
            render_error("Peer not found", status: :not_found) unless @peer
          end

          def set_grant
            @grant = ::System::FederationGrant.find_by(
              id: params[:id], federation_peer_id: @peer.id
            )
            render_error("Grant not found", status: :not_found) unless @grant
          end

          def sanitize_id_list(raw)
            Array(raw).map(&:to_s).reject(&:blank?).uniq
          end

          def sanitize_string_list(raw)
            Array(raw).map(&:to_s).map(&:strip).reject(&:blank?).uniq
          end

          def serialize(grant)
            lifecycle =
              if grant.archived?
                "archived"
              elsif grant.revoked?
                "revoked"
              elsif grant.expired?
                "expired"
              else
                "active"
              end

            {
              id: grant.id,
              federation_peer_id: grant.federation_peer_id,
              remote_subject: grant.remote_subject,
              resource_kind: grant.resource_kind,
              resource_id: grant.resource_id,
              permission_scopes: Array(grant.permission_scopes),
              lifecycle: lifecycle,
              issued_at: grant.issued_at&.iso8601,
              expires_at: grant.expires_at&.iso8601,
              revoked_at: grant.revoked_at&.iso8601,
              revocation_reason: grant.revocation_reason,
              archived_at: grant.archived_at&.iso8601,
              node_instance_ids: Array(grant.node_instance_ids),
              sdwan_network_ids: Array(grant.sdwan_network_ids),
              source_cidrs:      Array(grant.source_cidrs),
              unrestricted: grant.unrestricted?,
              grantor_user_id: grant.grantor_user_id,
              bearer_token_preview: grant.respond_to?(:bearer_token) ? grant.bearer_token : nil
            }
          end
        end
      end
    end
  end
end
