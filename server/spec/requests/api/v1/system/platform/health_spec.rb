# frozen_string_literal: true

require "rails_helper"

# Plan reference: Decentralized Federation §I + P7.2.
RSpec.describe "Api::V1::System::Platform::Health", type: :request do
  let(:account)  { create(:account) }
  let(:reader)   { user_with_permissions("system.platform.health.read", account: account) }
  let(:endpoint) { "/api/v1/system/platform/health" }

  it "returns a per-subsystem snapshot with all 7 subsystem keys" do
    get endpoint, headers: auth_headers_for(reader)
    expect(response).to have_http_status(:ok)

    health = json_response_data["health"]
    %w[rails worker redis postgres acme sdwan federation generated_at].each do |key|
      expect(health).to have_key(key), "missing #{key}"
    end
    expect(health["rails"]).to include("status", "rails_env")
    expect(health["postgres"]).to include("status")
  end

  it "rails subsystem reports ok with db_connected true" do
    get endpoint, headers: auth_headers_for(reader)
    expect(json_response_data["health"]["rails"]["status"]).to eq("ok")
    expect(json_response_data["health"]["rails"]["db_connected"]).to be true
  end

  it "isolates per-subsystem failures via rescue" do
    # If a single subsystem raises, the endpoint still returns 200 — the
    # offending subsystem reports status=down with its error message,
    # not a 500 for the whole response.
    allow(::Sdwan::VirtualIp).to receive(:where).and_raise(StandardError, "synthetic")
    get endpoint, headers: auth_headers_for(reader)
    expect(response).to have_http_status(:ok)
    expect(json_response_data["health"]["sdwan"]["status"]).to eq("down")
    expect(json_response_data["health"]["rails"]["status"]).to eq("ok")
  end

  it "forbids without health.read permission" do
    anon = create(:user, account: account)
    get endpoint, headers: auth_headers_for(anon)
    expect(response).to have_http_status(:forbidden)
  end
end
