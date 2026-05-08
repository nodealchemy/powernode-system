# frozen_string_literal: true

require "rails_helper"
require_relative "shared_examples"

# Self-Serve Hardening Plan M1 — ProCloudProvider integration spec.
#
# Stubs the Vultr API at the HTTP boundary via WebMock — never makes
# real network calls. The Slice-A `System::ProviderCredential` model
# is stubbed via `stub_const` so this spec runs whether or not Slice
# A has landed (per the M1 cross-slice contract).
RSpec.describe System::Providers::ProCloudProvider do
  let(:provider_record) { instance_double("System::Provider", id: "prov-uuid-1", provider_type: "pro_cloud") }
  let(:connection)      { instance_double("System::ProviderConnection", provider: provider_record, config: {}) }
  let(:region)          { instance_double("System::ProviderRegion", region_code: "us-east") }

  let(:api_key) { "VULTR_TEST_KEY_abc123" }

  # Synthetic ProviderCredential double — Slice A model. The real
  # model exposes a `.where(...).first` AR query interface and a
  # `#credentials` method that returns a decrypted Hash.
  let(:credential_record) { double("ProviderCredential", credentials: { api_key: api_key }) }

  let(:credential_relation) { double("ActiveRecord::Relation") }

  before do
    # Stub the AR-style credential lookup. `stub_const` creates the
    # class if it isn't loaded (Slice A pending).
    fake_class = Class.new do
      def self.where(*); end
    end
    stub_const("System::ProviderCredential", fake_class)
    allow(::System::ProviderCredential)
      .to receive(:where)
      .with(provider_id: provider_record.id, scope: :platform_pool, is_active: true)
      .and_return(credential_relation)
    allow(credential_relation).to receive(:first).and_return(credential_record)
  end

  subject(:provider) { described_class.new(connection, region: region) }

  it_behaves_like "a cloud provider"

  describe "#provider_type" do
    it "returns 'pro_cloud'" do
      expect(provider.provider_type).to eq("pro_cloud")
    end
  end

  describe "Registry integration" do
    it "is registered under 'pro_cloud'" do
      expect(System::Providers::Registry::PROVIDER_CLASSES["pro_cloud"])
        .to eq("System::Providers::ProCloudProvider")
    end

    it "shows up in available_providers" do
      expect(System::Providers::Registry.available_providers).to include("pro_cloud")
    end
  end

  describe "#credentials" do
    it "returns the decrypted credential payload" do
      expect(provider.credentials).to eq(api_key: api_key)
    end

    it "raises AuthenticationError when no platform_pool credential exists" do
      allow(credential_relation).to receive(:first).and_return(nil)
      expect { provider.credentials }
        .to raise_error(System::Providers::BaseProvider::AuthenticationError, /platform_pool/)
    end
  end

  describe "region + plan mapping" do
    it "maps 'us-east' to Vultr 'ewr'" do
      expect(provider.send(:map_region, "us-east")).to eq("ewr")
    end

    it "maps 'us-west' to Vultr 'lax'" do
      expect(provider.send(:map_region, "us-west")).to eq("lax")
    end

    it "passes through Vultr-native region codes" do
      expect(provider.send(:map_region, "dfw")).to eq("dfw")
    end

    it "defaults to 'ewr' when input is blank" do
      expect(provider.send(:map_region, nil)).to eq("ewr")
      expect(provider.send(:map_region, "")).to eq("ewr")
    end

    it "maps coarse plans tiny/small/medium to Vultr vc2 plans" do
      expect(provider.send(:map_plan, "tiny")).to eq("vc2-1c-1gb")
      expect(provider.send(:map_plan, "small")).to eq("vc2-1c-2gb")
      expect(provider.send(:map_plan, "medium")).to eq("vc2-2c-4gb")
    end

    it "passes through Vultr-native plan codes" do
      expect(provider.send(:map_plan, "vc2-4c-8gb")).to eq("vc2-4c-8gb")
    end
  end

  describe "#normalize_status" do
    it "maps Vultr power_status values" do
      expect(provider.send(:normalize_status, "running")).to eq("running")
      expect(provider.send(:normalize_status, "stopped")).to eq("stopped")
      expect(provider.send(:normalize_status, "starting")).to eq("starting")
    end

    it "maps Vultr lifecycle status values" do
      expect(provider.send(:normalize_status, "active")).to eq("running")
      expect(provider.send(:normalize_status, "pending")).to eq("pending")
      expect(provider.send(:normalize_status, "suspended")).to eq("stopped")
    end

    it "falls back to 'unknown' for unrecognized values" do
      expect(provider.send(:normalize_status, "totally-bogus")).to eq("unknown")
      expect(provider.send(:normalize_status, nil)).to eq("unknown")
    end
  end

  describe "#create_instance" do
    let(:params) do
      {
        name: "self-serve-1",
        instance_type: "small",
        region: "us-east"
      }
    end

    let(:vultr_payload) do
      {
        "instance" => {
          "id" => "vultr-instance-uuid-42",
          "region" => "ewr",
          "plan" => "vc2-1c-2gb",
          "os_id" => 2284,
          "main_ip" => "203.0.113.42",
          "internal_ip" => "10.99.0.42",
          "power_status" => "starting",
          "status" => "pending"
        }
      }
    end

    it "POSTs the translated body to /v2/instances and returns BaseProvider shape" do
      stub = stub_request(:post, "https://api.vultr.com/v2/instances")
        .with(
          headers: { "Authorization" => "Bearer #{api_key}" },
          body: hash_including(
            "region" => "ewr",
            "plan"   => "vc2-1c-2gb",
            "os_id"  => 2284,
            "label"  => "self-serve-1"
          )
        )
        .to_return(
          status: 202,
          body: vultr_payload.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = provider.create_instance(params)

      expect(stub).to have_been_requested
      expect(result[:success]).to be true
      expect(result[:cloud_instance_id]).to eq("vultr-instance-uuid-42")
      expect(result[:status]).to eq("starting")
      expect(result[:public_ip_address]).to eq("203.0.113.42")
      expect(result[:private_ip_address]).to eq("10.99.0.42")
      expect(result[:provider_type]).to eq("pro_cloud")
      expect(result[:plan]).to eq("vc2-1c-2gb")
      expect(result[:region]).to eq("ewr")
    end

    it "defaults to OS 2284 (Ubuntu 24.04) when os_id not specified" do
      stub_request(:post, "https://api.vultr.com/v2/instances")
        .with(body: hash_including("os_id" => 2284))
        .to_return(
          status: 202,
          body: vultr_payload.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      provider.create_instance(params)

      expect(WebMock).to have_requested(:post, "https://api.vultr.com/v2/instances")
        .with(body: hash_including("os_id" => 2284))
    end

    it "base64-encodes user_data when present" do
      stub_request(:post, "https://api.vultr.com/v2/instances")
        .to_return(
          status: 202,
          body: vultr_payload.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      provider.create_instance(params.merge(user_data: "#!/bin/bash\necho hi"))

      expect(WebMock).to have_requested(:post, "https://api.vultr.com/v2/instances")
        .with { |req|
          parsed = JSON.parse(req.body)
          encoded = parsed["user_data"]
          encoded == Base64.strict_encode64("#!/bin/bash\necho hi")
        }
    end

    it "raises AuthenticationError on 401" do
      stub_request(:post, "https://api.vultr.com/v2/instances")
        .to_return(
          status: 401,
          body: { error: "invalid api key" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect { provider.create_instance(params) }
        .to raise_error(System::Providers::BaseProvider::AuthenticationError, /authentication failed/i)
    end

    it "raises RateLimitError on 429" do
      stub_request(:post, "https://api.vultr.com/v2/instances")
        .to_return(status: 429, body: "{}", headers: { "Content-Type" => "application/json" })

      expect { provider.create_instance(params) }
        .to raise_error(System::Providers::BaseProvider::RateLimitError)
    end
  end

  describe "#terminate_instance" do
    it "DELETEs the instance and returns success" do
      stub = stub_request(:delete, "https://api.vultr.com/v2/instances/vultr-id-99")
        .with(headers: { "Authorization" => "Bearer #{api_key}" })
        .to_return(status: 204, body: "")

      result = provider.terminate_instance("vultr-id-99")

      expect(stub).to have_been_requested
      expect(result[:success]).to be true
      expect(result[:status]).to eq("terminated")
      expect(result[:cloud_instance_id]).to eq("vultr-id-99")
    end

    it "treats 404 as idempotent success" do
      stub_request(:delete, "https://api.vultr.com/v2/instances/already-gone")
        .to_return(
          status: 404,
          body: { error: "not found" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = provider.terminate_instance("already-gone")

      expect(result[:success]).to be true
      expect(result[:status]).to eq("terminated")
      expect(result[:note]).to eq("already_terminated")
    end

    it "raises ResourceNotFoundError via get_instance for genuine lookups" do
      # Sanity: 404 on GET should still surface as the typed family
      # for callers that need to distinguish missing from gone.
      stub_request(:get, "https://api.vultr.com/v2/instances/missing")
        .to_return(
          status: 404,
          body: { error: "not found" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = provider.get_instance("missing")
      expect(result[:success]).to be false
      expect(result[:error_code]).to eq("NotFound")
    end
  end

  describe "#start_instance / #stop_instance / #reboot_instance" do
    it "POSTs to /start and returns starting" do
      stub = stub_request(:post, "https://api.vultr.com/v2/instances/i-1/start")
        .to_return(status: 204, body: "")

      result = provider.start_instance("i-1")

      expect(stub).to have_been_requested
      expect(result[:success]).to be true
      expect(result[:status]).to eq("starting")
    end

    it "POSTs to /halt and returns stopping" do
      stub = stub_request(:post, "https://api.vultr.com/v2/instances/i-1/halt")
        .to_return(status: 204, body: "")

      result = provider.stop_instance("i-1")

      expect(stub).to have_been_requested
      expect(result[:status]).to eq("stopping")
    end

    it "reboot calls halt then start" do
      halt = stub_request(:post, "https://api.vultr.com/v2/instances/i-1/halt")
        .to_return(status: 204, body: "")
      start = stub_request(:post, "https://api.vultr.com/v2/instances/i-1/start")
        .to_return(status: 204, body: "")

      result = provider.reboot_instance("i-1")

      expect(halt).to have_been_requested
      expect(start).to have_been_requested
      expect(result[:status]).to eq("rebooting")
    end
  end

  describe "#get_instance" do
    it "GETs the instance and normalizes status" do
      stub_request(:get, "https://api.vultr.com/v2/instances/i-7")
        .to_return(
          status: 200,
          body: {
            instance: {
              id: "i-7",
              power_status: "running",
              status: "active",
              main_ip: "198.51.100.7",
              internal_ip: "10.0.0.7",
              region: "ewr",
              plan: "vc2-1c-2gb"
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = provider.get_instance("i-7")

      expect(result[:success]).to be true
      expect(result[:status]).to eq("running")
      expect(result[:public_ip_address]).to eq("198.51.100.7")
      expect(result[:private_ip_address]).to eq("10.0.0.7")
    end

    it "is aliased as instance_status" do
      expect(described_class.instance_method(:instance_status))
        .to eq(described_class.instance_method(:get_instance))
    end
  end

  describe "#test_connection" do
    it "returns success when credentials resolve" do
      result = provider.test_connection
      expect(result[:success]).to be true
      expect(result[:provider]).to eq("pro_cloud")
    end

    it "returns failure when credentials lookup raises" do
      allow(credential_relation).to receive(:first).and_return(nil)
      result = provider.test_connection
      expect(result[:success]).to be false
      expect(result[:error]).to match(/pro_cloud/i)
    end
  end

  describe "credential payload guard" do
    it "raises AuthenticationError when payload is missing :api_key" do
      allow(credential_record).to receive(:credentials).and_return({})
      stub_request(:any, /api\.vultr\.com/) # should never be hit
      expect { provider.create_instance(name: "x", instance_type: "tiny", region: "us-east") }
        .to raise_error(System::Providers::BaseProvider::AuthenticationError, /api_key/)
    end
  end
end
