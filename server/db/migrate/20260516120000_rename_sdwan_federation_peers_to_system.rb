# frozen_string_literal: true

# P3.9 — Namespace rename: Sdwan::FederationPeer → System::FederationPeer.
#
# Locked Decision rationale: federation peers are semantically a System
# concept (cross-Powernode-platform peering), not an SDWAN data-plane
# concept. The original `sdwan_federation_peers` table was created when
# v1 only supported data-plane peering; the P3 expansion turned it into
# a symmetric platform-level federation primitive (peer_kind discriminator
# separates the two flavors).
#
# PostgreSQL preserves all FK constraints + indexes across rename_table
# (OIDs don't change). Old migration files still reference the original
# table name (historical record); this rename runs after them.
#
# Plan reference: Decentralized Federation §C + P3.9.
class RenameSdwanFederationPeersToSystem < ActiveRecord::Migration[8.0]
  def change
    rename_table :sdwan_federation_peers, :system_federation_peers
  end
end
