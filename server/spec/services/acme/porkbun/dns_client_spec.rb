# frozen_string_literal: true

require "rails_helper"

RSpec.describe Acme::Porkbun::DnsClient, type: :service do
  let(:api_key) { "pk1_testkey" }
  let(:secret_api_key) { "sk1_testsecret" }
  let(:client) { described_class.new(api_key: api_key, secret_api_key: secret_api_key) }
  let(:base) { "https://porkbun.com/api/json/v3" }
  let(:zone) { "example.com" }

  # Matches Porkbun's required body shape: every request POSTs JSON with
  # the credentials inlined (no header auth).
  def auth_body(extra = {})
    { "apikey" => api_key, "secretapikey" => secret_api_key }.merge(extra)
  end

  describe "#initialize" do
    it "accepts explicit keyword credentials" do
      expect { described_class.new(api_key: api_key, secret_api_key: secret_api_key) }.not_to raise_error
    end

    it "accepts a credentials hash (string keys)" do
      c = described_class.new(credentials: { "api_key" => api_key, "secret_api_key" => secret_api_key })
      expect(c).to be_a(described_class)
    end

    it "accepts a credentials hash (symbol keys)" do
      c = described_class.new(credentials: { api_key: api_key, secret_api_key: secret_api_key })
      expect(c).to be_a(described_class)
    end

    it "accepts a positional credentials hash" do
      c = described_class.new({ "api_key" => api_key, "secret_api_key" => secret_api_key })
      expect(c).to be_a(described_class)
    end

    it "accepts the factory's api_token: as a JSON-encoded blob" do
      blob = { api_key: api_key, secret_api_key: secret_api_key }.to_json
      c = described_class.new(api_token: blob)
      expect(c).to be_a(described_class)
    end

    it "raises when the api_token: blob is not valid JSON (no credentials resolved)" do
      expect { described_class.new(api_token: "not-json") }
        .to raise_error(ArgumentError, /api_key is required/)
    end

    it "raises when api_key is missing" do
      expect { described_class.new(secret_api_key: secret_api_key) }
        .to raise_error(ArgumentError, /api_key is required/)
    end

    it "raises when secret_api_key is missing" do
      expect { described_class.new(api_key: api_key) }
        .to raise_error(ArgumentError, /secret_api_key is required/)
    end
  end

  describe "#list_zones" do
    it "maps domains to {id, name} and inlines credentials in the body (happy path)" do
      stub = stub_request(:post, "#{base}/domain/listAll")
             .with(body: auth_body("start" => "0"))
             .to_return(
               status: 200,
               body: {
                 status: "SUCCESS",
                 domains: [
                   { domain: "example.com", status: "ACTIVE", tld: "com" },
                   { domain: "other.net", status: "ACTIVE", tld: "net" }
                 ]
               }.to_json,
               headers: { "Content-Type" => "application/json" }
             )

      result = client.list_zones

      expect(stub).to have_been_requested
      expect(result.ok?).to be true
      expect(result.data.map { |z| z[:name] }).to contain_exactly("example.com", "other.net")
      expect(result.data.first[:id]).to eq("example.com")
    end

    it "client-filters by name when provided" do
      stub_request(:post, "#{base}/domain/listAll")
        .to_return(
          status: 200,
          body: {
            status: "SUCCESS",
            domains: [
              { domain: "example.com" },
              { domain: "other.net" }
            ]
          }.to_json
        )

      result = client.list_zones(name: "example.com")

      expect(result.ok?).to be true
      expect(result.data.map { |z| z[:name] }).to eq([ "example.com" ])
    end

    it "returns an error Result on a Porkbun ERROR envelope (error path)" do
      stub_request(:post, "#{base}/domain/listAll")
        .to_return(
          status: 400,
          body: { status: "ERROR", message: "Invalid API key." }.to_json
        )

      result = client.list_zones

      expect(result.ok?).to be false
      expect(result.error).to eq("Invalid API key.")
      expect(result.http_status).to eq(400)
      expect(result.cf_errors.first[:message]).to eq("Invalid API key.")
    end

    it "treats a 200 with status!=SUCCESS as a failure" do
      stub_request(:post, "#{base}/domain/listAll")
        .to_return(status: 200, body: { status: "ERROR", message: "Unexpected." }.to_json)

      result = client.list_zones

      expect(result.ok?).to be false
      expect(result.error).to eq("Unexpected.")
    end
  end

  describe "#list_records" do
    it "normalizes records under 'records' (happy path)" do
      stub = stub_request(:post, "#{base}/dns/retrieve/#{zone}")
             .with(body: auth_body)
             .to_return(
               status: 200,
               body: {
                 status: "SUCCESS",
                 records: [
                   { id: "111", name: "www.example.com", type: "A", content: "1.2.3.4", ttl: "600", prio: "0" },
                   { id: "222", name: "example.com", type: "TXT", content: "hello", ttl: "600" }
                 ]
               }.to_json
             )

      result = client.list_records(zone)

      expect(stub).to have_been_requested
      expect(result.ok?).to be true
      first = result.data.first
      expect(first[:id]).to eq("111")
      expect(first[:name]).to eq("www.example.com")
      expect(first[:content]).to eq("1.2.3.4")
      expect(first[:ttl]).to eq(600)
      expect(first[:zone_id]).to eq(zone)
      expect(first[:proxied]).to be false
    end

    it "client-filters by type" do
      stub_request(:post, "#{base}/dns/retrieve/#{zone}")
        .to_return(
          status: 200,
          body: {
            status: "SUCCESS",
            records: [
              { id: "111", name: "www.example.com", type: "A", content: "1.2.3.4", ttl: "600" },
              { id: "222", name: "example.com", type: "TXT", content: "hello", ttl: "600" }
            ]
          }.to_json
        )

      result = client.list_records(zone, type: "txt")

      expect(result.ok?).to be true
      expect(result.data.map { |r| r[:type] }).to eq([ "TXT" ])
    end

    it "returns an error Result on failure (error path)" do
      stub_request(:post, "#{base}/dns/retrieve/#{zone}")
        .to_return(status: 400, body: { status: "ERROR", message: "Domain not found." }.to_json)

      result = client.list_records(zone)

      expect(result.ok?).to be false
      expect(result.error).to eq("Domain not found.")
      expect(result.http_status).to eq(400)
    end
  end

  describe "#create_record" do
    it "posts the subdomain-only name and re-reads the record (happy path)" do
      create_stub = stub_request(:post, "#{base}/dns/create/#{zone}")
                    .with(body: auth_body("name" => "www", "type" => "A", "content" => "1.2.3.4", "ttl" => 600))
                    .to_return(status: 200, body: { status: "SUCCESS", id: 333 }.to_json)

      read_stub = stub_request(:post, "#{base}/dns/retrieve/#{zone}/333")
                  .with(body: auth_body)
                  .to_return(
                    status: 200,
                    body: {
                      status: "SUCCESS",
                      records: [ { id: "333", name: "www.example.com", type: "A", content: "1.2.3.4", ttl: "600" } ]
                    }.to_json
                  )

      result = client.create_record(zone, type: "A", name: "www.example.com", content: "1.2.3.4")

      expect(create_stub).to have_been_requested
      expect(read_stub).to have_been_requested
      expect(result.ok?).to be true
      expect(result.data[:id]).to eq("333")
      expect(result.data[:name]).to eq("www.example.com")
    end

    it "maps ttl=1 (auto) to Porkbun's 600 floor" do
      stub_request(:post, "#{base}/dns/create/#{zone}")
        .with(body: auth_body("name" => "auto", "type" => "A", "content" => "9.9.9.9", "ttl" => 600))
        .to_return(status: 200, body: { status: "SUCCESS", id: 1 }.to_json)
      stub_request(:post, "#{base}/dns/retrieve/#{zone}/1")
        .to_return(status: 200,
                   body: { status: "SUCCESS", records: [ { id: "1", name: "auto.example.com", type: "A", content: "9.9.9.9", ttl: "600" } ] }.to_json)

      result = client.create_record(zone, type: "A", name: "auto.example.com", content: "9.9.9.9", ttl: 1)
      expect(result.ok?).to be true
    end

    it "raises ApiError on an unsupported record type (does not hit network)" do
      expect { client.create_record(zone, type: "BOGUS", name: "x", content: "y") }
        .to raise_error(described_class::ApiError, /Unsupported record type/)
    end

    it "returns an error Result when Porkbun rejects the create (error path)" do
      stub_request(:post, "#{base}/dns/create/#{zone}")
        .to_return(status: 400, body: { status: "ERROR", message: "Record content invalid." }.to_json)

      result = client.create_record(zone, type: "A", name: "bad.example.com", content: "not-an-ip")

      expect(result.ok?).to be false
      expect(result.error).to eq("Record content invalid.")
      expect(result.http_status).to eq(400)
    end
  end

  describe "#delete_record" do
    it "posts to the delete endpoint and returns deleted: true (happy path)" do
      stub = stub_request(:post, "#{base}/dns/delete/#{zone}/444")
             .with(body: auth_body)
             .to_return(status: 200, body: { status: "SUCCESS" }.to_json)

      result = client.delete_record(zone, 444)

      expect(stub).to have_been_requested
      expect(result.ok?).to be true
      expect(result.data[:deleted]).to be true
    end

    it "returns an error Result on failure (error path)" do
      stub_request(:post, "#{base}/dns/delete/#{zone}/444")
        .to_return(status: 400, body: { status: "ERROR", message: "Record not found." }.to_json)

      result = client.delete_record(zone, 444)

      expect(result.ok?).to be false
      expect(result.error).to eq("Record not found.")
      expect(result.http_status).to eq(400)
    end
  end

  describe "error handling" do
    it "wraps a read timeout in a failed Result" do
      stub_request(:post, "#{base}/domain/listAll").to_timeout

      result = client.list_zones

      expect(result.ok?).to be false
      expect(result.error).to match(/Porkbun API (timeout|error)/)
    end

    it "wraps invalid JSON in a failed Result" do
      stub_request(:post, "#{base}/domain/listAll")
        .to_return(status: 200, body: "<html>not json</html>")

      result = client.list_zones

      expect(result.ok?).to be false
      expect(result.error).to match(/Invalid JSON from Porkbun/)
    end
  end
end
