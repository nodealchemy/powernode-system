# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # IMP-5b38cd356010 (APO-6b) — the REPLICATION-LAG SAMPLER for the
      # postgres cluster_member lane, and the producer
      # System::Ai::Skills::PromoteReplicaExecutor's data-loss gate shipped
      # without.
      #
      # THE GAP. IMP-93b83b5c82d8 landed the promote with a gate that reads the
      # LAST lag sample off the cluster_member peer
      # (metadata["cluster_pg"]["replication_lag_bytes"] / ["lag_sampled_at"])
      # against SiteSetting system.promote_replica.max_lag_bytes inside a
      # freshness window, and refuses on a missing or stale sample. Nothing
      # wrote that sample. So #lag_refusal refused EVERY real promote, the
      # operator ruling's auto arm ("proceed when the primary is confirmed
      # down AND the replica is caught up") was unreachable by construction,
      # and DR-3 was waiver-only: every promote had to pass
      # accept_data_loss: true. This sensor closes that.
      #
      # WHERE THE SAMPLE COMES FROM. The primary a cluster_member child streams
      # from is THIS platform's own database: PgReplicaSetupService creates the
      # physical slot on ActiveRecord::Base.connection, and the child's
      # pg-replica module dials the parent. So the lag is one catalog read on
      # the connection the tick already holds — pg_stat_replication joined to
      # pg_replication_slots by the slot name the setup service recorded —
      # with no credential, no ssh task and no agent change involved. The
      # slot name is the correlation key: it is the one thing the peer record
      # and the primary's catalog both carry.
      #
      # WHAT IT WRITES, AND WHY A SENSOR WRITES AT ALL. This is the ONE
      # SANCTIONED EXCEPTION to the read-side rule, and it is a closed one:
      # BaseSensor's class comment still states that rule without qualification
      # ("Sensors are pure read-side: they may not mutate the database") and
      # the sibling sensors restate it as binding — StorageAssignmentDriftSensor
      # after being rewritten for breaking it. Do not read this class as
      # licence to write from any other sensor. The exception is recorded in
      # docs/FLEET_SENSORS.md ("Adding a New Sensor"); amending BaseSensor's
      # own comment to name it is the outstanding half, DEFERRED rather than
      # blocked — this change adds a new sensor and deliberately edits none of
      # the shared sensor scaffolding — so until that amendment lands, the doc
      # and this block are where the exception is written down. A reader who
      # arrives at BaseSensor's unqualified rule first is not being misled by
      # it: the rule still binds every other sensor.
      #
      # It is sanctioned because this sensor is a SAMPLER (operator direction,
      # APO-6b batch 5): its product IS the two keys the executor reads, and a
      # sample has nowhere else to live — written onto the cluster_member peer
      # metadata the executor already reads, so no migration and no second
      # store are needed. The constraints that make it safe, and that any
      # future exception would have to meet: the write is confined to the
      # `cluster_pg` sub-hash, taken under the peer's row lock and re-checked
      # inside that lock, so a promote stamping the same record
      # (PromoteReplicaExecutor#stamp_promotion!) is never clobbered by a
      # sample taken a moment before it; and it goes through update_columns,
      # so the peer's own timestamps and callbacks are untouched — a sample is
      # not a heartbeat.
      #
      # WHAT IT DOES NOT WRITE. No walsender on the slot means the replica is
      # not streaming right now: that is not a lag of 0 and it is not a lag of
      # infinity — it is NO SAMPLE, so the last one is left as it stands and
      # the executor's freshness window is what retires it. A read that raises
      # (the platform's own DB in recovery, a catalog column the role cannot
      # see) is likewise unknown, and unknown writes nothing. The executor's
      # rule — absence and staleness are refusals — is only safe because this
      # sampler never manufactures a sample it did not take.
      #
      # THE SIGNAL. system.replica_lag_unsafe is emitted when the sample this
      # sensor just took is one the executor would REFUSE on — over the
      # DB-resolved bound, or not streaming at all — so a replica that has
      # silently stopped being a usable failover target is visible before the
      # day the primary dies. The bound is resolved from the executor's own
      # setting, not a second copy, so the sensor alarms exactly where the
      # gate refuses. Observation-level (system.observation, auto_approve, no
      # applier): there is nothing autonomous to DO about a lagging replica
      # that is safe — the answers are "wait" and "look at the primary's
      # write load", both a person's — and the dedicated notify-level category
      # is recorded as the follow-up.
      class ReplicaLagSensor < BaseSensor
        SIGNAL_KIND = "system.replica_lag_unsafe"

        # Fallbacks; overridable per account via SensorConfig as
        # "sample_interval_seconds" / "max_per_tick".
        #
        # 60s is one tick: a peer is re-sampled on every pass by default,
        # which keeps the sample comfortably inside the executor's 300s
        # freshness window (PromoteReplicaExecutor::DEFAULT_LAG_SAMPLE_MAX_AGE)
        # with room for a missed tick. An operator running many clusters
        # widens it; one who widens it past that window has made every
        # promote a waiver again, and the doc says so.
        SAMPLE_INTERVAL_SECONDS = 60
        MAX_PER_TICK = 25

        # Referenced, not restated: the keys and the setting are the
        # executor's, and the sensor exists to feed exactly those.
        EXECUTOR         = ::System::Ai::Skills::PromoteReplicaExecutor
        CLUSTER_PG_KEY   = EXECUTOR::CLUSTER_PG_KEY
        LAG_BYTES_KEY    = EXECUTOR::LAG_BYTES_KEY
        LAG_SAMPLED_KEY  = EXECUTOR::LAG_SAMPLED_KEY
        LAG_STATE_KEY    = "lag_sample_state"

        # NOT the executor's key, and deliberately not one it reads: when this
        # sensor last LOOKED at the peer, whether or not it got a sample.
        # See #due_for_sample? for why a sample stamp alone is not enough.
        LAG_ATTEMPT_KEY  = "lag_attempted_at"
        PEER_INSTANCE_KEY = EXECUTOR::PEER_INSTANCE_KEY

        # Only a peer PgReplicaSetupService has prepared and the promote has
        # not yet consumed. "promoted" means the child IS the primary now and
        # streams from nobody here.
        SAMPLEABLE_STATE = "ready"

        # The catalog read. pg_wal_lsn_diff against the replica's REPLAY
        # position, not its receive position: bytes received but not yet
        # replayed are still bytes a promote would lose. Cast to bigint —
        # the function returns numeric.
        LAG_SQL = <<~SQL.squish
          SELECT sr.state AS state,
                 pg_wal_lsn_diff(pg_current_wal_lsn(), sr.replay_lsn)::bigint AS lag_bytes
          FROM pg_replication_slots rs
          JOIN pg_stat_replication sr ON sr.pid = rs.active_pid
          WHERE rs.slot_name = $1
          LIMIT 1
        SQL

        def self.default_thresholds
          {
            "sample_interval_seconds" => SAMPLE_INTERVAL_SECONDS,
            "max_per_tick" => MAX_PER_TICK
          }
        end

        # lag_reader: a callable (slot_name) -> { bytes:, state: } | nil — the
        # test seam, the same shape PgReplicaSetupService's sql_executor takes.
        # nil means "no walsender on that slot"; a raise means "unknown".
        def initialize(account:, lag_reader: nil)
          super(account: account)
          @lag_reader = lag_reader || method(:read_lag)
        end

        # STALEST FIRST, then by id — never the raw id order. max_per_tick
        # truncates this list, so whatever sorts first is what gets looked at
        # when there are more clusters than budget; ordering by id would hand
        # the same low-id peers every slot on every tick and starve the rest
        # into permanent staleness, which is the executor refusing their
        # promotes — the exact defect this sensor exists to fix, reintroduced
        # for the peers that fell off the end. Ordering by attempt age makes
        # the budget a ROTATION: a peer looked at this tick sorts last on the
        # next one.
        def sense
          due = candidates.select { |peer| due_for_sample?(peer) }
                          .sort_by { |peer| [ last_attempt_at(peer) || Time.at(0).utc, peer.id ] }
          due.first(threshold("max_per_tick")).filter_map { |peer| sample!(peer) }
        end

        private

        # Every cluster_member PARENT peer on this account whose replication
        # record is prepared and names a slot — the only peers a lag can be
        # read for. Filtered in Ruby on the jsonb bag; the population is one
        # row per replica cluster, not per instance.
        def candidates
          ::System::FederationPeer
            .where(account_id: account.id, spawn_mode: "cluster_member", spawn_role: "parent")
            .order(:id)
            .to_a
            .select { |peer| sampleable?(cluster_pg_of(peer)) }
        end

        def sampleable?(cluster_pg)
          cluster_pg["state"] == SAMPLEABLE_STATE && cluster_pg["slot_name"].present?
        end

        def cluster_pg_of(peer)
          value = peer.metadata.is_a?(Hash) ? peer.metadata[CLUSTER_PG_KEY] : nil
          value.is_a?(Hash) ? value : {}
        end

        # Due on the last ATTEMPT, not the last successful sample. A replica
        # that is not streaming never gets a sample written (by design — see
        # the class comment), so a sample-stamp-only rule would leave it
        # permanently due: with more not-streaming peers than max_per_tick,
        # they would hold every budget slot for ever and healthy peers would
        # never be read at all. The attempt stamp is what makes the rotation
        # in #sense terminate. Falls back to the sample stamp for records
        # written before this key existed.
        def due_for_sample?(peer)
          taken = last_attempt_at(peer)
          taken.nil? || taken <= threshold("sample_interval_seconds").seconds.ago
        end

        def last_attempt_at(peer)
          cluster_pg = cluster_pg_of(peer)
          parse_time(cluster_pg[LAG_ATTEMPT_KEY]) || parse_time(cluster_pg[LAG_SAMPLED_KEY])
        end

        # One peer: read, write (if there is a sample), signal (if unsafe).
        # Per-peer rescue — one unreadable slot must not stop the others.
        def sample!(peer)
          cluster_pg = cluster_pg_of(peer)
          slot_name  = cluster_pg["slot_name"]
          reading    = @lag_reader.call(slot_name)

          if reading.nil?
            # No sample — but the LOOK happened, and it is the look the budget
            # rotation is bounded by. Stamping the attempt writes nothing the
            # executor reads, so the last sample still ages out on its own.
            touch_attempt!(peer)
            return unsafe_signal(peer, cluster_pg, reason: "not_streaming")
          end

          bytes = Integer(reading[:bytes].to_s, exception: false)
          if bytes.nil?
            Rails.logger.warn("[ReplicaLagSensor] unusable lag reading for slot #{slot_name}: #{reading.inspect}")
            touch_attempt!(peer)
            return nil
          end

          written = write_sample!(peer, bytes: bytes, state: reading[:state].to_s)
          return nil unless written

          max = max_lag_bytes
          return nil if bytes <= max

          unsafe_signal(peer, written, reason: "over_bound", extra: { "max_lag_bytes" => max })
        rescue StandardError => e
          Rails.logger.warn("[ReplicaLagSensor] sample failed for peer #{peer.id}: #{e.class}: #{e.message}")
          nil
        end

        # Default reader: the platform's own connection, which IS the primary
        # of every cluster_member child (see the class comment). Returns nil
        # when no walsender is active on the slot.
        #
        # A NULL lag has TWO causes and they are not the same event, so the
        # reader discriminates instead of blaming the likelier one:
        #
        #   * state present, replay_lsn NULL — a real walsender with no replay
        #     position yet ("startup", "backup", and briefly "catchup"). The
        #     replica is NOT a usable failover target right now, which is
        #     exactly what not-streaming means to this sensor: nil, so the peer
        #     is signalled and its last sample is left to age out. The state is
        #     logged, because "backup" for an hour is an operator's problem.
        #   * state NULL too — the row is there but its columns are hidden: a
        #     role without pg_read_all_stats sees pg_stat_replication rows for
        #     backends that are not its own with the activity columns NULLed.
        #     That is UNKNOWN, not a fact about the replica, so it raises and
        #     #sample! writes nothing.
        def read_lag(slot_name)
          bind = ::ActiveRecord::Relation::QueryAttribute.new(
            "slot_name", slot_name.to_s, ::ActiveModel::Type::String.new
          )
          row = ::ActiveRecord::Base.connection
                                    .exec_query(LAG_SQL, "ReplicaLagSensor", [ bind ])
                                    .first
          return nil if row.nil?

          if row["lag_bytes"].nil?
            if row["state"].blank?
              raise ::ActiveRecord::StatementInvalid,
                    "pg_stat_replication columns unreadable for slot #{slot_name} " \
                    "(does the platform role have pg_read_all_stats?)"
            end

            Rails.logger.info(
              "[ReplicaLagSensor] slot #{slot_name} walsender state=#{row['state']} has no replay_lsn yet; " \
              "treating as not streaming"
            )
            return nil
          end

          { bytes: row["lag_bytes"], state: row["state"] }
        end

        # Under the row lock, re-checked: a promote can stamp
        # cluster_pg.state = "promoted" between the candidate read and here,
        # and a sample must never overwrite that stamp. Returns the merged
        # record, or nil when the peer stopped being sampleable.
        def write_sample!(peer, bytes:, state:)
          merged = nil
          peer.with_lock do
            current = cluster_pg_of(peer)
            next unless sampleable?(current)

            now = Time.current.iso8601
            merged = current.merge(
              LAG_BYTES_KEY => bytes,
              LAG_SAMPLED_KEY => now,
              LAG_STATE_KEY => state,
              LAG_ATTEMPT_KEY => now
            )
            # update_columns: the sample is not a change to the PEER (no
            # touch of updated_at, no callbacks) — it is a fact about the
            # replica, kept on the record the executor reads.
            peer.update_columns(metadata: peer.metadata.merge(CLUSTER_PG_KEY => merged))
          end
          merged
        end

        # Record the LOOK on a peer no sample could be taken for. Same lock and
        # same in-lock re-check as the sample write, and it touches ONLY the
        # attempt key — a promote's stamp, and the last real sample, are both
        # left exactly as they stand. A read that RAISES is not stamped: that
        # failure mode (the catalog unreadable to the platform role, the DB in
        # recovery) is global rather than per-peer, so it starves nobody
        # relative to anybody, and stamping it would quietly widen the
        # effective sampling interval for every cluster at once.
        def touch_attempt!(peer)
          peer.with_lock do
            current = cluster_pg_of(peer)
            next unless sampleable?(current)

            peer.update_columns(
              metadata: peer.metadata.merge(
                CLUSTER_PG_KEY => current.merge(LAG_ATTEMPT_KEY => Time.current.iso8601)
              )
            )
          end
          nil
        end

        # The executor's bound, resolved the executor's way, so the alarm and
        # the refusal cannot disagree.
        def max_lag_bytes
          raw = defined?(::SiteSetting) ? ::SiteSetting.get(EXECUTOR::MAX_LAG_BYTES_SETTING) : nil
          value = Integer(raw.to_s, exception: false)
          value&.positive? ? value : EXECUTOR::DEFAULT_MAX_LAG_BYTES
        rescue StandardError
          EXECUTOR::DEFAULT_MAX_LAG_BYTES
        end

        def unsafe_signal(peer, cluster_pg, reason:, extra: {})
          signal(
            kind: SIGNAL_KIND,
            severity: :high,
            payload: {
              # federation_peer_id, NOT peer_id — the key the peer-scoped
              # FleetEvent readers (audit sealing, the excerpt API) index on.
              #
              # THAT KEY IS ALSO A DISCLOSURE, deliberately.
              # Api::V1::System::FederationApi::AuditExcerptsController selects
              # FleetEvents by `payload->>'federation_peer_id' = peer.id` and
              # returns the payload VERBATIM, with peering itself as the
              # credential. So this event becomes readable by the peer it
              # names — and only by that peer. slot_name and
              # replica_instance_id are that platform's own replication slot
              # and its own replica host: facts it already holds, and ones it
              # needs to act on a lag alarm about itself. Nothing about the
              # primary's other clusters rides along. A future key here that
              # is NOT the peer's own fact does not belong in this payload —
              # put it in the fingerprint or leave it in the logs.
              "federation_peer_id" => peer.id,
              "replica_instance_id" => (peer.metadata.is_a?(Hash) ? peer.metadata[PEER_INSTANCE_KEY] : nil),
              "slot_name" => cluster_pg["slot_name"],
              "reason" => reason,
              "replication_lag_bytes" => cluster_pg[LAG_BYTES_KEY],
              "last_sampled_at" => cluster_pg[LAG_SAMPLED_KEY],
              "lag_sample_state" => cluster_pg[LAG_STATE_KEY]
            }.merge(extra),
            fingerprint: "#{SIGNAL_KIND.delete_prefix('system.')}:#{peer.id}:#{reason}"
          )
        end

        def parse_time(value)
          return nil if value.blank?

          Time.zone.parse(value.to_s)
        rescue StandardError
          nil
        end
      end
    end
  end
end
