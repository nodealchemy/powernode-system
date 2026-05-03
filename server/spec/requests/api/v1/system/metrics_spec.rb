# frozen_string_literal: true

require "rails_helper"

# Comprehensive stabilization sweep Phase 10.5 — operator metrics endpoint.
RSpec.describe "GET /api/v1/system/metrics", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { user_with_permissions("system.metrics.read", account: account) }
  let(:headers) { auth_headers_for(user) }

  before do
    Rails.cache.clear if Rails.cache.respond_to?(:clear)
  end

  describe "GET /api/v1/system/metrics/dispatch" do
    it "returns aggregated metrics for tracked names" do
      System::Metrics::Aggregator.record(metric_name: "system.dispatch.completed",
                                         account_id: account.id)
      System::Metrics::Aggregator.record(metric_name: "system.dispatch.failed",
                                         account_id: account.id)
      System::Metrics::Aggregator.record(metric_name: "system.dispatch.failed",
                                         account_id: account.id)

      get "/api/v1/system/metrics/dispatch", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      metrics = body.dig("data", "metrics")

      expect(body.dig("data", "window_seconds")).to eq(300)
      expect(metrics).to include(
        "system.dispatch.claimed",
        "system.dispatch.started",
        "system.dispatch.completed",
        "system.dispatch.failed",
        "system.fleet.event"
      )
      expect(metrics["system.dispatch.completed"]["count"]).to eq(1)
      expect(metrics["system.dispatch.failed"]["count"]).to eq(2)
      expect(metrics["system.dispatch.claimed"]["count"]).to eq(0)
    end

    it "honors the window query param (capped at 3600s)" do
      get "/api/v1/system/metrics/dispatch?window=60", headers: headers
      expect(JSON.parse(response.body).dig("data", "window_seconds")).to eq(60)

      get "/api/v1/system/metrics/dispatch?window=99999", headers: headers
      expect(JSON.parse(response.body).dig("data", "window_seconds")).to eq(3600)
    end

    it "isolates metrics per-account" do
      System::Metrics::Aggregator.record(metric_name: "system.dispatch.completed",
                                         account_id: other_account.id)

      get "/api/v1/system/metrics/dispatch", headers: headers

      expect(JSON.parse(response.body)
        .dig("data", "metrics", "system.dispatch.completed", "count")).to eq(0)
    end

    it "returns 403 without system.metrics.read permission" do
      unprivileged = user_with_permissions("system.nodes.read", account: account)
      get "/api/v1/system/metrics/dispatch", headers: auth_headers_for(unprivileged)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 401 without authentication" do
      get "/api/v1/system/metrics/dispatch"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
