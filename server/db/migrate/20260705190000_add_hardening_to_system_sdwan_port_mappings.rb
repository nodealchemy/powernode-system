# frozen_string_literal: true

# Campaign 019f3458 increment 6 — Path C hardened DNAT tier
# (docs/runbooks/traefik-tcp-exposure-vs-dnat.md "Planned hardening
# (increment 6)"). Adds three optional enforcement axes to
# Sdwan::PortMapping, compiled by Sdwan::NatCompiler into the nft DNAT
# chain:
#
#   rate_limit      — integer requests-per-second cap (nft `limit rate
#                     over N/second`). Integer-only (not a free-form
#                     rate string like "10/second") because nft's rate
#                     grammar supports multiple units (second/minute/
#                     hour) and byte-rate forms (mbytes/second) that
#                     would need a real parser to validate strictly;
#                     an integer req/s is unambiguous and directly
#                     substitutable into the fixed `<n>/second` form.
#   max_connections — integer concurrent-connection cap (nft `ct count
#                     over N drop`, the standard nftables connlimit
#                     idiom).
#   source_cidrs    — allow-list of source CIDRs (v4 and/or v6). Same
#                     jsonb-array-of-strings shape as the existing
#                     System::FederationGrant#source_cidrs column
#                     (server/app/models/system/federation_grant.rb) —
#                     matched here for consistency rather than the
#                     native `string ... array: true` shape used by
#                     Sdwan::Peer#lan_subnets, since this column has no
#                     containment-query need (no GIN index, mirroring
#                     federation_grants.source_cidrs which also has
#                     none).
#
# NULL/empty on all three = no enforcement, zero emission change (see
# nat_compiler_spec.rb's byte-identical-when-unset regression case).
# No DB check_constraint for the array shape — Rails-level validation
# only, matching the increment 5 precedent
# (20260705180000_add_public_tls_exposure_to_system_sdwan_services.rb)
# of leaving new-column enforcement to `validates`/`validate`.
class AddHardeningToSystemSdwanPortMappings < ActiveRecord::Migration[8.1]
  def change
    add_column :system_sdwan_port_mappings, :rate_limit, :integer
    add_column :system_sdwan_port_mappings, :max_connections, :integer
    add_column :system_sdwan_port_mappings, :source_cidrs, :jsonb, default: [], null: false
  end
end
