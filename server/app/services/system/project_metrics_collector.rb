# frozen_string_literal: true

module System
  # Periodic sampler for project (infrastructure-mission) metrics.
  #
  # Wired into `FleetAutonomyService.tick!` so each fleet autonomy cycle (60s)
  # writes a fresh batch of `System::ProjectMetric` rows for every active
  # infrastructure mission. `ProjectSloSensor` then queries the latest rows
  # per mission to evaluate SLO/drift/cost signals.
  #
  # A metric with no source behind it records an HONEST `unavailable` sample
  # (observed nil, `source: "unavailable"`, a `note` saying why), never a
  # placeholder zero — the sensors' `.present?` guards then skip it instead of
  # reading a fabricated 0 as a real measurement. See #unavailable_sample; the
  # per-metric list of what is wired and what is not lives on #sample_all.
  #
  # Usage:
  #   System::ProjectMetricsCollector.collect!(mission: mission)
  #   System::ProjectMetricsCollector.collect!(mission: mission, correlation_id: tick_correlation)
  class ProjectMetricsCollector
    # How recent a runtime_metrics observation must be to describe the node's
    # CURRENT utilization. A heartbeat lands every ~30s, so 10 minutes
    # tolerates 20 consecutive misses before an instance stops contributing to
    # the mean. Past that the reading describes a node we have not heard from.
    #
    # Governs BOTH utilization samplers (memory_pct and, since APO-2a,
    # cpu_pct): they read the same document written by the same heartbeat, and
    # two windows over one observation would let the collector call the same
    # node fresh for one metric and stale for the other in a single tick.
    # Constant FALLBACK only — the effective value resolves from
    # SiteSetting first (see #sample_freshness).
    RUNTIME_SAMPLE_FRESHNESS = 10.minutes

    # Deployment-wide SiteSetting keys are "<SETTING_PREFIX>.<name>".
    SETTING_PREFIX = "system.project_metrics"

    # Deliberately does NOT say "the instances are not reporting": a fresh
    # runtime_metrics document can exist on every tick and still carry no
    # reading for this particular field (a pre-APO-2a agent for cpu_pct, an
    # unreadable /proc for either). Blaming heartbeat delivery would send an
    # operator to debug a subsystem that is working.
    MEMORY_UNREPORTED_NOTE = "no usable memory_pct in any fresh runtime_metrics observation " \
                             "(either the node reported no memory_free_kb, or the platform has no " \
                             "provisioned memory total to divide by \u2014 see NodeInstance#available_memory_mb)"
    CPU_UNREPORTED_NOTE = "no cpu_pct in any fresh runtime_metrics observation " \
                          "(the node agent measures it from /proc/stat; a pre-APO-2a " \
                          "agent, or one that could not read it, reports none)"

    # availability_pct measures HEARTBEAT LIVENESS, and an instance that has
    # never heartbeat at all is not evidence of an outage — it may be
    # mid-bootstrap, or carry no agent. It is excluded from the ratio and
    # surfaced as a coverage gap instead of being counted as unavailable.
    AVAILABILITY_UNREPORTED_NOTE = "none of this mission's instances that should be heartbeating has " \
                                   "ever done so (never-enrolled instances are not evidence of an outage)"
    AVAILABILITY_NO_LIVE_NOTE = "the mission has no live replicas to measure availability across " \
                                "(replica_count carries that fact)"
    # Live for capacity, but not running an agent that owes us a heartbeat.
    # Their silence is expected, so they leave the ratio rather than dragging
    # it down; `not_expected_to_report_count` keeps them visible.
    AVAILABILITY_NOT_EXPECTED_NOTE = "no replica of this mission is in a state where a heartbeat is " \
                                     "expected (stopped/rebooting replicas are silent by design)"

    METRIC_TYPE_MAP = {
      "p99_latency_ms"   => "latency",
      "availability_pct" => "latency",   # availability is co-evaluated w/ latency
      "cpu_pct"          => "utilization",
      "memory_pct"       => "utilization",
      "replica_count"    => "capacity",
      "region_count"     => "topology",
      "cost_usd_mtd"     => "cost",
      # IMP-25e75f960dee — aggregate SDWAN throughput across the peers of the
      # instances this mission provisioned. "utilization" rather than a new
      # METRIC_TYPE: it is bandwidth consumption, the same family as cpu/memory,
      # and inventing a sixth type would make System::ProjectMetric::METRIC_TYPES
      # a moving target for one metric.
      "sdwan_throughput_bytes_per_s" => "utilization"
    }.freeze

    # APO-2c — the currency `cost_usd_mtd` is denominated in. The metric name
    # says usd, ProjectSloSensor compares it against `cost_ceiling_usd`, and
    # the platform has no FX rates; a SKU priced in anything else is therefore
    # a price this metric cannot carry, not a price to convert.
    COST_CURRENCY = "USD"

    # APO-2c — the replica statuses a provider actually CHARGES COMPUTE for.
    # NodeInstance::LIVE_REPLICA_STATUSES is a CAPACITY scope, deliberately
    # wide so replica_count and the utilization means describe one fleet; it
    # also spans `pending`/`provisioning` (the VM may not exist at the provider
    # yet) and `stopped` (powered off — no instance-hour charge). Billing those
    # at the full catalog rate would OVERSTATE spend and fabricate exactly the
    # breach this metric exists to report honestly: a fleet stopped on the 2nd
    # TO SAVE MONEY would trip its own ceiling on the 30th. The transitional
    # states DO bill — the VM exists and is powered on through them.
    #
    # A capacity scope is not a billing scope; reusing it for a money question
    # is the category error, so the two sets are named separately.
    COST_ACCRUING_STATUSES = %w[running starting stopping rebooting].freeze

    COST_NO_LIVE_NOTE = "the mission has no live replicas to accrue cost for " \
                        "(replica_count carries that fact)"
    COST_UNPRICED_NOTE = "at least one accruing replica has no resolvable #{COST_CURRENCY} hourly " \
                         "rate (no provider_instance_type, no hourly_price in the catalog, a rate " \
                         "of 0 on a billed provider, or a rate quoted in another currency) " \
                         "\u2014 a partial sum would understate month-to-date spend and suppress " \
                         "a real ceiling breach"
    # Published on every LIVE cost sample. The accrual's two blind spots are
    # real and the operator must be able to see them: see #sample_cost_usd_mtd.
    COST_ACCRUAL_NOTE = "month-to-date accrual over the replicas STANDING NOW in a billed state. " \
                        "The platform records no instance state-transition history, so a replica " \
                        "torn down earlier this month contributes nothing (under-count) and a " \
                        "replica billed now that was stopped for part of the month is charged for " \
                        "the whole window (over-count) \u2014 compare instance_count, " \
                        "non_accruing_instance_count and provisioned_instance_count"

    # The metric this collector samples from Sdwan::Peer counters. Named once
    # so the sampler, the unit table and the state key cannot drift apart.
    THROUGHPUT_METRIC = "sdwan_throughput_bytes_per_s"

    # Key under ProjectMetric#value holding the per-peer counter snapshot this
    # tick observed. It is the NEXT tick's baseline — computation state, not an
    # observation (see #prune_superseded_peer_counters!).
    PEER_COUNTERS_KEY = "peer_counters"

    # Class-level entry point — mirrors the FleetAutonomyService.tick! shape
    # so callers don't have to construct the collector directly.
    def self.collect!(mission:, correlation_id: nil)
      new(mission: mission, correlation_id: correlation_id).collect!
    end

    def initialize(mission:, correlation_id: nil)
      @mission = mission
      @correlation_id = correlation_id || build_correlation_id
    end

    # Samples each metric in METRIC_TYPE_MAP and writes one ProjectMetric row
    # per metric. Returns the array of created records.
    def collect!
      return [] unless valid_mission?

      sampled_at = Time.current
      samples = sample_all
      records = []

      ::System::ProjectMetric.transaction do
        samples.each do |metric_name, payload|
          records << ::System::ProjectMetric.create!(
            mission_id: @mission.id,
            metric_name: metric_name,
            metric_type: METRIC_TYPE_MAP.fetch(metric_name),
            value: payload,
            sampled_at: sampled_at,
            correlation_id: @correlation_id
          )
        end
      end

      # The row we just superseded no longer needs to carry the peer counter
      # snapshot; only the newest one is a usable baseline.
      prune_superseded_peer_counters!

      records
    end

    private

    attr_reader :mission

    def valid_mission?
      return false if @mission.nil?
      return false unless @mission.respond_to?(:mission_type)
      @mission.mission_type.to_s == "infrastructure"
    end

    # Discovers a sample for every known metric. Sensors gracefully ignore
    # missing samples (observed: nil), so adding a metric here is
    # forward-compatible.
    #
    # Real sources are wired per-metric in `sample_metric`. Metrics whose
    # backend hasn't landed yet return an honest `unavailable` sample
    # (observed: nil) — never a fabricated zero (see `unavailable_sample`).
    # Intended sources for the still-unwired metrics:
    #   - p99_latency_ms: SDWAN edge probes (the Slo::TelemetryAdapter
    #     `metric.latency_ms` FleetEvent transport)
    #   - cpu_pct: WIRED (APO-2a), from the heartbeat's `cpu_pct` — which the
    #     agent MEASURES from /proc/stat deltas. Still NOT derived from
    #     load_average, here or anywhere: that is a /proc/loadavg-style STRING,
    #     converting it needs a per-instance core count (absent on
    #     physical/pivot nodes with no provider_instance_type), and load
    #     average folds in I/O-wait run-queue length, so it is not percent-busy
    #     even where a core count exists (IMP-938ee27f4921).
    #   - memory_pct: WIRED, from the heartbeat's memory_free_kb — see
    #     #sample_memory_pct and System::RuntimeMetricsWriter.
    #   - availability_pct: WIRED (APO-2a), from heartbeat liveness across the
    #     mission's live replicas — see #sample_availability_pct. This is the
    #     only sample that can tell DOWN from SLOW: a utilization metric of a
    #     node that stopped reporting merely goes stale.
    #   - cost_usd_mtd: WIRED (APO-2c), from the provider pricing catalog
    #     multiplied by this month's accrued instance-hours — see
    #     #sample_cost_usd_mtd. NOT a billing-engine invoice: the platform has
    #     no billing engine, and this is the accrual an operator's declared
    #     `cost_ceiling_usd` is checked against.
    def sample_all
      instance_ids = resolvable_instance_ids
      METRIC_TYPE_MAP.keys.each_with_object({}) do |metric_name, samples|
        samples[metric_name] = sample_metric(metric_name, instance_ids)
      end
    end

    # Per-metric dispatch. Each metric reads its real source where one is
    # wired; everything else returns an honest `unavailable` sample so the
    # SLO sensor skips it instead of reading a fabricated zero as a real
    # measurement. Wiring a new real source is a one-branch change here.
    def sample_metric(metric_name, instance_ids)
      sample_one(metric_name, instance_ids)
    rescue StandardError => e
      # IMP-7684d3f8658a — PER-METRIC CONTAINMENT, mirroring the rescue
      # sample_sdwan_throughput has carried since IMP-25e75f960dee. Without it
      # a raise anywhere in one sampler costs the mission its ENTIRE batch for
      # the tick: sample_all has no rescue of its own and
      # FleetAutonomyService#collect_project_metrics! only rescues per MISSION,
      # so a single bad JSONB document or a pricing lookup blowing up took
      # replica_count and region_count — and therefore drift detection — dark
      # with it, silently.
      #
      # It sits on the DISPATCHER rather than being copied into each sampler so
      # a metric wired later cannot be the one that forgets it. The sampler
      # that owns extra state on failure still rescues internally
      # (sample_sdwan_throughput unsets its counter-banking flag) and never
      # reaches here.
      #
      # The result is the same honest `unavailable` sample an unwired metric
      # records — observed nil, never a fabricated zero — so the sensors skip
      # the metric for this tick instead of reading a failure as a measurement.
      Rails.logger.warn(
        "[ProjectMetricsCollector] #{metric_name} sampling failed for " \
        "mission=#{@mission&.id}: #{e.class}: #{e.message}"
      )
      unavailable_sample(metric_name, "#{metric_name} sampling failed: #{e.class}")
    end

    def sample_one(metric_name, instance_ids)
      case metric_name
      when "replica_count" then sample_replica_count(instance_ids)
      when "region_count"  then sample_region_count(instance_ids)
      when THROUGHPUT_METRIC then sample_sdwan_throughput(instance_ids)
      when "memory_pct"      then sample_memory_pct(instance_ids)
      when "cpu_pct"         then sample_cpu_pct(instance_ids)
      when "availability_pct" then sample_availability_pct(instance_ids)
      when "cost_usd_mtd"     then sample_cost_usd_mtd(instance_ids)
      else unavailable_sample(metric_name)
      end
    end

    # replica_count = instances this mission provisioned that the control plane
    # still expects to serve — NodeInstance::LIVE_REPLICA_STATUSES, which the
    # `live_replicas` scope is the single spelling of.
    #
    # `unavailable` when the mission has no resolvable instances (we genuinely
    # can't tell); a resolvable mission with zero live instances reports a real
    # 0 — a meaningful "nothing came up" drift signal, not a stub.
    #
    # IMP-797a87dbd0bd: this filtered on `where.not(status: "terminated")`
    # alone, so an `error` instance — a replica the platform had marked FAILED
    # — still counted as capacity. ProjectSloSensor#detect_drift only fires on
    # observed != expected, so a mission whose replica died reported its full
    # count and drifted silently, in exactly the case the signal exists for.
    #
    # Not `active`: that scope (pending/provisioning/running/stopped) also
    # drops `starting`/`rebooting`, which would make every routine reboot read
    # as capacity loss and provoke a replacement provision — trading a silent
    # failure for a noisy false one.
    def sample_replica_count(instance_ids)
      return unavailable_sample("replica_count") if instance_ids.empty?

      count = ::System::NodeInstance.where(id: instance_ids).live_replicas.count
      live_sample("replica_count", count)
    end

    # region_count = distinct provider regions across the mission's live
    # instances, on the SAME liveness definition as replica_count.
    #
    # Sharing it is the point: the two metrics are sampled from one instance
    # set in one tick and land in one observation hash, so a region_count that
    # counted errored rows while replica_count did not would describe two
    # different fleets in the same breath. Semantically it is also the right
    # filter on its own — a region whose only instance has errored is one the
    # mission no longer occupies, and reporting it as still-occupied overstates
    # geographic coverage the same way the replica count overstated capacity.
    def sample_region_count(instance_ids)
      return unavailable_sample("region_count") if instance_ids.empty?

      count = ::System::NodeInstance.where(id: instance_ids)
                                    .live_replicas
                                    .distinct.count(:provider_region_id)
      live_sample("region_count", count)
    end

    # IMP-25e75f960dee — aggregate SDWAN throughput for this mission, derived
    # from the per-peer WireGuard byte counters IMP-ab73cc2fca65 put on
    # Sdwan::Peer. Those counters were measured, transmitted and persisted but
    # had no autonomy consumer at all: no sensor read them, and the metric
    # vocabulary had no slot to put them in. This is the slot.
    #
    # ATTRIBUTION — mission -> instances -> peers.
    # `resolvable_instance_ids` already resolves a mission to the NodeInstance
    # ids it provisioned (via the plan's recorded step outputs); it is the same
    # derivation replica_count and region_count are built on, and reusing it is
    # deliberate. `Sdwan::Peer belongs_to :node_instance` is a single non-null
    # FK, so the last hop is exact rather than heuristic: a peer counts for
    # this mission iff its node_instance is one this mission provisioned.
    # Nothing here filters by module name (the traversal Peer#k3s_host? needs)
    # because that walk goes the OTHER way — peer down to the node's module
    # list — and is not on this path.
    #
    # Also scoped by account_id, which the sibling samplers are not: the
    # instance ids come out of plan metadata, which is data, and a metric must
    # never aggregate another tenant's peers if that data is ever wrong.
    #
    # WHAT THE NUMBER MEANS: the sum over the mission's peers of
    # (rx + tx) / that peer's own observation interval. Both directions of
    # every tunnel endpoint are counted, so traffic between two instances of
    # the SAME mission contributes four times (each endpoint's rx and its tx).
    # It is a measure of fabric activity, not of distinct payload bytes, and an
    # operator declaring `min_throughput_bytes_per_s` is declaring against that
    # definition.
    #
    # RATE, NOT TOTAL, and the two-sample requirement that follows from it.
    # The stored counters are RAW CUMULATIVE kernel totals for the current
    # interface incarnation, so a single sample says nothing about an interval.
    # The rate needs a baseline, and the only place to keep one is the previous
    # ProjectMetric row — so this sampler both reads and writes
    # PEER_COUNTERS_KEY. Until a second observation exists the metric is
    # honestly `unavailable` (observed nil), never 0.
    #
    # PER-PEER differencing, then summed — NOT the difference of two sums. A
    # peer whose interface was recreated restarts its counter at zero; against
    # an aggregate that either shows up as a decrease (and Peer.counter_delta
    # would then hand back the whole aggregate as one interval's traffic — an
    # enormous fabricated spike) or is masked entirely by the other peers'
    # growth. Differencing each peer against its own baseline is the only
    # arrangement in which the reset rule means what it says.
    #
    # FULL COVERAGE OR NOTHING — the aggregate's own null-vs-zero rule, and the
    # one that is easiest to get wrong. Per-peer discipline is not enough: a
    # sum over the peers that happened to be ratable, published as `live`, is a
    # fabricated zero one level up. A mission with five peers of which four
    # have stalled clocks and one is measured-and-idle would otherwise report
    # observed 0.0 with source "live", and because a FLOOR breach fires on
    # `observed < target`, an incomplete sum can only ever UNDERSTATE and so
    # can only ever fabricate a breach — never suppress a real one. So a sum
    # that does not cover every peer of the mission's instances is not this
    # mission's throughput and is not published as an observation. The counts
    # stay in the blob so an operator can see WHY it went dark.
    def sample_sdwan_throughput(instance_ids)
      return unavailable_sample(THROUGHPUT_METRIC, "mission has no resolvable instances") if instance_ids.empty?
      return unavailable_sample(THROUGHPUT_METRIC, "Sdwan::Peer unavailable") unless defined?(::Sdwan::Peer)

      peer_rows = mission_peer_rows(instance_ids)
      return unavailable_sample(THROUGHPUT_METRIC, "mission's instances carry no SDWAN peers") if peer_rows.empty?

      current = measured_peer_counters(peer_rows)

      # Resolved unconditionally, BEFORE the no-measurement return: this same
      # row is the prune target, and a tick that measures nothing must leave
      # the standing baseline alone rather than orphan it (an orphaned map is
      # never read again and never pruned again).
      baseline = previous_peer_counters

      if current.empty?
        return unavailable_sample(
          THROUGHPUT_METRIC,
          "none of this mission's #{peer_rows.size} peer(s) has reported WireGuard counters yet"
        ).merge("peer_count" => peer_rows.size, "rated_peer_count" => 0)
      end

      rates = current.filter_map { |peer_id, now| peer_rate(baseline[peer_id], now) }
      @banked_peer_counters = true

      sample =
        if rates.size == peer_rows.size
          live_sample(THROUGHPUT_METRIC, rates.sum.round(2))
        else
          unavailable_sample(
            THROUGHPUT_METRIC,
            "partial coverage: #{rates.size} of #{peer_rows.size} peer(s) yielded a measurable interval"
          )
        end

      sample.merge(
        PEER_COUNTERS_KEY => current,
        "peer_count" => peer_rows.size,
        "rated_peer_count" => rates.size
      )
    rescue StandardError => e
      # A raise here would cost the mission its ENTIRE metric batch for the
      # tick — sample_all has no per-metric rescue and collect_project_metrics!
      # only rescues per mission — taking replica_count and region_count, and
      # therefore drift detection, dark with it. This sampler is the one doing
      # arithmetic on JSONB-sourced data, so it owns the risk and contains it.
      # Unset: the flag may already be true if the raise came after the merge
      # was set up, and pruning on a tick that published no snapshot would
      # strip the standing baseline with nothing to replace it.
      @banked_peer_counters = false
      Rails.logger.warn(
        "[ProjectMetricsCollector] throughput sampling failed for mission=#{@mission&.id}: #{e.class}: #{e.message}"
      )
      unavailable_sample(THROUGHPUT_METRIC, "throughput sampling failed: #{e.class}")
    end

    # EVERY peer of the mission's instances, measured or not. The unmeasured
    # ones are what make `peer_count` a coverage denominator rather than a
    # count of whatever happened to report.
    def mission_peer_rows(instance_ids)
      ::Sdwan::Peer
        .where(account_id: @mission.account_id, node_instance_id: instance_ids)
        .pluck(:id, :rx_bytes, :tx_bytes, :counters_sampled_at)
    end

    # The subset with a COMPLETE counter observation. All three columns are
    # independently nullable and each carries its own meaning, so a row missing
    # any of them is NOT MEASURED and is dropped rather than defaulted:
    # `rx_bytes` nil is not 0 bytes, and without counters_sampled_at there is
    # no clock to divide by. Keyed by peer id so the next tick can difference
    # each peer against ITSELF.
    #
    # counters_sampled_at is stored as an epoch float. It is stamped SERVER-SIDE
    # at heartbeat receipt (NodeApi::SdwanController#peer_observation_columns),
    # not by the node — immune to node clock skew, but not to delivery jitter,
    # so a reordered heartbeat can present a lower counter under a newer stamp.
    # It is still the only usable clock: the heartbeat write is an
    # update_columns that deliberately leaves updated_at alone.
    def measured_peer_counters(peer_rows)
      peer_rows.each_with_object({}) do |(id, rx, tx, at), acc|
        next if rx.nil? || tx.nil? || at.nil?

        acc[id.to_s] = { "rx" => rx, "tx" => tx, "at" => at.to_f }
      end
    end

    # Baseline snapshot from the most recent throughput row THAT CARRIES ONE —
    # not simply the most recent row. A tick that measured nothing writes a row
    # with no snapshot, and keying off "most recent row" would then read an
    # empty baseline and blind the metric for a second tick while stranding the
    # real snapshot on an older row forever. Memoized: sample_all runs this
    # once per collect!, and the row it finds is also the prune target.
    def previous_peer_counters
      return @previous_peer_counters if defined?(@previous_peer_counters)

      @previous_throughput_row = ::System::ProjectMetric
        .where(mission_id: @mission.id, metric_name: THROUGHPUT_METRIC)
        .where("jsonb_exists(value, ?)", PEER_COUNTERS_KEY)
        .order(sampled_at: :desc, id: :desc)
        .first

      stored = @previous_throughput_row&.value
      @previous_peer_counters =
        (stored.is_a?(Hash) && stored[PEER_COUNTERS_KEY].is_a?(Hash) ? stored[PEER_COUNTERS_KEY] : {})
    end

    # Bytes per second for ONE peer across ITS OWN observation interval, or nil
    # when that interval is not measurable. Returns a Float; 0.0 is a real
    # measurement (the peer was up and moved nothing) and must reach the caller
    # as such.
    #
    # The Numeric guard is not decoration. `baseline` is decoded from JSONB
    # written by an earlier run of this code, and the doctrine this whole
    # change is built on forbids a bare `.to_f` on anything that can be nil:
    # `nil.to_f` is 0.0, which here would make `elapsed` the whole Unix epoch
    # and divide a peer's cumulative counter by fifty-five years — a fabricated
    # near-zero rate that passes every downstream guard and reads as a critical
    # breach.
    #
    # `elapsed <= 0` is the stalled-agent case: a peer whose heartbeat stopped
    # keeps its last counters_sampled_at, so the tick sees the same observation
    # twice. Contributing 0.0 for it would report a silent peer as a quiet one
    # — the same nil-vs-zero error one level up. It contributes nothing, and
    # the coverage gate then refuses to publish the partial sum at all.
    def peer_rate(baseline, now)
      return nil unless baseline.is_a?(Hash)
      return nil unless baseline["at"].is_a?(Numeric) && now["at"].is_a?(Numeric)

      elapsed = now["at"] - baseline["at"]
      return nil unless elapsed.positive?

      rx = ::Sdwan::Peer.counter_delta(older: baseline["rx"], newer: now["rx"])
      tx = ::Sdwan::Peer.counter_delta(older: baseline["tx"], newer: now["tx"])
      return nil if rx.nil? || tx.nil?

      (rx + tx) / elapsed
    end

    # The peer counter map is COMPUTATION STATE, not an observation: only the
    # newest one is ever read, as the next tick's baseline. system_project_metrics
    # has no retention sweep and this collector writes a row per mission every
    # 60s, so leaving the snapshot on every superseded row would grow the table
    # by peer_count x 1440 map entries per mission per day, forever. Stripping
    # it from the row this run superseded keeps exactly one live copy.
    #
    # Guarded on @banked_peer_counters: prune ONLY when this run actually wrote
    # a replacement. A tick that measured nothing writes no snapshot, and
    # pruning the standing one there would throw away the baseline a resumed
    # fabric needs — the map would be gone and the row that held it would be
    # the only place it ever existed.
    #
    # `observed` — the measurement itself — is never touched, so the time series
    # stays intact and replayable. Best-effort: a metrics row that could not be
    # tidied must not fail the collection that produced a good sample.
    def prune_superseded_peer_counters!
      return unless @banked_peer_counters

      row = @previous_throughput_row
      return unless row

      stored = row.value
      return unless stored.is_a?(Hash) && stored.key?(PEER_COUNTERS_KEY)

      row.update_column(:value, stored.except(PEER_COUNTERS_KEY))
    rescue StandardError => e
      Rails.logger.warn(
        "[ProjectMetricsCollector] peer counter prune failed for mission=#{@mission&.id}: #{e.class}: #{e.message}"
      )
    end

    # A real measurement read from a wired backend.
    # memory_pct = mean percent-USED across the mission instances that have a
    # FRESH runtime_metrics observation (System::RuntimeMetricsWriter, written
    # from the heartbeat's memory_free_kb).
    #
    # `unavailable` — never a fabricated 0.0 — whenever we genuinely cannot
    # tell: no resolvable instances, none reporting, or every observation
    # stale. That distinction is the whole point of this collector: an
    # operator reading a fleet where nothing has reported must see "we don't
    # know", not "utilization: 0%", which reads as healthy.
    #
    # An instance with a stale observation is EXCLUDED from the mean rather
    # than counted at its last value — a node that stopped reporting is not
    # evidence of its old utilization. `measured_instance_count` vs
    # `instance_count` exposes that gap so a reader can see the sample covers
    # only part of the fleet instead of inferring full coverage.
    def sample_memory_pct(instance_ids)
      return unavailable_sample("memory_pct", "mission has no resolvable instances") if instance_ids.empty?

      instances = live_mission_instances(instance_ids)
      cutoff = sample_freshness.ago

      percents = instances.filter_map { |instance| memory_used_percent(instance, cutoff) }
      return unavailable_sample("memory_pct", MEMORY_UNREPORTED_NOTE) if percents.empty?

      live_sample("memory_pct", (percents.sum / percents.size).round(2)).merge(
        "measured_instance_count" => percents.size,
        "instance_count" => instances.size
      )
    end

    # APO-2a — cpu_pct, the load signal that is not memory. Mean percent-busy
    # across the mission instances with a FRESH runtime_metrics observation
    # carrying a `cpu_pct`, on exactly the memory_pct rules: stale excluded
    # (a node that stopped reporting is not evidence of its old utilization),
    # `unavailable` — never a fabricated 0.0 — when nothing reported, and the
    # measured-vs-total counts published so a reader sees the coverage.
    #
    # NOT derived from load_average. The agent measures the busy/idle split
    # itself (agent/internal/runtime/cpustat.go) precisely because the
    # conversion the server would have to do is the one IMP-938ee27f4921
    # refused: a load average is a run-queue length that folds in I/O wait, and
    # turning it into a percentage needs a core count the platform does not
    # reliably have. So an instance whose document carries only load_average
    # contributes NOTHING here — the honest outcome, not a fallback.
    def sample_cpu_pct(instance_ids)
      return unavailable_sample("cpu_pct", "mission has no resolvable instances") if instance_ids.empty?

      instances = live_mission_instances(instance_ids)
      cutoff = sample_freshness.ago

      percents = instances.filter_map { |instance| reported_cpu_percent(instance, cutoff) }
      return unavailable_sample("cpu_pct", CPU_UNREPORTED_NOTE) if percents.empty?

      live_sample("cpu_pct", (percents.sum / percents.size).round(2)).merge(
        "measured_instance_count" => percents.size,
        "instance_count" => instances.size
      )
    end

    # APO-2a — availability_pct: the fraction of this mission's live replicas
    # that are STILL REPORTING, which is the only sample here that can tell
    # "down" from "slow". A node that stops heartbeating does not make its
    # utilization metrics alarming; they simply go stale and drop out of the
    # mean, so a fleet that has half died reads as a healthy half fleet.
    #
    # WHAT THE NUMBER MEANS: 100 * (replicas expected to heartbeat whose
    # last_heartbeat_at is within the silence window) / (replicas expected to
    # heartbeat that have EVER heartbeat).
    #
    # THE DENOMINATOR IS THE EVER-REPORTED SET, not every live replica. An
    # instance that has never heartbeat is not evidence of an outage — it may
    # be mid-bootstrap, or a provider VM carrying no agent at all — and
    # counting it as unavailable would manufacture a breach on every mission
    # that provisions faster than its nodes enrol. It is excluded and shown as
    # the gap between `measured_instance_count` and `instance_count`. When
    # NOTHING has ever reported the sample is `unavailable`, never 0.
    #
    # A measured 0.0 (every reporting replica silent) IS published: that is a
    # total outage, the single most important reading this metric can carry.
    #
    # ONLY REPLICAS THAT OWE US A HEARTBEAT ARE MEASURED. .live_replicas is
    # the CAPACITY population — it includes stopped/stopping/rebooting/pending
    # /provisioning — and those are silent BY DESIGN. Counting them as
    # unavailable would make a routine reboot read as a 50% outage and, with
    # ProjectSloSensor's 99.5% default target, fire a breach and a scale-out
    # proposal off an operator's own `stop`. That is precisely the false
    # positive sample_replica_count refuses above, and it does not become
    # acceptable on a different scope. They are partitioned out and published
    # as `not_expected_to_report_count`.
    #
    # BOTH THE POPULATION AND THE WINDOW ARE InstanceStatusSensor'S, resolved
    # through the one operator seam that already owns them
    # (HEARTBEAT_EXPECTED_STATUSES / silent_threshold_seconds), so this
    # collector and that sensor cannot drift apart about WHICH nodes should be
    # answering or HOW LONG silence is tolerated — the same invariant
    # IMP-ca485128072e preserved between InstanceStatusSensor and
    # InstanceUnrecoverableSensor.
    #
    # ONE DELIBERATE DIFFERENCE REMAINS: the sensor signals a never-heartbeat
    # `running` instance as silent (a failed enrolment is worth an operator's
    # attention); this metric excludes it, because a mission that provisions
    # faster than its nodes enrol has not suffered an outage. The gap is
    # visible as measured_instance_count vs instance_count rather than hidden
    # in the ratio.
    def sample_availability_pct(instance_ids)
      return unavailable_sample("availability_pct", "mission has no resolvable instances") if instance_ids.empty?

      instances = live_mission_instances(instance_ids)
      return unavailable_sample("availability_pct", AVAILABILITY_NO_LIVE_NOTE) if instances.empty?

      expected, silent_by_design = instances.partition do |instance|
        ::System::Fleet::Sensors::InstanceStatusSensor::HEARTBEAT_EXPECTED_STATUSES.include?(instance.status)
      end

      coverage = {
        "available_instance_count" => 0,
        "measured_instance_count" => 0,
        "not_expected_to_report_count" => silent_by_design.size,
        "instance_count" => instances.size
      }

      if expected.empty?
        return unavailable_sample("availability_pct", AVAILABILITY_NOT_EXPECTED_NOTE).merge(coverage)
      end

      reporting = expected.select { |instance| instance.last_heartbeat_at.present? }
      if reporting.empty?
        return unavailable_sample("availability_pct", AVAILABILITY_UNREPORTED_NOTE).merge(coverage)
      end

      window = silent_threshold_seconds
      cutoff = Time.current - window.seconds
      available = reporting.count { |instance| instance.last_heartbeat_at >= cutoff }

      live_sample("availability_pct", ((available.to_f / reporting.size) * 100).round(2)).merge(
        coverage.merge(
          "available_instance_count" => available,
          "measured_instance_count" => reporting.size,
          "silent_threshold_seconds" => window
        )
      )
    end

    # APO-2c — cost_usd_mtd: this month's accrued spend for the mission,
    # the input `system.project_cost_breach` never had. The signal's whole
    # lane existed (ProjectSloSensor#cost_breach_signal, DecisionEngine's
    # SIGNAL_BINDINGS row and its remediation applier) but nothing produced
    # the observation, so `return nil if observed.nil?` meant no budget on any
    # mission could ever trip it.
    #
    # WHAT THE NUMBER MEANS: sum over the mission's ACCRUING replicas of
    # (that replica's USD hourly rate) x (its hours inside the current
    # calendar month). It is an ACCRUAL computed from the provider pricing
    # catalog, not an invoice — the platform has no billing engine, and an
    # operator's `cost_ceiling_usd` is a declaration about this fleet's own
    # spend, which is exactly what this measures.
    #
    # ONLY THE REPLICAS A PROVIDER CHARGES COMPUTE FOR (see
    # COST_ACCRUING_STATUSES). The capacity scope .live_replicas is not a
    # billing scope: it also holds `pending`/`provisioning` (no VM at the
    # provider yet) and `stopped` (powered off), and charging those the full
    # catalog rate would fabricate the very breach this metric is here to
    # report honestly. Non-accruing replicas still ride the sample as
    # `non_accruing_instance_count`, so the fleet view stays whole.
    #
    # WHAT IT CANNOT SEE, DISCLOSED ON EVERY LIVE SAMPLE (COST_ACCRUAL_NOTE).
    # The platform records no instance state-transition history — no
    # termination timestamp, no stop/start ledger; `updated_at` moves on every
    # later write and dates nothing in particular. So the accrual is wrong in
    # BOTH directions at the edges: a replica torn down earlier this month
    # contributes nothing (under-count), and a replica billed now that spent
    # part of the month stopped is charged for the whole window (over-count).
    # It is therefore an ESTIMATE, not a bound, and it is not called one. The
    # alternative — refusing to publish at all once the record is imperfect —
    # would return the metric to permanent silence for every mission that has
    # ever replaced or cycled an instance, i.e. reinstate the defect this
    # sampler exists to fix. Closing either gap needs a state-transition
    # timestamp on NodeInstance, at which point #billable_hours is the one
    # place that changes.
    #
    # FULL COVERAGE OR NOTHING over the replicas it does bill, on the same
    # rule as sample_sdwan_throughput and for the mirror-image reason. A
    # ceiling breach fires on `observed > target`, so DROPPING an unpriced
    # accruing replica from the sum can only ever lower it and therefore only
    # ever SUPPRESS a real breach — silently, in the one case a budget guard
    # is for. So an unpriced ACCRUING replica takes the whole sample to
    # `unavailable` (the operator's fix is a catalog rate, and the count
    # points at it), never to a partial number wearing `source: "live"`. A
    # non-accruing replica is exempt: it contributes a real zero whatever the
    # catalog says about its SKU, so its missing rate blanks nothing.
    #
    # A LOCAL-HYPERVISOR REPLICA IS A REAL ZERO, not an unknown: it accrues no
    # provider charge, so it neither adds to the sum nor poisons it. Which
    # providers those are is CORE's judgement
    # (Ai::Provisioning::CostEstimatorService::LOCAL_PROVIDER_TYPES, which the
    # plan-time quote already prices at zero), read rather than re-declared —
    # two opinions about which hardware is free would let the forecast and the
    # accrual disagree about the same fleet.
    def sample_cost_usd_mtd(instance_ids)
      return unavailable_sample("cost_usd_mtd", "mission has no resolvable instances") if instance_ids.empty?

      instances = live_mission_instances(instance_ids)
      accruing = instances.select { |instance| COST_ACCRUING_STATUSES.include?(instance.status.to_s) }
      coverage = {
        "instance_count" => instances.size,
        "provisioned_instance_count" => instance_ids.size,
        "non_accruing_instance_count" => instances.size - accruing.size
      }
      return unavailable_sample("cost_usd_mtd", COST_NO_LIVE_NOTE).merge(coverage) if instances.empty?

      now = Time.current
      window_start = now.beginning_of_month

      unpriced = 0
      total = accruing.sum do |instance|
        hourly = hourly_rate_for(instance)
        if hourly.nil?
          unpriced += 1
          next 0.0
        end
        hourly * billable_hours(instance, window_start, now)
      end

      coverage = coverage.merge(
        "unpriced_instance_count" => unpriced,
        "window_start" => window_start.iso8601
      )

      if unpriced.positive?
        return unavailable_sample("cost_usd_mtd", COST_UNPRICED_NOTE).merge(coverage)
      end

      # `currency` rides only samples the metric could actually denominate: on
      # an unavailable row there is no figure to denominate, and the non-USD
      # case would be told in USD the very thing it could not be told in.
      live_sample("cost_usd_mtd", total.round(2))
        .merge(coverage)
        .merge("currency" => COST_CURRENCY, "note" => COST_ACCRUAL_NOTE)
    end

    # Hours this instance has been accruing INSIDE the current month.
    # `created_at` is the only start the platform records, clamped to the
    # month boundary so an instance running since March bills 1st-to-now
    # rather than its whole life. A start in the future (clock skew, a
    # backdated fixture) bills nothing rather than a negative.
    #
    # Called only for a replica that is accruing NOW, and there is no ledger
    # of when it started and stopped being so — a replica that was down for
    # part of the month is billed for it. This method is the single place a
    # state-transition timestamp would land; see #sample_cost_usd_mtd.
    def billable_hours(instance, window_start, now)
      started = instance.created_at
      return 0.0 if started.nil?

      from = [ started, window_start ].max
      return 0.0 if from >= now

      (now - from).to_f / 1.hour
    end

    # This instance's USD hourly rate, or nil when the catalog cannot price it
    # — which takes the whole sample to `unavailable` (see the caller).
    #
    # Memoized per (SKU, region) pair: a homogeneous fleet is the normal case
    # and #pricing_row_for issues a query, which would otherwise run once per
    # replica on every 60s tick.
    def hourly_rate_for(instance)
      key = [ instance.provider_instance_type_id, instance.provider_region_id ]
      @hourly_rates ||= {}
      return @hourly_rates[key] if @hourly_rates.key?(key)

      @hourly_rates[key] = resolve_hourly_rate(instance)
    end

    # ZERO IS NOT A PRICE on a billed provider. Compute costs something, so a
    # 0 (or absent) rate is an unpopulated catalog row, and treating it as
    # free would let a whole unpriced fleet report $0.00 as a LIVE reading —
    # the fabricated zero every other sampler here refuses. Core's plan-time
    # quote makes the same call (`compute_unpriced = compute_monthly <= 0`).
    # The one legitimate zero is local hardware, handled above it.
    def resolve_hourly_rate(instance)
      type = instance.provider_instance_type
      return nil unless type
      return 0.0 if local_hardware?(type)

      row = type.pricing_row_for(instance.provider_region)
      return nil unless row
      return nil unless row.effective_currency.to_s.casecmp(COST_CURRENCY).zero?

      rate = row.hourly_price.to_f
      rate.positive? ? rate : nil
    rescue StandardError => e
      Rails.logger.warn("[ProjectMetricsCollector] pricing lookup failed for instance=#{instance.id}: " \
                        "#{e.class}: #{e.message}")
      nil
    end

    def local_hardware?(type)
      return false unless defined?(::Ai::Provisioning::CostEstimatorService)

      provider = type.provider
      return false unless provider

      ::Ai::Provisioning::CostEstimatorService::LOCAL_PROVIDER_TYPES.include?(provider.provider_type.to_s)
    rescue StandardError
      false
    end

    # The mission's live replicas, loaded ONCE per collect!.
    #
    # .live_replicas for the SAME reason sample_region_count shares it: a
    # utilization or availability figure that counted an errored row while
    # replica_count did not would describe two different fleets in the same
    # breath — and an out-of-memory node's last reading is exactly the one that
    # would skew a mean. .includes keeps available_memory_mb's
    # provider_instance_type lookup — and, since APO-2c, the cost sampler's
    # walk to that type's provider and to the instance's region — off the 60s
    # tick's N+1 path.
    #
    # Memoized because three samplers now ask for the same set in one tick;
    # re-querying would also let them disagree about the fleet mid-tick. Keyed
    # by the id set rather than a bare ivar so the memo can never answer a
    # question it was not asked.
    def live_mission_instances(instance_ids)
      @live_mission_instances ||= {}
      @live_mission_instances[instance_ids] ||= ::System::NodeInstance
                                               .where(id: instance_ids)
                                               .live_replicas
                                               .includes(:provider_region,
                                                         provider_instance_type: :provider)
                                               .to_a
    end

    # The effective staleness window for a runtime_metrics observation:
    # operator SiteSetting first, the constant as the fallback. Memoized for
    # one collect! so a mid-tick change cannot make two samplers disagree
    # about which observations are fresh.
    def sample_freshness
      return @sample_freshness if defined?(@sample_freshness)

      raw = ::SiteSetting.get("#{SETTING_PREFIX}.sample_freshness_seconds")
      seconds = raw.to_s.strip.match?(/\A\d+\z/) ? raw.to_i : 0
      @sample_freshness = seconds.positive? ? seconds.seconds : RUNTIME_SAMPLE_FRESHNESS
    rescue StandardError => e
      Rails.logger.warn("[ProjectMetricsCollector] sample freshness fell back to its default: #{e.class}: #{e.message}")
      @sample_freshness = RUNTIME_SAMPLE_FRESHNESS
    end

    # Resolved through InstanceStatusSensor rather than re-declared here: that
    # sensor OWNS the definition of a silent instance, and a second constant
    # would be a second opinion about which nodes are down.
    def silent_threshold_seconds
      @silent_threshold_seconds ||= ::System::Fleet::Sensors::InstanceStatusSensor
                                    .resolved_threshold("silent_threshold_seconds", account: @mission.account)
    rescue StandardError => e
      Rails.logger.warn("[ProjectMetricsCollector] silent threshold fell back to its default: #{e.class}: #{e.message}")
      ::System::Fleet::Sensors::InstanceStatusSensor::SILENT_THRESHOLD.to_i
    end

    # The instance's runtime_metrics document, or nil when it is absent or
    # too old to describe the node's current state. ONE definition of
    # freshness for every field the document carries.
    def fresh_runtime_metrics(instance, cutoff)
      doc = instance.config&.dig(::System::RuntimeMetricsWriter::CONFIG_KEY)
      return nil unless doc.is_a?(Hash)

      observed_at = begin
        Time.iso8601(doc["observed_at"].to_s)
      rescue ArgumentError, TypeError
        nil
      end
      return nil if observed_at.nil? || observed_at < cutoff

      doc
    end

    # nil (not 0.0) unless this instance shipped a real percentage. 0.0 is a
    # genuinely idle node and MUST survive as a reading, so the guard is an
    # explicit type+range test rather than a truthiness check — which would
    # silently drop the idle case and turn a quiet fleet into "we don't know".
    # Out of 0..100 is a broken producer, not a reading (the ingest writer
    # already refuses those; this is the reader's own defence against a
    # document written before it did).
    def reported_cpu_percent(instance, cutoff)
      doc = fresh_runtime_metrics(instance, cutoff)
      return nil unless doc

      value = doc["cpu_pct"]
      return nil unless value.is_a?(Numeric)
      return nil unless value >= 0 && value <= 100

      value.to_f
    end

    # nil (not 0.0) whenever this instance cannot contribute a real reading:
    # no document, unparseable/stale timestamp, no memory_free_kb, or no known
    # provisioned total to divide by. Each of those is "unknown", and coercing
    # any of them to a number would put a fabricated value into the mean.
    def memory_used_percent(instance, cutoff)
      doc = fresh_runtime_metrics(instance, cutoff)
      return nil unless doc

      free_kb = doc["memory_free_kb"]
      return nil unless free_kb.is_a?(Integer) && free_kb >= 0

      total_mb = instance.available_memory_mb
      return nil if total_mb.nil? || total_mb.to_i <= 0

      total_kb = total_mb.to_i * 1024

      # free > total is not a 0% reading, it is two numbers that do not agree —
      # a placeholder provider_instance_type or an understated config["memory_mb"]
      # hint against real metal. Clamping it to 0.0 would publish "0% memory
      # used" (maximum headroom) as a LIVE sample, indistinguishable from an
      # instance genuinely reporting all memory free. An impossible reading is
      # UNKNOWN; route it to the same exclusion path as a missing one.
      return nil if free_kb > total_kb

      used = ((total_kb - free_kb).to_f / total_kb) * 100
      used.clamp(0.0, 100.0) # float-rounding guard only; the real range is enforced above
    end

    def live_sample(metric_name, observed)
      { "observed" => observed, "unit" => unit_for(metric_name), "source" => "live" }
    end

    # Honest stand-in for a metric whose telemetry backend isn't wired yet.
    # `observed: nil` (NOT 0) so ProjectSloSensor's `.present?` guards skip it
    # rather than treating a fabricated zero as a real sample. Replaces the
    # prior zero-valued stub, which risked false SLO/availability violations
    # the moment any single real metric was wired alongside it.
    def unavailable_sample(metric_name, note = nil)
      {
        "observed" => nil,
        "unit" => unit_for(metric_name),
        "source" => "unavailable",
        "note" => note || "no telemetry backend wired for #{metric_name} yet (TODO metrics-backend)"
      }
    end

    # Resolves the NodeInstance ids this mission provisioned, via the
    # provisioning runner's recorded step outputs. The mission soft-links to
    # its Ai::GoalPlan through configuration["plan"]["plan_id"] (stamped by
    # PlanComposerService); each completed step records produced ids under
    # metadata["last_outputs"]["outputs"]["node_instance_ids"] — the same seam
    # the runner uses for cross-step data flow.
    #
    # THE WRITER HAS THREE SHAPES; THIS READS ALL OF THEM (IMP-9978fcf23a27).
    #
    # SkillCompositionRunner#result_outputs is
    #   result[:data] || result["data"] || result[:outputs] || result["outputs"] || result.to_h
    # and #record_outputs stores whatever that returns VERBATIM as
    # metadata["last_outputs"]. So the envelope decides the depth:
    #
    #   :data present  -> last_outputs is the payload; ids under its "outputs"
    #   :outputs only  -> last_outputs IS the outputs hash; ids at the TOP level
    #   neither        -> last_outputs is result.to_h; ids at the TOP level
    #
    # The nested level was wrong here until IMP-3431f73dabe6: digging the ids at
    # the top always returned nil, so this returned [], so replica_count and
    # region_count short-circuited to `unavailable` and ProjectSloSensor never
    # saw a live sample.
    #
    # WHAT THE ENUMERATION FOUND, recorded because the severity claim depends on
    # it: every executor SkillCompositionRunner.resolve_executor can reach today
    # — 58 under System::Ai::Skills, 2 under Ai::Skills, CrudFactory subclasses
    # included — returns BaseSkillExecutor#success, i.e. { success: true, data: }.
    # So the narrowed dig was NOT silently broken again; the other two branches
    # are live in the writer with no executor behind them. Reading all three is
    # hardening against the writer's actual contract rather than repair of an
    # active defect, and it is what stops the next executor that returns a bare
    # envelope from re-creating IMP-3431f73dabe6 in silence.
    #
    # deep_stringify_keys matches the sibling readers (VerificationService
    # #last_outputs, AdaptationDispatchService#produced_instance_ids), which all
    # normalize before digging; this reader was the only one that did not.
    #
    # Returns [] (never raises) so a mission without a resolvable plan
    # degrades to `unavailable`, not a false zero.
    def resolvable_instance_ids
      cfg = @mission.configuration
      plan_id = cfg.is_a?(Hash) ? cfg.dig("plan", "plan_id") : nil
      return [] if plan_id.blank?

      plan = ::Ai::GoalPlan.find_by(id: plan_id)
      return [] unless plan

      plan.steps.where(status: "completed").flat_map { |step|
        step_instance_ids(step)
      }.compact.uniq
    rescue StandardError => e
      Rails.logger.warn("[ProjectMetricsCollector] instance resolution failed for mission=#{@mission&.id}: #{e.class}: #{e.message}")
      []
    end

    # Both depths, unioned. Deduping is left to the single `.uniq` in the
    # caller, which already spans every step — a second one here would be a
    # redundant mechanism, and two guards for one property make a mutation test
    # unable to tell which of them is actually holding the line.
    def step_instance_ids(step)
      meta = step.metadata.is_a?(Hash) ? step.metadata : {}
      outs = meta["last_outputs"] || meta[:last_outputs] || {}
      return [] unless outs.is_a?(Hash)

      outs = outs.deep_stringify_keys
      Array(outs.dig("outputs", "node_instance_ids")) + Array(outs["node_instance_ids"])
    end

    def unit_for(metric_name)
      case metric_name
      when "p99_latency_ms" then "ms"
      when "availability_pct", "cpu_pct", "memory_pct" then "percent"
      when "replica_count", "region_count" then "count"
      when "cost_usd_mtd" then "usd"
      # BYTES per second, not bits. WireGuard's counters are byte totals and
      # nothing on this path multiplies by 8, so the name and the unit both
      # say bytes; "bps" would have invited a silent 8x error at the first
      # dashboard that read it.
      when THROUGHPUT_METRIC then "bytes_per_s"
      end
    end

    def build_correlation_id
      bucket = (Time.current.to_i / 60).to_s
      "project_metrics:#{@mission&.id}:#{bucket}"
    end
  end
end
