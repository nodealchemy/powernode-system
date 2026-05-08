# frozen_string_literal: true

module System
  # Time-series sample of a project (infrastructure-mission) metric.
  #
  # Written by `System::ProjectMetricsCollector` (sampling service wired into
  # `FleetAutonomyService.tick!`); read by `System::Fleet::Sensors::ProjectSloSensor`
  # to evaluate SLO/drift/cost-breach signals against live telemetry instead
  # of the legacy `mission.configuration["latest_observations"]` test seam.
  #
  # Schema reference: `db/migrate/20260507000010_create_system_project_metrics.rb`.
  class ProjectMetric < BaseRecord
    self.table_name = "system_project_metrics"

    # Metric family classification. Validated; unknown values are rejected
    # so the vocabulary stays explicit.
    METRIC_TYPES = %w[latency utilization cost capacity topology].freeze

    # Canonical metric_name vocabulary the sensor knows about. Kept here
    # (rather than as a DB enum) so sampler code can reference the constants
    # directly without a magic string. The collector and sensor must agree on
    # these names.
    KNOWN_METRIC_NAMES = %w[
      p99_latency_ms
      availability_pct
      cpu_pct
      memory_pct
      replica_count
      region_count
      cost_usd_mtd
    ].freeze

    belongs_to :mission, class_name: "::Ai::Mission"

    validates :metric_name, presence: true
    validates :metric_type, presence: true, inclusion: { in: METRIC_TYPES }
    validates :sampled_at, presence: true

    attribute :value, :json, default: -> { {} }

    before_validation :default_sampled_at

    # Latest sample per metric_name for a given mission. Returns one row per
    # distinct metric_name (the most recent).
    #
    # Implementation: a `DISTINCT ON (metric_name)` subselect of IDs scoped
    # to the mission, then a join back to fetch the full rows. Postgres-
    # native — `DISTINCT ON` keeps the latest sample per metric_name once
    # the inner ordering is `(metric_name, sampled_at DESC)`.
    scope :recent_for_mission, ->(mission_id) {
      latest_ids = unscoped
        .select(Arel.sql("DISTINCT ON (metric_name) id"))
        .where(mission_id: mission_id)
        .order(:metric_name, sampled_at: :desc)
      where(id: latest_ids)
    }

    # Convenience: the observed numeric value (top-level `observed` key in
    # the JSONB blob). Returns `nil` if the value was written without one.
    def observed
      v = value.is_a?(Hash) ? value : {}
      v["observed"] || v[:observed]
    end

    # Convenience: the target threshold the collector recorded alongside the
    # observation, if any. Sensors usually pull the target from
    # `mission.configuration["slo_targets"]`, but collectors may also stamp
    # the snapshot here for forensic replay.
    def target
      v = value.is_a?(Hash) ? value : {}
      v["target"] || v[:target]
    end

    private

    def default_sampled_at
      self.sampled_at ||= Time.current
    end
  end
end
