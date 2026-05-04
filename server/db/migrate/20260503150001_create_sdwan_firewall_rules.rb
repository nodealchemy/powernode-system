# frozen_string_literal: true

# Sdwan::FirewallRule — declarative network-scoped firewall policy. The
# Sdwan::FirewallCompiler turns these rows into an `nft` script that the
# agent applies inside the per-tenant `inet powernode_sdwan` table. Each
# network has its own chain (`sdwan_<8-char-net-id>`) so policy changes
# on one network don't disturb others.
#
# JSONB selectors (`src_selector`, `dst_selector`) accept four primitive
# kinds in v1: { "peer_id": "<uuid>" }, { "tag": "<label>" },
# { "cidr": "fd...::/64" }, { "all": true }. The model validates this and
# Sdwan::SelectorResolver turns them into nft match clauses at compile time.
#
# Slice 2 of the SDWAN plan (we-are-continuing-development-spicy-bear.md).
class CreateSdwanFirewallRules < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_firewall_rules, id: :uuid do |t|
      t.references :sdwan_network, null: false, type: :uuid, foreign_key: true
      t.references :account,       null: false, type: :uuid, foreign_key: true

      t.string :name, null: false

      # Lower priority numbers compile to earlier nft rule positions (first-match wins).
      t.integer :priority, default: 1000, null: false

      # accept | drop | reject
      t.string :action,    default: "accept", null: false

      # ingress | egress | both. Slice 2 emits ingress-hook rules only;
      # the column ships now so slice 5 can add the output-hook chain
      # without a migration.
      t.string :direction, default: "both", null: false

      # any | tcp | udp | icmp6
      t.string :protocol,  default: "any", null: false

      # Selector shape: { "peer_id": "uuid" } | { "tag": "label" } |
      #                 { "cidr": "fd...::/64" } | { "all": true }
      t.jsonb :src_selector, default: {}, null: false
      t.jsonb :dst_selector, default: {}, null: false

      # Postgres int4range. Nullable — only meaningful for tcp/udp.
      # Validation enforces that constraint; the column is simply absent
      # when the rule is protocol-agnostic or non-port-based.
      t.column :dst_port_range, :int4range

      t.boolean :enabled, default: true, null: false

      t.datetime :last_compiled_at
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :sdwan_firewall_rules, %i[sdwan_network_id name], unique: true
    add_index :sdwan_firewall_rules, %i[sdwan_network_id priority]
    add_index :sdwan_firewall_rules, :enabled
  end
end
