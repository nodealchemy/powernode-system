# frozen_string_literal: true

require "rails_helper"

# The controller's validate_credentials rescue used to return e.message as the
# caller-facing error, so a driver's "connection refused to 10.1.2.3:5432" (or an
# SDK's request detail) reached the browser. It now routes through the same
# authored text as System::CredentialValidationService (safe_error_text).
RSpec.describe "Api::V1::System::ProviderCredentials error text", type: :request do
  let(:account) { create(:account) }
  let(:user) { user_with_permissions("system.providers.create", "system.providers.test", account: account) }
  let(:hostname) { "db-internal-7.corp.example.invalid" }

  def post_credential
    post "/api/v1/system/provider_credentials",
         params: { provider_id: "proxmox", credentials: { "api_key" => "byoc-test-#{SecureRandom.hex(6)}" } }.to_json,
         headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  def stub_probe_raising(error)
    allow(::System::CredentialValidationService).to receive(:test).and_raise(error)
  end

  it "does not echo a connection error's hostname in the response body" do
    stub_probe_raising(Errno::ECONNREFUSED.new("connect to #{hostname}:5432"))

    post_credential

    expect(response.body).not_to include(hostname)
    expect(response.body).not_to include("5432")
    expect(response.body).to include("unreachable")
  end

  it "categorises a timeout" do
    stub_probe_raising(Net::OpenTimeout.new("execution expired talking to #{hostname}"))

    post_credential

    expect(response.body).not_to include(hostname)
    expect(response.body).to include("timed out")
  end

  it "points at the server log for an uncategorised failure and logs the raw message" do
    allow(Rails.logger).to receive(:error)
    stub_probe_raising(StandardError.new("boom at #{hostname}"))

    post_credential

    expect(response.body).not_to include(hostname)
    expect(response.body).to include("server log")
    expect(Rails.logger).to have_received(:error).with(/StandardError/).at_least(:once)
  end
end
