# frozen_string_literal: true

require "rails_helper"

# Comprehensive stabilization sweep P7.1 — verifies the boot_replay
# endpoint scopes to operator's account, filters to boot.* events,
# computes phase summaries, and respects the optional correlation_id
# scoping query.
RSpec.describe "GET /api/v1/system/fleet/boot_replay", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { user_with_permissions("system.fleet.autonomy", account: account) }
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:node) { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, node: node, name: "i-test") }
  let(:correlation) { SecureRandom.uuid }

  before do
    create(:account) # noop — ensure clean DB
    @firmware_event = create_event(kind: "boot.firmware", offset: 0)
    @kernel_event   = create_event(kind: "boot.kernel",   offset: 5,
                                    correlation_id: correlation)
    @initramfs_evt  = create_event(kind: "boot.initramfs", offset: 8,
                                    correlation_id: correlation)
    @enroll_event   = create_event(kind: "instance.enroll", offset: 15,
                                    correlation_id: correlation)
    # An event NOT prefixed boot.* without correlation_id — should be excluded
    @noise_event    = create_event(kind: "system.module_drift", offset: 12)
  end

  describe "happy path" do
    it "returns boot.* events for the requested instance" do
      get "/api/v1/system/fleet/boot_replay?instance_id=#{instance.id}", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      kinds = body.dig("data", "events").map { |e| e["kind"] }

      expect(kinds).to include("boot.firmware", "boot.kernel", "boot.initramfs")
      expect(kinds).not_to include("system.module_drift") # noise filtered out
    end

    it "computes a phase_summary keyed by phase label" do
      get "/api/v1/system/fleet/boot_replay?instance_id=#{instance.id}", headers: headers

      summary = JSON.parse(response.body).dig("data", "phase_summary")
      expect(summary).to be_a(Hash)
      expect(summary.keys).to include("firmware", "kernel", "initramfs")
      expect(summary["firmware"]["count"]).to eq(1)
    end

    it "orders events chronologically" do
      get "/api/v1/system/fleet/boot_replay?instance_id=#{instance.id}", headers: headers

      events = JSON.parse(response.body).dig("data", "events")
      timestamps = events.map { |e| e["emitted_at"] }
      expect(timestamps).to eq(timestamps.sort)
    end
  end

  describe "correlation_id scoping" do
    it "includes non-boot events that share the correlation_id" do
      get "/api/v1/system/fleet/boot_replay?instance_id=#{instance.id}&correlation_id=#{correlation}", headers: headers

      kinds = JSON.parse(response.body).dig("data", "events").map { |e| e["kind"] }
      # boot.* events that DON'T share correlation are still returned
      # because the LIKE 'boot.%' clause is OR'd with the correlation_id check.
      expect(kinds).to include("boot.firmware", "boot.kernel", "instance.enroll")
    end

    it "still excludes correlation-less non-boot noise" do
      get "/api/v1/system/fleet/boot_replay?instance_id=#{instance.id}&correlation_id=#{correlation}", headers: headers

      kinds = JSON.parse(response.body).dig("data", "events").map { |e| e["kind"] }
      expect(kinds).not_to include("system.module_drift")
    end
  end

  describe "validation + scoping" do
    it "requires instance_id param" do
      get "/api/v1/system/fleet/boot_replay", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "404s for an instance in another account" do
      foreign_node = create(:system_node, account: other_account)
      foreign_instance = create(:system_node_instance, node: foreign_node)

      get "/api/v1/system/fleet/boot_replay?instance_id=#{foreign_instance.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "rejects without system.fleet.autonomy permission" do
      no_perm = create(:user, account: account)
      no_perm_headers = auth_headers_for(no_perm).merge("Content-Type" => "application/json")

      get "/api/v1/system/fleet/boot_replay?instance_id=#{instance.id}", headers: no_perm_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  def create_event(kind:, offset:, correlation_id: nil)
    System::FleetEvent.create!(
      account: account,
      node_instance_id: instance.id,
      kind: kind,
      severity: "low",
      payload: {},
      source: "test",
      correlation_id: correlation_id,
      emitted_at: 30.minutes.ago + offset.seconds
    )
  end
end
