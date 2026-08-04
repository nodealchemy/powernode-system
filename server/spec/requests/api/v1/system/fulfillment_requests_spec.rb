# frozen_string_literal: true

require "rails_helper"

# IMP-d4fc286b7ccf defect 2 — the `composed → approved` transition had NO
# operator surface. `config/routes.rb` carried only the worker-API
# `fulfillment/sweep`, and the sweep deliberately excludes `composed`
# (System::FulfillmentRequest::ADVANCEABLE_STATES), because a composed request
# is waiting on an out-of-band human decision, not on the orchestrator. With no
# endpoint to make that decision, an interactive request hung in `composed`
# forever and the whole "purpose → node" flow was unreachable.
#
# The approval contract (campaign 019f6084 inc-M, and aac422c0): the plan was
# FROZEN at compose time in `plan["execution"]`. Approving it releases exactly
# those bytes — the endpoint must never re-compose, re-filter, or drop the
# `unresolved_gaps` / `parked` trail the executor recorded.
RSpec.describe "Operator API — Fulfillment Requests", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }
  let(:user)          { user_with_permissions("system.fulfillment_requests.approve", account: account) }
  let(:headers)       { auth_headers_for(user) }

  # A composed request carrying the frozen plan shape the executor produces,
  # including the withheld-autonomous-approval park + unresolved gaps (aac422c0).
  def composed_request(account:, request: "give me a running memcached instance")
    ::System::FulfillmentRequest.create_composed!(
      account: account,
      request: request,
      plan: {
        "execution" => {
          "base_os_module_id" => "base-os-id",
          "reused_module_ids" => %w[mod-a],
          "gaps" => [ { "package" => "memcached" } ],
          "template_name" => "fulfill-memcached"
        },
        "unresolved_gaps" => [
          { "capability" => "memcached-exporter", "reason" => "author_module" }
        ]
      },
      cost_estimate: { "monthly_usd" => 12.0 },
      reused_modules: %w[mod-a],
      lease_ttl_seconds: 3600
    )
  end

  # The orchestrator is exercised by its own spec; here we only assert the
  # endpoint kicks exactly one advance (a real advance would try to materialize
  # modules and dispatch a build).
  def stub_advance(state: "materializing", advanced: 1, already_advancing: false)
    result = ::System::FulfillmentAdvanceOrchestrator::Result.new(
      "ok?": true, state: state, advanced: advanced, waiting: false, parked: [], error: nil,
      already_advancing: already_advancing
    )
    allow(::System::FulfillmentAdvanceOrchestrator).to receive(:advance!).and_return(result)
    result
  end

  describe "POST /api/v1/system/fulfillment_requests/:id/approve" do
    context "permissions" do
      # An UNREGISTERED permission name does not fail loudly — has_permission?
      # short-circuits on system.admin, so a name missing from the catalog
      # silently means "admins only" rather than "nobody", and the 403 example
      # below would still pass on a typo. Pin catalog membership directly.
      it "gates on a permission that is actually registered in the catalog" do
        expect(::Permissions.permission_exists?("system.fulfillment_requests.approve")).to be(true)
      end

      it "403s without system.fulfillment_requests.approve" do
        fr = composed_request(account: account)
        viewer = user_without_permissions(account: account)

        post "/api/v1/system/fulfillment_requests/#{fr.id}/approve",
             headers: auth_headers_for(viewer)

        expect(response).to have_http_status(:forbidden)
        expect(fr.reload.state).to eq("composed")
      end
    end

    context "scoping" do
      it "404s for a request in another account" do
        foreign = composed_request(account: other_account)

        post "/api/v1/system/fulfillment_requests/#{foreign.id}/approve", headers: headers

        expect(response).to have_http_status(:not_found)
        expect(foreign.reload.state).to eq("composed")
      end
    end

    context "happy path" do
      it "approves the composed request and kicks one advance" do
        fr = composed_request(account: account)
        stub_advance(state: "materializing")

        post "/api/v1/system/fulfillment_requests/#{fr.id}/approve", headers: headers

        expect(response).to have_http_status(:ok)
        expect(::System::FulfillmentAdvanceOrchestrator).to have_received(:advance!).once

        fr.reload
        # The endpoint's own transition. The advance is stubbed here, so the row
        # stops at `approved` — a real advance would carry it on from there.
        expect(fr.state).to eq("approved")
        expect(fr.approved_at).to be_present
      end

      it "returns the request summary plus the advance outcome" do
        fr = composed_request(account: account)
        stub_advance(state: "materializing", advanced: 2)

        post "/api/v1/system/fulfillment_requests/#{fr.id}/approve", headers: headers

        body = JSON.parse(response.body).dig("data", "fulfillment_request")
        expect(body["id"]).to eq(fr.id)
        expect(body["request"]).to eq("give me a running memcached instance")

        advance = JSON.parse(response.body).dig("data", "advance")
        expect(advance["state"]).to eq("materializing")
        expect(advance["advanced"]).to eq(2)
      end

      # If the 60s sweep already holds the per-request advisory lock when the
      # operator approves, advance! returns immediately with already_advancing:
      # true and advanced: false — otherwise the operator sees "advanced: false"
      # with no explanation for why nothing happened.
      it "surfaces already_advancing so a lock loser is self-explaining, not silent" do
        fr = composed_request(account: account)
        stub_advance(state: "composed", advanced: 0, already_advancing: true)

        post "/api/v1/system/fulfillment_requests/#{fr.id}/approve", headers: headers

        advance = JSON.parse(response.body).dig("data", "advance")
        expect(advance["already_advancing"]).to be(true)
      end
    end

    context "the approval trail" do
      # The model called this "the single audited decision" and the migration
      # called every run "auditable", but nothing recorded WHICH operator
      # released a plan that provisions billable cloud instances — no AuditLog,
      # no FleetEvent, only approved_at. These pin what is actually recorded.
      it "records WHO approved, not just when" do
        fr = composed_request(account: account)
        stub_advance

        post "/api/v1/system/fulfillment_requests/#{fr.id}/approve", headers: headers

        fr.reload
        expect(fr.approved_by_user_id).to eq(user.id)
        expect(fr.approved_at).to be_present
        expect(JSON.parse(response.body).dig("data", "fulfillment_request", "approved_by_user_id"))
          .to eq(user.id)
      end

      it "emits a system.fulfillment_approved fleet event carrying the approver and plan digest" do
        fr = composed_request(account: account)
        stub_advance

        expect {
          post "/api/v1/system/fulfillment_requests/#{fr.id}/approve", headers: headers
        }.to change { ::System::FleetEvent.where(kind: "system.fulfillment_approved").count }.by(1)

        event = ::System::FleetEvent.where(kind: "system.fulfillment_approved").last
        expect(event.payload["fulfillment_request_id"]).to eq(fr.id)
        expect(event.payload["approved_by_user_id"]).to eq(user.id)
        expect(event.payload["autonomous"]).to be(false)
        expect(event.payload["plan_digest"]).to eq(fr.reload.plan_digest)
        expect(event.payload["unresolved_gap_count"]).to eq(1)
        expect(event.source).to eq("operator_ui")
      end

      it "does not emit an approval event when the request is not composed" do
        fr = composed_request(account: account)
        fr.approve!

        expect {
          post "/api/v1/system/fulfillment_requests/#{fr.id}/approve", headers: headers
        }.not_to change { ::System::FleetEvent.where(kind: "system.fulfillment_approved").count }
      end
    end

    context "the frozen plan (TOCTOU contract)" do
      it "approves the plan AS-IS — no re-compose, no filtering of unresolved_gaps" do
        fr = composed_request(account: account)
        fr.add_park!(step: "autonomous_approval", reason: "unresolved_gaps present")
        frozen_plan = fr.reload.plan.deep_dup
        frozen_parked = fr.parked.deep_dup
        stub_advance

        post "/api/v1/system/fulfillment_requests/#{fr.id}/approve", headers: headers

        expect(response).to have_http_status(:ok)
        fr.reload
        expect(fr.plan).to eq(frozen_plan)
        expect(fr.plan["unresolved_gaps"]).to be_present
        expect(fr.parked).to eq(frozen_parked)
      end
    end

    context "wrong state" do
      it "422s when the request is not composed, without advancing it" do
        fr = composed_request(account: account)
        fr.approve!
        allow(::System::FulfillmentAdvanceOrchestrator).to receive(:advance!)

        post "/api/v1/system/fulfillment_requests/#{fr.id}/approve", headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(::System::FulfillmentAdvanceOrchestrator).not_to have_received(:advance!)
      end
    end
  end
end
