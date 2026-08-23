# frozen_string_literal: true

# Operator-facing federation peer management. Read endpoints are gated on
# sdwan.federation.read (slice 1 seed); mutate endpoints on
# sdwan.federation.manage (slice 6 seed).
#
# v1 transitions: propose (create) → accept → revoke (terminal). The
# controller honors V1_TRANSITIONS on the model — attempts to flip status
# outside the allowed set return 422. All three trust-boundary verbs are
# approval-gated here: propose (#create), accept (#update, status → accepted)
# and revoke (#destroy, #revoke, and #update with status → revoked). The
# remaining transitions are inline.
#
# The SDWAN federation-peer surface is now gated on BOTH its halves:
# IMP-2795453255c3 routed Ai::Tools::SdwanTool#propose_federation_peer and
# #revoke_federation_peer — the last two arms calling create!/revoke! inline
# while their twins here were gated — through the same categories and
# executors, so an agent refused on one of those two surfaces can no longer
# reach the other. Held by
# spec/services/ai/tools/sdwan_mcp_federation_gate_parity_spec.rb.
#
# That is a claim about THIS controller and that tool, and deliberately not
# about System::FederationPeer as a whole — the model is reached ungated from
# three other places, all outside the SDWAN slice and tracked separately:
# Api::V1::System::Platform::PeersController#invite (a bare save! plus a
# plaintext generate_acceptance_token!) and #revoke, and
# Api::V1::System::Federation::ChildrenController#revoke. The previous
# revision of this comment universally quantified over "every surface" while
# those three contradicted it; the whole point of IMP-2795453255c3 was that a
# parity claim wider than its oracle is how the MCP arms stayed inline for as
# long as they did.
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
          #
          # The candidate is never saved — Sdwan::Executors::ProposeFederationPeer
          # stays the sole authority over the write. gate_create! validates it
          # BEFORE the gate (the sequence, and why it is in that order, lives
          # once in Ai::GatedActions#gate_create!), so an unsaveable payload
          # keeps its field-level 422 and opens no audit row for an operation
          # that could never run.
          #
          # IMP-785d60f5ec3e — this used to call gate! with raw params and no
          # candidate, which made the ANSWER track the account's intervention
          # policy rather than the request: the same invalid propose was PARKED
          # at 202 where the policy defers (failing later in front of an
          # approver who could not see it was doomed when submitted) and 422
          # where the policy proceeds — the latter only because
          # Ai::AutonomyGate#evaluate rescues the executor's RecordInvalid into
          # a bare ":blocked / Gate evaluation failed" with no details.errors.
          #
          # The control flags are stripped through the executor's OWN constant
          # rather than trusted to stay absent from peer_params: they steer
          # token minting and reach no column, so adding one to the permit list
          # would raise UnknownAttributeError building the candidate here while
          # the executor went on quietly dropping it.
          def create
            require_permission("system.sdwan.federation.manage")
            attrs = peer_params.to_h
            candidate_attrs = attrs.except(*::Sdwan::Executors::ProposeFederationPeer::CONTROL_FLAG_KEYS)

            gate_create!(
              # status: mirrors what the executor merges, so the candidate is
              # validated as the row that would actually be written.
              candidate: ::System::FederationPeer.new(
                candidate_attrs.merge(account_id: @account.id, status: "proposed")
              ),
              scope: ::System::FederationPeer.where(account_id: @account.id),
              result_key: :federation_peer_id,
              response_key: :federation_peer,
              serializer: ->(p) { serialize_peer_full(p) },
              action_category: ::Sdwan::Executors::ProposeFederationPeer::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::ProposeFederationPeer",
              params: { attributes: attrs },
              description: "Propose federation with #{attrs[:remote_instance_url]}"
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

            # A residency change and a status transition cannot ride in one
            # PATCH. Each of the three dispatches below owns a DIFFERENT
            # executor, and none of them performs both writes: the accept and
            # revoke executors apply no residency audit event, and the residency
            # executor deliberately never flips status (a residency approval is
            # not a back door to a trust transition). Silently applying half of
            # such a request — which is what dispatching on either one alone
            # does — is worse than refusing it, because the dropped half is
            # returned behind a 200/202 that reads as success. Refused rather
            # than gated twice: two approvals for one operator intent is not a
            # shape this surface has anywhere else.
            if new_status.present? && residency_change_requested?
              return render_error(
                "data_residency cannot change in the same request as a status transition — " \
                "they are separately approved. Send the status change and the residency change as two requests.",
                status: :unprocessable_content
              )
            end

            return gated_accept! if new_status == "accepted"
            return gated_revoke! if new_status == "revoked"

            # data_residency is not a status transition, but it is a compliance
            # DECLARATION rather than a label — Federation::ResidencyEnforcer
            # gates cross-boundary record homing on it — so a CHANGE to it is
            # gated alongside the trust-boundary verbs (IMP-9bf58a693634).
            # Resending the current value is not a change and stays inline: a
            # form-shaped client resends every permitted field on every PATCH,
            # and parking an approval for a no-op is what
            # #residency_change_requested? exists to avoid.
            return gated_residency! if residency_change_requested?

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
              action_category: ::Sdwan::Executors::RevokeFederationPeer::ACTION_CATEGORY,
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
              action_category: ::Sdwan::Executors::RevokeFederationPeer::ACTION_CATEGORY,
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
          # A peer carrying a Phase 11b acceptance_token_digest needs the
          # plaintext token, and #create mints one by default
          # (ProposeFederationPeer generates unless attributes[:generate_token]
          # is false) — so that is the COMMON case, not an edge one. The inline
          # `@peer.update(status: "accepted")` this replaces never reached
          # accept! and so skipped that verification entirely; routing through
          # the executor closes the bypass.
          #
          # IMP-8df377f7d255 — this used to pass a hard-coded nil, and
          # peer_update_params never permitted acceptance_token, so the check
          # below could only ever fail: PATCH {status: "accepted"} 422'd
          # unconditionally for every default-token peer and MCP was the only
          # surface that could complete the flow. The 422 was the right call
          # (see below) but it left this surface unable to do the job it exists
          # for.
          #
          # It has to be refused UP FRONT rather than at execution: on the
          # :pending path the executor runs from
          # Ai::ApprovalRequest#notify_source_of_decision, which rescues and only
          # logs — an operator would approve, get 200, and never learn the peer
          # stayed proposed. The executor re-runs the same check when it finally
          # executes; that is the one that enforces.
          #
          # The plaintext rides on the deferred operation because the single-use
          # token has to outlive the approval window to be verified and consumed
          # there — the same convention as the MCP path. It is not stored in the
          # clear anywhere an approver reads it: Ai::SensitiveParams.filter runs
          # at approval-request serialization and masks any key containing
          # "token". Token-handling hardening beyond that belongs to
          # IMP-b44483c3c098, not here.
          def gated_accept!
            token = acceptance_token_param

            if (token_error = @peer.acceptance_token_error(token))
              return render_error(token_error, status: :unprocessable_content)
            end

            gate!(
              action_category: ::Sdwan::Executors::AcceptFederationPeer::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::AcceptFederationPeer",
              params: { federation_peer_id: @peer.id, acceptance_token: token,
                        attributes: peer_update_params.to_h.except("status") },
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
              action_category: ::Sdwan::Executors::RevokeFederationPeer::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::RevokeFederationPeer",
              params: { federation_peer_id: @peer.id, reason: revocation_reason_param },
              source_type: "System::FederationPeer",
              source_id: @peer.id,
              description: "Revoke federation peer #{@peer.remote_instance_url}",
              on_proceed: ->(_r) { render_success(federation_peer: serialize_peer_full(@peer.reload)) }
            )
          end

          # The residency leg of #update — the twin of
          # Ai::Tools::SdwanTool#set_data_residency, on the same category and
          # executor, so one approval policy and one audit trail cover both
          # routes to a rewritten residency tag.
          #
          # Ride-along fields of the same PATCH travel WITH the deferral rather
          # than being written ahead of it, following gated_accept! and for the
          # same reason: they are one operator intent, and a PATCH answered 202
          # must not be half-committed. `status` is excluded — the two gated
          # transitions were already dispatched above, and the inline ones have
          # their own transition matrix; a residency approval is not a back door
          # to a status flip.
          #
          # Validated BEFORE the gate (Ai::GatedActions#gate_update! carries the
          # sequence and why): the column is varchar(64) and an over-long tag
          # would otherwise reach it as a StatementInvalid at approval time,
          # parking a change that could only ever fail.
          def gated_residency!
            attrs = peer_update_params.to_h.except("status")

            gate_update!(
              record: @peer,
              attributes: attrs,
              response_key: :federation_peer,
              serializer: ->(peer) { serialize_peer_full(peer) },
              action_category: ::Sdwan::Executors::SetFederationPeerDataResidency::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::SetFederationPeerDataResidency",
              params: { federation_peer_id: @peer.id, attributes: attrs },
              source_type: "System::FederationPeer",
              source_id: @peer.id,
              description: "Set data residency for federation peer #{@peer.remote_instance_url}"
            )
          end

          # True only when the PATCH carries data_residency AND it differs from
          # what is stored. `key?`, not presence: clearing a declared residency
          # (to nil or "") is itself a compliance change — Federation::
          # ResidencyEnforcer reads a blank tag as "not declared" and stops
          # treating the peer as boundary-constrained — so it must gate, not
          # slip through inline as an absent field would.
          def residency_change_requested?
            permitted = peer_update_params
            return false unless permitted.key?("data_residency")

            permitted["data_residency"].to_s != @peer.data_residency.to_s
          end

          # The reason is not a peer column, so a client may send it beside the
          # peer body (the shape POST /revoke takes) or inside it. Both are read:
          # the audited cause of a trust withdrawal must not be dropped over a
          # nesting choice.
          def revocation_reason_param
            params[:reason].presence || params.dig(:federation_peer, :reason).presence
          end

          # Same shape, same reason: the acceptance token is NOT a peer column.
          #
          # Deliberately read here rather than added to peer_update_params —
          # permitting it there would carry it into `@peer.update` on the
          # ordinary edit path AND into the executor's ride-along attributes,
          # and both call update! with it, which raises on an unknown attribute.
          # Reading both nestings also matches what a form-shaped client sends.
          def acceptance_token_param
            params[:acceptance_token].presence || params.dig(:federation_peer, :acceptance_token).presence
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

          # data_residency is permitted here (IMP-9bf58a693634) so operators
          # have ANY route to a field that was previously writable only over
          # MCP. Permitting it does not make it an ordinary inline edit: a
          # CHANGE to it is dispatched to gated_residency! above, and a change
          # to it alongside a status transition is refused there — so the only
          # value that ever rides along into the accept executor's attributes
          # is the one already stored, which that write is a no-op over.
          def peer_update_params
            params.require(:federation_peer).permit(
              :status, :remote_instance_url, :remote_instance_id, :remote_account_id,
              :remote_prefix_advertisement, :signed_at, :expires_at, :data_residency,
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

          # data_residency is projected HERE and not in the compact #index
          # shape, matching how revocation_reason was promoted: an operator
          # editing a peer reads this projection, and a field the API accepts
          # on PATCH but never hands back is a write-only control — nothing can
          # confirm an approved change, and #residency_change_requested?'s
          # "a form-shaped client resends every permitted field" premise is only
          # true if the client was given the field to resend.
          def serialize_peer_full(p)
            serialize_peer(p).merge(
              data_residency: p.data_residency,
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
