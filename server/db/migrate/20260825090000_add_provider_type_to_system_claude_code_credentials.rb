# frozen_string_literal: true

# Multi-provider support for on-node AI CLI credentials.
#
# This table was built for exactly one consumer (the claude-tmux NodeModule)
# and so hard-coded a single vendor in two places: one row per instance, and
# a Vault credential type that is always an Anthropic one. The grok-cli
# NodeModule needs the same primitive — a per-instance, Vault-backed API key
# fetched over the mTLS node_api at boot — for xAI, and duplicating the
# table, the concern wiring, and the read path per vendor is how a platform
# ends up with N copies of one credential lifecycle to drift apart.
#
# So the row gains the provider it belongs to. `provider_type` matches
# Ai::Constants (the same vocabulary Ai::Provider#provider_type validates
# against), defaulting to "anthropic" so every existing row keeps its exact
# current meaning with no backfill.
#
# The unique index moves from (node_instance_id) to
# (node_instance_id, provider_type): an instance may now carry one
# credential PER PROVIDER, and still at most one per provider. Dropping the
# uniqueness altogether would let two rows for the same instance+provider
# both claim to be authoritative, and the node_api read path resolves by
# find_by — it would silently serve whichever came first.
#
# DELIBERATELY NOT DONE HERE: renaming the table/class to a provider-neutral
# name, and generalizing the operator-facing REST surface at
# /nodes/:id/node_instances/:id/claude_code_credential. Both are pure
# renames across a live deployment and belong in their own change; this one
# stays additive so it is safe to apply to a running fleet.
class AddProviderTypeToSystemClaudeCodeCredentials < ActiveRecord::Migration[8.1]
  def change
    add_column :system_claude_code_credentials, :provider_type, :string,
               null: false, default: "anthropic"

    # Add the composite index BEFORE removing the single-column one so the
    # uniqueness guarantee is never absent, not even between two statements
    # of the same migration.
    add_index :system_claude_code_credentials, %i[node_instance_id provider_type],
              unique: true,
              name: "index_system_cc_credentials_on_instance_and_provider"

    remove_index :system_claude_code_credentials, column: :node_instance_id,
                 unique: true,
                 name: "index_system_claude_code_credentials_on_node_instance_id"
  end
end
