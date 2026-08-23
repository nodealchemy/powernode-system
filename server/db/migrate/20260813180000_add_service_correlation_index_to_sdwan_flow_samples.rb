# frozen_string_literal: true

# IMP-c7d663f24a0b follow-up — supporting index for the service-health
# correlation.
#
# SdwanServiceHealthSensor issues ONE query per active service:
#
#   WHERE account_id = ? AND observed_at >= ? AND dst_ip = ? AND dst_port = ?
#
# That per-service shape is deliberate (it keeps the comparison in inet address
# space, so a non-canonical operator-entered VIP still matches — grouping would
# force it into text space via host(dst_ip), where it silently correlates to
# nothing). The cost of keeping it is N lookups per tick, and the only existing
# index is (account_id, observed_at DESC), so each one scans every sample the
# account collected inside the window. On a busy overlay that window is the
# large majority of the table.
#
# This index makes each lookup a direct probe while leaving the per-service
# semantics untouched. observed_at trails the equality columns so the same
# index also serves the MAX(observed_at) as a backwards scan.
#
# Separate migration rather than an edit to 20260813170000: that one is already
# applied, and an applied migration never re-runs.
#
# Built CONCURRENTLY because system_sdwan_flow_samples is the IPFIX ingest
# firehose. A plain CREATE INDEX holds a SHARE lock for the whole build, which
# blocks every ingest INSERT behind it; live installs auto-apply migrations, so
# that lock window stalls ingest for as long as the build runs.
#
# CORRECTION (post-hoc review, 2026-08-14) — recorded forward, not rewritten:
# the commit that added concurrency here justified it by claiming the resulting
# hole is read by SdwanServiceHealthSensor as service SILENCE. That is wrong.
# A table-wide write block starves last_flow_at and holders_observed? EQUALLY,
# and silence_provable? gates on the latter (sdwan_service_health_sensor.rb:174-188),
# so the sensor stamps "unknown" and returns — never "silent". Reaching "silent"
# requires a SELECTIVE gap (holder-peer flows present while VIP+port flows are
# absent), which a whole-table lock is not.
#
# The real harm is narrower and still worth avoiding: ingest stalls behind the
# lock, health_state churns serving→unknown, and a collector whose POST times out
# and drops rather than retries loses samples outright. Two facts bound it further
# — SHARE blocks writes but not reads, so rows already inside the window stay
# visible; and blocked INSERTs queue rather than drop, carrying their own
# observed_at (ipfix_ingest_service.rb), so a build finishing inside the 900s flow
# window often leaves no hole at all.
#
# Tolerating a pre-existing index is load-bearing, not decoration: without it
# this migration raises PG::DuplicateTable over an index an operator pre-built
# by hand, which is precisely what makes "build it concurrently ahead of the
# deploy" unavailable as a mitigation today.
#
# That tolerance used to be `if_not_exists: true`, which is NOT safe next to
# `algorithm: :concurrently` (IMP-7b0b46b4ccc9). A concurrent build runs outside
# a transaction, so a build that fails partway is not rolled back — it leaves an
# index with `pg_index.indisvalid = false` that the planner will never use. The
# migration raises without stamping, the operator re-runs, and IF NOT EXISTS
# — which matches BY NAME ONLY, consulting neither `indisvalid` nor the
# definition — silently skips over the corpse and stamps as applied. The index
# then exists in `db/schema.rb` and in `schema_migrations`, and is permanently
# dead, with no error anywhere.
#
# So this is now the first consumer of
# `Powernode::MigrationHelpers::ConcurrentIndex#add_index_concurrently`, which
# keeps the pre-built-by-hand tolerance but decides it from the catalog:
# an invalid leftover with no build in flight is dropped so the rebuild is real,
# an identical valid index is a genuine no-op, and a valid index of the same
# name with a DIFFERENT definition raises and names the index rather than being
# silently accepted. Critically for the pre-build mitigation above, an index
# that is invalid only because the operator's CREATE INDEX CONCURRENTLY is
# STILL RUNNING is refused, never dropped.
#
# `up`/`down` rather than `change`, because the helper reads the catalog and so
# cannot be recorded by the reversible-migration CommandRecorder.
#
# Concurrency was added by EDITING this already-applied migration rather than by
# shipping a follow-up (lead decision, 2026-08-14). A follow-up cannot fix this:
# pending migrations run in ascending order, so a later-dated one runs AFTER the
# blocking build wherever this is still pending, and is redundant wherever it
# already ran. The "never edit an applied migration" rule guards DIVERGENCE
# BETWEEN INSTALLS, and that hazard is nil here — this has only ever been applied
# on the unmerged dev-loop/dev-improve checkout, and concurrency changes only HOW
# the index is built, never WHAT exists afterward.
class AddServiceCorrelationIndexToSdwanFlowSamples < ActiveRecord::Migration[8.0]
  include Powernode::MigrationHelpers::ConcurrentIndex

  disable_ddl_transaction!

  INDEX_NAME = "index_system_sdwan_flow_samples_on_service_correlation"

  def up
    add_index_concurrently :system_sdwan_flow_samples,
                           %i[account_id dst_ip dst_port observed_at],
                           name: INDEX_NAME
  end

  def down
    remove_index :system_sdwan_flow_samples,
                 name: INDEX_NAME,
                 algorithm: :concurrently,
                 if_exists: true
  end
end
