# frozen_string_literal: true

# Production observability table for the AI-driven provisioning conversation
# (M0/M1/M2). The `ProjectSloSensor` previously read its observations from the
# `mission.configuration["latest_observations"]` test seam — fine for fixture
# tests, useless in production. This table is the queryable, time-series
# storage that real metrics collectors (cloud provider agents, Prometheus
# scrapers, billing exporters) write into so the sensor can evaluate SLO,
# drift, and cost breaches against actual telemetry.
#
# Each row captures a single observation: one metric_name, one mission, one
# `sampled_at` timestamp, one `value` JSONB blob (`{ observed:, target?: }`).
#
# `ProjectMetricsCollector` (sampling service, wired into
# `FleetAutonomyService.tick!`) is the writer. `ProjectSloSensor` is the
# reader — it queries `recent_for_mission` for the latest sample per metric
# and falls back to the legacy `mission.configuration["latest_observations"]`
# test seam when no DB metrics exist yet.
class CreateSystemProjectMetrics < ActiveRecord::Migration[8.0]
  def up
    create_table :system_project_metrics, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # mission_id FK — sampled metrics belong to an active infrastructure
      # mission. `t.references` already creates an index on this column,
      # so we don't add a separate one (per platform CLAUDE.md).
      t.references :mission, type: :uuid, null: false,
                   foreign_key: { to_table: :ai_missions }

      # Metric vocabulary: short, machine-readable identifiers the sensor
      # keys on. Keep the set explicit — undocumented names will silently
      # be ignored by the sensor.
      #   p99_latency_ms, availability_pct, cpu_pct, memory_pct,
      #   replica_count, region_count, cost_usd_mtd
      t.string :metric_name, null: false

      # Higher-level family classification. Used by dashboards / aggregation;
      # the sensor doesn't care about it directly. Validated by the model.
      #   latency | utilization | cost | capacity | topology
      t.string :metric_type, null: false

      # `{ observed: <number>, target?: <number>, unit?: <string>, note?: <string> }`
      # Lambda default per platform JSON-column convention.
      t.jsonb :value, null: false, default: -> { "'{}'::jsonb" }

      # When the sample was observed (collector wallclock). Indexed via the
      # composite below for the "latest sample per metric" query path.
      t.datetime :sampled_at, null: false

      # Threads the FleetAutonomy tick correlation_id through metrics writes
      # so a sample can be tied back to the tick that produced it.
      t.string :correlation_id

      t.timestamps
    end

    # Composite index for the dominant query pattern: "latest sample for
    # (mission, metric_name)". Postgres can use this for both the equality
    # filter on (mission_id, metric_name) and the DESC ORDER BY on sampled_at.
    add_index :system_project_metrics,
              [ :mission_id, :metric_name, :sampled_at ],
              order: { sampled_at: :desc },
              name: "idx_system_project_metrics_lookup"

    # Useful for retention / cleanup jobs that walk all metrics older than N.
    add_index :system_project_metrics, :sampled_at,
              name: "idx_system_project_metrics_sampled_at"

    # Allow dashboards to filter by metric_type without a full scan.
    add_index :system_project_metrics, :metric_type,
              name: "idx_system_project_metrics_metric_type"
  end

  def down
    drop_table :system_project_metrics
  end
end
