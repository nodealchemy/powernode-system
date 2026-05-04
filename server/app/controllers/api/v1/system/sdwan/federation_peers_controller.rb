# frozen_string_literal: true

# Operator-facing federation peer management. Read endpoints are gated on
# sdwan.federation.read (slice 1 seed); mutate endpoints on
# sdwan.federation.manage (slice 6 seed).
#
# v1 transitions: propose (create) → revoke (terminal). Accept/suspend
# transitions ship in the future federation slice once cross-CA
# verification is implemented. The controller honors V1_TRANSITIONS on
# the model — attempts to flip status outside the allowed set return 422.
#
# Slice 6 of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class FederationPeersController < ::Api::V1::System::BaseController
          before_action :set_account
          before_action :set_peer, only: %i[show update destroy revoke]

          def index
            require_permission("sdwan.federation.read")
            peers = ::Sdwan::FederationPeer.where(account_id: @account.id).order(created_at: :desc)
            peers = peers.where(status: params[:status]) if params[:status].present?
            render_success(federation_peers: peers.map { |p| serialize_peer(p) }, count: peers.size)
          end

          def show
            require_permission("sdwan.federation.read")
            render_success(federation_peer: serialize_peer_full(@peer))
          end

          # POST creates a "proposed" row. Operators can later transition
          # via a future federation slice once cross-CA verification ships.
          def create
            require_permission("sdwan.federation.manage")
            attrs = peer_params

            peer = ::Sdwan::FederationPeer.new(attrs.merge(account_id: @account.id, status: "proposed"))
            if peer.save
              render_success({ federation_peer: serialize_peer_full(peer) }, status: :created)
            else
              render_validation_error(peer)
            end
          end

          def update
            require_permission("sdwan.federation.manage")
            new_status = params.dig(:federation_peer, :status)
            if new_status.present? && !@peer.can_transition_to?(new_status)
              return render_error(
                "Transition #{@peer.status} → #{new_status} is not permitted in v1 (federation activation is deferred)",
                status: :unprocessable_entity
              )
            end

            if @peer.update(peer_update_params)
              render_success(federation_peer: serialize_peer_full(@peer.reload))
            else
              render_validation_error(@peer)
            end
          end

          def destroy
            require_permission("sdwan.federation.manage")
            @peer.destroy!
            render_success(deleted: true, id: @peer.id)
          end

          def revoke
            require_permission("sdwan.federation.manage")
            @peer.revoke!(reason: params[:reason])
            render_success(federation_peer: serialize_peer_full(@peer.reload), revoked: true)
          end

          private

          def set_peer
            @peer = ::Sdwan::FederationPeer.where(account_id: @account.id).find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Federation Peer")
          end

          def peer_params
            params.require(:federation_peer).permit(
              :remote_instance_url, :remote_instance_id, :remote_account_id,
              :remote_prefix_advertisement, :signed_at, :expires_at,
              metadata: {}
            )
          end

          def peer_update_params
            params.require(:federation_peer).permit(
              :status, :remote_instance_url, :remote_instance_id, :remote_account_id,
              :remote_prefix_advertisement, :signed_at, :expires_at,
              metadata: {}
            )
          end

          def serialize_peer(p)
            {
              id: p.id,
              remote_instance_url: p.remote_instance_url,
              remote_instance_id: p.remote_instance_id,
              remote_account_id: p.remote_account_id,
              remote_prefix_advertisement: p.remote_prefix_advertisement,
              status: p.status,
              signed_at: p.signed_at&.iso8601,
              expires_at: p.expires_at&.iso8601,
              created_at: p.created_at.iso8601
            }
          end

          def serialize_peer_full(p)
            serialize_peer(p).merge(
              metadata: p.metadata,
              has_trust_jwt: p.vault_path.present? || p.encrypted_credentials.present?,
              v1_allowed_transitions: ::Sdwan::FederationPeer::V1_TRANSITIONS.fetch(p.status, [])
            )
          end
        end
      end
    end
  end
end
