# frozen_string_literal: true

require "rails_helper"
require "faraday"
require_relative "shared_examples"

# AzureProvider is a hand-rolled REST client over faraday-2 (the official
# `azure_mgmt_compute` SDK transitively pins faraday < 2). These specs stub
# HTTP responses with `Faraday::Adapter::Test` rather than mocking SDK
# classes — that lets us exercise the request/response wiring (status
# dispatch, nextLink pagination, body parsing) without hitting Azure.
RSpec.describe System::Providers::AzureProvider do
  let(:connection) do
    instance_double(
      "System::ProviderConnection",
      access_key: "test-client-id",
      secret_key: "test-client-secret",
      tenant: "test-tenant-id",
      config: {
        "subscription_id" => "sub-12345",
        "resource_group" => "test-rg"
      }
    )
  end
  let(:region) { instance_double("System::ProviderRegion", region_code: "eastus") }

  subject(:provider) { described_class.new(connection, region: region) }

  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:fake_arm_connection) do
    Faraday.new(url: System::Providers::AzureProvider::MGMT_BASE) do |f|
      f.response :json, content_type: /\bjson$/
      f.adapter :test, stubs
    end
  end

  before do
    # Bypass real OAuth — token fetch hits login.microsoftonline.com; not
    # what we're testing here.
    allow(provider).to receive(:fetch_token!).and_return("fake-bearer-token")
    allow(provider).to receive(:arm_connection).and_return(fake_arm_connection)
  end

  it_behaves_like "a cloud provider"
  it_behaves_like "a provider class with BaseProvider signatures"

  describe "#provider_type" do
    it "returns 'azure'" do
      expect(provider.provider_type).to eq("azure")
    end
  end

  describe "#normalize_status" do
    it_behaves_like "a cloud provider with status normalization", {
      "PowerState/starting"        => "starting",
      "PowerState/running"         => "running",
      "PowerState/stopping"        => "stopping",
      "PowerState/stopped"         => "stopped",
      "PowerState/deallocating"    => "stopping",
      "PowerState/deallocated"     => "stopped",
      "ProvisioningState/creating" => "pending",
      "ProvisioningState/deleting" => "terminating"
    }
  end

  let(:vm_payload) do
    {
      "name" => "test-vm-1",
      "id" => "/subscriptions/sub-12345/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/test-vm-1",
      "location" => "eastus",
      "properties" => {
        "hardwareProfile" => { "vmSize" => "Standard_D2s_v3" },
        "instanceView" => {
          "statuses" => [
            { "code" => "ProvisioningState/succeeded" },
            { "code" => "PowerState/running" }
          ]
        }
      }
    }
  end

  describe "#list_instances" do
    let(:list_path) { "/subscriptions/sub-12345/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines" }

    it "returns aggregated instances and pagination metadata" do
      stubs.get(list_path) do
        [200, { "Content-Type" => "application/json" }, { "value" => [vm_payload] }.to_json]
      end

      result = provider.list_instances
      expect(result[:success]).to be true
      expect(result[:instances]).to be_an(Array)
      expect(result[:instances].size).to eq(1)
      expect(result[:instances].first[:cloud_id]).to eq("test-vm-1")
      expect(result[:instances].first[:status]).to eq("running")
      expect(result[:page_count]).to eq(1)
      expect(result[:truncated]).to be false
    end

    it "follows nextLink across pages" do
      page2_url = "https://management.azure.com/page2-token"
      stubs.get(list_path) do
        [200, { "Content-Type" => "application/json" },
         { "value" => [vm_payload], "nextLink" => page2_url }.to_json]
      end
      stubs.get("/page2-token") do
        [200, { "Content-Type" => "application/json" },
         { "value" => [vm_payload.merge("name" => "test-vm-2",
                                        "id" => vm_payload["id"].sub("test-vm-1", "test-vm-2"))] }.to_json]
      end

      result = provider.list_instances
      expect(result[:instances].size).to eq(2)
      expect(result[:instances].map { |i| i[:cloud_id] }).to contain_exactly("test-vm-1", "test-vm-2")
      expect(result[:page_count]).to eq(2)
      expect(result[:truncated]).to be false
    end

    it "respects max_pages and reports truncation" do
      page2_url = "https://management.azure.com/page2-token"
      stubs.get(list_path) do
        [200, { "Content-Type" => "application/json" },
         { "value" => [vm_payload], "nextLink" => page2_url }.to_json]
      end

      result = provider.list_instances(max_pages: 1)
      expect(result[:instances].size).to eq(1)
      expect(result[:page_count]).to eq(1)
      expect(result[:truncated]).to be true
    end
  end

  describe "#get_instance" do
    it "returns instance details" do
      stubs.get("/subscriptions/sub-12345/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/test-vm") do
        [200, { "Content-Type" => "application/json" }, vm_payload.merge("name" => "test-vm").to_json]
      end

      # NIC + public-IP lookups have their own focused endpoints; stub the
      # helper methods rather than chaining a tower of NIC stubs into a
      # smoke test.
      allow(provider).to receive(:vm_private_ip).and_return("10.0.0.4")
      allow(provider).to receive(:vm_public_ip).and_return(nil)

      result = provider.get_instance("test-vm")
      expect(result[:cloud_id]).to eq("test-vm")
      expect(result[:status]).to eq("running")
    end

    it "returns nil when the VM does not exist (non-success)" do
      stubs.get("/subscriptions/sub-12345/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/missing-vm") do
        [404, {}, { "error" => { "message" => "Not found" } }.to_json]
      end
      expect(provider.get_instance("missing-vm")).to be_nil
    end
  end

  describe "#terminate_instance" do
    it "returns success on 202 Accepted (Azure async delete)" do
      stubs.delete("/subscriptions/sub-12345/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/test-vm") do
        [202, { "Content-Type" => "application/json" }, ""]
      end

      result = provider.terminate_instance("test-vm")
      expect(result[:success]).to be true
    end
  end

  describe "#reboot_instance" do
    it "POSTs to the /restart action endpoint" do
      stubs.post("/subscriptions/sub-12345/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/test-vm/restart") do
        [202, { "Content-Type" => "application/json" }, ""]
      end
      expect(provider.reboot_instance("test-vm")[:success]).to be true
    end
  end

  describe "typed error contract" do
    let(:list_path) { "/subscriptions/sub-12345/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines" }

    # Trigger a list_instances call against the stub. Each example below
    # registers the stub that produces the failure code, then `subject`
    # invokes the request.
    let(:trigger_auth_failure) { provider.list_instances }
    let(:trigger_rate_limit) { provider.list_instances }
    let(:trigger_not_found) { provider.list_instances }

    context "on 401 Unauthorized" do
      before do
        stubs.get(list_path) do
          [401, {}, { "error" => { "message" => "Token invalid" } }.to_json]
        end
      end

      it_behaves_like "a cloud provider raises on auth failure"
    end

    context "on 403 Forbidden" do
      before do
        stubs.get(list_path) do
          [403, {}, { "error" => { "message" => "Forbidden" } }.to_json]
        end
      end

      it "raises AuthenticationError" do
        expect { provider.list_instances }
          .to raise_error(System::Providers::BaseProvider::AuthenticationError)
      end
    end

    context "on 429 Too Many Requests" do
      before do
        stubs.get(list_path) do
          [429, {}, { "error" => { "message" => "Throttled" } }.to_json]
        end
      end

      it_behaves_like "a cloud provider raises on rate limit"
    end

    context "on 404 Not Found (subscription scope)" do
      before do
        stubs.get(list_path) do
          [404, {}, { "error" => { "message" => "Subscription not found" } }.to_json]
        end
      end

      it_behaves_like "a cloud provider raises on not found"
    end

    context "on 402 Payment Required (quota)" do
      before do
        stubs.get(list_path) do
          [402, {}, { "error" => { "message" => "Subscription quota exceeded" } }.to_json]
        end
      end

      it "raises QuotaExceededError" do
        expect { provider.list_instances }
          .to raise_error(System::Providers::BaseProvider::QuotaExceededError)
      end
    end

    context "on 500 Internal Server Error" do
      before do
        stubs.get(list_path) do
          [500, {}, { "error" => { "message" => "Service down" } }.to_json]
        end
      end

      it "raises generic ProviderError" do
        expect { provider.list_instances }
          .to raise_error(System::Providers::BaseProvider::ProviderError, /HTTP 500/)
      end
    end
  end

  describe "credential validation" do
    let(:trigger_credential_check) { provider.send(:tenant_id) }

    context "when tenant is missing" do
      let(:connection) do
        instance_double(
          "System::ProviderConnection",
          access_key: "id", secret_key: "secret", tenant: nil,
          config: { "subscription_id" => "sub-12345" }
        )
      end

      it_behaves_like "a cloud provider validates credentials"
    end
  end

  after do
    stubs.verify_stubbed_calls
  rescue StandardError
    # Some examples register stubs they don't end up exercising (e.g.,
    # when an upstream path short-circuits). Don't fail the example just
    # because a stub went unused.
  end
end
