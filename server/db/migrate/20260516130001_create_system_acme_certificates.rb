# frozen_string_literal: true

# P2.5.1 — system_acme_certificates: per-domain TLS certificates issued
# by an ACME server (Let's Encrypt by default), used by Traefik for
# TLS termination on the platform's public listeners.
#
# Cert material (PEM, private key, chain, ACME account key) lives in
# Vault under a new VaultCredential type "acme_certificate". This row
# only carries: identification, lifecycle state, Vault paths, and a
# pointer to the DNS credential used for the DNS-01 challenge.
#
# Plan reference: Decentralized Federation §J + P2.5.
class CreateSystemAcmeCertificates < ActiveRecord::Migration[8.0]
  def change
    create_table :system_acme_certificates, id: :uuid do |t|
      t.references :account,
        type: :uuid, null: false,
        foreign_key: { to_table: :accounts, on_delete: :cascade }

      # The DNS credential used to solve DNS-01 challenges for this
      # cert's domain(s). Nullable for HTTP-01 challenges (opt-in,
      # only when the operator has port 80 reachability) and for
      # internal-CA certs.
      t.references :dns_credential,
        type: :uuid, null: true,
        foreign_key: { to_table: :system_acme_dns_credentials, on_delete: :nullify }

      # Common Name (CN) — the primary domain (e.g. "hub.example.com").
      t.string :common_name, null: false, limit: 255

      # Subject Alternative Names — additional domains this cert covers
      # (e.g. ["www.example.com", "git.example.com"]).
      t.jsonb :sans, null: false, default: []

      # Issuer identifier. Whitelist:
      #   - "letsencrypt-prod"   (production LE — rate-limited)
      #   - "letsencrypt-staging" (staging — for testing)
      #   - "internal-ca"        (Powernode internal CA — air-gapped deployments)
      t.string :issuer, null: false, default: "letsencrypt-prod", limit: 64

      # Challenge type per RFC 8555. DNS-01 is the default (works behind NAT).
      # HTTP-01 + TLS-ALPN-01 require inbound port reachability.
      t.string :challenge_type, null: false, default: "dns-01", limit: 16

      # Cert lifecycle state machine:
      #   pending  → issuing → valid ⇄ renewing → valid
      #                              ↘ failed (retryable)
      #                              ↘ expired (next renewal cycle)
      #            ↘ failed
      #   revoked (terminal, operator-initiated)
      t.string :status, null: false, default: "pending", limit: 32

      t.datetime :issued_at
      t.datetime :expires_at
      t.datetime :last_renewal_attempt_at
      t.text :last_renewal_error

      # Vault paths — actual cert material lives in Vault under
      # VaultCredential type "acme_certificate".
      t.string :vault_path_certificate
      t.string :vault_path_private_key
      t.string :vault_path_chain
      t.string :vault_path_account_key

      # Traefik dynamic-config identifier. Acme::TraefikConfigWriter
      # references this name when generating the resolver block so the
      # router-to-cert binding is stable across rotations.
      t.string :traefik_resolver_name

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    # One cert per (account, common_name) — same domain can't have two
    # active certs in the same tenant.
    add_index :system_acme_certificates, [ :account_id, :common_name ],
              unique: true,
              name: "idx_acme_certs_acct_cn_unique"

    add_index :system_acme_certificates, :status
    add_index :system_acme_certificates, :expires_at
    add_index :system_acme_certificates, :issuer
  end
end
