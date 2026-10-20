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

  it "counts /enroll.json and /enroll/ against the same cap (no suffix bypass)" do
    json_enroll = lambda do
      post "/api/v1/system/node_api/enroll.json", params: { bootstrap_token: "k", csr_pem: "x" }.to_json,
                                                 headers: { "Content-Type" => "application/json" }
    end
    slash_enroll = lambda do
      post "/api/v1/system/node_api/enroll/", params: { bootstrap_token: "k", csr_pem: "x" }.to_json,
                                             headers: { "Content-Type" => "application/json" }
    end
    json_enroll.call
    slash_enroll.call
    enroll
    expect(response).not_to have_http_status(:too_many_requests)

    json_enroll.call
    expect(response).to have_http_status(:too_many_requests)
  end

  it "counts //enroll, enroll.xml and enroll.txt against the same cap (any format, squeezed slashes)" do
    hdr = { "Content-Type" => "application/json" }
    body = { bootstrap_token: "k", csr_pem: "x" }.to_json
    post "/api/v1/system/node_api//enroll", params: body, headers: hdr
    post "/api/v1/system/node_api/enroll.xml", params: body, headers: hdr
    post "/api/v1/system/node_api/enroll.txt", params: body, headers: hdr
    expect(response).not_to have_http_status(:too_many_requests)

    enroll
    expect(response).to have_http_status(:too_many_requests)
  end

  it "counts exotic format suffixes (.a-b, %xx, ;x) against the same cap" do
    hdr = { "Content-Type" => "application/json" }
    body = { bootstrap_token: "k", csr_pem: "x" }.to_json
    %w[enroll.json-x enroll.j%73on enroll.json;x].each do |tail|
      post "/api/v1/system/node_api/#{tail}", params: body, headers: hdr
    end
    expect(response).not_to have_http_status(:too_many_requests)
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
    expect(safelist.matched_by?(req.call("/api/v1/system/node_api/enroll.json", "POST"))).to be(false)
    expect(safelist.matched_by?(req.call("/api/v1/system/node_api/enroll/", "POST"))).to be(false)
    expect(safelist.matched_by?(req.call("/api/v1/system/node_api/claim.json", "POST"))).to be(false)
    expect(safelist.matched_by?(req.call("/api/v1/system/node_api/claim/", "POST"))).to be(false)
    %w[//enroll enroll.xml enroll.txt enroll.json/ ].each do |tail|
      expect(safelist.matched_by?(req.call("/api/v1/system/node_api/#{tail}", "POST"))).to be(false), tail
    end
    %w[enroll.json-x enroll.j%73on enroll.json;x enroll.%C3%A9 claim.a-b claim.j%73on claim.json;x].each do |tail|
      expect(safelist.matched_by?(req.call("/api/v1/system/node_api/#{tail}", "POST"))).to be(false), tail
    end
    %w[//claim claim.xml claim.txt].each do |tail|
      expect(safelist.matched_by?(req.call("/api/v1/system/node_api/#{tail}", "POST"))).to be(false), tail
    end
    expect(safelist.matched_by?(req.call("/api/v1/system/node_api/enroll/refresh", "POST"))).to be(true)
    expect(safelist.matched_by?(req.call("/api/v1/system/node_api/enroll/refresh.json", "POST"))).to be(true)
    expect(safelist.matched_by?(req.call("/api/v1/system//node_api/tasks", "GET"))).to be(true)
    expect(safelist.matched_by?(req.call("/api/v1/system/worker_api/fleet/reconcile.json", "POST"))).to be(true)
    expect(safelist.matched_by?(req.call("/api/v1/system/federation_api/ping", "GET"))).to be(true)
    expect(safelist.matched_by?(req.call("/api/v1/system/node_api/tasks", "GET"))).to be(true)
  end
end
