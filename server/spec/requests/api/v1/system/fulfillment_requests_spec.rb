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

  # IMP-3fd7f5c67a7b — approve recorded source "operator_ui" while no operator
  # surface existed: there was no index/show route, so a composed request could
  # not be found, let alone reviewed, before releasing its frozen plan.
  describe "GET /api/v1/system/fulfillment_requests" do
    let(:reader) { user_with_permissions("system.fulfillment_requests.read", account: account) }

    it "lists this account's requests, newest first" do
      older = composed_request(account: account, request: "older")
      newer = composed_request(account: account, request: "newer")
      older.update!(created_at: 2.hours.ago)

      get "/api/v1/system/fulfillment_requests", headers: auth_headers_for(reader)

      expect(response).to have_http_status(:ok)
      rows = JSON.parse(response.body)["data"]["fulfillment_requests"]
      expect(rows.map { |r| r["id"] }).to eq([ newer.id, older.id ])
    end

    it "never leaks another account's requests" do
      mine = composed_request(account: account)
      theirs = composed_request(account: other_account)

      get "/api/v1/system/fulfillment_requests", headers: auth_headers_for(reader)

      ids = JSON.parse(response.body)["data"]["fulfillment_requests"].map { |r| r["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(theirs.id)
    end

    it "filters by state so the operator can isolate what awaits a decision" do
      composed = composed_request(account: account)
      approved = composed_request(account: account)
      approved.approve_by!(user: reader, source: "test")

      get "/api/v1/system/fulfillment_requests", params: { state: "composed" },
          headers: auth_headers_for(reader)

      ids = JSON.parse(response.body)["data"]["fulfillment_requests"].map { |r| r["id"] }
      expect(ids).to eq([ composed.id ])
      expect(ids).not_to include(approved.id)
    end

    it "carries the pending-decision count so the hub can badge the tab" do
      composed_request(account: account)
      get "/api/v1/system/fulfillment_requests", headers: auth_headers_for(reader)
      expect(JSON.parse(response.body)["data"]["awaiting_approval_count"]).to eq(1)
    end

    it "does NOT include the frozen plan in list rows" do
      composed_request(account: account)
      get "/api/v1/system/fulfillment_requests", headers: auth_headers_for(reader)
      row = JSON.parse(response.body)["data"]["fulfillment_requests"].first
      expect(row).not_to have_key("plan")
    end

    # Same trap the approve block documents: an unregistered name silently means
    # "admins only" rather than "nobody", so the 403 examples below would pass on
    # a typo. Pin catalog membership directly.
    it "gates on a permission that is actually registered in the catalog" do
      expect(::Permissions.permission_exists?("system.fulfillment_requests.read")).to be(true)
    end

    it "rejects a user without the read permission" do
      anon = create(:user, account: account)
      get "/api/v1/system/fulfillment_requests", headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end

    it "does not accept the approve permission as a substitute for read" do
      approver = user_with_permissions("system.fulfillment_requests.approve", account: account)
      get "/api/v1/system/fulfillment_requests", headers: auth_headers_for(approver)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/system/fulfillment_requests/:id" do
    let(:reader) { user_with_permissions("system.fulfillment_requests.read", account: account) }

    it "returns the FROZEN plan, so the operator approves what will execute" do
      fr = composed_request(account: account)

      get "/api/v1/system/fulfillment_requests/#{fr.id}", headers: auth_headers_for(reader)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)["data"]["fulfillment_request"]
      expect(body["id"]).to eq(fr.id)
      # The exact bytes approve releases — not a re-composed or filtered copy.
      expect(body["plan"]).to eq(fr.plan)
      expect(body.dig("plan", "execution", "template_name")).to eq("fulfill-memcached")
    end

    it "surfaces the cumulative park trail, including a withheld autonomous approval" do
      fr = composed_request(account: account)
      fr.add_park!(step: "autonomous_approval", reason: "confidence below threshold")

      get "/api/v1/system/fulfillment_requests/#{fr.id}", headers: auth_headers_for(reader)

      parked = JSON.parse(response.body)["data"]["fulfillment_request"]["parked"]
      expect(parked.first["step"]).to eq("autonomous_approval")
      expect(parked.first["reason"]).to eq("confidence below threshold")
    end

    it "surfaces unresolved gaps rather than hiding them from the approver" do
      fr = composed_request(account: account)
      get "/api/v1/system/fulfillment_requests/#{fr.id}", headers: auth_headers_for(reader)
      gaps = JSON.parse(response.body)["data"]["fulfillment_request"]["plan"]["unresolved_gaps"]
      expect(gaps.first["capability"]).to eq("memcached-exporter")
    end

    # Compared against the IN-MEMORY object create_composed! returned, which is
    # the stronger assertion: plan_digest canonicalises (deep-sorts keys) before
    # hashing, so the round trip through jsonb no longer changes it
    # (IMP-09837d6cf5ff). Before that fix this had to reload first.
    it "carries the plan digest an auditor can match against the approval event" do
      fr = composed_request(account: account)

      get "/api/v1/system/fulfillment_requests/#{fr.id}", headers: auth_headers_for(reader)

      body = JSON.parse(response.body)["data"]["fulfillment_request"]
      expect(body["plan_digest"]).to eq(fr.plan_digest)
      expect(body["plan_digest"]).to eq(::System::FulfillmentRequest.find(fr.id).plan_digest)
      expect(body["plan_digest"]).to match(/\A\h{64}\z/)
    end

    # The digest only earns its place if the number shown to the operator is the
    # number the approval trail records. Assert across the two code paths rather
    # than against the same method twice.
    it "shows the digest the approval event then records" do
      fr = composed_request(account: account)
      get "/api/v1/system/fulfillment_requests/#{fr.id}", headers: auth_headers_for(reader)
      shown = JSON.parse(response.body)["data"]["fulfillment_request"]["plan_digest"]

      emitted = nil
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!) do |**kwargs|
        emitted = kwargs[:payload] if kwargs[:kind] == "system.fulfillment_approved"
      end
      ::System::FulfillmentRequest.find(fr.id).approve_by!(user: reader, source: "test")

      expect(emitted[:plan_digest]).to eq(shown)
    end

    it "shows the same plan bytes the approval then releases" do
      fr = composed_request(account: account)
      get "/api/v1/system/fulfillment_requests/#{fr.id}", headers: auth_headers_for(reader)
      shown = JSON.parse(response.body)["data"]["fulfillment_request"]["plan"]

      # What show rendered must be what approve releases — the frozen-plan
      # contract read from the operator's end.
      expect(shown).to eq(::System::FulfillmentRequest.find(fr.id).plan)
    end

    it "404s for another account's request" do
      theirs = composed_request(account: other_account)
      get "/api/v1/system/fulfillment_requests/#{theirs.id}", headers: auth_headers_for(reader)
      expect(response).to have_http_status(:not_found)
    end

    it "rejects a user without the read permission" do
      fr = composed_request(account: account)
      anon = create(:user, account: account)
      get "/api/v1/system/fulfillment_requests/#{fr.id}", headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end

    # The permission is checked BEFORE the row is looked up, so an unprivileged
    # caller cannot use the 403/404 difference to learn which ids exist.
    it "answers 403, not 404, for a nonexistent id when the caller cannot read" do
      anon = create(:user, account: account)
      get "/api/v1/system/fulfillment_requests/#{SecureRandom.uuid}",
          headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end
  end

end
