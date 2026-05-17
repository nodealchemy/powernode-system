# frozen_string_literal: true

module Api
  module V1
    module System
      module Federation
        # Operator-side admin endpoints for the "Children" dashboard
        # panel — platforms this operator spawned + the spawn-launch
        # action.
        #
        # GET    /api/v1/system/federation/children
        #   Lists spawned-child FederationPeer rows (peer_kind=platform,
        #   spawn_role=parent — meaning "the row representing the child
        #   from our perspective").
        #
        # POST   /api/v1/system/federation/children/spawn
        #   Body: { spawn_mode, parent_url, spawn_target: {...} }
        #   Triggers System::SpawnPlatformService.spawn!. Returns the
        #   newly-created FederationPeer row + the acceptance token
        #   ONCE (token is single-use; operator must capture immediately).
        #
        # POST   /api/v1/system/federation/children/:id/revoke
        #   Revokes the FederationPeer (terminal). Operator-initiated
        #   teardown of a previously-spawned child.
        #
        # Permissions:
        #   system.children.read  — list + show
        #   system.children.spawn — spawn action
        #   system.children.manage — revoke
        #
        # Plan reference: Decentralized Federation §H + P6.
        class ChildrenController < ApplicationController
          REQUIRED_SPAWN_FIELDS = %w[spawn_mode parent_url spawn_target].freeze

          before_action :set_child, only: %i[show revoke]

          def index
            return render_error("Forbidden", status: :forbidden) unless
              current_user&.has_permission?("system.children.read")

            children = ::System::FederationPeer
                         .where(account: current_account,
                                peer_kind: "platform",
                                spawn_role: "parent")
                         .order(created_at: :desc)
            children = children.where(spawn_mode: params[:spawn_mode]) if params[:spawn_mode].present?
            children = children.where(status: params[:status].split(",")) if params[:status].present?

            render_success(
              children: children.map { |p| serialize(p) },
              count: children.count
            )
          end

          def show
            return render_error("Forbidden", status: :forbidden) unless
              current_user&.has_permission?("system.children.read")
            render_success(child: serialize(@child, full: true))
          end

          def spawn
            return render_error("Forbidden", status: :forbidden) unless
              current_user&.has_permission?("system.children.spawn")
            return unless validate_spawn_payload!

            # P6.7 — pass the provider-aware provisioner so the spawn
            # actually creates a NodeInstance + boots a VM. If the
            # operator wants the legacy manual-attach flow (e.g. for an
            # externally-provisioned host), they can omit the
            # provisioner by setting spawn_target[:manual_attach] = true.
            provisioner = if spawn_target_hash[:manual_attach] || spawn_target_hash["manual_attach"]
                            nil
            else
                            ::Federation::SpawnProvisioner.new(
                              account: current_account,
                              current_user: current_user
                            )
            end

            result = ::System::SpawnPlatformService.spawn!(
              account: current_account,
              spawn_mode: params[:spawn_mode].to_s,
              spawn_target: spawn_target_hash,
              parent_url: params[:parent_url].to_s,
              initiated_by_user: current_user,
              token_ttl_seconds: params[:token_ttl_seconds]&.to_i ||
                                  ::System::SpawnPlatformService::DEFAULT_TOKEN_TTL,
              provisioner: provisioner
            )

            if result.ok?
              render_success(
                {
                  child: serialize(result.federation_peer, full: true),
                  # Token shown ONCE — operator must capture or re-spawn.
                  acceptance_token: result.acceptance_token,
                  spawn_payload: result.spawn_payload
                },
                status: :created
              )
            else
              render_error("Spawn failed: #{result.error}", status: :unprocessable_entity)
            end
          end

          def revoke
            return render_error("Forbidden", status: :forbidden) unless
              current_user&.has_permission?("system.children.manage")

            if @child.status == "revoked"
              return render_error("Child already revoked", status: :conflict)
            end

            @child.revoke!(reason: params[:reason] || "operator-initiated")
            render_success(child: serialize(@child.reload, full: true))
          end

          private

          def set_child
            @child = ::System::FederationPeer.find_by(
              id: params[:id], account: current_account,
              spawn_role: "parent", peer_kind: "platform"
            )
            render_error("Child not found", status: :not_found) unless @child
          end

          def validate_spawn_payload!
            missing = REQUIRED_SPAWN_FIELDS.reject { |f| params[f].present? }
            if missing.any?
              render_error("Missing required fields: #{missing.join(', ')}", status: :bad_request)
              return false
            end
            unless ::System::SpawnPlatformService::SPAWN_MODES.include?(params[:spawn_mode].to_s)
              render_error(
                "Invalid spawn_mode (allowed: #{::System::SpawnPlatformService::SPAWN_MODES.inspect})",
                status: :bad_request
              )
              return false
            end
            true
          end

          def spawn_target_hash
            target = params[:spawn_target]
            if target.respond_to?(:to_unsafe_h)
              raw = target.to_unsafe_h
            elsif target.is_a?(Hash)
              raw = target
            else
              raw = {}
            end
            raw.symbolize_keys
          end

          def serialize(peer, full: false)
            base = {
              id: peer.id,
              remote_instance_url: peer.remote_instance_url,
              spawn_mode: peer.spawn_mode,
              status: peer.status,
              created_at: peer.created_at&.iso8601,
              last_heartbeat_at: peer.last_heartbeat_at&.iso8601,
              acceptance_pending: peer.acceptance_token_digest.present?,
              acceptance_expires_at: peer.acceptance_token_expires_at&.iso8601
            }
            return base unless full
            base.merge(
              endpoints: peer.endpoints,
              capabilities: peer.capabilities,
              metadata: peer.metadata,
              signed_at: peer.signed_at&.iso8601
            )
          end
        end
      end
    end
  end
end
