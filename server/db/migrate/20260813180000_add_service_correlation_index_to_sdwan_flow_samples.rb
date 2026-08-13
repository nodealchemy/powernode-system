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
class AddServiceCorrelationIndexToSdwanFlowSamples < ActiveRecord::Migration[8.0]
  def change
    add_index :system_sdwan_flow_samples,
              %i[account_id dst_ip dst_port observed_at],
              name: "index_system_sdwan_flow_samples_on_service_correlation"
  end
end
