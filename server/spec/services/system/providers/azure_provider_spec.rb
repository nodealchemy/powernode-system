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
        [ 200, { "Content-Type" => "application/json" }, { "value" => [ vm_payload ] }.to_json ]
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
        [ 200, { "Content-Type" => "application/json" },
         { "value" => [ vm_payload ], "nextLink" => page2_url }.to_json ]
      end
      stubs.get("/page2-token") do
        [ 200, { "Content-Type" => "application/json" },
         { "value" => [ vm_payload.merge("name" => "test-vm-2",
                                        "id" => vm_payload["id"].sub("test-vm-1", "test-vm-2")) ] }.to_json ]
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
        [ 200, { "Content-Type" => "application/json" },
         { "value" => [ vm_payload ], "nextLink" => page2_url }.to_json ]
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
        [ 200, { "Content-Type" => "application/json" }, vm_payload.merge("name" => "test-vm").to_json ]
      end

      # NIC + public-IP lookups have their own focused endpoints; stub the
      # helper methods rather than chaining a tower of NIC stubs into a
      # smoke test.
      allow(provider).to receive(:vm_private_ip).and_return("10.0.0.4")
      allow(provider).to receive(:vm_public_ip).and_return(nil)

      result = provider.get_instance("test-vm")
      # Adapter contract (base_provider#build_instance_response): the :success
      # flag, :cloud_instance_id, and the :*_address IP keys CloudSyncService
      # reads — NOT a bespoke :cloud_id/:private_ip hash.
      expect(result[:success]).to be true
      expect(result[:cloud_instance_id]).to eq("test-vm")
      expect(result[:status]).to eq("running")
      expect(result[:private_ip_address]).to eq("10.0.0.4")
      expect(result[:public_ip_address]).to be_nil
    end

    it "raises ResourceNotFoundError when the VM does not exist (404)" do
      stubs.get("/subscriptions/sub-12345/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/missing-vm") do
        [ 404, {}, { "error" => { "message" => "Not found" } }.to_json ]
      end
      expect { provider.get_instance("missing-vm") }
        .to raise_error(described_class::ResourceNotFoundError)
    end
  end

  describe "#terminate_instance" do
    it "returns success on 202 Accepted (Azure async delete)" do
      stubs.delete("/subscriptions/sub-12345/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/test-vm") do
        [ 202, { "Content-Type" => "application/json" }, "" ]
      end

      result = provider.terminate_instance("test-vm")
      expect(result[:success]).to be true
    end
  end

  describe "#reboot_instance" do
    it "POSTs to the /restart action endpoint" do
      stubs.post("/subscriptions/sub-12345/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/test-vm/restart") do
        [ 202, { "Content-Type" => "application/json" }, "" ]
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
          [ 401, {}, { "error" => { "message" => "Token invalid" } }.to_json ]
        end
      end

      it_behaves_like "a cloud provider raises on auth failure"
    end

    context "on 403 Forbidden" do
      before do
        stubs.get(list_path) do
          [ 403, {}, { "error" => { "message" => "Forbidden" } }.to_json ]
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
          [ 429, {}, { "error" => { "message" => "Throttled" } }.to_json ]
        end
      end

      it_behaves_like "a cloud provider raises on rate limit"
    end

    context "on 404 Not Found (subscription scope)" do
      before do
        stubs.get(list_path) do
          [ 404, {}, { "error" => { "message" => "Subscription not found" } }.to_json ]
        end
      end

      it_behaves_like "a cloud provider raises on not found"
    end

    context "on 402 Payment Required (quota)" do
      before do
        stubs.get(list_path) do
          [ 402, {}, { "error" => { "message" => "Subscription quota exceeded" } }.to_json ]
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
          [ 500, {}, { "error" => { "message" => "Service down" } }.to_json ]
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
          config: { "subscription_id" => "sub-12345" },
          # account + provider reached by BaseProvider#pve_credential's BYOC
          # fallback (System::ProviderCredential.for(account:, provider:))
          # before raising missing-credentials. Same shape as the proxmox
          # spec fix in commit b697abd.
          account: nil, provider: nil
        )
      end

      it_behaves_like "a cloud provider validates credentials"
    end
  end

  # Provisioning resilience: the AAD token (login) connection previously
  # lacked explicit timeouts, so an auth-endpoint blip blocked for the
  # Faraday/Net::HTTP default and stalled provisioning. Both the token and
  # ARM connections must now carry the 10s-connect / 60s-read convention.
  describe "auth/token connection timeouts" do
    it "applies the connect/read convention to the AAD token (login) connection" do
      conn = provider.send(:login_connection)
      expect(conn.options.open_timeout).to eq(10)
      expect(conn.options.timeout).to eq(60)
    end

    it "applies the convention to the ARM data-plane connection" do
      # The shared `before` stubs #arm_connection on the subject; build a
      # fresh instance so the real builder runs.
      fresh = described_class.new(connection, region: region)
      conn = fresh.send(:arm_connection)
      expect(conn.options.open_timeout).to eq(10)
      expect(conn.options.timeout).to eq(60)
    end
  end

  # IMP-73635a2e7cd8 — Azure reimplemented #log_operation redacting only 3 keys
  # (shallow .except), bypassing BaseProvider#log_operation + sanitize_for_log
  # which recursively redacts the full LOG_SENSITIVE_KEYS. create_instance logs
  # the whole params hash, so user_data/password/ssh_keys/access_token leaked to
  # logs on Azure only. The override is removed so Azure inherits the safe base.
  describe "#log_operation secret redaction" do
    it "redacts all LOG_SENSITIVE_KEYS from operation logs (not just 3 keys)" do
      logged = []
      allow(Rails.logger).to receive(:info) { |msg| logged << msg.to_s }

      provider.send(:log_operation, "create_instance", params: {
        name: "vm-1",
        user_data: "BASE64_CLOUD_INIT_PAYLOAD",
        password: "hunter2-secret",
        ssh_keys: [ "ssh-rsa AAAASECRETKEY" ],
        access_token: "azure_access_token_secret",
        secret_key: "client_secret_value"
      })

      line = logged.join("\n")
      expect(line).to be_present
      # None of the sensitive values may appear in the log line.
      expect(line).not_to include("BASE64_CLOUD_INIT_PAYLOAD")
      expect(line).not_to include("hunter2-secret")
      expect(line).not_to include("ssh-rsa AAAASECRETKEY")
      expect(line).not_to include("azure_access_token_secret")
      expect(line).not_to include("client_secret_value")
      # Sensitive keys are replaced with the base sanitizer's marker.
      expect(line).to include("[REDACTED]")
      # Non-sensitive values are preserved.
      expect(line).to include("vm-1")
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
