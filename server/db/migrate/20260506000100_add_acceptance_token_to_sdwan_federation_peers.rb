# frozen_string_literal: true

# Adds acceptance_token columns to sdwan_federation_peers for the token
# round-trip handshake (Phase 11b). The propose flow generates a
# high-entropy token; Account A's operator copies the plaintext
# out-of-band to Account B's operator who pastes it into the accept
# action. The platform stores only the SHA-256 digest + expiry.
#
# This is a TOFU-style mechanism — first acceptance establishes trust,
# subsequent operations rely on the cross-CA bridging from Phase 11c.
#
# Reference: extensions/system/docs/plans/missing-features.md (Phase 11b).
class AddAcceptanceTokenToSdwanFederationPeers < ActiveRecord::Migration[8.1]
  def change
    change_table :sdwan_federation_peers, bulk: true do |t|
      t.string :acceptance_token_digest,
               comment: "SHA-256 hex digest of the plaintext acceptance token. Plaintext returned exactly once on propose; stored only as digest."
      t.datetime :acceptance_token_expires_at,
                 comment: "When the acceptance token expires. accept! refuses tokens past this time."
    end

    add_index :sdwan_federation_peers, :acceptance_token_digest,
              where: "acceptance_token_digest IS NOT NULL",
              name: "index_federation_peers_on_token_digest"
  end
end
