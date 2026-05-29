# frozen_string_literal: true

require "rails_helper"

RSpec.describe Acme::Gcloud::DnsClient, type: :service do
  # A throwaway RSA key so the JWT-bearer signing step runs for real
  # (we never hit the network — the OAuth exchange is WebMock-stubbed).
  let(:rsa_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:project_id) { "my-project" }
  let(:client_email) { "dns@my-project.iam.gserviceaccount.com" }
  let(:service_account_json) do
    {
      type: "service_account",
      project_id: project_id,
      client_email: client_email,
      private_key: rsa_key.to_pem
    }.to_json
  end

  let(:client) do
    described_class.new(service_account_json: service_account_json, project_id: project_id)
  end

  let(:oauth_url) { "https://oauth2.googleapis.com/token" }
  let(:dns_base) { "https://dns.googleapis.com/dns/v1/projects/#{project_id}" }
  let(:zone) { "example-zone" }
  let(:access_token) { "ya29.test-access-token" }

  # Every DNS request first exchanges a signed JWT for an access_token.
  before do
    stub_request(:post, oauth_url)
      .to_return(
        status: 200,
        body: { access_token: access_token, token_type: "Bearer", expires_in: 3600 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  describe "#initialize" do
    it "accepts explicit keyword credentials" do
      expect { described_class.new(service_account_json: service_account_json, project_id: project_id) }
        .not_to raise_error
    end

    it "accepts a credentials hash (string keys)" do
      c = described_class.new(credentials: { "service_account_json" => service_account_json, "project_id" => project_id })
      expect(c).to be_a(described_class)
    end

    it "accepts a credentials hash (symbol keys)" do
      c = described_class.new(credentials: { service_account_json: service_account_json, project_id: project_id })
      expect(c).to be_a(described_class)
    end

    it "raises when service_account_json is missing" do
      expect { described_class.new(project_id: project_id) }
        .to raise_error(ArgumentError, /service_account_json is required/)
    end

    it "raises when project_id is missing" do
      expect { described_class.new(service_account_json: service_account_json) }
        .to raise_error(ArgumentError, /project_id is required/)
    end
  end

  describe "OAuth token exchange" do
    it "mints a JWT-bearer assertion and bearers the returned access_token on DNS calls" do
      token_stub = stub_request(:post, oauth_url)
                   .with(body: hash_including("grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer"))
                   .to_return(status: 200, body: { access_token: access_token, expires_in: 3600 }.to_json)

      dns_stub = stub_request(:get, "#{dns_base}/managedZones")
                 .with(headers: { "Authorization" => "Bearer #{access_token}" })
                 .with(query: hash_including("maxResults" => "50"))
                 .to_return(status: 200, body: { managedZones: [] }.to_json)

      result = client.list_zones

      expect(token_stub).to have_been_requested
      expect(dns_stub).to have_been_requested
      expect(result.ok?).to be true
    end

    it "caches the access_token across multiple calls (single token exchange)" do
      stub_request(:get, "#{dns_base}/managedZones").to_return(status: 200, body: { managedZones: [] }.to_json)

      client.list_zones
      client.list_zones

      expect(a_request(:post, oauth_url)).to have_been_made.once
    end

    it "surfaces an OAuth failure as a failed Result" do
      stub_request(:post, oauth_url)
        .to_return(status: 401, body: { error: "invalid_grant", error_description: "Invalid JWT" }.to_json)

      result = client.list_zones

      expect(result.ok?).to be false
      expect(result.error).to match(/Google OAuth token exchange failed: Invalid JWT/)
    end

    it "fails clearly when the service_account_json is not valid JSON" do
      bad = described_class.new(service_account_json: "{not json", project_id: project_id)
      result = bad.list_zones
      expect(result.ok?).to be false
      expect(result.error).to match(/not valid JSON/)
    end
  end

  describe "#list_zones" do
    it "maps managedZones to {id, name} stripping the trailing dot (happy path)" do
      stub = stub_request(:get, "#{dns_base}/managedZones")
             .with(query: hash_including("maxResults" => "50"))
             .to_return(
               status: 200,
               body: {
                 managedZones: [
                   { name: "example-zone", dnsName: "example.com.", description: "primary" },
                   { name: "other-zone", dnsName: "other.net." }
                 ]
               }.to_json,
               headers: { "Content-Type" => "application/json" }
             )

      result = client.list_zones

      expect(stub).to have_been_requested
      expect(result.ok?).to be true
      expect(result.data.map { |z| z[:id] }).to contain_exactly("example-zone", "other-zone")
      expect(result.data.map { |z| z[:name] }).to contain_exactly("example.com", "other.net")
    end

    it "passes a trailing-dot dnsName filter when name is provided" do
      stub = stub_request(:get, "#{dns_base}/managedZones")
             .with(query: hash_including("dnsName" => "example.com."))
             .to_return(status: 200, body: { managedZones: [ { name: "example-zone", dnsName: "example.com." } ] }.to_json)

      result = client.list_zones(name: "example.com")

      expect(stub).to have_been_requested
      expect(result.ok?).to be true
      expect(result.data.first[:name]).to eq("example.com")
    end

    it "returns an error Result on a Google error envelope (error path)" do
      stub_request(:get, "#{dns_base}/managedZones")
        .with(query: hash_including("maxResults" => "50"))
        .to_return(
          status: 403,
          body: { error: { code: 403, message: "Permission denied.",
                           errors: [ { reason: "forbidden", message: "Permission denied." } ] } }.to_json
        )

      result = client.list_zones

      expect(result.ok?).to be false
      expect(result.error).to eq("Permission denied.")
      expect(result.http_status).to eq(403)
      expect(result.cf_errors.first[:code]).to eq("forbidden")
    end
  end

  describe "#list_records" do
    it "normalizes rrsets to the shared record shape (happy path)" do
      stub = stub_request(:get, "#{dns_base}/managedZones/#{zone}/rrsets")
             .with(query: hash_including("maxResults" => "100"))
             .to_return(
               status: 200,
               body: {
                 rrsets: [
                   { name: "www.example.com.", type: "A", ttl: 300, rrdatas: [ "1.2.3.4" ] },
                   { name: "example.com.", type: "TXT", ttl: 300, rrdatas: [ '"hello world"' ] }
                 ]
               }.to_json
             )

      result = client.list_records(zone)

      expect(stub).to have_been_requested
      expect(result.ok?).to be true
      a_rec = result.data.first
      expect(a_rec[:id]).to eq("www.example.com.|A")
      expect(a_rec[:name]).to eq("www.example.com")
      expect(a_rec[:content]).to eq("1.2.3.4")
      expect(a_rec[:ttl]).to eq(300)
      expect(a_rec[:zone_id]).to eq(zone)
      expect(a_rec[:proxied]).to be false
      # TXT rrdatas are unquoted at the contract boundary
      txt_rec = result.data.last
      expect(txt_rec[:content]).to eq("hello world")
    end

    it "passes a type filter through to the rrsets query" do
      stub = stub_request(:get, "#{dns_base}/managedZones/#{zone}/rrsets")
             .with(query: hash_including("type" => "TXT"))
             .to_return(status: 200, body: { rrsets: [] }.to_json)

      client.list_records(zone, type: "txt")

      expect(stub).to have_been_requested
    end

    it "returns an error Result on failure (error path)" do
      stub_request(:get, "#{dns_base}/managedZones/#{zone}/rrsets")
        .with(query: hash_including("maxResults" => "100"))
        .to_return(status: 404, body: { error: { code: 404, message: "Zone not found." } }.to_json)

      result = client.list_records(zone)

      expect(result.ok?).to be false
      expect(result.error).to eq("Zone not found.")
      expect(result.http_status).to eq(404)
    end
  end

  describe "#create_record" do
    it "POSTs a change with additions carrying the rrset (happy path)" do
      stub = stub_request(:post, "#{dns_base}/managedZones/#{zone}/changes")
             .with(body: hash_including(
               "additions" => [ { "name" => "www.example.com.", "type" => "A",
                                  "ttl" => 300, "rrdatas" => [ "1.2.3.4" ] } ]
             ))
             .to_return(
               status: 200,
               body: {
                 additions: [ { name: "www.example.com.", type: "A", ttl: 300, rrdatas: [ "1.2.3.4" ] } ]
               }.to_json
             )

      result = client.create_record(zone, type: "A", name: "www.example.com", content: "1.2.3.4", ttl: 300)

      expect(stub).to have_been_requested
      expect(result.ok?).to be true
      expect(result.data[:name]).to eq("www.example.com")
      expect(result.data[:content]).to eq("1.2.3.4")
    end

    it "maps ttl=1 (auto) to the default TTL" do
      stub = stub_request(:post, "#{dns_base}/managedZones/#{zone}/changes")
             .with(body: hash_including(
               "additions" => [ { "name" => "auto.example.com.", "type" => "A",
                                  "ttl" => 300, "rrdatas" => [ "9.9.9.9" ] } ]
             ))
             .to_return(status: 200, body: { additions: [ { name: "auto.example.com.", type: "A", ttl: 300, rrdatas: [ "9.9.9.9" ] } ] }.to_json)

      result = client.create_record(zone, type: "A", name: "auto.example.com", content: "9.9.9.9", ttl: 1)

      expect(stub).to have_been_requested
      expect(result.ok?).to be true
    end

    it "quotes TXT rrdatas in the change body" do
      stub = stub_request(:post, "#{dns_base}/managedZones/#{zone}/changes")
             .with(body: hash_including(
               "additions" => [ { "name" => "example.com.", "type" => "TXT",
                                  "ttl" => 300, "rrdatas" => [ '"verify=abc"' ] } ]
             ))
             .to_return(status: 200, body: { additions: [ { name: "example.com.", type: "TXT", ttl: 300, rrdatas: [ '"verify=abc"' ] } ] }.to_json)

      result = client.create_record(zone, type: "TXT", name: "example.com", content: "verify=abc")

      expect(stub).to have_been_requested
      expect(result.ok?).to be true
    end

    it "raises ApiError on an unsupported record type (does not hit network)" do
      expect { client.create_record(zone, type: "BOGUS", name: "x", content: "y") }
        .to raise_error(described_class::ApiError, /Unsupported record type/)
    end

    it "returns an error Result when Google rejects the change (error path)" do
      stub_request(:post, "#{dns_base}/managedZones/#{zone}/changes")
        .to_return(status: 409, body: { error: { code: 409, message: "The resource already exists." } }.to_json)

      result = client.create_record(zone, type: "A", name: "dup.example.com", content: "1.2.3.4")

      expect(result.ok?).to be false
      expect(result.error).to eq("The resource already exists.")
      expect(result.http_status).to eq(409)
    end
  end

  describe "#delete_record" do
    let(:record_id) { "old.example.com.|A" }

    # Delete first reads the existing rrset (to build the exact deletion
    # payload Google requires) then POSTs a change with deletions.
    before do
      stub_request(:get, "#{dns_base}/managedZones/#{zone}/rrsets")
        .with(query: hash_including("type" => "A", "name" => "old.example.com."))
        .to_return(
          status: 200,
          body: { rrsets: [ { name: "old.example.com.", type: "A", ttl: 300, rrdatas: [ "1.1.1.1" ] } ] }.to_json
        )
    end

    it "reads the rrset then POSTs a deletions change (happy path)" do
      del_stub = stub_request(:post, "#{dns_base}/managedZones/#{zone}/changes")
                 .with(body: hash_including(
                   "deletions" => [ { "name" => "old.example.com.", "type" => "A",
                                      "ttl" => 300, "rrdatas" => [ "1.1.1.1" ] } ]
                 ))
                 .to_return(status: 200, body: { deletions: [ { name: "old.example.com.", type: "A" } ] }.to_json)

      result = client.delete_record(zone, record_id)

      expect(del_stub).to have_been_requested
      expect(result.ok?).to be true
      expect(result.data[:deleted]).to be true
    end

    it "returns a 404 Result when the record does not exist" do
      stub_request(:get, "#{dns_base}/managedZones/#{zone}/rrsets")
        .with(query: hash_including("type" => "A", "name" => "old.example.com."))
        .to_return(status: 200, body: { rrsets: [] }.to_json)

      result = client.delete_record(zone, record_id)

      expect(result.ok?).to be false
      expect(result.http_status).to eq(404)
      expect(result.error).to match(/not found/)
    end

    it "returns an error Result when the deletions change fails (error path)" do
      stub_request(:post, "#{dns_base}/managedZones/#{zone}/changes")
        .to_return(status: 412, body: { error: { code: 412, message: "Precondition failed." } }.to_json)

      result = client.delete_record(zone, record_id)

      expect(result.ok?).to be false
      expect(result.error).to eq("Precondition failed.")
      expect(result.http_status).to eq(412)
    end
  end

  describe "error handling" do
    it "wraps a read timeout in a failed Result" do
      stub_request(:get, "#{dns_base}/managedZones").to_timeout

      result = client.list_zones

      expect(result.ok?).to be false
      expect(result.error).to match(/Google Cloud DNS API (timeout|error)/)
    end

    it "wraps invalid JSON in a failed Result" do
      stub_request(:get, "#{dns_base}/managedZones")
        .with(query: hash_including("maxResults" => "50"))
        .to_return(status: 200, body: "<html>not json</html>")

      result = client.list_zones

      expect(result.ok?).to be false
      expect(result.error).to match(/Invalid JSON from Google Cloud DNS/)
    end
  end
end
