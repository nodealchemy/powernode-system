# frozen_string_literal: true

require "rails_helper"

RSpec.describe Acme::Ovh::DnsClient, type: :service do
  let(:application_key)    { "app-key-abc" }
  let(:application_secret) { "app-secret-xyz" }
  let(:consumer_key)       { "consumer-key-123" }
  let(:endpoint)           { "ovh-eu" }
  let(:base)               { "https://eu.api.ovh.com/1.0" }

  subject(:client) do
    described_class.new(
      application_key: application_key,
      application_secret: application_secret,
      consumer_key: consumer_key,
      endpoint: endpoint,
      logger: Logger.new(IO::NULL)
    )
  end

  # Every signed request first probes OVH server time. Stub it so the
  # client uses a deterministic, drift-free timestamp.
  before do
    stub_request(:get, "#{base}/auth/time")
      .to_return(status: 200, body: "1700000000", headers: { "Content-Type" => "text/plain" })
  end

  describe "#initialize" do
    it "raises when application_key is missing" do
      expect do
        described_class.new(application_secret: application_secret, consumer_key: consumer_key, endpoint: endpoint)
      end.to raise_error(ArgumentError, /application_key is required/)
    end

    it "raises when endpoint is missing" do
      expect do
        described_class.new(application_key: application_key, application_secret: application_secret,
                            consumer_key: consumer_key)
      end.to raise_error(ArgumentError, /endpoint is required/)
    end

    it "raises on an unknown endpoint slug" do
      expect do
        described_class.new(application_key: application_key, application_secret: application_secret,
                            consumer_key: consumer_key, endpoint: "ovh-mars")
      end.to raise_error(ArgumentError, /Unknown OVH endpoint/)
    end

    it "accepts a positional credentials hash" do
      c = described_class.new(
        { "application_key" => application_key, "application_secret" => application_secret,
          "consumer_key" => consumer_key, "endpoint" => endpoint },
        logger: Logger.new(IO::NULL)
      )
      expect(c).to be_a(described_class)
    end

    it "decodes the factory's api_token JSON blob" do
      blob = {
        application_key: application_key, application_secret: application_secret,
        consumer_key: consumer_key, endpoint: endpoint
      }.to_json
      c = described_class.new(api_token: blob, logger: Logger.new(IO::NULL))
      expect(c).to be_a(described_class)
    end

    it "resolves a full URL endpoint as-is" do
      stub_request(:get, "https://my.ovh.example/1.0/auth/time")
        .to_return(status: 200, body: "1700000000")
      stub_request(:get, "https://my.ovh.example/1.0/domain/zone")
        .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })

      c = described_class.new(application_key: application_key, application_secret: application_secret,
                              consumer_key: consumer_key, endpoint: "https://my.ovh.example/1.0",
                              logger: Logger.new(IO::NULL))
      expect(c.list_zones).to be_ok
    end
  end

  describe "request signing" do
    it "sends the OVH auth headers with a SHA1 $1$ signature" do
      stub = stub_request(:get, "#{base}/domain/zone")
        .with(headers: {
          "X-Ovh-Application" => application_key,
          "X-Ovh-Consumer" => consumer_key,
          "X-Ovh-Timestamp" => "1700000000"
        })
        .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })

      client.list_zones

      expect(stub).to have_been_requested
      expect(a_request(:get, "#{base}/domain/zone").with { |req|
        sig = req.headers["X-Ovh-Signature"]
        expected = "$1$" + Digest::SHA1.hexdigest(
          [ application_secret, consumer_key, "GET", "#{base}/domain/zone", "", 1_700_000_000 ].join("+")
        )
        sig == expected
      }).to have_been_made
    end

    it "probes /auth/time only once across multiple requests" do
      stub_request(:get, "#{base}/domain/zone")
        .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })

      client.list_zones
      client.list_zones

      expect(a_request(:get, "#{base}/auth/time")).to have_been_made.once
    end
  end

  describe "#list_zones" do
    it "maps bare domain names to id+name zones" do
      stub_request(:get, "#{base}/domain/zone")
        .to_return(status: 200, body: %w[example.com example.net].to_json,
                    headers: { "Content-Type" => "application/json" })

      result = client.list_zones
      expect(result).to be_ok
      expect(result.data).to contain_exactly(
        a_hash_including(id: "example.com", name: "example.com", status: "active"),
        a_hash_including(id: "example.net", name: "example.net", status: "active")
      )
    end

    it "client-filters by name" do
      stub_request(:get, "#{base}/domain/zone")
        .to_return(status: 200, body: %w[example.com example.net].to_json,
                    headers: { "Content-Type" => "application/json" })

      result = client.list_zones(name: "example.net")
      expect(result.data.map { |z| z[:name] }).to eq([ "example.net" ])
    end

    it "surfaces an API error as a non-ok Result" do
      stub_request(:get, "#{base}/domain/zone")
        .to_return(status: 403, body: { message: "Invalid signature", class: "Client::Forbidden" }.to_json,
                    headers: { "Content-Type" => "application/json" })

      result = client.list_zones
      expect(result).not_to be_ok
      expect(result.error).to eq("Invalid signature")
      expect(result.http_status).to eq(403)
      expect(result.cf_errors).to eq([ { code: "Client::Forbidden", message: "Invalid signature" } ])
    end
  end

  describe "#list_records" do
    it "hydrates each record id returned by the list endpoint" do
      stub_request(:get, "#{base}/domain/zone/example.com/record")
        .to_return(status: 200, body: [ 101, 102 ].to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:get, "#{base}/domain/zone/example.com/record/101")
        .to_return(status: 200,
                    body: { id: 101, zone: "example.com", fieldType: "A", subDomain: "www",
                            target: "203.0.113.1", ttl: 3600 }.to_json,
                    headers: { "Content-Type" => "application/json" })
      stub_request(:get, "#{base}/domain/zone/example.com/record/102")
        .to_return(status: 200,
                    body: { id: 102, zone: "example.com", fieldType: "TXT", subDomain: "",
                            target: "hello", ttl: 600 }.to_json,
                    headers: { "Content-Type" => "application/json" })

      result = client.list_records("example.com")
      expect(result).to be_ok
      expect(result.data).to eq([
        { id: "101", zone_id: "example.com", zone_name: "example.com", type: "A",
          name: "www.example.com", content: "203.0.113.1", ttl: 3600, proxied: false },
        { id: "102", zone_id: "example.com", zone_name: "example.com", type: "TXT",
          name: "example.com", content: "hello", ttl: 600, proxied: false }
      ])
    end

    it "passes fieldType + relativized subDomain filters to the list endpoint" do
      stub = stub_request(:get, "#{base}/domain/zone/example.com/record")
        .with(query: { fieldType: "A", subDomain: "www" })
        .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })

      client.list_records("example.com", type: "a", name: "www.example.com")
      expect(stub).to have_been_requested
    end

    it "returns the hydration error if a per-record GET fails" do
      stub_request(:get, "#{base}/domain/zone/example.com/record")
        .to_return(status: 200, body: [ 101 ].to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:get, "#{base}/domain/zone/example.com/record/101")
        .to_return(status: 404, body: { message: "Record not found" }.to_json,
                    headers: { "Content-Type" => "application/json" })

      result = client.list_records("example.com")
      expect(result).not_to be_ok
      expect(result.http_status).to eq(404)
    end
  end

  describe "#create_record" do
    it "POSTs the OVH field shape and refreshes the zone" do
      create_stub = stub_request(:post, "#{base}/domain/zone/example.com/record")
        .with(body: { fieldType: "A", subDomain: "www", target: "203.0.113.5", ttl: 3600 })
        .to_return(status: 200,
                    body: { id: 555, zone: "example.com", fieldType: "A", subDomain: "www",
                            target: "203.0.113.5", ttl: 3600 }.to_json,
                    headers: { "Content-Type" => "application/json" })
      refresh_stub = stub_request(:post, "#{base}/domain/zone/example.com/refresh")
        .to_return(status: 200, body: "", headers: { "Content-Type" => "application/json" })

      result = client.create_record("example.com", type: "A", name: "www.example.com",
                                    content: "203.0.113.5", ttl: 3600)
      expect(result).to be_ok
      expect(result.data).to include(id: "555", type: "A", name: "www.example.com", content: "203.0.113.5")
      expect(create_stub).to have_been_requested
      expect(refresh_stub).to have_been_requested
    end

    it "maps the Cloudflare ttl=1 sentinel to OVH's 3600 default" do
      stub = stub_request(:post, "#{base}/domain/zone/example.com/record")
        .with(body: hash_including("ttl" => 3600))
        .to_return(status: 200,
                    body: { id: 1, fieldType: "A", subDomain: "x", target: "1.2.3.4", ttl: 3600 }.to_json,
                    headers: { "Content-Type" => "application/json" })
      stub_request(:post, "#{base}/domain/zone/example.com/refresh").to_return(status: 200, body: "")

      client.create_record("example.com", type: "A", name: "x.example.com", content: "1.2.3.4")
      expect(stub).to have_been_requested
    end

    it "rejects an unsupported record type before any HTTP call" do
      expect do
        client.create_record("example.com", type: "BOGUS", name: "x", content: "y")
      end.to raise_error(Acme::Ovh::DnsClient::ApiError, /Unsupported record type/)
    end

    it "does not refresh when the create fails" do
      stub_request(:post, "#{base}/domain/zone/example.com/record")
        .to_return(status: 400, body: { message: "bad target" }.to_json,
                    headers: { "Content-Type" => "application/json" })

      result = client.create_record("example.com", type: "A", name: "x.example.com", content: "bad")
      expect(result).not_to be_ok
      expect(result.error).to eq("bad target")
      expect(a_request(:post, "#{base}/domain/zone/example.com/refresh")).not_to have_been_made
    end
  end

  describe "#delete_record" do
    it "DELETEs the record and refreshes the zone" do
      del_stub = stub_request(:delete, "#{base}/domain/zone/example.com/record/777")
        .to_return(status: 200, body: "", headers: { "Content-Type" => "application/json" })
      refresh_stub = stub_request(:post, "#{base}/domain/zone/example.com/refresh")
        .to_return(status: 200, body: "")

      result = client.delete_record("example.com", "777")
      expect(result).to be_ok
      expect(result.data).to eq({ deleted: true })
      expect(del_stub).to have_been_requested
      expect(refresh_stub).to have_been_requested
    end

    it "treats 204 No Content as a successful delete" do
      stub_request(:delete, "#{base}/domain/zone/example.com/record/777")
        .to_return(status: 204, body: "")
      stub_request(:post, "#{base}/domain/zone/example.com/refresh").to_return(status: 200, body: "")

      result = client.delete_record("example.com", "777")
      expect(result).to be_ok
    end

    it "surfaces a delete failure and skips the refresh" do
      stub_request(:delete, "#{base}/domain/zone/example.com/record/missing")
        .to_return(status: 404, body: { message: "Record not found" }.to_json,
                    headers: { "Content-Type" => "application/json" })

      result = client.delete_record("example.com", "missing")
      expect(result).not_to be_ok
      expect(result.http_status).to eq(404)
      expect(a_request(:post, "#{base}/domain/zone/example.com/refresh")).not_to have_been_made
    end
  end

  describe "error handling" do
    it "wraps a connection timeout in a non-ok Result" do
      stub_request(:get, "#{base}/domain/zone").to_timeout

      result = client.list_zones
      expect(result).not_to be_ok
      expect(result.error).to match(/OVH API (timeout|error)/)
    end

    it "returns a parse error for malformed JSON" do
      stub_request(:get, "#{base}/domain/zone")
        .to_return(status: 200, body: "not json{", headers: { "Content-Type" => "application/json" })

      result = client.list_zones
      expect(result).not_to be_ok
      expect(result.error).to match(/Invalid JSON from OVH/)
    end
  end
end
