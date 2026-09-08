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

    it "surfaces production_ready per provider so the UI never hardcodes readiness" do
      get base_path, headers: auth_headers_for(reader)
      providers = JSON.parse(response.body)["data"]["supported_providers"]

      expect(providers).to all(have_key("production_ready"))
      expect(providers.find { |p| p["slug"] == "cloudflare" }["production_ready"]).to be true
      # Pin a false on the wire independently of the registry lookup below, so
      # the loop cannot pass by comparing a flipped registry against itself.
      expect(providers.find { |p| p["slug"] == "route53" }["production_ready"]).to be false

      Acme::DnsProviderRegistry::PROVIDERS.each_key do |slug|
        payload = providers.find { |p| p["slug"] == slug }
        expect(payload["production_ready"])
          .to eq(Acme::DnsProviderRegistry.production_ready?(slug)),
              "#{slug} readiness in the payload disagrees with the registry"
      end
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

    # IMP-e24167f9dc58. Readiness became a backend fact in IMP-352cfa773ecb, but
    # only the modal gated on it, so this endpoint accepted any supported?
    # provider and the failure surfaced later, on the node, at issuance.
    it "422s a provider the registry has not marked production_ready, naming it" do
      expect(fake_vault).not_to receive(:store_credential)
      body = valid_body.merge(
        provider: "route53",
        credentials: { access_key_id: "AKIA", secret_access_key: "s", region: "us-east-1" }
      )

      expect {
        post base_path, params: body.to_json,
             headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      }.not_to change { ::System::AcmeDnsCredential.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("route53")
    end

    it "still creates a provider the registry HAS marked production_ready" do
      post base_path, params: valid_body.to_json,
           headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:created)
    end

    # Must follow the registry rather than a hardcoded slug — the point of the
    # earlier task was that readiness is per-deployment backend state.
    it "follows the registry rather than a hardcoded slug" do
      allow(::Acme::DnsProviderRegistry).to receive(:production_ready?).and_call_original
      allow(::Acme::DnsProviderRegistry).to receive(:production_ready?).with("cloudflare").and_return(false)

      post base_path, params: valid_body.to_json,
           headers: auth_headers_for(manager).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("cloudflare")
    end

    # An unsupported slug and a not-ready one are different refusals: the first
    # says the platform has never heard of it, the second that this deployment
    # cannot use it. Collapsing them would mislead the operator.
    it "distinguishes an unknown provider from a known-but-not-ready one" do
      post base_path, params: valid_body.merge(provider: "megacorp-dns").to_json,
           headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      unknown = JSON.parse(response.body)["error"]

      post base_path, params: valid_body.merge(
        provider: "route53",
        credentials: { access_key_id: "A", secret_access_key: "s", region: "r" }
      ).to_json, headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      not_ready = JSON.parse(response.body)["error"]

      expect(unknown).to include("Unsupported provider")
      expect(not_ready).not_to include("Unsupported provider")
      expect(not_ready).to include("route53")
    end

    # Mirrors the tool spec's ordering example. Without this the controller's
    # guard could move below the missing-fields check and every other example
    # here would still pass, because they all supply a complete credential set.
    it "reports NOT-READY before missing fields when a provider fails both" do
      post base_path, params: valid_body.merge(
        provider: "route53", credentials: { access_key_id: "AKIA..." }
      ).to_json, headers: auth_headers_for(manager).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:unprocessable_content)
      error = JSON.parse(response.body)["error"]
      expect(error).to include("route53")
      expect(error).not_to include("Missing required credential field")
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
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Unsupported provider")
    end

    it "rejects missing required fields" do
      body = valid_body.merge(credentials: {})
      post base_path, params: body.to_json,
                       headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content)
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

  describe "PATCH /acme_dns_credentials/:id" do
    let!(:cred) do
      create(:system_acme_dns_credential, account: account, name: "alice-cf",
                                          provider: "cloudflare", status: "valid")
    end

    # This is the PREMISE the readiness gate's narrowing rests on: #update is
    # left ungated because it cannot change the provider. That was true only by
    # inspection of update_params, so adding :provider there would have opened
    # an ungated write path while the comment still said it was impossible.
    it "cannot change the provider, which is why #update needs no readiness gate" do
      patch "#{base_path}/#{cred.id}",
            params: { name: "renamed", provider: "route53" }.to_json,
            headers: auth_headers_for(manager).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(cred.reload.provider).to eq("cloudflare")
      expect(cred.name).to eq("renamed")
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

    # Regression: a sealed/unreachable Vault makes get_credential return an empty
    # read, which the controller used to report as 422 "no credential for this
    # row" — indistinguishable from real data loss. It must be a transient 503.
    it "returns 503 (not a misleading 422) when Vault is sealed/unreachable" do
      allow(fake_vault).to receive(:get_credential).and_return({})
      allow(::Security::VaultClient).to receive(:sealed?).and_return(true)

      post test_path, headers: auth_headers_for(reader).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:service_unavailable)
      expect(response.body).to match(/sealed|unreachable/i)
    end

    it "returns 422 when the credential is genuinely absent (Vault healthy but empty)" do
      allow(fake_vault).to receive(:get_credential).and_return({})
      allow(::Security::VaultClient).to receive(:sealed?).and_return(false)

      post test_path, headers: auth_headers_for(reader).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to match(/no credential/i)
    end

    # The two examples above stub ::Security::VaultClient.sealed? directly,
    # so they never exercise its real implementation — masking the bug this
    # context reproduces. On a Vault-less deployment (ops-hub, by design:
    # VAULT_ROLE_ID/VAULT_SECRET_ID absent, credentials fall back to DB
    # encryption), Security::VaultClient.instance raises AuthenticationError
    # while constructing the Vault::Client (AppRole login). The controller's
    # direct `::Security::VaultClient.sealed?` call was unguarded, so that
    # raise escaped as a 500 whenever the DB-fallback read came back empty.
    context "when Vault is genuinely unconfigured (VAULT_ROLE_ID/VAULT_SECRET_ID absent)" do
      around do |example|
        ::Security::VaultClient.reconfigure!
        example.run
        ::Security::VaultClient.reconfigure!
      end

      before do
        allow(::Security::VaultClient).to receive(:admin_setting_config).and_return({})
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("VAULT_ROLE_ID").and_return(nil)
        allow(ENV).to receive(:[]).with("VAULT_SECRET_ID").and_return(nil)
      end

      it "runs the DNS validator against the DB-fallback credential without ever touching Vault" do
        ok = ::Acme::DnsCredentialValidator::Result.ok(message: "Cloudflare token verified")
        allow_any_instance_of(::Acme::DnsCredentialValidator).to receive(:verify).and_return(ok)
        # fake_vault#get_credential (top-level before block) already returns a
        # present credential hash, standing in for a DB-encrypted read.

        post test_path, headers: auth_headers_for(reader).merge("Content-Type" => "application/json")

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)["data"]
        expect(body["ok"]).to be true
        expect(body["credential"]["status"]).to eq("valid")
      end

      it "returns 503 — not a 500 — when the DB-fallback read is also empty" do
        allow(fake_vault).to receive(:get_credential).and_return({})

        post test_path, headers: auth_headers_for(reader).merge("Content-Type" => "application/json")

        expect(response).to have_http_status(:service_unavailable)
        expect(response.body).to match(/sealed|unreachable/i)
      end
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
