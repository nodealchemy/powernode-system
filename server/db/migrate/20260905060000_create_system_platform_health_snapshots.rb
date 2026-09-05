# frozen_string_literal: true

# Offer 01a07024-d980 — the composite platform-health series.
#
# WHY A TABLE AND NOT A `System::FleetEvent` KIND
#
# FleetEvent already carries `emitted_at`, a `kind` index and a jsonb payload,
# so "another kind" is the cheaper thing to WRITE. It is the more expensive
# thing to READ and the riskier thing to emit:
#
#   * "show me health over the last hour" against FleetEvent means filtering
#     the whole fleet-signal firehose by kind and then extracting `overall`
#     out of jsonb per row. Here `overall` is a column and
#     (account_id, captured_at DESC) is an index, so the same question is one
#     index scan and no deserialization.
#   * the fleet event stream is an INPUT to the autonomy sensors and decision
#     engine. Adding a periodic high-volume kind to it changes what those
#     consumers perceive. A health series is an observation ABOUT the platform,
#     not a fleet signal to be reasoned over, and it does not belong in their
#     scope.
#   * FleetEvent.severity is constrained to low/medium/high/critical, which
#     cannot express `not_measured` — the one status this feature exists to
#     make representable. Encoding it in the payload would put the load-bearing
#     value back behind a jsonb read.
class CreateSystemPlatformHealthSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :system_platform_health_snapshots, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid,
                   index: false # covered by the composite index below

      # ok | degraded | down | unknown. `unknown` is the overall a run reports
      # when nothing was observed to be wrong AND at least one subsystem could
      # not be observed at all — it is deliberately NOT `ok`.
      t.string :overall, null: false

      # subsystem name => { status:, ...evidence }. Every declared subsystem
      # appears on every run, including the ones that came back not_measured:
      # a missing key would be indistinguishable from a subsystem nobody
      # thought to probe, which is the failure mode this whole feature exists
      # to close.
      t.jsonb :subsystems, null: false, default: {}

      # Denormalised counts so an operator can rank runs without opening the
      # payload. Derivable from `subsystems`; stored because the ranking query
      # is the common one.
      t.integer :down_count,         null: false, default: 0
      t.integer :degraded_count,     null: false, default: 0
      t.integer :not_measured_count, null: false, default: 0

      # What produced the run (e.g. the MCP verb). Distinguishes an operator
      # asking from a scheduled capture when both write to this table.
      t.string :source

      t.datetime :captured_at, null: false

      t.timestamps
    end

    # The "health over the last hour" access path.
    add_index :system_platform_health_snapshots, %i[account_id captured_at],
              name: "index_platform_health_snapshots_on_account_and_time",
              order: { captured_at: :desc }

    # "when did it stop being ok" without a payload read.
    add_index :system_platform_health_snapshots, %i[account_id overall captured_at],
              name: "index_platform_health_snapshots_on_account_overall_time",
              order: { captured_at: :desc }

    add_check_constraint :system_platform_health_snapshots,
                         "overall IN ('ok','degraded','down','unknown')",
                         name: "ck_platform_health_snapshots_overall"
  end
end
