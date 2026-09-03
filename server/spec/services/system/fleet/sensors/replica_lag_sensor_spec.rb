# frozen_string_literal: true

require "rails_helper"

# IMP-5b38cd356010 (APO-6b) — the SAMPLER PromoteReplicaExecutor's data-loss
# gate was shipped without.
#
# THE DEFECT. IMP-93b83b5c82d8 landed the promote with a gate that reads the
# last replication-lag sample (cluster_pg.replication_lag_bytes /
# cluster_pg.lag_sampled_at on the cluster_member peer) against SiteSetting
# system.promote_replica.max_lag_bytes inside a freshness window. Nothing wrote
# that sample — grep over server/, worker/, agent/, modules/ found only the
# executor and its spec — so #lag_refusal refused EVERY real promote and the
# only reachable path was an operator passing accept_data_loss: true. The
# operator ruling's auto arm (proceed when the primary is confirmed down AND
# the replica is caught up) was unreachable by construction.
#
# THE FIX (operator direction, batch 5): a sensor on the fleet tick samples
# pg_stat_replication on the primary — which is the platform's OWN database
# connection, the same one System::ClusterMember::PgReplicaSetupService created
# the slot on — and writes the two keys onto the peer metadata the executor
# already reads. No migration; the interval is SensorConfig-tunable.
#
# The oracles below are stated against the CONSUMER: a sample the sensor writes
# must be one the executor's own #lag_refusal accepts, not merely one that looks
# right in the metadata.
RSpec.describe System::Fleet::Sensors::ReplicaLagSensor do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }

  let(:node_template) { create(:system_node_template, account: account) }
  let(:replica_instance) do
    node = create(:system_node, account: account, node_template: node_template)
    create(:system_node_instance, node: node, name: "pg-replica", status: "running")
  end

  let(:slot_name) { "powernode_repl_0123456789abcdef0123456789abcdef" }

  # The replication record ClusterMemberPgReplicaSetupService stamps, BEFORE
  # any sample exists — the shape every real peer had when the executor shipped.
  def ready_cluster_pg(extra = {})
    {
      "slot_name" => slot_name,
      "primary_host" => "10.0.0.9",
      "primary_port" => 5432,
      "credential_id" => "cred",
      "state" => "ready",
      "prepared_at" => 1.day.ago.iso8601
    }.merge(extra)
  end

  def cluster_member_peer(account: self.account, cluster_pg: ready_cluster_pg, spawn_role: "parent")
    create(:system_federation_peer, :platform, account: account,
           spawn_mode: "cluster_member", spawn_role: spawn_role,
           metadata: { "node_instance_id" => replica_instance.id, "cluster_pg" => cluster_pg })
  end

  let!(:peer) { cluster_member_peer }

  let(:reads) { [] }
  let(:sample) { { bytes: 4096, state: "streaming" } }
  let(:lag_reader) do
    lambda do |slot|
      reads << slot
      sample
    end
  end

  let(:sensor) { described_class.new(account: account, lag_reader: lag_reader) }

  # The gate this sensor exists to feed. Called directly so the oracle is the
  # executor's OWN verdict on the written sample, not a restatement of it.
  def executor_lag_refusal(peer)
    System::Ai::Skills::PromoteReplicaExecutor
      .new(account: account, agent: nil, user: nil)
      .send(:lag_refusal, peer.reload)
  end

  describe "registration and tunables" do
    it "runs on the Fleet Autonomy tick" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end

    it "declares the sampling interval and the per-tick bound as SensorConfig-tunable keys" do
      expect(described_class.sensor_key).to eq("replica_lag")
      expect(described_class.default_thresholds).to eq(
        "sample_interval_seconds" => described_class::SAMPLE_INTERVAL_SECONDS,
        "max_per_tick" => described_class::MAX_PER_TICK
      )
    end

    # Without this, deleting the routing edge leaves the sensor emitting a kind
    # the DecisionEngine classifies as UNBOUND — a silent lane — with every
    # other example here still green. Nothing else in the suite pins it: the
    # SIGNAL_BINDINGS block in decision_engine_spec.rb only constrains bindings
    # that HAVE a skill, and there is no global "every emitted kind is bound"
    # equality.
    it "routes its signal through the DecisionEngine as an observation with no applier" do
      expect(System::Fleet::DecisionEngine::SIGNAL_BINDINGS.fetch(described_class::SIGNAL_KIND))
        .to eq(skill: nil, action_category: "system.observation")
    end
  end

  describe "the sample the executor reads" do
    it "refuses the promote before any sample exists (the shipped state)" do
      expect(executor_lag_refusal(peer)).to include("carries no replication lag sample")
    end

    it "writes replication_lag_bytes + lag_sampled_at onto the peer so the executor's gate passes" do
      sensor.sense

      cluster_pg = peer.reload.metadata["cluster_pg"]
      expect(reads).to eq([ slot_name ])
      expect(cluster_pg["replication_lag_bytes"]).to eq(4096)
      expect(cluster_pg["lag_sample_state"]).to eq("streaming")
      expect(Time.zone.parse(cluster_pg["lag_sampled_at"])).to be_within(5.seconds).of(Time.current)
      # The setup record survives the merge — the sample is ADDED to it.
      expect(cluster_pg).to include("slot_name" => slot_name, "state" => "ready", "credential_id" => "cred")

      expect(executor_lag_refusal(peer)).to be_nil
    end

    it "emits nothing for a caught-up replica" do
      expect(sensor.sense).to eq([])
    end

    it "reads the slot the setup service created, by its recorded name, on the platform's own connection" do
      # The default reader, against THIS test database: no replica streams from
      # it, so the answer is "not streaming" — and the point is that the query
      # runs, i.e. the channel the sampler uses exists. A typo in a catalog
      # column name surfaces here rather than on a fleet tick.
      expect(described_class.new(account: account).send(:read_lag, slot_name)).to be_nil
    end
  end

  describe "the sampling interval (SensorConfig-tunable)" do
    it "does not re-sample a peer whose sample is younger than sample_interval_seconds" do
      peer.update!(metadata: peer.metadata.merge(
        "cluster_pg" => ready_cluster_pg("replication_lag_bytes" => 10, "lag_sampled_at" => 10.seconds.ago.iso8601)
      ))

      sensor.sense

      expect(reads).to eq([])
      expect(peer.reload.metadata.dig("cluster_pg", "replication_lag_bytes")).to eq(10)
    end

    it "re-samples once the stored sample is older than the interval" do
      peer.update!(metadata: peer.metadata.merge(
        "cluster_pg" => ready_cluster_pg("replication_lag_bytes" => 10,
                                         "lag_sampled_at" => (described_class::SAMPLE_INTERVAL_SECONDS + 5).seconds.ago.iso8601)
      ))

      sensor.sense

      expect(reads).to eq([ slot_name ])
      expect(peer.reload.metadata.dig("cluster_pg", "replication_lag_bytes")).to eq(4096)
    end

    it "honours an operator override of the interval" do
      peer.update!(metadata: peer.metadata.merge(
        "cluster_pg" => ready_cluster_pg("replication_lag_bytes" => 10, "lag_sampled_at" => 10.seconds.ago.iso8601)
      ))
      System::Fleet::SensorConfig.upsert_for(account: account, sensor: "replica_lag",
                                             config: { "sample_interval_seconds" => 5 })

      sensor.sense

      expect(reads).to eq([ slot_name ])
    end

    it "bounds the reads per tick by max_per_tick" do
      3.times { cluster_member_peer }
      System::Fleet::SensorConfig.upsert_for(account: account, sensor: "replica_lag",
                                             config: { "max_per_tick" => 2 })

      sensor.sense

      expect(reads.size).to eq(2)
    end

    # THE STARVATION THIS ORDERING EXISTS TO PREVENT. A peer that is not
    # streaming never gets a sample written — by design — so a due-list keyed
    # on the SAMPLE stamp and ordered by id would hand that peer the same
    # budget slot on every tick, for ever. The healthy peer behind it would
    # never be read, its sample would age past the executor's freshness
    # window, and its promote would go back to being waiver-only: this task's
    # own defect, reintroduced for whoever sorts last.
    #
    # Stated across TWO ticks, because one tick cannot tell "rotates" from
    # "got lucky": the budget is one read, and the two ticks must not read the
    # same peer.
    it "rotates the per-tick budget instead of starving a peer behind an unreadable one" do
      quiet_slot   = peer.metadata.dig("cluster_pg", "slot_name")
      healthy_slot = "powernode_repl_ffffffffffffffffffffffffffffffff"
      healthy = cluster_member_peer(cluster_pg: ready_cluster_pg("slot_name" => healthy_slot))
      expect(peer.id).to be < healthy.id # the id order the naive scan would follow

      System::Fleet::SensorConfig.upsert_for(account: account, sensor: "replica_lag",
                                             config: { "max_per_tick" => 1 })
      rotating = lambda do |slot|
        reads << slot
        slot == quiet_slot ? nil : { bytes: 4096, state: "streaming" }
      end

      described_class.new(account: account, lag_reader: rotating).sense
      expect(reads).to eq([ quiet_slot ])

      described_class.new(account: account, lag_reader: rotating).sense

      expect(reads).to eq([ quiet_slot, healthy_slot ])
      expect(healthy.reload.metadata.dig("cluster_pg", "replication_lag_bytes")).to eq(4096)
      expect(executor_lag_refusal(healthy)).to be_nil
    end

    # The attempt stamp is the sensor's own bookkeeping, and it must stay
    # invisible to the gate: stamping a look at a replica that gave no sample
    # must not read as a sample.
    it "records the attempt on an unreadable peer without writing anything the executor reads" do
      described_class.new(account: account, lag_reader: ->(_slot) { reads << :quiet; nil }).sense

      cluster_pg = peer.reload.metadata["cluster_pg"]
      expect(Time.zone.parse(cluster_pg["lag_attempted_at"])).to be_within(5.seconds).of(Time.current)
      expect(cluster_pg).not_to have_key("replication_lag_bytes")
      expect(cluster_pg).not_to have_key("lag_sampled_at")
      expect(executor_lag_refusal(peer)).to include("carries no replication lag sample")
    end
  end

  describe "the population" do
    it "samples only cluster_member PARENT peers whose replication record is ready" do
      cluster_member_peer(spawn_role: "child")
      cluster_member_peer(cluster_pg: ready_cluster_pg("state" => "promoted"))
      cluster_member_peer(cluster_pg: ready_cluster_pg("slot_name" => nil))
      cluster_member_peer(account: other_account)
      create(:system_federation_peer, :platform, account: account, spawn_mode: "out_of_band",
             spawn_role: "parent", metadata: { "cluster_pg" => ready_cluster_pg })

      sensor.sense

      expect(reads).to eq([ slot_name ])
    end
  end

  describe "the write itself (the read-side exception's constraints)" do
    it "never clobbers a promote that stamped the record between selection and the write" do
      # The race the in-lock re-check exists for: PromoteReplicaExecutor
      # #stamp_promotion! flips cluster_pg.state to "promoted" while this tick
      # is mid-flight. A sample taken a moment earlier must not land on top of
      # it — the child IS the primary now and streams from nobody here.
      promoting_reader = lambda do |slot|
        reads << slot
        peer.update!(metadata: peer.metadata.merge(
          "cluster_pg" => ready_cluster_pg("state" => "promoted", "promoted_at" => Time.current.iso8601)
        ))
        { bytes: 4096, state: "streaming" }
      end

      expect(described_class.new(account: account, lag_reader: promoting_reader).sense).to eq([])

      cluster_pg = peer.reload.metadata["cluster_pg"]
      expect(reads).to eq([ slot_name ])
      expect(cluster_pg["state"]).to eq("promoted")
      expect(cluster_pg["promoted_at"]).to be_present
      expect(cluster_pg).not_to have_key("replication_lag_bytes")
    end

    it "does not touch the peer's own timestamps — a sample is not a heartbeat" do
      before_updated_at = peer.reload.updated_at

      sensor.sense

      expect(peer.reload.metadata.dig("cluster_pg", "replication_lag_bytes")).to eq(4096)
      expect(peer.reload.updated_at).to eq(before_updated_at)
    end
  end

  describe "an UNSAFE replica — the state in which the executor would refuse" do
    it "signals over-bound lag, with the bound resolved from the executor's own SiteSetting" do
      SiteSetting.set(System::Ai::Skills::PromoteReplicaExecutor::MAX_LAG_BYTES_SETTING, 1000,
                      setting_type: "integer")

      signals = sensor.sense

      expect(signals.map(&:kind)).to eq([ described_class::SIGNAL_KIND ])
      signal = signals.first
      expect(signal.severity).to eq(:high)
      expect(signal.fingerprint).to eq("replica_lag_unsafe:#{peer.id}:over_bound")
      expect(signal.payload).to include(
        "federation_peer_id" => peer.id,
        "replica_instance_id" => replica_instance.id,
        "slot_name" => slot_name,
        "reason" => "over_bound",
        "replication_lag_bytes" => 4096,
        "max_lag_bytes" => 1000
      )
      # The sample is STILL written: over-bound is a fact about the replica,
      # and the executor's own bound (not the sensor) is what refuses on it.
      expect(peer.reload.metadata.dig("cluster_pg", "replication_lag_bytes")).to eq(4096)
      expect(executor_lag_refusal(peer)).to include("over the 1000-byte bound")
    end

    context "when the replica is not streaming (no walsender on its slot)" do
      let(:sample) { nil }

      it "signals it and leaves the LAST sample untouched — the age window is what retires it" do
        stale = 10.minutes.ago.iso8601
        peer.update!(metadata: peer.metadata.merge(
          "cluster_pg" => ready_cluster_pg("replication_lag_bytes" => 10, "lag_sampled_at" => stale)
        ))

        signals = sensor.sense

        expect(signals.map(&:fingerprint)).to eq([ "replica_lag_unsafe:#{peer.id}:not_streaming" ])
        expect(signals.first.payload).to include("reason" => "not_streaming", "last_sampled_at" => stale)
        cluster_pg = peer.reload.metadata["cluster_pg"]
        expect(cluster_pg["replication_lag_bytes"]).to eq(10)
        expect(cluster_pg["lag_sampled_at"]).to eq(stale)
        expect(executor_lag_refusal(peer)).to include("older than the")
      end
    end

    context "when a walsender has no replay position yet (state present, replay_lsn NULL)" do
      # pg reports state "startup"/"backup" with a NULL replay_lsn. That is a
      # replica which is NOT a usable failover target right now — the same
      # thing not-streaming means here — and it must NOT be diagnosed as the
      # pg_read_all_stats permissions gap, which is the case where the row's
      # columns are hidden (state NULL too).
      let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter) }
      let(:reader) { described_class.new(account: account) }

      def stub_row(row)
        allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
        allow(connection).to receive(:exec_query).and_return([ row ])
      end

      it "reads as not-streaming, not as a permissions gap" do
        stub_row("state" => "backup", "lag_bytes" => nil)

        expect(reader.send(:read_lag, slot_name)).to be_nil
      end

      it "raises UNKNOWN when the row's columns are hidden from the role" do
        stub_row("state" => nil, "lag_bytes" => nil)

        expect { reader.send(:read_lag, slot_name) }
          .to raise_error(ActiveRecord::StatementInvalid, /pg_read_all_stats/)
      end
    end

    context "when the read itself fails" do
      let(:lag_reader) { ->(_slot) { raise ActiveRecord::StatementInvalid, "recovery is in progress" } }

      it "writes nothing, signals nothing and does not break the tick — unknown is not a sample" do
        expect { expect(sensor.sense).to eq([]) }.not_to raise_error
        expect(peer.reload.metadata["cluster_pg"]).not_to have_key("replication_lag_bytes")
      end
    end
  end
end
