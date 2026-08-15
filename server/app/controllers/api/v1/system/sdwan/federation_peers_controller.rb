# frozen_string_literal: true

# Operator-facing federation peer management. Read endpoints are gated on
# sdwan.federation.read (slice 1 seed); mutate endpoints on
# sdwan.federation.manage (slice 6 seed).
#
# v1 transitions: propose (create) → accept → revoke (terminal). The
# controller honors V1_TRANSITIONS on the model — attempts to flip status
# outside the allowed set return 422. All three trust-boundary verbs are
# approval-gated on every REST surface that reaches them: propose (#create),
# accept (#update, status → accepted) and revoke (#destroy, #revoke, and
# #update with status → revoked). The remaining transitions are inline.
#
# REST is not the whole surface, and this comment claims nothing about the
# rest of it: Ai::Tools::SdwanTool#revoke_federation_peer calls
# FederationPeer#revoke! directly with no gate (its sibling
# accept_federation_peer does gate), so an MCP-driven agent still reaches
# "revoked" ungated. Tracked separately as IMP-2795453255c3.
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

            # Two transitions reachable here cross the trust boundary, and both
            # are gated:
            #
            #   accepted — EXTENDS trust: completes the handshake that starts
            #     mutual route advertisement with a remote instance.
            #   revoked  — WITHDRAWS it: cuts cross-instance routing, and is the
            #     transition whose cause has to be audited. V1_TRANSITIONS lists
            #     "revoked" from every non-terminal state, so this PATCH reaches
            #     the same state change as #destroy and #revoke — which have
            #     gated it all along.
            #
            # Gating only acceptance left that third path open (IMP-ca3440a11a9a):
            # the reasoning was that acceptance is the transition that extends
            # trust, which is true and beside the point — withdrawing trust is
            # equally a trust decision, and it was already gated everywhere else.
            # Being inline, it also never reached FederationPeer#revoke!, so no
            # revocation_reason was recorded.
            #
            # Suspend/enroll/activate narrow or track an existing link and stay
            # inline.
            return gated_accept! if new_status == "accepted"
            return gated_revoke! if new_status == "revoked"

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

          # The revocation leg of #update — same action_category and executor as
          # #revoke, so one approval policy and one audit trail cover all three
          # routes to a revoked peer.
          #
          # Nothing is mutated here or in on_proceed, for the same reason as
          # gated_accept!: require_approval is the normal path and gate! never
          # calls on_proceed on its :pending branch, so
          # Sdwan::Executors::RevokeFederationPeer owns the state change (it
          # calls FederationPeer#revoke!, which is what records the reason).
          #
          # Unlike gated_accept!, the ride-along fields of the same PATCH are NOT
          # forwarded: revoked is terminal and the revoke executor applies no
          # attributes, so there is nowhere for them to land. They are ignored
          # rather than refused with a 422, because a form-shaped client resends
          # every permitted field on every PATCH and refusing that would break a
          # legitimate revocation.
          #
          # No up-front guard is added here, unlike gated_accept!'s token check.
          # The narrow claim that supports that: the only peer on which revoke!
          # silently does nothing is one already revoked, and can_transition_to?
          # refused that above (V1_TRANSITIONS["revoked"] is empty). It is NOT
          # the broader claim that the deferred revocation cannot fail — revoke!
          # runs update!, so a row that no longer validates (a platform peer with
          # a blank spawn_role) raises inside the executor, and on the :pending
          # path that raise is swallowed by the log-only rescue in
          # ApprovalRequest#notify_source_of_decision. That is pre-existing,
          # reached identically by #revoke and #destroy, and not inducible from
          # anything this request carries.
          def gated_revoke!
            gate!(
              action_category: "sdwan.federation_peer_revoke",
              executor_class: "Sdwan::Executors::RevokeFederationPeer",
              params: { federation_peer_id: @peer.id, reason: revocation_reason_param },
              source_type: "System::FederationPeer",
              source_id: @peer.id,
              description: "Revoke federation peer #{@peer.remote_instance_url}",
              on_proceed: ->(_r) { render_success(federation_peer: serialize_peer_full(@peer.reload)) }
            )
          end

          # The reason is not a peer column, so a client may send it beside the
          # peer body (the shape POST /revoke takes) or inside it. Both are read:
          # the audited cause of a trust withdrawal must not be dropped over a
          # nesting choice.
          def revocation_reason_param
            params[:reason].presence || params.dig(:federation_peer, :reason).presence
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
              # #index projects this compact shape and never the full metadata
              # blob, so without an explicit field the recorded revocation cause
              # is invisible in the peer LIST — the one federation view the
              # operator UI actually reads. Promoted rather than widening the
              # projection to all of metadata.
              revocation_reason: p.metadata["revocation_reason"],
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
