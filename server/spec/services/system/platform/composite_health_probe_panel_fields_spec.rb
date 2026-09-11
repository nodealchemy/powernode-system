# frozen_string_literal: true

require "rails_helper"

# The four fields the fleet HealthPanel showed (campaign 01a08c9b, C4 row 24's
# neighbours), now emitted by the composite probe in its own subsystem entries.
# The platform_subsystem contributor carries an entry as evidence minus its
# status, so the drawer shows these exactly as the probe measured them.
#
# THE RULE EVERY ARM BELOW PINS: a field that cannot be read is ABSENT, with
# the probe's reason beside it. It is never 0 and never a 1970 timestamp —
# both would read as a measurement.
RSpec.describe System::Platform::CompositeHealthProbe do
  let(:account) { create(:account) }
  let(:probe)   { described_class.new(account: account, source: "spec") }

  def entry(name)
    probe.send(:measure, name)
  end

  describe "rails: uptime of the reporting process" do
    it "reports uptime with the process's role, host and pid" do
      rails = entry(:rails)

      expect(rails).to include(pid: Process.pid, host: Socket.gethostname,
                               role: File.basename($PROGRAM_NAME))
      expect(rails[:uptime_seconds]).to be_a(Integer).and be >= 0
      expect(rails[:uptime_human]).to be_a(String)
      expect(rails[:boot_time]).to eq(Rails.application.config.boot_time.iso8601)
    end

    it "leaves uptime absent, with a reason, when this process recorded no boot time" do
      allow(Rails.application.config).to receive(:boot_time).and_return(nil)

      rails = entry(:rails)

      expect(rails).not_to have_key(:uptime_seconds)
      expect(rails).not_to have_key(:uptime_human)
      expect(rails[:uptime_reason]).to be_present
      expect(rails).to include(pid: Process.pid)
    end
  end

  describe "sidekiq: when the worker was last seen" do
    let(:worker_redis) { double("worker redis") }

    before do
      allow(Powernode::Redis).to receive(:new_worker_client).and_return(worker_redis)
      allow(worker_redis).to receive(:smembers).with("queues").and_return([])
      allow(worker_redis).to receive(:smembers).with("processes").and_return(%w[p1 p2])
    end

    it "is the newest heartbeat across the registered processes" do
      allow(worker_redis).to receive(:hget).with("p1", "beat").and_return("1757560000.5")
      allow(worker_redis).to receive(:hget).with("p2", "beat").and_return("1757560100.25")

      expect(entry(:sidekiq)[:last_seen_at]).to eq(Time.at(1_757_560_100.25).utc.iso8601)
    end

    it "is absent, with a reason, when no process carries a heartbeat" do
      allow(worker_redis).to receive(:hget).and_return(nil)

      sidekiq = entry(:sidekiq)
      expect(sidekiq).not_to have_key(:last_seen_at)
      expect(sidekiq[:last_seen_reason]).to be_present
    end
  end

  describe "redis: the cache store" do
    it "names the cache store this process uses" do
      expect(entry(:redis)[:cache_store]).to eq(Rails.cache.class.name)
    end

    it "still names it when Redis itself is unreachable, because it is read in-process" do
      allow(Powernode::Redis).to receive(:new_client).and_raise(Errno::ECONNREFUSED)

      redis = entry(:redis)
      expect(redis[:status]).to eq(described_class::DOWN)
      expect(redis[:cache_store]).to eq(Rails.cache.class.name)
    end
  end

  describe "postgres: database, size and active connections" do
    let(:connection) { ActiveRecord::Base.connection }

    it "reports the database name, its size and its active connections" do
      postgres = entry(:postgres)

      expect(postgres[:database]).to eq(connection.current_database)
      expect(postgres[:size_bytes]).to be_a(Integer).and be > 0
      expect(postgres[:active_connections]).to be_a(Integer).and be >= 1
    end

    it "leaves the size absent, with a reason, when the size query is refused" do
      allow(connection).to receive(:select_value).and_call_original
      allow(connection).to receive(:select_value).with(/pg_database_size/)
                                                  .and_raise(ActiveRecord::StatementInvalid, "permission denied")

      postgres = entry(:postgres)
      expect(postgres[:status]).to eq(described_class::OK)
      expect(postgres).not_to have_key(:size_bytes)
      expect(postgres[:size_bytes_reason]).to include("permission denied")
      expect(postgres[:database]).to eq(connection.current_database)
    end

    it "leaves active connections absent, with a reason, when pg_stat_activity is refused" do
      allow(connection).to receive(:select_value).and_call_original
      allow(connection).to receive(:select_value).with(/pg_stat_activity/)
                                                  .and_raise(ActiveRecord::StatementInvalid, "permission denied")

      postgres = entry(:postgres)
      expect(postgres[:status]).to eq(described_class::OK)
      expect(postgres).not_to have_key(:active_connections)
      expect(postgres[:active_connections_reason]).to include("permission denied")
    end
  end

  # The drawer reads a persisted snapshot, not the probe, so the fields have to
  # survive the snapshot write AND the contributor's evidence step. This writes
  # through the probe's own #persist and compares whole entries: the evidence
  # must be exactly what was stored, minus the status the condition carries.
  describe "through the platform_subsystem contributor" do
    let(:contributor)  { System::Status::Contributors::PlatformSubsystemContributor.new }
    let(:worker_redis) { double("worker redis") }
    let(:panel)        { %i[rails sidekiq redis postgres] }

    before do
      allow(Powernode::Redis).to receive(:new_worker_client).and_return(worker_redis)
      allow(worker_redis).to receive(:smembers).with("queues").and_return([])
      allow(worker_redis).to receive(:smembers).with("processes").and_return(%w[p1])
      allow(worker_redis).to receive(:hget).with("p1", "beat").and_return("1757560100.25")
    end

    def healthy_evidence(records, key)
      contributor.conditions_for(records.fetch(key)).find { |c| c["type"] == "Healthy" }["evidence"]
    end

    it "carries each panel entry into the Healthy evidence unchanged, minus status" do
      measured = panel.index_with { |name| entry(name) }
      probe.send(:persist, { overall: "ok", subsystems: measured, down: [], degraded: [], not_measured: [] })
      expect(System::PlatformHealthSnapshot.for_account(account).count).to eq(1)

      records = [].tap { |acc| contributor.each_component(account) { |r| acc << r } }.index_by(&:key)
      panel.each do |name|
        expect(healthy_evidence(records, name.to_s)).to eq(measured[name].as_json.except("status")),
                                                         "#{name} evidence differs from what the probe stored"
      end

      expect(healthy_evidence(records, "rails")).to include("role", "host", "pid", "uptime_seconds", "boot_time")
      expect(healthy_evidence(records, "sidekiq")).to include("last_seen_at")
      expect(healthy_evidence(records, "redis")).to include("cache_store")
      expect(healthy_evidence(records, "postgres")).to include("database", "size_bytes", "active_connections")
    end
  end
end
