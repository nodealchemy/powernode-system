# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::Federation::ServiceSubscriptions", type: :request do
  let(:account) { create(:account) }
  let(:user) do
    user_with_permissions("system.service_subscriptions.read",
                          "system.service_subscriptions.cancel",
                          account: account)
  end
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }
  let(:base_path) { "/api/v1/system/federation/service_subscriptions" }

  let(:peer) { create(:system_federation_peer, :platform, :active, account: account) }

  describe "GET /service_subscriptions" do
    let!(:active_sub) do
      create(:system_federation_service_subscription, :active,
              account: account, federation_peer: peer,
              service_offering_slug: "gitea",
              local_hostname: "git.alice.tld")
    end
    let!(:pending_sub) do
      create(:system_federation_service_subscription,
              account: account, federation_peer: peer,
              service_offering_slug: "managed-pg",
              local_hostname: "pg.alice.tld")
    end
    let!(:other_account_sub) do
      create(:system_federation_service_subscription, :active,
              account: create(:account),
              service_offering_slug: "leak-test",
              local_hostname: "leak.example.com")
    end

    it "lists subscriber's own subscriptions + scopes to current account" do
      get base_path, headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      slugs = body["data"]["subscriptions"].map { |s| s["service_offering_slug"] }
      expect(slugs).to match_array([ "gitea", "managed-pg" ])
      expect(slugs).not_to include("leak-test")
    end

    it "filters by status" do
      get base_path, headers: headers, params: { status: "active" }
      body = JSON.parse(response.body)
      expect(body["data"]["subscriptions"].map { |s| s["status"] }).to eq([ "active" ])
    end

    it "filters by peer_id" do
      get base_path, headers: headers, params: { peer_id: peer.id }
      body = JSON.parse(response.body)
      expect(body["data"]["subscriptions"].size).to eq(2)
    end
  end

  describe "GET /service_subscriptions/:id" do
    let!(:sub) do
      create(:system_federation_service_subscription, :active,
              account: account, federation_peer: peer,
              local_hostname: "git.alice.tld")
    end

    it "returns the subscription with full detail including metadata" do
      get "#{base_path}/#{sub.id}", headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["subscription"]["local_hostname"]).to eq("git.alice.tld")
      expect(body["data"]["subscription"]).to have_key("federation_grant_id")
      expect(body["data"]["subscription"]).to have_key("acme_certificate_id")
      expect(body["data"]["subscription"]).to have_key("metadata")
    end

    it "404 for subscription in a different account" do
      other_sub = create(:system_federation_service_subscription, :active, account: create(:account))
      get "#{base_path}/#{other_sub.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /service_subscriptions/:id/cancel" do
    let!(:sub) do
      create(:system_federation_service_subscription, :active,
              account: account, federation_peer: peer,
              local_hostname: "git.alice.tld")
    end

    it "cancels the subscription" do
      post "#{base_path}/#{sub.id}/cancel",
           params: { reason: "no longer needed" }.to_json,
           headers: headers
      expect(response).to have_http_status(:ok)
      sub.reload
      expect(sub.status).to eq("cancelled")
      expect(sub.metadata["cancellation_reason"]).to eq("no longer needed")
    end

    it "409 when already cancelled" do
      sub.cancel!(reason: "test")
      post "#{base_path}/#{sub.id}/cancel", headers: headers
      expect(response).to have_http_status(:conflict)
    end
  end

  # IMP-563999967998 — the sibling of ServiceOfferingsController's bypass, and
  # it is real: authorize_cancel! is a bare `render_error("Forbidden", ...)`
  # with no return, called INLINE from #cancel, and #cancel then runs on to
  # `@subscription.cancel!` (terminal? is true only for an already-cancelled
  # row, so nothing else stopped it). So a caller without
  # system.service_subscriptions.cancel got a 403 AND the subscription really
  # was cancelled; the follow-up render_success raised DoubleRenderError, which
  # ApiResponse swallows via `unless performed?`.
  #
  # These examples REPLACE two status-only ones ("rejects without read
  # permission", "rejects without cancel permission") that passed with the bug
  # live — the 403 IS rendered, so the status was never the defect.
  describe "a refused caller (authorization must halt the action)" do
    let(:no_cancel) { user_with_permissions("system.service_subscriptions.read", account: account) }
    # NOT `create(:user, account:)` — the first user in an account gets the
    # OWNER role; see the note in the offerings spec.
    let(:no_read)   { user_without_permissions(account: account) }

    def json_headers(user)
      auth_headers_for(user).merge("Content-Type" => "application/json")
    end

    def sql_touching(table)
      seen = []
      collector = lambda do |*, payload|
        sql = payload[:sql].to_s
        seen << sql if sql.include?(table) && !sql.start_with?("SAVEPOINT", "RELEASE", "ROLLBACK")
      end
      ActiveSupport::Notifications.subscribed(collector, "sql.active_record") { yield }
      seen
    end

    describe "POST /:id/cancel (authorize_cancel!)" do
      let!(:sub) do
        create(:system_federation_service_subscription, :active,
                account: account, federation_peer: peer,
                local_hostname: "git.alice.tld")
      end

      it "returns 403 AND does not cancel the subscription" do
        post "#{base_path}/#{sub.id}/cancel",
             params: { reason: "smuggled" }.to_json,
             headers: json_headers(no_cancel)

        expect(response).to have_http_status(:forbidden)
        sub.reload
        expect(sub.status).to eq("active")
        expect(sub.cancelled_at).to be_nil
        expect(sub.metadata["cancellation_reason"]).to be_nil
      end
    end

    describe "GET /service_subscriptions (authorize_read!)" do
      let!(:sub) do
        create(:system_federation_service_subscription, :active,
                account: account, federation_peer: peer,
                local_hostname: "git.alice.tld")
      end

      # No row changes on a read path, so the absence-of-effect oracle is that
      # the GUARDED WORK NEVER RUNS: #index has no before_action touching the
      # subscriptions table, so any SELECT against it proves the action
      # continued past the refusal. (#show is deliberately absent here: its
      # set_subscription before_action legitimately reads the same table before
      # authorize_read! runs, and serialize emits no further query, so that one
      # call site has no runtime observable at all — the static guard in
      # spec/integration/render_and_return_halt_idiom_spec.rb is its oracle.)
      # POSITIVE CONTROL — pins the probe to reality; see the offerings spec.
      it "the probe sees the listing query when the caller IS authorized" do
        statements = sql_touching("system_federation_service_subscriptions") do
          get base_path, headers: headers
        end

        expect(response).to have_http_status(:ok)
        expect(statements).not_to be_empty
      end

      it "returns 403 AND never runs the guarded query" do
        statements = sql_touching("system_federation_service_subscriptions") do
          get base_path, headers: json_headers(no_read)
        end

        expect(response).to have_http_status(:forbidden)
        expect(statements).to be_empty,
                              "the action continued past the refusal and listed subscriptions anyway:\n" \
                              "#{statements.join("\n")}"
      end
    end
  end
end
