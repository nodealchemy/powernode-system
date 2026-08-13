# frozen_string_literal: true

# Operator-facing federation peer management. Read endpoints are gated on
# sdwan.federation.read (slice 1 seed); mutate endpoints on
# sdwan.federation.manage (slice 6 seed).
#
# v1 transitions: propose (create) → accept → revoke (terminal). The
# controller honors V1_TRANSITIONS on the model — attempts to flip status
# outside the allowed set return 422. All three trust-boundary verbs are
# approval-gated: propose (#create), accept (#update, status → accepted)
# and revoke (#destroy/#revoke). The remaining transitions are inline.
#
# Slice 6 of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class FederationPeersController < ::Api::V1::System::BaseController
          include ::System::GatedActions

          before_action :set_account
          before_action :set_peer, only: %i[show update destroy revoke]

          def index
            require_permission("system.sdwan.federation.read")
            peers = ::System::FederationPeer.where(account_id: @account.id).order(created_at: :desc)
            peers = peers.where(status: params[:status]) if params[:status].present?
            render_success(federation_peers: peers.map { |p| serialize_peer(p) }, count: peers.size)
          end

          def show
            require_permission("system.sdwan.federation.read")
            render_success(federation_peer: serialize_peer_full(@peer))
          end

          # POST creates a "proposed" row. Federation peering is sensitive —
          # always gated through Ai::AutonomyGate (default require_approval).
          def create
            require_permission("system.sdwan.federation.manage")
            attrs = peer_params.to_h

            gate!(
              action_category: "sdwan.federation_peer_propose",
              executor_class: "Sdwan::Executors::ProposeFederationPeer",
              params: { attributes: attrs },
              description: "Propose federation with #{attrs[:remote_instance_url]}",
              on_proceed: ->(result) {
                peer_id = result.result&.dig(:data, :federation_peer_id)
                peer = ::System::FederationPeer.find(peer_id) if peer_id
                if peer
                  render_success({ federation_peer: serialize_peer_full(peer) }, status: :created)
                else
                  render_error("Federation peer not found after create", status: :internal_server_error)
                end
              }
            )
          end

          def update
            require_permission("system.sdwan.federation.manage")
            new_status = params.dig(:federation_peer, :status)
            if new_status.present? && !@peer.can_transition_to?(new_status)
              return render_error(
                "Transition #{@peer.status} → #{new_status} is not permitted in v1 (federation activation is deferred)",
                status: :unprocessable_content
              )
            end

            # Acceptance is the only transition here that EXTENDS trust —
            # it completes the handshake that starts mutual route advertisement
            # with a remote instance. Its inverse is approval-gated on both
            # #destroy and #revoke, so forming the link is gated to match.
            # Suspend/enroll/activate narrow or track an existing link and stay
            # inline.
            return gated_accept! if new_status == "accepted"

            if @peer.update(peer_update_params)
              render_success(federation_peer: serialize_peer_full(@peer.reload))
            else
              render_validation_error(@peer)
            end
          end

          def destroy
            require_permission("system.sdwan.federation.manage")
            id = @peer.id
            url = @peer.remote_instance_url
            gate!(
              action_category: "sdwan.federation_peer_revoke",
              executor_class: "Sdwan::Executors::RevokeFederationPeer",
              params: { federation_peer_id: id },
              source_type: "System::FederationPeer",
              source_id: id,
              description: "Revoke federation peer #{url}",
              on_proceed: ->(_r) { render_success(deleted: true, id: id) }
            )
          end

          def revoke
            require_permission("system.sdwan.federation.manage")
            id = @peer.id
            url = @peer.remote_instance_url
            gate!(
              action_category: "sdwan.federation_peer_revoke",
              executor_class: "Sdwan::Executors::RevokeFederationPeer",
              params: { federation_peer_id: id, reason: params[:reason] },
              source_type: "System::FederationPeer",
              source_id: id,
              description: "Revoke federation peer #{url}",
              on_proceed: ->(_r) { render_success(federation_peer: serialize_peer_full(@peer.reload), revoked: true) }
            )
          end

          private

          # The acceptance leg of #update. Every field the same PATCH carried
          # rides along to the executor rather than being written ahead of the
          # approval — they are one operator intent, and applying half of it now
          # would let an unapproved caller edit the peer.
          #
          # Nothing is mutated in on_proceed: `sdwan.federation_peer_accept`
          # resolves to require_approval, gate! never calls on_proceed on its
          # :pending branch, and the acceptance must survive that path — so
          # Sdwan::Executors::AcceptFederationPeer owns the state change and
          # this lambda only renders (IMP-322999495307).
          #
          # The REST surface collects no acceptance token, so a peer carrying a
          # Phase 11b acceptance_token_digest cannot be accepted here at all —
          # #create mints one by default (ProposeFederationPeer generates unless
          # attributes[:generate_token] is false), so that is the COMMON case,
          # not an edge one. The inline `@peer.update(status: "accepted")` this
          # replaces never reached accept! and so skipped that verification
          # entirely; routing through the executor closes the bypass.
          #
          # It has to be refused UP FRONT rather than at execution: on the
          # :pending path the executor runs from
          # Ai::ApprovalRequest#notify_source_of_decision, which rescues and only
          # logs — an operator would approve, get 200, and never learn the peer
          # stayed proposed.
          def gated_accept!
            if (token_error = @peer.acceptance_token_error(nil))
              return render_error(
                "#{token_error}; accept it through system_sdwan_accept_federation_peer, " \
                "which carries the token",
                status: :unprocessable_content
              )
            end

            gate!(
              action_category: "sdwan.federation_peer_accept",
              executor_class: "Sdwan::Executors::AcceptFederationPeer",
              params: { federation_peer_id: @peer.id, attributes: peer_update_params.to_h.except("status") },
              source_type: "System::FederationPeer",
              source_id: @peer.id,
              description: "Accept federation peer #{@peer.remote_instance_url}",
              on_proceed: ->(_r) { render_success(federation_peer: serialize_peer_full(@peer.reload)) }
            )
          end

          def set_peer
            @peer = ::System::FederationPeer.where(account_id: @account.id).find(params[:id])
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
              v1_allowed_transitions: ::System::FederationPeer::V1_TRANSITIONS.fetch(p.status, [])
            )
          end
        end
      end
    end
  end
end
