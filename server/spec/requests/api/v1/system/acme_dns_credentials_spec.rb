# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::AcmeDnsCredentials", type: :request do
  let(:account) { create(:account) }
  let(:reader)  { user_with_permissions("system.acme_dns.read", account: account) }
  let(:manager) do
    user_with_permissions("system.acme_dns.read", "system.acme_dns.manage", account: account)
  end
  let(:base_path) { "/api/v1/system/acme_dns_credentials" }

  # Vault stubbing — never touch real Vault from request specs.
  let(:fake_vault) { instance_double("Security::VaultCredentialProvider") }
  before do
    allow(::Security::VaultCredentialProvider).to receive(:new).and_return(fake_vault)
    allow(fake_vault).to receive(:store_credential).and_return(true)
    allow(fake_vault).to receive(:get_credential).and_return("api_token" => "stub-token")
    allow(fake_vault).to receive(:delete_credential).and_return(true)
    allow(fake_vault).to receive(:rotate_credential).and_return(true)
  end

  describe "GET /acme_dns_credentials" do
    let!(:own_cred) do
      create(:system_acme_dns_credential, account: account, name: "alice-cloudflare",
                                          provider: "cloudflare", status: "valid")
    end
    let!(:other_cred) do
      create(:system_acme_dns_credential, account: create(:account),
                                          name: "bob-cloudflare", provider: "cloudflare")
    end

    it "lists credentials scoped to the current account" do
      get base_path, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      names = body["data"]["credentials"].map { |c| c["name"] }
      expect(names).to eq([ "alice-cloudflare" ])
      expect(names).not_to include("bob-cloudflare")
    end

    it "surfaces the supported-providers list with required_fields" do
      get base_path, headers: auth_headers_for(reader)
      providers = JSON.parse(response.body)["data"]["supported_providers"]
      cloudflare = providers.find { |p| p["slug"] == "cloudflare" }
      expect(cloudflare["required_fields"]).to eq([ "api_token" ])
    end

    it "rejects requests without read permission" do
      anon = create(:user, account: account)
      get base_path, headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end

    it "never echoes credential plaintext in the index response" do
      # The string "api_token" appears legitimately as a field name in the
      # supported_providers metadata; what must NEVER appear is the actual
      # token value the stub Vault returns.
      get base_path, headers: auth_headers_for(reader)
      expect(response.body).not_to include("stub-token")
      expect(response.body).not_to include("TEST-CF-TOKEN")
    end
  end

  describe "POST /acme_dns_credentials" do
    let(:valid_body) do
      {
        name: "production-cloudflare",
        provider: "cloudflare",
        credentials: { api_token: "TEST-CF-TOKEN-VALUE" }
      }
    end

    it "creates the row with status=untested + stores credentials in Vault" do
      expect(fake_vault).to receive(:store_credential).with(
        hash_including(
          credential_type: :acme_dns,
          data: { "api_token" => "TEST-CF-TOKEN-VALUE" }
        )
      )

      expect {
        post base_path, params: valid_body.to_json, headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      }.to change { ::System::AcmeDnsCredential.count }.by(1)

      expect(response).to have_http_status(:created)
      cred = JSON.parse(response.body)["data"]["credential"]
      expect(cred["status"]).to eq("untested")
      expect(cred["provider"]).to eq("cloudflare")
    end

    it "never echoes the token plaintext in the create response" do
      post base_path, params: valid_body.to_json,
                       headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      expect(response.body).not_to include("TEST-CF-TOKEN-VALUE")
    end

    it "drops fields outside the provider's allowlist" do
      body = valid_body.deep_merge(credentials: { api_token: "T", account_email: "leak@bad.tld" })
      expect(fake_vault).to receive(:store_credential).with(
        hash_including(data: { "api_token" => "T" })
      )
      post base_path, params: body.to_json,
                       headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:created)
    end

    it "rejects unsupported providers" do
      body = valid_body.merge(provider: "godaddy")
      post base_path, params: body.to_json,
                       headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Unsupported provider")
    end

    it "rejects missing required fields" do
      body = valid_body.merge(credentials: {})
      post base_path, params: body.to_json,
                       headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Missing required credential field")
    end

    it "forbids users without manage permission" do
      post base_path, params: valid_body.to_json,
                       headers: auth_headers_for(reader).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "rolls back the DB row when Vault write fails" do
      allow(fake_vault).to receive(:store_credential)
        .and_raise(StandardError, "Vault unreachable")

      expect {
        post base_path, params: valid_body.to_json,
                         headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      }.not_to change { ::System::AcmeDnsCredential.count }
    end
  end

  describe "POST /acme_dns_credentials/:id/test_connectivity" do
    let!(:cred) do
      create(:system_acme_dns_credential, account: account, name: "alice-cf",
                                          provider: "cloudflare", status: "untested")
    end
    let(:test_path) { "#{base_path}/#{cred.id}/test_connectivity" }

    it "verifies + marks the credential valid on success" do
      ok = ::Acme::DnsCredentialValidator::Result.ok(message: "Cloudflare token verified")
      allow_any_instance_of(::Acme::DnsCredentialValidator).to receive(:verify).and_return(ok)

      post test_path, headers: auth_headers_for(reader).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)["data"]
      expect(body["ok"]).to be true
      expect(body["credential"]["status"]).to eq("valid")
    end

    it "marks the credential invalid on failure + surfaces the reason" do
      bad = ::Acme::DnsCredentialValidator::Result.fail(message: "401 from Cloudflare")
      allow_any_instance_of(::Acme::DnsCredentialValidator).to receive(:verify).and_return(bad)

      post test_path, headers: auth_headers_for(reader).merge("Content-Type" => "application/json")
      body = JSON.parse(response.body)["data"]
      expect(body["ok"]).to be false
      expect(body["credential"]["status"]).to eq("invalid")
      # Verifier text lives at data.reason (controller renames message → reason
      # to avoid colliding with render_success's reserved top-level message).
      expect(body["reason"]).to include("401")
    end
  end

  describe "DELETE /acme_dns_credentials/:id" do
    let!(:cred) do
      create(:system_acme_dns_credential, account: account, name: "alice-cf", provider: "cloudflare")
    end

    it "deletes the row + the Vault credential" do
      expect(fake_vault).to receive(:delete_credential).with(
        hash_including(credential_type: :acme_dns, credential_id: cred.id)
      ).and_return(true)

      delete "#{base_path}/#{cred.id}", headers: auth_headers_for(manager)
      # Diagnostic — surface controller error message on failure
      expect(response).to have_http_status(:ok), -> { "body=#{response.body}" }
      expect(::System::AcmeDnsCredential.where(id: cred.id)).to be_empty
    end

    it "refuses to delete when active certificates reference it" do
      create(:system_acme_certificate,
             account: account, dns_credential: cred, status: "valid",
             common_name: "alice.tld")
      delete "#{base_path}/#{cred.id}", headers: auth_headers_for(manager)
      expect(response).to have_http_status(:conflict)
    end
  end

  describe "POST /acme_dns_credentials/:id/rotate" do
    let!(:cred) do
      create(:system_acme_dns_credential, account: account, name: "alice-cf",
                                          provider: "cloudflare", status: "valid")
    end

    it "rotates the Vault credential + resets status to untested" do
      cred.update!(last_validated_at: 1.hour.ago)

      expect(fake_vault).to receive(:rotate_credential).with(
        hash_including(credential_type: :acme_dns, credential_id: cred.id)
      )

      post "#{base_path}/#{cred.id}/rotate",
           params: { credentials: { api_token: "NEW-TOKEN" } }.to_json,
           headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      cred.reload
      expect(cred.status).to eq("untested")
      expect(cred.last_validated_at).to be_nil
    end
  end
end
