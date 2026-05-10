# frozen_string_literal: true

# Adds the `sdwan_flow_samples` table — per-flow telemetry records
# ingested from IPFIX exporters. Distributed-sidecar architecture: each
# host runs vector/fluent-bit (or future Go-agent embedded listener)
# that parses IPFIX bytes from OVS and POSTs batched JSON to the
# platform's ingest endpoint.
#
# The platform owns the storage + query surface; binary protocol parsing
# is delegated to mature external tools (vector/fluent-bit) so we don't
# reinvent IPFIX parsers, template caching, etc.
#
# Partitioning: not enabled at MVP. Operators with large fleets
# (hundreds of hosts at high sampling rates) will want to add range
# partitioning by observed_at via pg_partman or similar follow-up
# migration. For now a single flat table + retention job suffices.
#
# Index strategy:
#   - (account_id, observed_at desc): primary query path —
#     "show recent flows for my account"
#   - (ipfix_collector_id, observed_at desc): per-collector query —
#     "show flows from this collector in the last hour"
#   Additional indexes (src_ip, dst_ip, protocol) are NOT added at MVP;
#   add them when concrete query patterns emerge to avoid write-cost.
#
# Phase O6 follow-up of the OVS+OVN dual-profile networking roadmap.
class CreateSdwanFlowSamples < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_flow_samples, id: :uuid do |t|
      t.references :ipfix_collector, type: :uuid, null: false,
                   foreign_key: { to_table: :sdwan_ipfix_collectors, on_delete: :cascade },
                   index: false # composite index covers per-collector queries
      t.references :account, type: :uuid, null: false,
                   foreign_key: true,
                   index: false # composite index covers account-scoped queries

      # 5-tuple. inet holds IPv4 or IPv6; src_port + dst_port are
      # nullable because some protocols (ICMP, raw IP) don't have ports.
      t.inet     :src_ip,    null: false
      t.inet     :dst_ip,    null: false
      t.integer  :src_port
      t.integer  :dst_port
      t.integer  :protocol,  null: false  # IANA protocol number (6=TCP, 17=UDP, 1=ICMP, ...)

      # Counters. bigint because flows can carry billions of bytes
      # over their lifetime (long-lived TCP connections, video streams).
      t.bigint   :octet_count,  null: false, default: 0
      t.bigint   :packet_count, null: false, default: 0

      # Flow lifetime as reported by the exporter. Sidecar parses these
      # from IPFIX flowStartMilliseconds/flowEndMilliseconds (or v9
      # SysUpTime variants converted to wall-clock time).
      t.datetime :flow_start_at, null: false
      t.datetime :flow_end_at,   null: false

      # When the platform persisted the row. Distinct from flow_end_at
      # because exporters may batch + delay; observed_at lets us reason
      # about "when did the platform learn about this flow".
      t.datetime :observed_at,   null: false

      t.timestamps
    end

    # Primary query index: account-scoped time range. Descending order
    # on observed_at because operators typically want recent-first.
    add_index :sdwan_flow_samples,
              %i[account_id observed_at],
              order: { observed_at: :desc },
              name: "idx_flow_samples_account_recent"

    # Per-collector index for "show me what this collector emitted".
    add_index :sdwan_flow_samples,
              %i[ipfix_collector_id observed_at],
              order: { observed_at: :desc },
              name: "idx_flow_samples_collector_recent"
  end
end
