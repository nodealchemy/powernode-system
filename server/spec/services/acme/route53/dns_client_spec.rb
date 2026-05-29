# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

# Unit spec for the Route53 DNS adapter. Every HTTP call is stubbed at
# the Net::HTTP boundary with WebMock — no live AWS network, no real
# SigV4 round-trip against the service. We assert on the normalized
# Result shape (the shared Acme::Cloudflare::DnsClient::Result struct)
# and on the request bodies/headers we put on the wire.
#
# Route53 specifics exercised here:
#   - SigV4 Authorization header is generated and sent (we don't verify
#     the signature cryptographically — that's aws-sigv4's job — only
#     that the adapter signs every request).
#   - XML request bodies (ChangeResourceRecordSetsRequest) for
#     create/delete carry the right Action + ResourceRecordSet.
#   - XML responses are parsed and the "/hostedzone/" prefix stripped.
#   - <ErrorResponse> bodies surface as ok? == false with the message.
RSpec.describe Acme::Route53::DnsClient do
  subject(:client) do
    described_class.new(
      access_key_id: "AKIAEXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      region: "us-east-1"
    )
  end

  let(:base) { "https://route53.amazonaws.com/2013-04-01" }
  let(:zone_id) { "Z123456789ABCDEFGHIJ" }

  # ── Fixtures ──────────────────────────────────────────────────────────

  def list_zones_xml
    <<~XML
      <?xml version="1.0"?>
      <ListHostedZonesResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
        <HostedZones>
          <HostedZone>
            <Id>/hostedzone/#{zone_id}</Id>
            <Name>example.com.</Name>
            <Config><PrivateZone>false</PrivateZone></Config>
            <ResourceRecordSetCount>4</ResourceRecordSetCount>
          </HostedZone>
          <HostedZone>
            <Id>/hostedzone/Z000OTHER0000000000</Id>
            <Name>other.net.</Name>
            <Config><PrivateZone>false</PrivateZone></Config>
            <ResourceRecordSetCount>2</ResourceRecordSetCount>
          </HostedZone>
        </HostedZones>
        <IsTruncated>false</IsTruncated>
        <MaxItems>50</MaxItems>
      </ListHostedZonesResponse>
    XML
  end

  def list_rrset_xml
    <<~XML
      <?xml version="1.0"?>
      <ListResourceRecordSetsResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
        <ResourceRecordSets>
          <ResourceRecordSet>
            <Name>www.example.com.</Name>
            <Type>A</Type>
            <TTL>300</TTL>
            <ResourceRecords>
              <ResourceRecord><Value>192.0.2.1</Value></ResourceRecord>
              <ResourceRecord><Value>192.0.2.2</Value></ResourceRecord>
            </ResourceRecords>
          </ResourceRecordSet>
          <ResourceRecordSet>
            <Name>example.com.</Name>
            <Type>NS</Type>
            <TTL>172800</TTL>
            <ResourceRecords>
              <ResourceRecord><Value>ns-1.awsdns.com.</Value></ResourceRecord>
            </ResourceRecords>
          </ResourceRecordSet>
        </ResourceRecordSets>
        <IsTruncated>false</IsTruncated>
        <MaxItems>100</MaxItems>
      </ListResourceRecordSetsResponse>
    XML
  end

  def change_response_xml(status: "PENDING")
    <<~XML
      <?xml version="1.0"?>
      <ChangeResourceRecordSetsResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
        <ChangeInfo>
          <Id>/change/C2682N5HXP0BZ4</Id>
          <Status>#{status}</Status>
          <SubmittedAt>2026-05-28T00:00:00Z</SubmittedAt>
        </ChangeInfo>
      </ChangeResourceRecordSetsResponse>
    XML
  end

  def error_xml(code: "InvalidInput", message: "The request was rejected.")
    <<~XML
      <?xml version="1.0"?>
      <ErrorResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
        <Error>
          <Type>Sender</Type>
          <Code>#{code}</Code>
          <Message>#{message}</Message>
        </Error>
        <RequestId>abc-123</RequestId>
      </ErrorResponse>
    XML
  end

  # ── Construction ──────────────────────────────────────────────────────

  describe "#initialize" do
    it "raises when access keys are missing" do
      expect { described_class.new(region: "us-east-1") }
        .to raise_error(ArgumentError, /access_key_id and secret_access_key are required/)
    end

    it "accepts a positional credentials hash" do
      c = described_class.new(
        "access_key_id" => "AKIA", "secret_access_key" => "secret", "region" => "us-west-2"
      )
      expect(c).to be_a(described_class)
    end

    it "tolerates the factory's api_token: keyword (Route53 ignores it)" do
      c = described_class.new(
        api_token: "ignored", access_key_id: "AKIA", secret_access_key: "secret", region: "us-east-1"
      )
      expect(c).to be_a(described_class)
    end
  end

  # ── list_zones ──────────────────────────────────────────────────────────

  describe "#list_zones" do
    it "returns normalized zones with the /hostedzone/ prefix stripped (happy path)" do
      stub = stub_request(:get, "#{base}/hostedzone")
             .with(query: hash_including("maxitems" => "50"))
             .to_return(status: 200, body: list_zones_xml,
                        headers: { "Content-Type" => "application/xml" })

      result = client.list_zones

      expect(stub).to have_been_requested
      expect(result).to be_ok
      expect(result.http_status).to eq(200)
      expect(result.data.map { |z| z[:id] }).to contain_exactly(zone_id, "Z000OTHER0000000000")
      first = result.data.find { |z| z[:id] == zone_id }
      expect(first[:name]).to eq("example.com.")
      expect(first[:records_count]).to eq(4)
      expect(first[:private]).to be false
    end

    it "client-filters by zone name (trailing-dot tolerant)" do
      stub_request(:get, "#{base}/hostedzone")
        .with(query: hash_including("maxitems" => "50"))
        .to_return(status: 200, body: list_zones_xml)

      result = client.list_zones(name: "example.com")

      expect(result).to be_ok
      expect(result.data.map { |z| z[:name] }).to eq([ "example.com." ])
    end

    it "signs the request with a SigV4 Authorization header" do
      stub = stub_request(:get, "#{base}/hostedzone")
             .with(query: hash_including("maxitems" => "50")) do |req|
               req.headers["Authorization"].to_s.start_with?("AWS4-HMAC-SHA256")
             end
             .to_return(status: 200, body: list_zones_xml)

      client.list_zones
      expect(stub).to have_been_requested
    end

    it "surfaces an <ErrorResponse> as ok? == false (error path)" do
      stub_request(:get, "#{base}/hostedzone")
        .with(query: hash_including("maxitems" => "50"))
        .to_return(status: 403,
                    body: error_xml(code: "AccessDenied", message: "User is not authorized."))

      result = client.list_zones

      expect(result).not_to be_ok
      expect(result.http_status).to eq(403)
      expect(result.error).to eq("User is not authorized.")
      expect(result.cf_errors.first[:code]).to eq("AccessDenied")
    end

    it "returns an error Result on a transport timeout (does not raise)" do
      stub_request(:get, "#{base}/hostedzone")
        .with(query: hash_including("maxitems" => "50"))
        .to_timeout

      result = client.list_zones

      expect(result).not_to be_ok
      expect(result.error).to match(/Route53 API/i)
    end
  end

  # ── list_records ────────────────────────────────────────────────────────

  describe "#list_records" do
    it "returns normalized records, one row per rrset with joined values (happy path)" do
      stub = stub_request(:get, "#{base}/hostedzone/#{zone_id}/rrset")
             .with(query: hash_including("maxitems" => "100"))
             .to_return(status: 200, body: list_rrset_xml)

      result = client.list_records(zone_id)

      expect(stub).to have_been_requested
      expect(result).to be_ok
      a = result.data.find { |r| r[:type] == "A" }
      expect(a[:name]).to eq("www.example.com.")
      expect(a[:id]).to eq("A:www.example.com.")
      expect(a[:content]).to eq("192.0.2.1 192.0.2.2")
      expect(a[:values]).to eq([ "192.0.2.1", "192.0.2.2" ])
      expect(a[:ttl]).to eq(300)
      expect(a[:zone_id]).to eq(zone_id)
      expect(a[:proxied]).to be false
    end

    it "filters by type when supplied" do
      stub_request(:get, "#{base}/hostedzone/#{zone_id}/rrset")
        .with(query: hash_including("type" => "NS"))
        .to_return(status: 200, body: list_rrset_xml)

      result = client.list_records(zone_id, type: "ns")

      expect(result).to be_ok
      expect(result.data.map { |r| r[:type] }).to eq([ "NS" ])
    end

    it "surfaces an error response (error path)" do
      stub_request(:get, "#{base}/hostedzone/#{zone_id}/rrset")
        .with(query: hash_including("maxitems" => "100"))
        .to_return(status: 404,
                    body: error_xml(code: "NoSuchHostedZone", message: "No hosted zone found."))

      result = client.list_records(zone_id)

      expect(result).not_to be_ok
      expect(result.http_status).to eq(404)
      expect(result.error).to eq("No hosted zone found.")
    end
  end

  # ── create_record ────────────────────────────────────────────────────────

  describe "#create_record" do
    it "POSTs an UPSERT change batch and returns the normalized record (happy path)" do
      stub = stub_request(:post, "#{base}/hostedzone/#{zone_id}/rrset")
             .with do |req|
               req.body.include?("<Action>UPSERT</Action>") &&
                 req.body.include?("<Name>api.example.com.</Name>") &&
                 req.body.include?("<Type>A</Type>") &&
                 req.body.include?("<Value>198.51.100.7</Value>")
             end
             .to_return(status: 200, body: change_response_xml(status: "PENDING"))

      result = client.create_record(
        zone_id, type: "A", name: "api.example.com", content: "198.51.100.7", ttl: 300
      )

      expect(stub).to have_been_requested
      expect(result).to be_ok
      expect(result.data[:id]).to eq("A:api.example.com.")
      expect(result.data[:name]).to eq("api.example.com.")
      expect(result.data[:content]).to eq("198.51.100.7")
      expect(result.data[:ttl]).to eq(300)
      expect(result.data[:change_status]).to eq("PENDING")
      expect(result.data[:change_id]).to eq("/change/C2682N5HXP0BZ4")
    end

    it "normalizes the Cloudflare auto-TTL sentinel (1) to a sane default" do
      stub_request(:post, "#{base}/hostedzone/#{zone_id}/rrset")
        .with { |req| req.body.include?("<TTL>300</TTL>") }
        .to_return(status: 200, body: change_response_xml)

      result = client.create_record(zone_id, type: "A", name: "x.example.com", content: "203.0.113.9")

      expect(result).to be_ok
      expect(result.data[:ttl]).to eq(300)
    end

    it "rejects an unsupported record type before any HTTP call" do
      expect { client.create_record(zone_id, type: "WIDGET", name: "x", content: "y") }
        .to raise_error(Acme::Route53::DnsClient::ApiError, /Unsupported record type/)
    end

    it "surfaces a Route53 validation error (error path)" do
      stub_request(:post, "#{base}/hostedzone/#{zone_id}/rrset")
        .to_return(status: 400,
                    body: error_xml(code: "InvalidChangeBatch", message: "RRSet already exists."))

      result = client.create_record(zone_id, type: "A", name: "dup.example.com", content: "192.0.2.50")

      expect(result).not_to be_ok
      expect(result.http_status).to eq(400)
      expect(result.error).to eq("RRSet already exists.")
      expect(result.cf_errors.first[:code]).to eq("InvalidChangeBatch")
    end
  end

  # ── delete_record ────────────────────────────────────────────────────────

  describe "#delete_record" do
    let(:record_id) { "A:www.example.com." }

    it "re-fetches the rrset then POSTs a DELETE change batch (happy path)" do
      # delete_record → list_records (GET rrset, unfiltered) → POST DELETE.
      # The re-fetch carries the real API's maxitems param (Route53's
      # ListResourceRecordSets always paginates), so match it the same way
      # the #list_records examples above do.
      get_stub = stub_request(:get, "#{base}/hostedzone/#{zone_id}/rrset")
                 .with(query: hash_including("maxitems" => "100"))
                 .to_return(status: 200, body: list_rrset_xml)

      post_stub = stub_request(:post, "#{base}/hostedzone/#{zone_id}/rrset")
                  .with do |req|
                    req.body.include?("<Action>DELETE</Action>") &&
                      req.body.include?("<Name>www.example.com.</Name>") &&
                      req.body.include?("<Type>A</Type>") &&
                      req.body.include?("<Value>192.0.2.1</Value>") &&
                      req.body.include?("<Value>192.0.2.2</Value>")
                  end
                  .to_return(status: 200, body: change_response_xml(status: "PENDING"))

      result = client.delete_record(zone_id, record_id)

      expect(get_stub).to have_been_requested
      expect(post_stub).to have_been_requested
      expect(result).to be_ok
      expect(result.data[:deleted]).to be true
      expect(result.data[:change_status]).to eq("PENDING")
    end

    it "returns a not-found Result when the record is absent (error path)" do
      stub_request(:get, "#{base}/hostedzone/#{zone_id}/rrset")
        .with(query: hash_including("maxitems" => "100"))
        .to_return(status: 200, body: list_rrset_xml)

      result = client.delete_record(zone_id, "TXT:missing.example.com.")

      expect(result).not_to be_ok
      expect(result.http_status).to eq(404)
      expect(result.error).to match(/not found/i)
    end

    it "propagates a Route53 error on the DELETE change (error path)" do
      stub_request(:get, "#{base}/hostedzone/#{zone_id}/rrset")
        .with(query: hash_including("maxitems" => "100"))
        .to_return(status: 200, body: list_rrset_xml)
      stub_request(:post, "#{base}/hostedzone/#{zone_id}/rrset")
        .to_return(status: 400,
                    body: error_xml(code: "InvalidChangeBatch", message: "Tried to delete resource record set but it was not found."))

      result = client.delete_record(zone_id, record_id)

      expect(result).not_to be_ok
      expect(result.error).to match(/not found/i)
    end
  end
end
