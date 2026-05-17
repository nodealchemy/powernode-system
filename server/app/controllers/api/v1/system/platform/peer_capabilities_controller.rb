# frozen_string_literal: true

module Api
  module V1
    module System
      module Platform
        # Operator-side CRUD for FederationCapability rows scoped to a
        # specific peer. Capabilities declare per-resource-kind sync
        # direction + policy + filter + conflict-resolution policy
        # (per pair, not symmetric — each peer declares their own).
        #
        # Endpoints:
        #   GET    /api/v1/system/platform/peers/:peer_id/capabilities
        #     List capabilities for the peer.
        #
        #   POST   /api/v1/system/platform/peers/:peer_id/capabilities
        #     Create. Body: resource_kind (required), direction
        #     (push_local_to_remote|pull_remote_to_local|bidirectional|
        #     migration_only), policy (manual|auto_on_change|auto_periodic|
        #     on_match_filter), filter (optional JSON object),
        #     conflict_resolution (optional, defaults to local_wins).
        #
        #   DELETE /api/v1/system/platform/peers/:peer_id/capabilities/:id
        #     Hard-delete (capabilities are mutable declarations, not
        #     audit records — destruction is appropriate).
        #
        # Permissions:
        #   system.peers.read   — index
        #   system.peers.manage — create + destroy
        #
        # Plan reference: Decentralized Federation §D + §I + P4 + P7.6.
        class PeerCapabilitiesController < ApplicationController
          before_action :authenticate_request
          before_action :set_peer
          before_action :set_capability, only: %i[destroy]

          def index
            return forbidden unless current_user&.has_permission?("system.peers.read")

            caps = ::System::FederationCapability.where(federation_peer_id: @peer.id)
                                                 .order(:resource_kind, :direction)
            render_success(
              capabilities: caps.map { |c| serialize(c) },
              count: caps.count
            )
          end

          def create
            return forbidden unless current_user&.has_permission?("system.peers.manage")

            kind      = params[:resource_kind].to_s.strip
            direction = params[:direction].to_s.strip
            policy    = params[:policy].to_s.strip

            if kind.blank?
              return render_error("resource_kind is required", status: :bad_request)
            end

            allowed_dirs = ::System::FederationCapability::DIRECTIONS
            unless allowed_dirs.include?(direction)
              return render_error("invalid direction (allowed: #{allowed_dirs.inspect})",
                                  status: :bad_request)
            end

            allowed_policies = ::System::FederationCapability::POLICIES
            policy = "manual" if policy.blank?
            unless allowed_policies.include?(policy)
              return render_error("invalid policy (allowed: #{allowed_policies.inspect})",
                                  status: :bad_request)
            end

            conflict = params[:conflict_resolution].presence || "local_wins"
            unless ::System::FederationCapability::CONFLICT_RESOLUTIONS.include?(conflict)
              return render_error(
                "invalid conflict_resolution (allowed: #{::System::FederationCapability::CONFLICT_RESOLUTIONS.inspect})",
                status: :bad_request
              )
            end

            filter = parse_filter_payload(params[:filter])

            cap = ::System::FederationCapability.new(
              account: current_account,
              federation_peer: @peer,
              resource_kind: kind,
              direction: direction,
              policy: policy,
              filter: filter,
              conflict_resolution: conflict
            )

            if cap.save
              render_success({ capability: serialize(cap) }, status: :created)
            else
              render_error("Capability creation failed: #{cap.errors.full_messages.join(', ')}",
                          status: :unprocessable_entity)
            end
          rescue StandardError => e
            render_error("Capability creation failed: #{e.message}",
                        status: :internal_server_error)
          end

          def destroy
            return forbidden unless current_user&.has_permission?("system.peers.manage")

            @capability.destroy!
            render_success(deleted: true, id: @capability.id)
          end

          private

          def forbidden
            render_error("Forbidden", status: :forbidden)
          end

          def set_peer
            @peer = ::System::FederationPeer.find_by(
              id: params[:peer_id], account: current_account, peer_kind: "platform"
            )
            render_error("Peer not found", status: :not_found) unless @peer
          end

          def set_capability
            @capability = ::System::FederationCapability.find_by(
              id: params[:id], federation_peer_id: @peer.id
            )
            render_error("Capability not found", status: :not_found) unless @capability
          end

          # Accept either a hash (already-parsed JSON body) or a string
          # (textarea-supplied JSON). Returns {} on unparseable input.
          def parse_filter_payload(raw)
            case raw
            when Hash, ActionController::Parameters
              raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
            when String
              return {} if raw.strip.empty?
              JSON.parse(raw)
            else
              {}
            end
          rescue JSON::ParserError
            {}
          end

          def serialize(cap)
            {
              id: cap.id,
              federation_peer_id: cap.federation_peer_id,
              resource_kind: cap.resource_kind,
              direction: cap.direction,
              policy: cap.policy,
              filter: cap.filter,
              conflict_resolution: cap.conflict_resolution,
              last_synced_at: cap.respond_to?(:last_synced_at) ? cap.last_synced_at&.iso8601 : nil,
              sync_cursor: cap.respond_to?(:sync_cursor) ? cap.sync_cursor : nil,
              created_at: cap.created_at&.iso8601,
              updated_at: cap.updated_at&.iso8601
            }
          end
        end
      end
    end
  end
end
