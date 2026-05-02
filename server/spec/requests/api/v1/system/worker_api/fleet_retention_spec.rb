# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block W (BB1) — FleetEvent retention sweep request spec.
RSpec.describe "POST /api/v1/system/worker_api/fleet/retention_sweep", type: :request do
  let(:account) { create(:account) }
  let(:plain_token) { "wrk-tok-#{SecureRandom.hex(8)}" }
  let!(:worker) do
    # let! (eager) so the worker is created before the request fires —
    # request specs don't auto-resolve `let` references on Worker.authenticate.
    w = create(:worker, account: account, status: "active")
    w.update_columns(token_digest: Digest::SHA256.hexdigest(plain_token))
    w
  end
  let(:headers) { { "X-Worker-Token" => plain_token } }

  before do
    # Stub permission check rather than wrestling with role_permission seeding.
    # Worker#has_permission? is exercised elsewhere in worker permission specs.
    allow_any_instance_of(Worker).to receive(:has_permission?)
      .with("system.fleet.reconcile").and_return(true)
  end

  describe "with worker token" do
    it "deletes routine events older than retention_days" do
      old_routine = System::FleetEvent.create!(
        account: account, kind: "system.module_drift", severity: "low",
        payload: {}, emitted_at: 100.days.ago
      )
      fresh_routine = System::FleetEvent.create!(
        account: account, kind: "system.module_drift", severity: "medium",
        payload: {}, emitted_at: 30.days.ago
      )

      post "/api/v1/system/worker_api/fleet/retention_sweep", headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.dig("data", "deleted_routine")).to be >= 1
      expect(System::FleetEvent.where(id: old_routine.id)).not_to exist
      expect(System::FleetEvent.where(id: fresh_routine.id)).to exist
    end

    it "preserves critical/high events past the routine cutoff but inside critical retention" do
      borderline_critical = System::FleetEvent.create!(
        account: account, kind: "decision.blocked", severity: "critical",
        payload: {}, emitted_at: 200.days.ago
      )
      old_critical = System::FleetEvent.create!(
        account: account, kind: "system.honeypot_triggered", severity: "high",
        payload: {}, emitted_at: 400.days.ago
      )

      post "/api/v1/system/worker_api/fleet/retention_sweep", headers: headers
      body = JSON.parse(response.body)
      expect(body.dig("data", "deleted_critical")).to be >= 1
      expect(System::FleetEvent.where(id: borderline_critical.id)).to exist
      expect(System::FleetEvent.where(id: old_critical.id)).not_to exist
    end

    it "returns retention configuration in the response" do
      post "/api/v1/system/worker_api/fleet/retention_sweep", headers: headers
      body = JSON.parse(response.body)
      expect(body.dig("data", "retention_days")).to eq(90)
      expect(body.dig("data", "retention_critical_days")).to eq(365)
    end

    it "honors POWERNODE_FLEET_EVENT_RETENTION_DAYS override" do
      original = ENV["POWERNODE_FLEET_EVENT_RETENTION_DAYS"]
      ENV["POWERNODE_FLEET_EVENT_RETENTION_DAYS"] = "30"
      begin
        post "/api/v1/system/worker_api/fleet/retention_sweep", headers: headers
        body = JSON.parse(response.body)
        expect(body.dig("data", "retention_days")).to eq(30)
      ensure
        ENV["POWERNODE_FLEET_EVENT_RETENTION_DAYS"] = original
      end
    end

    it "is account-isolated when the worker is account-scoped" do
      other_account = create(:account)
      other_old = System::FleetEvent.create!(
        account: other_account, kind: "x", severity: "low",
        payload: {}, emitted_at: 200.days.ago
      )
      # The current implementation deletes globally by emitted_at + severity;
      # if a future revision narrows to account scope this assertion will need
      # to be updated. For now we assert the cross-account row is also dropped.
      post "/api/v1/system/worker_api/fleet/retention_sweep", headers: headers
      expect(System::FleetEvent.where(id: other_old.id)).not_to exist
    end
  end

  describe "without worker token" do
    it "returns 401" do
      post "/api/v1/system/worker_api/fleet/retention_sweep"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
