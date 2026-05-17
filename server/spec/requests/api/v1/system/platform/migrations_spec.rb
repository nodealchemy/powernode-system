# frozen_string_literal: true

require "rails_helper"

# Plan reference: Decentralized Federation §F + §I + P5 + P7.4.
RSpec.describe "Api::V1::System::Platform::Migrations", type: :request do
  let(:account) { create(:account) }
  let(:reader)  { user_with_permissions("system.platform.read", account: account) }
  let(:base)    { "/api/v1/system/platform/migrations" }

  describe "GET /migrations" do
    let!(:m_planned) do
      create(:system_migration, account: account, operation: "duplicate",
                                 root_resource_kind: "skill", status: "planned")
    end
    let!(:m_completed) do
      create(:system_migration, :completed, account: account, operation: "migrate",
                                             root_resource_kind: "trading_strategy")
    end
    let!(:cross_account) do
      create(:system_migration, account: create(:account))
    end

    it "lists this account's migrations sorted by created_at desc" do
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)

      data = json_response_data
      expect(data["count"]).to eq(2)
      kinds = data["migrations"].map { |m| m["root_resource_kind"] }
      expect(kinds).to include("skill", "trading_strategy")
    end

    it "filters by status" do
      get base, headers: auth_headers_for(reader), params: { status: "completed" }
      expect(json_response_data["migrations"].map { |m| m["status"] }).to eq([ "completed" ])
    end

    it "forbids without read permission" do
      anon = create(:user, account: account)
      get base, headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /migrations/:id" do
    let!(:migration) do
      create(:system_migration, :completed, account: account,
                                             plan_summary: { "total_steps" => 3 },
                                             audit_log: [ { "event" => "plan_composed" } ])
    end

    it "returns full detail with plan_summary + audit_log" do
      get "#{base}/#{migration.id}", headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)

      data = json_response_data["migration"]
      expect(data["plan_summary"]).to eq("total_steps" => 3)
      expect(data["audit_log"].size).to eq(1)
      expect(data["audit_log"].first["event"]).to eq("plan_composed")
      expect(data["terminal"]).to be true
    end

    it "404s for unknown id" do
      get "#{base}/nonexistent", headers: auth_headers_for(reader)
      expect(response).to have_http_status(:not_found)
    end
  end
end
