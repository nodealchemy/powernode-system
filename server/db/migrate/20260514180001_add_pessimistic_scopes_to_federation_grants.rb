# frozen_string_literal: true

# P4.5.2 — Three pessimistic-scope allowlists on FederationGrant per
# Locked Decision #12 of the Decentralized Federation plan:
#
#   - node_instance_ids:  the calling NodeInstance.id must be in this
#                         list (when populated)
#   - sdwan_network_ids:  the SDWAN network the request arrived over
#                         must be in this list (when populated)
#   - source_cidrs:       the source IP must fall in one of these CIDRs
#                         (when populated)
#
# Empty allowlist on any axis = no restriction on that axis (back-compat
# for grants created before LD #12). Populated = pessimistic: the
# request is denied unless the calling context matches.
#
# Plan reference: Decentralized Federation §K + P4.5.2.
class AddPessimisticScopesToFederationGrants < ActiveRecord::Migration[8.0]
  def change
    add_column :system_federation_grants, :node_instance_ids, :jsonb,
      null: false, default: []
    add_column :system_federation_grants, :sdwan_network_ids, :jsonb,
      null: false, default: []
    add_column :system_federation_grants, :source_cidrs, :jsonb,
      null: false, default: []

    # GIN indices on the allowlists so the FederationManager AI Skill
    # can efficiently find "grants restricting to instance X" or
    # "grants restricting to network Y" without table scans.
    add_index :system_federation_grants, :node_instance_ids, using: :gin
    add_index :system_federation_grants, :sdwan_network_ids, using: :gin
  end
end
