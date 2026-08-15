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
# `if_not_exists: true` is load-bearing, not
# decoration: without it this migration raises PG::DuplicateTable over an index
# an operator pre-built by hand, which is precisely what makes "build it
# concurrently ahead of the deploy" unavailable as a mitigation today.
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
  disable_ddl_transaction!

  def change
    add_index :system_sdwan_flow_samples,
              %i[account_id dst_ip dst_port observed_at],
              name: "index_system_sdwan_flow_samples_on_service_correlation",
              algorithm: :concurrently,
              if_not_exists: true
  end
end
