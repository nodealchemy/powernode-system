# frozen_string_literal: true

# P2.5.1 — system_acme_dns_credentials: per-account DNS provider
# credentials used by the ACME DNS-01 challenge to prove control of a
# domain when issuing/renewing Let's Encrypt certificates.
#
# Provider API tokens (Cloudflare, Route53, etc.) live in Vault under
# a new VaultCredential type "acme_dns" — this row only carries the
# Vault path, metadata, and validation state.
#
# Plan reference: Decentralized Federation §J + P2.5.
class CreateSystemAcmeDnsCredentials < ActiveRecord::Migration[8.0]
  def change
    create_table :system_acme_dns_credentials, id: :uuid do |t|
      t.references :account,
        type: :uuid, null: false,
        foreign_key: { to_table: :accounts, on_delete: :cascade }

      # Operator-visible label (e.g. "Cloudflare production")
      t.string :name, null: false, limit: 255

      # DNS provider identifier — the Acme::DnsProviderRegistry whitelist
      # gates which values are accepted. Examples: "cloudflare", "route53",
      # "gcloud", "digitalocean", "hetzner", "porkbun", "ovh".
      t.string :provider, null: false, limit: 64

      # Validation lifecycle. `untested` is the initial state;
      # `valid`/`invalid`/`expired` are set by Acme::CertificateManager
      # after a probe round-trip with the provider's API.
      t.string :status, null: false, default: "untested", limit: 32
      t.datetime :last_validated_at

      # Vault path where the provider's API tokens are stored.
      # VaultCredential concern manages the read/write through this path.
      t.string :vault_path_credentials

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    # One credential per (account, name) — operator labels are unique
    # per tenant so the UI can show them unambiguously.
    add_index :system_acme_dns_credentials, [ :account_id, :name ],
              unique: true,
              name: "idx_acme_dns_creds_acct_name_unique"

    add_index :system_acme_dns_credentials, :provider
    add_index :system_acme_dns_credentials, :status
  end
end
