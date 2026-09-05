# frozen_string_literal: true

require "rails_helper"

# Plan reference: Decentralized Federation §I + P7.2.
#
# This endpoint was the FOURTH producer of "is the platform healthy?" and it
# disagreed with the other three. It carried its own copy of the subsystem
# probes, its rails entry was the literal `{ status: "ok" }`, and it had no
# fleet-instance subsystem at all — so the compute/platform dashboard could
# render every card green while NodeInstances sat in status "error", which is
# the same wrong answer offer 01a07024-d980 was filed for.
#
# It now delegates to System::Platform::CompositeHealthProbe. The response
# CONTRACT is preserved (a frontend consumes it — see
# frontend/src/features/system/types/platform-health.types.ts) and extended
# additively.
RSpec.describe "Api::V1::System::Platform::Health", type: :request do
  let(:account)  { create(:account) }
  let(:reader)   { user_with_permissions("system.platform.health.read", account: account) }
  let(:endpoint) { "/api/v1/system/platform/health" }

  # The union the frontend's StatusPill can render. It indexes a Record keyed
  # by exactly these four and dereferences the result with NO default, so a
  # fifth value is not a cosmetic problem — it is a TypeError that takes the
  # whole panel down. This is why `not_measured` is mapped to "unknown" on the
  # wire and carried separately in `measurement`.
  RENDERABLE_STATUSES = %w[ok degraded down unknown].freeze

  def health
    json_response_data["health"]
  end

  def get_health
    get endpoint, headers: auth_headers_for(reader)
  end

  def stub_probe(name, entry)
    allow_any_instance_of(System::Platform::CompositeHealthProbe)
      .to receive(:"probe_#{name}").and_return(entry)
  end

  describe "the preserved contract" do
    it "returns every legacy subsystem key" do
      get_health
      expect(response).to have_http_status(:ok)

      %w[rails worker redis postgres acme sdwan federation generated_at].each do |key|
        expect(health).to have_key(key), "missing #{key}"
      end
    end

    # Transcribed from frontend/src/features/system/types/platform-health.types.ts.
    # Every field below is one HealthPanel actually reads. They are optional in
    # TypeScript, so dropping one does not fail a type-check and does not throw
    # at runtime -- the card silently renders a dash. That silence is why this
    # oracle is exhaustive rather than a spot check: two fields (acme.count and
    # sdwan.virtual_ips) were in fact lost in the first draft of this adapter
    # and only a full transcription caught them. `error` is excluded: it is
    # present only on failure.
    CONTRACT_FIELDS = {
      "rails"      => %w[status uptime_seconds uptime_human db_connected rails_env ruby_version],
      "worker"     => %w[status stats last_seen_at],
      "redis"      => %w[status cache_store probe_at],
      "postgres"   => %w[status database size_bytes size_human active_connections],
      "acme"       => %w[status count by_status expiring_within_30d expiring_within_7d
                         failed_count nearest_expiry_at],
      "sdwan"      => %w[status networks_count virtual_ips bgp],
      "federation" => %w[status total active degraded suspended heartbeat_stale last_handshake_at]
    }.freeze

    it "keeps every field the dashboard cards read" do
      get_health

      CONTRACT_FIELDS.each do |subsystem, fields|
        fields.each do |field|
          expect(health[subsystem]).to have_key(field),
            "#{subsystem}.#{field} missing -- the card renders a dash instead"
        end
      end
    end

    it "keeps the nested shapes the cards destructure" do
      get_health

      expect(health["sdwan"]["virtual_ips"]).to include("count", "assigned")
      expect(health["sdwan"]["bgp"]).to include("total", "established")
      expect(health["worker"]["stats"]).to be_a(Hash)
    end

    # The crash guard. Every status the frontend receives must be one the
    # StatusPill Record actually has a key for.
    it "never emits a status the frontend cannot render" do
      stub_probe(:redis, { status: "not_measured", reason: "unreachable" })
      get_health

      statuses = health.values.filter_map { |v| v["status"] if v.is_a?(Hash) }
      expect(statuses).to all(be_in(RENDERABLE_STATUSES))
      expect(health["overall"]).to be_in(RENDERABLE_STATUSES)
    end
  end

  describe "the fleet-instance subsystem it used to lack" do
    it "reports instances in error, and overall is not ok" do
      node = create(:system_node, account: account)
      3.times { create(:system_node_instance, node: node, status: "error") }
      create(:system_node_instance, :running, node: node, last_heartbeat_at: 1.minute.ago)

      get_health

      expect(health["fleet_instances"]).to include("status", "error_count", "total")
      expect(health["fleet_instances"]["error_count"]).to eq(3)
      expect(health["fleet_instances"]["status"]).to eq("degraded")
      expect(health["overall"]).not_to eq("ok")
    end
  end

  describe "rails is no longer a constant" do
    it "reports what the probe found rather than a hardcoded ok" do
      stub_probe(:rails, { status: "degraded", observed_via: "in_process",
                           env: "test", ruby: RUBY_VERSION, pending_migrations: 4 })

      get_health

      expect(health["rails"]["status"]).to eq("degraded")
      expect(health["overall"]).not_to eq("ok")
    end

    # Scoped to CODE. An earlier version of this oracle matched the comment
    # that explains the old constant, which would have forced deleting the
    # explanation to make the spec pass -- the check punishing the record of
    # the defect instead of the defect.
    it "carries no literal ok status in the controller code" do
      source = File.read(
        Rails.root.join("..", "extensions", "system", "server", "app", "controllers",
                        "api", "v1", "system", "platform", "health_controller.rb")
      )
      code = source.lines.reject { |line| line.strip.start_with?("#") }.join

      expect(code).not_to match(/status:\s*"ok"/)
    end
  end

  describe "a probe that raises is not a subsystem that is down" do
    # THE behaviour change, and it is the fix rather than a regression. This
    # example used to assert "down" for a raising probe. A raise tells us our
    # PROBE broke; it does not tell us the subsystem failed. Reporting "down"
    # there is the same class of false claim as reporting "ok" for something
    # never measured — confident about something unobserved.
    it "surfaces a raising probe as unknown, tagged not_measured" do
      allow(::Sdwan::VirtualIp).to receive(:where).and_raise(StandardError, "synthetic")

      get_health

      expect(response).to have_http_status(:ok)
      expect(health["sdwan"]["status"]).to eq("unknown")
      expect(health["sdwan"]["measurement"]).to eq("not_measured")
    end

    it "does not let an unobserved subsystem make overall ok" do
      allow(::Sdwan::VirtualIp).to receive(:where).and_raise(StandardError, "synthetic")

      get_health

      expect(health["overall"]).not_to eq("ok")
      expect(health["not_measured"]).to include("sdwan")
    end

    it "still isolates the failure — other subsystems keep reporting" do
      allow(::Sdwan::VirtualIp).to receive(:where).and_raise(StandardError, "synthetic")

      get_health

      expect(response).to have_http_status(:ok)
      expect(health["rails"]["status"]).to eq("ok")
      expect(health["postgres"]["status"]).to eq("ok")
    end
  end

  describe "presentation enrichment can never change a status" do
    # size_human / active_connections / uptime are dashboard decoration. If
    # one of those queries fails, the card loses a number — it must not turn
    # a healthy Postgres into a down one, which is how a formatting bug would
    # otherwise become a false outage.
    it "keeps the probe's status when an enrichment query raises" do
      allow(ActiveRecord::Base.connection).to receive(:execute).and_call_original
      allow(ActiveRecord::Base.connection).to receive(:execute)
        .with(/pg_database_size/).and_raise(StandardError, "synthetic enrichment failure")

      get_health

      expect(response).to have_http_status(:ok)
      expect(health["postgres"]["status"]).to eq("ok")
    end
  end

  describe "the dashboard does not write a snapshot" do
    # The panel polls every 30 seconds. The MCP verb persists because an
    # operator asking is a discrete event worth a row; a poll is not, and
    # persisting one would write thousands of rows a day per open tab.
    it "reads without persisting" do
      expect { get_health }.not_to change { System::PlatformHealthSnapshot.count }
    end
  end

  it "forbids without health.read permission" do
    anon = create(:user, account: account)
    get endpoint, headers: auth_headers_for(anon)
    expect(response).to have_http_status(:forbidden)
  end
end
