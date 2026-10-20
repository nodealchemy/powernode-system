# frozen_string_literal: true

require "rails_helper"

# IMP-02a42b90598b (Provisioning D13): POST /node_api/enroll is the anonymous,
# bootstrap-token-authenticated endpoint. Like /claim it was safelisted out of
# every throttle, so an unauthenticated caller could grind keys / burn CA
# signing capacity without limit. It is carved out of the node_api safelist and
# capped per IP. /enroll/refresh stays safelisted: it needs the instance's
# CURRENT mTLS cert (not anonymous) and throttling it would starve a fleet
# behind one NAT of its own cert rotation.
RSpec.describe "Rack::Attack throttling for POST /api/v1/system/node_api/enroll", type: :request do
  around do |example|
    original_store   = Rack::Attack.cache.store
    original_enabled = Rack::Attack.enabled
    Rack::Attack.enabled = true
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
      .with("node_enroll_attempts_per_minute", anything).and_return(3)
  end

  def enroll
    post "/api/v1/system/node_api/enroll",
         params: { bootstrap_token: "not-a-real-key", csr_pem: "x" }.to_json,
         headers: { "Content-Type" => "application/json" }
  end

  it "answers 429 after the per-minute cap from one IP" do
    3.times do
      enroll
      expect(response).not_to have_http_status(:too_many_requests)
    end

    enroll
    expect(response).to have_http_status(:too_many_requests)
  end

  it "does not count another IP against the cap" do
    3.times { enroll }
    post "/api/v1/system/node_api/enroll",
         params: { bootstrap_token: "k", csr_pem: "x" }.to_json,
         headers: { "Content-Type" => "application/json" },
         env: { "REMOTE_ADDR" => "203.0.113.9" }
    expect(response).not_to have_http_status(:too_many_requests)
  end

  it "carves /enroll out of the node_api safelist; /enroll/refresh and agent paths stay safelisted" do
    safelist = Rack::Attack.safelists.fetch("powernode_node_api")
    req = ->(path, method) { Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: method)) }

    expect(safelist.matched_by?(req.call("/api/v1/system/node_api/enroll", "POST"))).to be(false)
    expect(safelist.matched_by?(req.call("/api/v1/system/node_api/enroll/refresh", "POST"))).to be(true)
    expect(safelist.matched_by?(req.call("/api/v1/system/node_api/tasks", "GET"))).to be(true)
  end
end
