# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::Federation::ServiceOfferings", type: :request do
  let(:account) { create(:account) }
  let(:user) { user_with_permissions("system.service_offerings.read", "system.service_offerings.manage", account: account) }
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:base_path) { "/api/v1/system/federation/service_offerings" }

  describe "GET /service_offerings" do
    let!(:active_offering)     { create(:system_federation_service_offering, :active, account: account, slug: "gitea", name: "Hosted Git") }
    let!(:draft_offering)      { create(:system_federation_service_offering, account: account, slug: "draft-svc", name: "Draft") }
    let!(:other_account_offering) { create(:system_federation_service_offering, :active, account: create(:account), slug: "leak-test") }

    it "lists the operator's own offerings + scopes to current account" do
      get base_path, headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      slugs = body["data"]["offerings"].map { |o| o["slug"] }
      expect(slugs).to match_array([ "gitea", "draft-svc" ])
      expect(slugs).not_to include("leak-test")
    end

    it "filters by status when supplied" do
      get base_path, headers: headers, params: { status: "active" }
      slugs = JSON.parse(response.body)["data"]["offerings"].map { |o| o["slug"] }
      expect(slugs).to eq([ "gitea" ])
    end
  end

  describe "GET /service_offerings/:id" do
    let!(:offering) { create(:system_federation_service_offering, :active, account: account, slug: "gitea") }

    it "returns the offering with full detail" do
      get "#{base_path}/#{offering.id}", headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["offering"]["slug"]).to eq("gitea")
      expect(body["data"]["offering"]).to have_key("description_markdown")
      expect(body["data"]["offering"]).to have_key("metadata")
    end

    it "404 for offering in a different account" do
      other_offering = create(:system_federation_service_offering, account: create(:account))
      get "#{base_path}/#{other_offering.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /service_offerings" do
    let!(:backing_service) do
      create(:sdwan_service, account: account, slug: "managed-pg-svc",
                             protocol: "tcp", backend_host: "pg-backend.example.com", backend_port: 5432)
    end
    let(:create_payload) do
      {
        slug: "managed-pg",
        name: "Managed Postgres",
        service_id: backing_service.id,
        default_grant_ttl_days: 30,
        default_grant_scopes: %w[read write]
      }
    end

    it "creates an offering in draft status" do
      post base_path, params: create_payload.to_json, headers: headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["data"]["offering"]["slug"]).to eq("managed-pg")
      expect(body["data"]["offering"]["status"]).to eq("draft")
    end

    it "422 on validation failure (invalid slug)" do
      post base_path, params: create_payload.merge(slug: "Bad Slug").to_json, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /service_offerings/:id" do
    let!(:offering) { create(:system_federation_service_offering, account: account, slug: "gitea", name: "Original") }

    it "updates allowed fields" do
      patch "#{base_path}/#{offering.id}",
            params: { name: "Renamed Gitea", default_grant_ttl_days: 60 }.to_json,
            headers: headers
      expect(response).to have_http_status(:ok)
      expect(offering.reload.name).to eq("Renamed Gitea")
      expect(offering.default_grant_ttl_days).to eq(60)
    end

    it "ignores slug changes (slug is the stable identifier)" do
      patch "#{base_path}/#{offering.id}",
            params: { slug: "new-slug" }.to_json,
            headers: headers
      expect(offering.reload.slug).to eq("gitea")
    end
  end

  describe "POST /:id/activate + /deprecate + /retire" do
    let!(:offering) { create(:system_federation_service_offering, account: account, slug: "gitea") }

    it "activate transitions draft → active" do
      post "#{base_path}/#{offering.id}/activate", headers: headers
      expect(response).to have_http_status(:ok)
      expect(offering.reload.status).to eq("active")
    end

    it "deprecate transitions active → deprecated with reason" do
      offering.activate!
      post "#{base_path}/#{offering.id}/deprecate",
           params: { reason: "replaced by v2" }.to_json,
           headers: headers
      expect(response).to have_http_status(:ok)
      offering.reload
      expect(offering.status).to eq("deprecated")
      expect(offering.metadata["deprecation_reason"]).to include("v2")
    end

    it "retire is terminal" do
      offering.activate!
      post "#{base_path}/#{offering.id}/retire", headers: headers
      expect(response).to have_http_status(:ok)
      offering.reload
      expect(offering.status).to eq("retired")
      expect(offering.terminal?).to be true
    end

    it "422 when trying to activate a retired offering" do
      offering.update!(status: "retired", retired_at: 1.day.ago)
      post "#{base_path}/#{offering.id}/activate", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /service_offerings/:id (= retire)" do
    let!(:offering) { create(:system_federation_service_offering, :active, account: account) }

    it "retires the offering (soft delete)" do
      delete "#{base_path}/#{offering.id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(offering.reload.status).to eq("retired")
    end

    it "409 when already retired" do
      offering.update!(status: "retired", retired_at: 1.day.ago)
      delete "#{base_path}/#{offering.id}", headers: headers
      expect(response).to have_http_status(:conflict)
    end
  end

  # IMP-563999967998 — a refusal must HALT the action, not merely render.
  #
  # These examples REPLACE two earlier ones ("rejects requests without the read
  # permission", "rejects without manage permission") that asserted the STATUS
  # ONLY. Both passed while the bug was live, and that is the whole trap:
  # authorize_manage! rendered a bare `render_error("Forbidden", ...)` with no
  # return of any kind, so the 403 really WAS rendered — and then the action ran
  # on into the write. The follow-up render raised DoubleRenderError, which
  # ApiResponse's `unless performed?` rescue swallows, so the caller saw a clean
  # 403 over a committed write. "Unauthorized caller gets 403" is fully
  # compatible with the action having executed; the oracle has to be ABSENCE OF
  # EFFECT. The weak examples are deleted rather than kept alongside, so the
  # cheap oracle cannot survive next to the strong one.
  #
  # All eight inline call sites get an example — six authorize_manage!
  # (create/update/destroy/activate/deprecate/retire) and two authorize_read!
  # (index/show). A halt that covers create but not retire is the same defect
  # with a smaller surface.
  #
  # The two READ sites have no row to count: under the bug the smuggled
  # render_success was swallowed, so nothing leaked into the body and the status
  # was already 403. Their absence-of-effect oracle is therefore that the
  # GUARDED WORK NEVER RUNS AT ALL, observed as SQL: #index must issue no SELECT
  # against the offerings table (set_offering does not run for index), and #show
  # must issue no SELECT against the subscriptions table, which only
  # serialize(full: true) -> active_subscription_count would emit.
  describe "a refused caller (authorization must halt the action)" do
    let(:no_manage) { user_with_permissions("system.service_offerings.read", account: account) }
    # NOT `create(:user, account:)` — the FIRST user in an account gets the
    # OWNER role from assign_default_role, which spec/factories/users.rb warns
    # about explicitly. A negative-authorization actor must be permissionless
    # by construction, not by accident of what the catalog happens to grant.
    let(:no_read)   { user_without_permissions(account: account) }

    def json_headers(user)
      auth_headers_for(user).merge("Content-Type" => "application/json")
    end

    # Records every SQL statement naming `table` while the block runs. Used as
    # the read-side absence-of-effect oracle: the guarded query is the effect.
    def sql_touching(table)
      seen = []
      collector = lambda do |*, payload|
        sql = payload[:sql].to_s
        seen << sql if sql.include?(table) && !sql.start_with?("SAVEPOINT", "RELEASE", "ROLLBACK")
      end
      ActiveSupport::Notifications.subscribed(collector, "sql.active_record") { yield }
      seen
    end

    # --- authorize_manage! call sites (six mutating actions) ---------------

    describe "POST /service_offerings (create)" do
      let!(:backing_service) do
        create(:sdwan_service, account: account, slug: "halt-probe-svc",
                               protocol: "tcp", backend_host: "pg.example.com", backend_port: 5432)
      end
      let(:payload) do
        { slug: "smuggled-offering", name: "Smuggled", service_id: backing_service.id }
      end

      it "returns 403 AND creates no offering" do
        expect {
          post base_path, params: payload.to_json, headers: json_headers(no_manage)
        }.not_to change(::System::Federation::ServiceOffering, :count)

        expect(response).to have_http_status(:forbidden)
        expect(::System::Federation::ServiceOffering.where(slug: "smuggled-offering")).to be_empty

        # The refusal contract the frontend sees is unchanged by switching from
        # render to raise: same 403, byte-identical message. The rescue_from
        # path adds a `code` key, which errorHandler.ts does not read (it
        # derives its code from the HTTP status).
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("Forbidden")
      end
    end

    describe "PATCH /service_offerings/:id (update)" do
      let!(:offering) { create(:system_federation_service_offering, account: account, name: "Original") }

      it "returns 403 AND leaves the offering unchanged" do
        patch "#{base_path}/#{offering.id}",
              params: { name: "Smuggled Rename", default_grant_ttl_days: 99 }.to_json,
              headers: json_headers(no_manage)

        expect(response).to have_http_status(:forbidden)
        offering.reload
        expect(offering.name).to eq("Original")
        expect(offering.default_grant_ttl_days).not_to eq(99)
      end
    end

    describe "DELETE /service_offerings/:id (retire)" do
      let!(:offering) { create(:system_federation_service_offering, :active, account: account) }

      it "returns 403 AND does not retire the offering" do
        delete "#{base_path}/#{offering.id}", headers: json_headers(no_manage)

        expect(response).to have_http_status(:forbidden)
        offering.reload
        expect(offering.status).to eq("active")
        expect(offering.retired_at).to be_nil
      end
    end

    describe "POST /:id/activate" do
      let!(:offering) { create(:system_federation_service_offering, account: account) }

      it "returns 403 AND leaves the offering in draft" do
        post "#{base_path}/#{offering.id}/activate", headers: json_headers(no_manage)

        expect(response).to have_http_status(:forbidden)
        expect(offering.reload.status).to eq("draft")
      end
    end

    describe "POST /:id/deprecate" do
      let!(:offering) { create(:system_federation_service_offering, :active, account: account) }

      it "returns 403 AND does not deprecate the offering" do
        post "#{base_path}/#{offering.id}/deprecate",
             params: { reason: "smuggled" }.to_json,
             headers: json_headers(no_manage)

        expect(response).to have_http_status(:forbidden)
        offering.reload
        expect(offering.status).to eq("active")
        expect(offering.deprecated_at).to be_nil
        expect(offering.metadata["deprecation_reason"]).to be_nil
      end
    end

    describe "POST /:id/retire" do
      let!(:offering) { create(:system_federation_service_offering, :active, account: account) }

      it "returns 403 AND does not retire the offering" do
        post "#{base_path}/#{offering.id}/retire",
             params: { reason: "smuggled" }.to_json,
             headers: json_headers(no_manage)

        expect(response).to have_http_status(:forbidden)
        offering.reload
        expect(offering.status).to eq("active")
        expect(offering.retired_at).to be_nil
      end
    end

    # --- authorize_read! call sites (two read actions) --------------------

    describe "GET /service_offerings (index)" do
      let!(:offering) { create(:system_federation_service_offering, :active, account: account) }

      # POSITIVE CONTROL. Without this, a typo in the table name — or the
      # listing query moving elsewhere — would make the refusal example below
      # pass forever while proving nothing. This pins the probe to reality:
      # the query it looks for really is emitted when the action is allowed to
      # run.
      it "the probe sees the listing query when the caller IS authorized" do
        statements = sql_touching("system_federation_service_offerings") do
          get base_path, headers: headers
        end

        expect(response).to have_http_status(:ok)
        expect(statements).not_to be_empty
      end

      it "returns 403 AND never runs the guarded query" do
        statements = sql_touching("system_federation_service_offerings") do
          get base_path, headers: json_headers(no_read)
        end

        expect(response).to have_http_status(:forbidden)
        expect(statements).to be_empty,
                              "the action continued past the refusal and listed offerings anyway:\n" \
                              "#{statements.join("\n")}"
      end
    end

    describe "GET /service_offerings/:id (show)" do
      let!(:offering) { create(:system_federation_service_offering, :active, account: account) }

      # set_offering IS a before_action (Rails really halts there), so the
      # offerings table is legitimately read before authorize_read! runs and
      # cannot discriminate. The subscriptions COUNT can: `serialize` emits it
      # via active_subscription_count — it sits in the `base` hash, so BOTH
      # serialize modes emit it — and #show reaches serialize only if the
      # action continued past the refusal.
      it "the probe sees the serialize query when the caller IS authorized" do
        statements = sql_touching("system_federation_service_subscriptions") do
          get "#{base_path}/#{offering.id}", headers: headers
        end

        expect(response).to have_http_status(:ok)
        expect(statements).not_to be_empty
      end

      it "returns 403 AND never reaches serialize" do
        statements = sql_touching("system_federation_service_subscriptions") do
          get "#{base_path}/#{offering.id}", headers: json_headers(no_read)
        end

        expect(response).to have_http_status(:forbidden)
        expect(statements).to be_empty,
                              "the action continued past the refusal and serialized the offering:\n" \
                              "#{statements.join("\n")}"
      end
    end
  end
end
