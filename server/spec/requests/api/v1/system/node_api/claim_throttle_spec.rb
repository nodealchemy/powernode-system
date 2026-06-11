# frozen_string_literal: true

require "rails_helper"

# Audit finding F6-03: the anonymous device-claim endpoint was unthrottled
# AND safelisted from every Rack::Attack throttle, allowing unbounded
# UnclaimedDevice creation by an unauthenticated caller varying the MAC.
# These specs pin the fix: the claim path is carved out of the node_api
# safelist and capped by the system_node_claim_by_ip throttle.
RSpec.describe "Rack::Attack throttling for POST /api/v1/system/node_api/claim", type: :request do
  let!(:account) { create(:account, name: "Powernode") }

  around do |example|
    original_store   = Rack::Attack.cache.store
    original_enabled = Rack::Attack.enabled
    Rack::Attack.enabled = true
    # Test Rails.cache may be a NullStore, which would never accumulate
    # throttle counters — use a real in-memory store for these examples.
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rack::Attack.cache.store = original_store
    Rack::Attack.enabled     = original_enabled
  end

  before do
    allow(Rack::Attack).to receive(:rate_limiting_enabled?).and_return(true)
    allow(Rack::Attack).to receive(:get_rate_limit).and_call_original
    allow(Rack::Attack).to receive(:get_rate_limit)
      .with("node_claim_attempts_per_minute", anything).and_return(3)
  end

  def claim(mac)
    post "/api/v1/system/node_api/claim",
         params: { mac: mac }.to_json,
         headers: { "Content-Type" => "application/json" }
  end

  it "throttles distinct-MAC discovery from one IP after the per-minute cap" do
    3.times do |i|
      claim("de:ad:00:00:00:0#{i}")
      expect(response).to have_http_status(:ok)
    end

    expect {
      claim("de:ad:00:00:00:99")
    }.not_to change { System::UnclaimedDevice.count }

    expect(response).to have_http_status(:too_many_requests)
  end

  it "keeps the claim path out of the node_api safelist while agent paths stay safelisted" do
    safelist = Rack::Attack.safelists.fetch("powernode_node_api")

    claim_req = Rack::Attack::Request.new(
      Rack::MockRequest.env_for("/api/v1/system/node_api/claim", method: "POST")
    )
    poll_req = Rack::Attack::Request.new(
      Rack::MockRequest.env_for("/api/v1/system/node_api/tasks", method: "GET")
    )

    expect(safelist.matched_by?(claim_req)).to be(false)
    expect(safelist.matched_by?(poll_req)).to be(true)
  end
end
