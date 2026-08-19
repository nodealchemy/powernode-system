# frozen_string_literal: true

module Sdwan
  # IMP-b24afe85a309 — retention sweep for system_sdwan_flow_samples.
  #
  # This is the highest-volume table in the extension (per-flow IPFIX telemetry
  # from every collector-attached node) and had NO retention path of any kind:
  # nothing deleted, pruned, partitioned or aged out its rows. It grew for the
  # life of the install, and every DDL or index build on it got proportionally
  # slower as a result.
  #
  # Structurally this follows the extension's existing sweep precedent —
  # SystemFleetEventRetentionJob -> a worker_api endpoint -> server-side
  # deletion, so per-account scoping and audit hooks run on the platform rather
  # than in the worker. It deliberately does NOT copy two properties of that
  # precedent, both of which are wrong for a table this size:
  #
  #   * that sweep reads its window from ENV; this one is DB-driven
  #     (Account#settings, then SiteSetting, then the fallback constant),
  #     matching how the consuming sensor already resolves ITS window.
  #   * that sweep issues an unbounded `delete_all`; on a table with tens of
  #     millions of rows the first run would hold locks long enough to stall
  #     ingest. This one deletes in bounded batches with a per-run ceiling, so
  #     a backlog drains over several nights instead of in one stop-the-world
  #     statement.
  #
  # SAFETY FLOOR. The only consumer of this table is
  # System::Fleet::Sensors::SdwanServiceHealthSensor, which correlates flows
  # inside a DB-driven window of its own. Retention shorter than that window
  # would delete rows the sensor is about to read, and its traffic-absent
  # branch would then report every service as silent — turning a cleanup job
  # into a false-alarm generator. The floor is therefore DERIVED from the
  # sensor's own window resolution rather than duplicated as a constant here,
  # so an operator who widens the sensor's window automatically widens the
  # retention floor with it.
  #
  # PARTITIONING TRADEOFF (noted for the operator, deliberately NOT implemented
  # here). The durable answer for a firehose table is native range partitioning
  # on observed_at with a DETACH/DROP of whole partitions, which reclaims space
  # in O(1) instead of O(rows) and never produces dead tuples for autovacuum to
  # chase. It was not done here because it is a destructive table rewrite
  # requiring a migration window, it changes the primary-key/index story (every
  # index becomes partition-local, and the existing service-correlation index
  # from IMP-624692c5054f would need rebuilding per partition), and it needs a
  # partition-maintenance job of its own. Batched deletion is the reversible
  # step that stops the bleeding; partitioning is the follow-up to schedule
  # deliberately once the table's steady-state size is known.
  class FlowSampleRetentionService
    # Deployment-wide SiteSetting keys: "<SETTING_PREFIX>.<name>".
    SETTING_PREFIX = "system.sdwan.flow_sample_retention"
    # Per-account overrides on Account#settings, flat-keyed to match that
    # column's convention: "<ACCOUNT_SETTING_PREFIX>_<name>".
    ACCOUNT_SETTING_PREFIX = "sdwan_flow_sample_retention"

    # Fallbacks only — every one of these is overridable per deployment and
    # per account. They are NOT the retention policy.
    DEFAULT_RETENTION_SECONDS = 7.days.to_i
    DEFAULT_BATCH_SIZE = 5_000
    DEFAULT_MAX_ROWS_PER_RUN = 500_000

    # How much wider than the sensor's correlation window the retention floor
    # sits. A multiple rather than an additive margin so it scales with an
    # operator who widens the sensor window substantially.
    SENSOR_WINDOW_SAFETY_MULTIPLE = 4

    # Upper bounds are the real guard here: a fat-fingered batch_size is what
    # would reproduce the unbounded-delete problem this service exists to avoid.
    MAX_BATCH_SIZE = 50_000
    MAX_ROWS_CEILING = 5_000_000

    def self.call(now: Time.current)
      new(now: now).call
    end

    # Public so specs and operators can ask what the floor currently is for an
    # account without running a sweep.
    def self.retention_floor_seconds(account)
      sensor_window = ::System::Fleet::Sensors::SdwanServiceHealthSensor
                        .new(account: account)
                        .flow_window_seconds
      sensor_window * SENSOR_WINDOW_SAFETY_MULTIPLE
    end

    def initialize(now: Time.current)
      @now = now
    end

    def call
      summary = {
        accounts: 0, deleted_total: 0, batches: 0,
        capped: false, floored: false, per_account: []
      }
      remaining = max_rows_per_run

      accounts_with_samples.find_each do |account|
        summary[:accounts] += 1
        break if remaining <= 0

        outcome = sweep_account(account, remaining)

        summary[:deleted_total] += outcome[:deleted]
        summary[:batches] += outcome[:batches]
        summary[:floored] ||= outcome[:floored]
        summary[:per_account] << outcome.slice(:account_id, :deleted, :retention_seconds, :floored)
        remaining -= outcome[:deleted]
      end

      # Capped means "there was more to delete than this run was allowed to
      # take" — the operator's signal that the backlog needs more nights, or a
      # higher ceiling, and the reason the table is not shrinking as fast as
      # expected.
      summary[:capped] = remaining <= 0 && more_to_delete?
      summary
    end

    private

    attr_reader :now

    def sweep_account(account, budget)
      configured = setting_int(account, "retention_seconds", DEFAULT_RETENTION_SECONDS)
      floor = self.class.retention_floor_seconds(account)
      retention = [ configured, floor ].max
      cutoff = now - retention.seconds

      deleted = 0
      batches = 0
      batch = batch_size(account)

      while deleted < budget
        take = [ batch, budget - deleted ].min
        ids = ::Sdwan::FlowSample
                .where(account_id: account.id)
                .where(observed_at: ...cutoff)
                .limit(take)
                .pluck(:id)
        break if ids.empty?

        # Delete by primary key rather than re-running the range predicate:
        # the row set is already chosen, and Postgres has no DELETE ... LIMIT,
        # so this is what keeps each statement bounded.
        deleted += ::Sdwan::FlowSample.where(id: ids).delete_all
        batches += 1
        break if ids.size < take
      end

      { account_id: account.id, deleted: deleted, batches: batches,
        retention_seconds: retention, floored: retention > configured }
    end

    def accounts_with_samples
      ::Account.where(id: ::Sdwan::FlowSample.select(:account_id).distinct)
    end

    # Only asked once, after the budget is spent, to distinguish "finished" from
    # "ran out of budget".
    def more_to_delete?
      accounts_with_samples.find_each do |account|
        retention = [ setting_int(account, "retention_seconds", DEFAULT_RETENTION_SECONDS),
                      self.class.retention_floor_seconds(account) ].max
        return true if ::Sdwan::FlowSample
                         .where(account_id: account.id)
                         .where(observed_at: ...(now - retention.seconds))
                         .exists?
      end
      false
    end

    def batch_size(account)
      setting_int(account, "batch_size", DEFAULT_BATCH_SIZE).clamp(1, MAX_BATCH_SIZE)
    end

    def max_rows_per_run
      # Deployment-wide only — a per-account ceiling would let one tenant
      # starve the others out of the run's budget.
      raw = ::SiteSetting.get("#{SETTING_PREFIX}.max_rows_per_run").to_i
      (raw.positive? ? raw : DEFAULT_MAX_ROWS_PER_RUN).clamp(1, MAX_ROWS_CEILING)
    end

    # Same resolution order the consuming sensor uses: per-account first
    # (this is a multi-tenant control plane), then deployment-wide, then the
    # fallback constant.
    def setting_int(account, suffix, fallback)
      raw = account.settings&.dig("#{ACCOUNT_SETTING_PREFIX}_#{suffix}").presence ||
            ::SiteSetting.get("#{SETTING_PREFIX}.#{suffix}")
      value = raw.to_i
      value.positive? ? value : fallback
    end
  end
end
