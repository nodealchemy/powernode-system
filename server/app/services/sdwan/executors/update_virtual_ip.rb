# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdateVirtualIp < ::System::Executors::Base
      # IMP-391525770512 — the replay-sensitive columns are exactly the ones
      # Sdwan::VirtualIp#failover! writes (virtual_ip.rb:110-114), because
      # failover is the concurrent writer that makes the park→approve window
      # real rather than theoretical. It reaches this row from three places,
      # only the first of which is human-paced:
      #
      #   * Sdwan::Executors::FailoverVirtualIp (gated REST/MCP failover),
      #     which also rewrites failover_holder_peer_ids in #prefer_target!;
      #   * System::Ai::Skills::SdwanVipFailoverExecutor, the AUTONOMOUS
      #     sensor-driven failover (reason: "sensor_failover") — ungated, so
      #     it can land inside an approval window with no operator involved;
      #   * the model op itself, from anything else holding the record.
      #
      # failover_holder_peer_ids is NOT the lesser half of this pair. A parked
      # candidate-list edit replayed after a failover can name the peer that
      # is now the PRIMARY holder: failover! then computes old_holder ==
      # new_holder, leaves both arrays unchanged, and the VIP is permanently
      # unfailoverable while still reading state "active" — with the
      # legitimate standby silently dropped and an assignment row churned on
      # every attempt.
      #
      # `state` is deliberately NOT fingerprinted, and that is a live residual
      # rather than a proof of safety: failover! writes state: "active", so a
      # parked state edit replayed afterwards can write a holderless state
      # onto a held VIP. It is excluded because a request naming `state`
      # expressed a direct opinion about it, so refusing is a policy call
      # about operator intent rather than a lost update — queued separately.
      #
      # The remaining columns (description, tags, advertised_*) have no
      # concurrent writer, and stay unfingerprinted so a parked edit to them
      # is not invalidated by a failover it never expressed an opinion about.
      def self.replay_baseline_attributes
        %i[holder_peer_ids failover_holder_peer_ids].freeze
      end

      protected

      # IMP-0e44cf2fc80b — the holder-sync side-effect fires HERE, not on the
      # surfaces: gate! / gated_result never invoke their proceed blocks on
      # the :pending branch, so a sync left on VirtualIpsController#update
      # would silently not happen on every APPROVED holder change — the row
      # updated, the slice-9b assignment audit trail didn't ("no phantom
      # current state without a history row"). The canonical diff-based sync
      # lives on Sdwan::VirtualIp#sync_holder_assignments!; attribution is
      # this operation's requesting user, riding the DeferredOperation across
      # the approval window (Base#requesting_user — nil-safe across the
      # duck-typed composition contexts).
      def perform
        vip = resolve_scoped(::Sdwan::VirtualIp, params[:vip_id])
        # holder_peers_belong_to_network is RELATIVE to the VIP's network, so
        # a foreign sdwan_network_id (plus that network's peers as holders)
        # passes every validation and Sdwan::TopologyCompiler#vips_held_by
        # walks the row into the victim network's agent payloads. Guard
        # semantics live on Base#anchor_reparent! (IMP-0e44cf2fc80b); once
        # the network is anchored, the relative validation transitively
        # anchors the holders.
        anchor_reparent!(:sdwan_network_id, ::Sdwan::Network)
        ::Sdwan::VirtualIp.transaction do
          # Inside the transaction and behind a row lock, not before it. A
          # raise here rolls back just as cleanly, so placing the check
          # outside bought nothing — and it left the guard racing the very
          # writer it exists to catch: a failover landing between an
          # unlocked read and the write passes the check and is then
          # reverted. The lock also makes previous_holders below a read of
          # CURRENT state, so sync_holder_assignments! cannot compute its
          # departed/arrived diff against a row that has since moved.
          vip.lock!
          verify_replay_baseline!(vip)
          previous_holders = Array(vip.holder_peer_ids).dup
          vip.update!(attrs)
          vip.sync_holder_assignments!(previous_holders, triggered_by_user: requesting_user)
        end
        { vip_id: vip.id }
      end

      # IMP-3a563becb7d7 convention: #summarize is the approval/notification
      # body (Ai::DeferredOperationApprovalContent renders preview[:summary]),
      # and the sentence matches VirtualIpsController#update's gate
      # description verbatim so the two surfaces naming this one operation
      # cannot disagree (the IMP-ee57d0fbe859 lesson, UpdatePortMapping
      # precedent). The bare id is only the floor for a row already gone.
      #
      # IMP-8e4674f4d62d: through the same account anchor `perform` resolves
      # by (was a bare `find_by(id:)`). This card names the VIP AND its
      # network, so an unanchored lookup disclosed two of another account's
      # resource names; the network is reached through the anchored VIP, with
      # the same alignment caveat UpdateFirewallRule records.
      def summarize
        vip = scoped_label_record(::Sdwan::VirtualIp, params[:vip_id])
        return "Update VIP #{params[:vip_id]}" unless vip

        "Update SDWAN VIP '#{vip.name}' on network #{vip.network.name}"
      end
    end
  end
end
