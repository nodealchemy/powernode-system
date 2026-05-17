# frozen_string_literal: true

# P9.4 — Data residency declaration on federation peers.
#
# Adds `data_residency` to `system_federation_peers` so each peer
# declares the jurisdiction (region) where its data lives, per Social
# Contract commitment #8 ("Data residency disclosure"). Operators
# declare their own platform's residency once at install; remote
# peers' residency is reported via the heartbeat payload + recorded
# here at handshake-time.
#
# Conventional values: ISO 3166-1 alpha-2 country codes ("US", "DE",
# "BR"), region groupings ("EU", "APAC"), or "global" for federally-
# hosted multi-region. Free-form to accommodate operator-specific
# regulatory framings.
#
# Plan reference: Decentralized Federation Social Contract #8 + P9.4.
class AddDataResidencyToFederationPeers < ActiveRecord::Migration[8.1]
  def change
    add_column :system_federation_peers, :data_residency, :string, limit: 64, null: true
    add_index  :system_federation_peers, :data_residency, name: "idx_federation_peers_data_residency"
  end
end
