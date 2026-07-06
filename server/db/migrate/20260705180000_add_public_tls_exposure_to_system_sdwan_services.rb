# frozen_string_literal: true

# Campaign 019f3458 increment 5 — Path B: public TLS-carrying TCP exposure via
# Traefik SNI (docs/runbooks/traefik-tcp-exposure-vs-dnat.md, docs/operations/
# reverse-proxy.md "Ratified decisions"). Adds the PUBLIC facet to
# Sdwan::Service, alongside the existing LOCAL (`local_enabled`) facet:
#
#   public_enabled — opts a service into a public HostSNI tcp.router on the
#                    existing websecure entrypoint (no new entrypoint, ever).
#   edge_mode      — "passthrough" (default; Traefik forwards the encrypted
#                    stream, backend terminates TLS) or "terminate" (opt-in;
#                    Traefik terminates via the service's own ACME cert).
#   client_auth    — "none" (default) or "required" (proxy-terminated mTLS,
#                    ships in v1; only meaningful under edge_mode=terminate —
#                    Traefik cannot inspect a client cert on an undecrypted
#                    passthrough stream, enforced by a model validation).
#
# No DB check_constraint — enum enforcement is Rails-level (validates
# inclusion:), matching the most recent sibling pattern for new enum-shaped
# columns (core 20260704080000_create_ai_content_drafts.rb's `status`).
class AddPublicTlsExposureToSystemSdwanServices < ActiveRecord::Migration[8.1]
  def change
    add_column :system_sdwan_services, :public_enabled, :boolean, default: false, null: false
    add_column :system_sdwan_services, :edge_mode, :string, default: "passthrough", null: false
    add_column :system_sdwan_services, :client_auth, :string, default: "none", null: false
    add_index :system_sdwan_services, :public_enabled
  end
end
