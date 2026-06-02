# frozen_string_literal: true

# Federation mTLS Phase 2 — separate the three distinct certificate concerns
# that the single `node_certificate_id` column conflated:
#
#   1. OUTBOUND identity  — the cert WE present when calling this peer.
#                           Our private key, Vault-backed NodeCertificate.
#                           Read by Federation::PeerClient.
#   2. INBOUND subject     — the CN the peer presents TO us. Used by
#                           FederationApi::BaseController to resolve the
#                           caller. Always `fed:<peer.id>` (an identity WE
#                           assign), so no peer can claim another's subject.
#   3. TRUSTED CA anchor   — the peer's CA we accept on the federation-only
#                           mTLS Traefik route (symmetric peers only; nil
#                           for hierarchical children we issued to off our
#                           own CA). CA public certs are not secret, so a
#                           plain text column is correct (no Vault).
#
# Clean break, no back-compat: the conflated `node_certificate_id` is
# removed outright.
class RefactorFederationPeerCertDirectionality < ActiveRecord::Migration[8.0]
  def up
    # ── Drop the conflated single-cert reference ────────────────────────
    if foreign_key_exists?(:system_federation_peers, :system_node_certificates,
                           column: :node_certificate_id)
      remove_foreign_key :system_federation_peers, column: :node_certificate_id
    end
    remove_reference :system_federation_peers, :node_certificate, index: true

    # ── 1. Outbound identity ────────────────────────────────────────────
    add_reference :system_federation_peers, :outbound_certificate,
                  type: :uuid, index: true,
                  foreign_key: { to_table: :system_node_certificates }

    # ── 2. Inbound subject (the CN the peer presents to us) ─────────────
    add_column :system_federation_peers, :inbound_subject, :string, limit: 255
    add_index  :system_federation_peers, :inbound_subject,
               unique: true,
               where: "inbound_subject IS NOT NULL",
               name: "index_federation_peers_on_inbound_subject"

    # ── 3. Trusted peer CA anchor (federation-only Traefik trust) ───────
    add_column :system_federation_peers, :trusted_ca_pem, :text
  end

  def down
    remove_column :system_federation_peers, :trusted_ca_pem
    remove_index  :system_federation_peers, name: "index_federation_peers_on_inbound_subject"
    remove_column :system_federation_peers, :inbound_subject

    if foreign_key_exists?(:system_federation_peers, :system_node_certificates,
                           column: :outbound_certificate_id)
      remove_foreign_key :system_federation_peers, column: :outbound_certificate_id
    end
    remove_reference :system_federation_peers, :outbound_certificate, index: true

    add_reference :system_federation_peers, :node_certificate,
                  type: :uuid, index: true,
                  foreign_key: { to_table: :system_node_certificates }
  end
end
