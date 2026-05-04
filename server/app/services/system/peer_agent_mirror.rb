# frozen_string_literal: true

module System
  # Maintains a mirror Ai::Agent record for each enabled NodeInstancePeer.
  # Activating a peer also creates/updates the mirror; deactivating archives it.
  #
  # The mirror is a first-class platform agent (gets trust score, intervention
  # policies, audit log access if seeded later) — peers become uniformly
  # addressable through the platform's existing agent infrastructure rather
  # than carrying a parallel data model.
  #
  # Mention-picker surface is workspace-scoped today, so creating the mirror
  # alone does NOT make peers @-mention-able from any conversation. Bridging
  # peers into a shared "System Fleet" workspace, or extending the mention
  # picker to also fetch account-wide agents, is a follow-up.
  #
  # Reference: comprehensive stabilization sweep Phase 10.7; user
  # decision 2026-05-04 — peer-as-Agent (option A).
  class PeerAgentMirror
    # Ai::Agent.agent_type is restricted to a parent-platform allow-list
    # that doesn't include "node_peer". Use "assistant" (generic) and
    # discriminate via metadata.kind="system_node_peer" for filtering.
    AGENT_TYPE = "assistant"
    METADATA_KIND = "system_node_peer"

    class << self
      # Create or update the mirror Ai::Agent for a peer. Idempotent —
      # repeated calls update the existing row in place.
      #
      # @param peer [System::NodeInstancePeer]
      # @param creator [User, nil] used only on first create; preserves
      #   operator overrides on subsequent updates
      # @return [Ai::Agent, nil]
      def mirror_for_peer!(peer, creator: nil)
        return nil unless peer&.account_id

        agent = find_mirror(peer)
        provider = ::Ai::Provider.first
        return nil unless provider

        node = peer.node_instance&.node
        node_name = node&.name || "unknown"

        attrs = {
          status: "active",
          description: "NodeInstance peer mirror — handle=#{peer.handle} on node=#{node_name}",
          metadata: build_metadata(peer)
        }

        if agent
          agent.update!(attrs.merge(name: peer.handle))
        else
          agent = ::Ai::Agent.create!(
            attrs.merge(
              account_id: peer.account_id,
              name: peer.handle,
              agent_type: AGENT_TYPE,
              creator_id: creator&.id || fallback_creator_id(peer.account_id),
              ai_provider_id: provider.id
            )
          )
        end
        agent
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("[PeerAgentMirror] mirror create/update failed: #{e.message}")
        nil
      end

      # Archive the mirror agent for a peer (set status=archived). Safe
      # to call when no mirror exists — returns nil.
      def archive_for_peer!(peer)
        return nil unless peer

        agent = find_mirror(peer)
        return nil unless agent

        agent.update!(status: "archived")
        agent
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("[PeerAgentMirror] archive failed: #{e.message}")
        nil
      end

      # Locate the mirror agent for a peer via metadata.peer_id pointer.
      # Account-scoped to prevent cross-tenant collisions on peer ids.
      def find_mirror(peer)
        return nil unless peer&.id && peer.account_id

        ::Ai::Agent
          .where(account_id: peer.account_id, agent_type: AGENT_TYPE)
          .where("metadata ->> 'kind' = ?", METADATA_KIND)
          .where("metadata ->> 'peer_id' = ?", peer.id.to_s)
          .first
      end

      private

      def build_metadata(peer)
        {
          "peer_id" => peer.id,
          "node_instance_id" => peer.node_instance_id,
          "kind" => METADATA_KIND,
          "extension" => "system"
        }
      end

      # When a peer activates from a worker callback (no operator user in
      # context), fall back to the account's first user with system perms.
      # Ai::Agent.creator is NOT NULL so we must pick something.
      def fallback_creator_id(account_id)
        ::User.where(account_id: account_id).order(:created_at).pick(:id)
      end
    end
  end
end
