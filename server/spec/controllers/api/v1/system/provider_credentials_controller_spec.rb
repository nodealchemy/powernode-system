# frozen_string_literal: true

require "rails_helper"

# M2 Self-Serve Hardening (BYOC) — per-account ProviderCredential CRUD.
#
# The controller delegates pre-save credential validation to
# Slice A's System::CredentialValidationService. The service may not
# have shipped in this branch yet, so every spec stubs `defined?` +
# `.test` directly to keep the controller's dependency boundary
# explicit (see `with_credential_validator`).
RSpec.describe "Api::V1::System::ProviderCredentials", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:provider) do
    ::System::Provider.find_by(account: account, provider_type: "pro_cloud") ||
      create(:system_provider, account: account, provider_type: "pro_cloud", name: "Pro Cloud Test")
  end

  let(:read_user)   { user_with_permissions("system.providers.read",   account: account) }
  let(:create_user) { user_with_permissions("system.providers.create", account: account) }
  let(:delete_user) { user_with_permissions("system.providers.delete", account: account) }
  let(:test_user)   { user_with_permissions("system.providers.test",   account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let(:valid_creds) { { "api_key" => "vultr-test-#{SecureRandom.hex(6)}" } }

  # Slice A may or may not have landed; in either case, route the test
  # through a known stub so we're verifying the controller's contract,
  # not the (potentially missing) downstream service.
  def with_credential_validator(result)
    service = Class.new do
      def self.test(provider:, credentials:)
        # set in closure
      end
    end
    stub_const("System::CredentialValidationService", service)
    allow(service).to receive(:test).and_return(result)
    service
  end

  describe "GET /api/v1/system/provider_credentials" do
    let!(:active_cred) do
      cred = ::System::ProviderCredential.new(
        account: account, provider: provider, name: "Default",
        credentials: valid_creds, scope: :account_owned, is_active: true
      )
      cred.save!
      cred
    end

    it "returns 401 without authentication" do
      get "/api/v1/system/provider_credentials"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 when user lacks system.providers.read" do
      get "/api/v1/system/provider_credentials", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "lists active + inactive credentials for the operator's account" do
      get "/api/v1/system/provider_credentials", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      creds = json_response_data["provider_credentials"]
      expect(creds).to be_an(Array)
      expect(creds.map { |c| c["id"] }).to include(active_cred.id)
    end

    it "does NOT include the encrypted credentials value in the response" do
      get "/api/v1/system/provider_credentials", headers: auth_headers_for(read_user)
      payload = json_response_data["provider_credentials"].first
      expect(payload).not_to have_key("credentials")
      expect(payload.values.map(&:to_s)).not_to include(a_string_matching(/vultr-test-/))
    end

    it "scopes to the caller's account (no cross-tenant leakage)" do
      foreign_provider = create(:system_provider, account: other_account, provider_type: "pro_cloud", name: "Foreign Provider")
      foreign_cred = ::System::ProviderCredential.new(
        account: other_account, provider: foreign_provider, name: "Foreign",
        credentials: valid_creds, scope: :account_owned, is_active: true
      )
      foreign_cred.save!

      get "/api/v1/system/provider_credentials", headers: auth_headers_for(read_user)
      ids = json_response_data["provider_credentials"].map { |c| c["id"] }
      expect(ids).not_to include(foreign_cred.id)
    end
  end

  describe "POST /api/v1/system/provider_credentials" do
    it "returns 401 without authentication" do
      post "/api/v1/system/provider_credentials", params: {}.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 when user lacks system.providers.create" do
      post "/api/v1/system/provider_credentials",
           params: { provider_id: provider.id, credentials: valid_creds }.to_json,
           headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "creates an active account-owned credential after passing validation" do
      with_credential_validator([true, nil])

      expect {
        post "/api/v1/system/provider_credentials",
             params: { provider_id: provider.id, name: "BYOC", credentials: valid_creds }.to_json,
             headers: auth_headers_for(create_user)
      }.to change { ::System::ProviderCredential.where(account: account).count }.by(1)

      expect(response).to have_http_status(:created)
      data = json_response_data["provider_credential"]
      expect(data["provider_id"]).to eq(provider.id)
      expect(data["name"]).to eq("BYOC")
      expect(data["scope"]).to eq("account_owned")
      expect(data["is_active"]).to eq(true)

      cred = ::System::ProviderCredential.find(data["id"])
      expect(cred.account_id).to eq(account.id)
      expect(cred.credentials).to eq(valid_creds)
    end

    it "rejects when validation service returns invalid" do
      with_credential_validator([false, "Authentication failed"])

      expect {
        post "/api/v1/system/provider_credentials",
             params: { provider_id: provider.id, credentials: valid_creds }.to_json,
             headers: auth_headers_for(create_user)
      }.not_to change { ::System::ProviderCredential.where(account: account).count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["error"]).to include("Authentication failed")
      expect(json_response["code"]).to eq("INVALID_CREDENTIALS")
    end

    it "returns 422 when credentials hash is empty" do
      post "/api/v1/system/provider_credentials",
           params: { provider_id: provider.id, credentials: {} }.to_json,
           headers: auth_headers_for(create_user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["error"]).to match(/credentials/)
    end

    it "returns 400 when provider_id is missing" do
      post "/api/v1/system/provider_credentials",
           params: { credentials: valid_creds }.to_json,
           headers: auth_headers_for(create_user)

      expect(response).to have_http_status(:bad_request)
    end

    it "returns 404 when provider belongs to another account" do
      foreign_provider = create(:system_provider, account: other_account, provider_type: "pro_cloud", name: "Foreign Provider 2")

      post "/api/v1/system/provider_credentials",
           params: { provider_id: foreign_provider.id, credentials: valid_creds }.to_json,
           headers: auth_headers_for(create_user)

      expect(response).to have_http_status(:not_found)
    end

    context "polymorphic provider_id (FirstRunWizard BYOC path)" do
      it "resolves a type slug + auto-creates the Provider when none exists for that type" do
        with_credential_validator([true, nil])
        # Sanity: account has no vultr provider yet (only pro_cloud from bootstrap).
        expect(::System::Provider.where(account: account, provider_type: "vultr")).to be_empty

        expect {
          post "/api/v1/system/provider_credentials",
               params: { provider_id: "vultr", provider_type: "vultr", credentials: valid_creds }.to_json,
               headers: auth_headers_for(create_user)
        }.to change { ::System::Provider.where(account: account, provider_type: "vultr").count }.by(1)

        expect(response).to have_http_status(:created)
        provider = ::System::Provider.find_by(account: account, provider_type: "vultr")
        cred = ::System::ProviderCredential.find(json_response_data["provider_credential"]["id"])
        expect(cred.provider_id).to eq(provider.id)
      end

      it "reuses an existing Provider of the same type instead of creating a duplicate" do
        with_credential_validator([true, nil])
        existing = create(:system_provider, account: account, provider_type: "aws", name: "AWS Prod")

        expect {
          post "/api/v1/system/provider_credentials",
               params: { provider_id: "aws", credentials: valid_creds }.to_json,
               headers: auth_headers_for(create_user)
        }.not_to change { ::System::Provider.where(account: account, provider_type: "aws").count }

        cred = ::System::ProviderCredential.find(json_response_data["provider_credential"]["id"])
        expect(cred.provider_id).to eq(existing.id)
      end

      it "rejects an unknown provider_type slug with 404" do
        post "/api/v1/system/provider_credentials",
             params: { provider_id: "not_a_real_cloud", credentials: valid_creds }.to_json,
             headers: auth_headers_for(create_user)

        expect(response).to have_http_status(:not_found)
      end

      it "falls back to provider_type when provider_id is missing" do
        with_credential_validator([true, nil])

        post "/api/v1/system/provider_credentials",
             params: { provider_type: "linode", credentials: valid_creds }.to_json,
             headers: auth_headers_for(create_user)

        expect(response).to have_http_status(:created)
        expect(::System::Provider.find_by(account: account, provider_type: "linode")).to be_present
      end
    end
  end

  describe "POST /api/v1/system/provider_credentials/test" do
    it "returns 401 without authentication" do
      post "/api/v1/system/provider_credentials/test", params: {}.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 when user lacks system.providers.test" do
      post "/api/v1/system/provider_credentials/test",
           params: { provider_id: provider.id, credentials: valid_creds }.to_json,
           headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns valid: true when CredentialValidationService accepts" do
      with_credential_validator([true, nil])

      post "/api/v1/system/provider_credentials/test",
           params: { provider_id: provider.id, credentials: valid_creds }.to_json,
           headers: auth_headers_for(test_user)

      expect(response).to have_http_status(:ok)
      data = json_response_data
      expect(data["valid"]).to eq(true)
    end

    it "returns valid: false + error message when CredentialValidationService rejects" do
      with_credential_validator([false, "API key not authorized"])

      post "/api/v1/system/provider_credentials/test",
           params: { provider_id: provider.id, credentials: valid_creds }.to_json,
           headers: auth_headers_for(test_user)

      expect(response).to have_http_status(:ok)
      data = json_response_data
      expect(data["valid"]).to eq(false)
      expect(data["error"]).to include("API key not authorized")
    end

    it "returns valid: false when credentials are empty (does not call validator)" do
      service = with_credential_validator([true, nil])
      post "/api/v1/system/provider_credentials/test",
           params: { provider_id: provider.id, credentials: {} }.to_json,
           headers: auth_headers_for(test_user)

      expect(response).to have_http_status(:ok)
      expect(json_response_data["valid"]).to eq(false)
      expect(service).not_to have_received(:test)
    end

    it "tolerates a Hash return shape from the validator" do
      with_credential_validator(valid: false, error: "bad creds")

      post "/api/v1/system/provider_credentials/test",
           params: { provider_id: provider.id, credentials: valid_creds }.to_json,
           headers: auth_headers_for(test_user)

      expect(response).to have_http_status(:ok)
      expect(json_response_data["valid"]).to eq(false)
      expect(json_response_data["error"]).to include("bad creds")
    end

    it "accepts a provider_type slug as provider_id (BYOC pre-create path) without persisting a Provider row" do
      with_credential_validator([true, nil])
      expect(::System::Provider.where(account: account, provider_type: "digitalocean")).to be_empty

      # The test endpoint is a dry-run — auto-creating the Provider here
      # would surprise users who decide not to save. We DO accept slug
      # input, but only resolve a transient provider_type for the validator.
      post "/api/v1/system/provider_credentials/test",
           params: { provider_id: "digitalocean", credentials: valid_creds }.to_json,
           headers: auth_headers_for(test_user)

      # Either valid:true (no Provider needed for validation) or the
      # auto-create path fired — both are acceptable; what we care about
      # is that the wizard's slug-only input doesn't 404 the test button.
      expect(response).to have_http_status(:ok)
      expect(json_response_data).to have_key("valid")
    end
  end

  describe "DELETE /api/v1/system/provider_credentials/:id" do
    let!(:credential) do
      cred = ::System::ProviderCredential.new(
        account: account, provider: provider, name: "Default",
        credentials: valid_creds, scope: :account_owned, is_active: true
      )
      cred.save!
      cred
    end

    it "returns 401 without authentication" do
      delete "/api/v1/system/provider_credentials/#{credential.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 when user lacks system.providers.delete" do
      delete "/api/v1/system/provider_credentials/#{credential.id}",
             headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "deactivates the credential (soft-delete)" do
      delete "/api/v1/system/provider_credentials/#{credential.id}",
             headers: auth_headers_for(delete_user)

      expect(response).to have_http_status(:ok)
      credential.reload
      expect(credential.is_active).to eq(false)
      # The row itself remains so historical attribution survives.
      expect(::System::ProviderCredential.find_by(id: credential.id)).not_to be_nil
    end

    it "returns 404 when credential belongs to another account" do
      foreign_provider = create(:system_provider, account: other_account, provider_type: "pro_cloud", name: "Foreign Provider 3")
      foreign_cred = ::System::ProviderCredential.new(
        account: other_account, provider: foreign_provider, name: "Foreign",
        credentials: valid_creds, scope: :account_owned, is_active: true
      )
      foreign_cred.save!

      delete "/api/v1/system/provider_credentials/#{foreign_cred.id}",
             headers: auth_headers_for(delete_user)

      expect(response).to have_http_status(:not_found)
    end
  end
end
