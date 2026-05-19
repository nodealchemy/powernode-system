# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — operator CRUD controller spec.
# ProvidersController has full CRUD + a `test` action for connection validation.
RSpec.describe "Api::V1::System::Providers", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.providers.read",   account: account) }
  let(:create_user) { user_with_permissions("system.providers.create", account: account) }
  let(:update_user) { user_with_permissions("system.providers.update", account: account) }
  let(:delete_user) { user_with_permissions("system.providers.delete", account: account) }
  let(:test_user)   { user_with_permissions("system.providers.test",   account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let!(:provider) { create(:system_provider, account: account, name: "Spec Provider #{SecureRandom.hex(3)}") }

  describe "GET /api/v1/system/providers" do
    it "returns 401 without auth" do
      get "/api/v1/system/providers"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/providers", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "lists providers scoped to the account" do
      get "/api/v1/system/providers", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      ids = json_response_data["providers"].map { |p| p["id"] }
      expect(ids).to include(provider.id)
    end

    it "does NOT leak other accounts' providers" do
      foreign = create(:system_provider, account: other_account, name: "Foreign Provider")
      get "/api/v1/system/providers", headers: auth_headers_for(read_user)
      ids = json_response_data["providers"].map { |p| p["id"] }
      expect(ids).not_to include(foreign.id)
    end
  end

  describe "GET /api/v1/system/providers/:id" do
    it "returns the provider" do
      get "/api/v1/system/providers/#{provider.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["provider"]["id"]).to eq(provider.id)
    end

    it "returns 404 for another account's provider" do
      foreign = create(:system_provider, account: other_account, name: "Foreign Provider")
      get "/api/v1/system/providers/#{foreign.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/providers" do
    let(:create_params) do
      { provider: { name: "New Provider #{SecureRandom.hex(3)}", provider_type: "aws", enabled: true, config: {} } }
    end

    it "returns 403 without create perm" do
      post "/api/v1/system/providers", params: create_params.to_json,
                                        headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a provider scoped to the account" do
      expect {
        post "/api/v1/system/providers", params: create_params.to_json,
                                          headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      }.to change { ::System::Provider.where(account: account).count }.by(1)
      expect(response.status).to be_between(200, 299)
    end
  end

  describe "PATCH /api/v1/system/providers/:id" do
    it "returns 403 without update perm" do
      patch "/api/v1/system/providers/#{provider.id}",
            params: { provider: { name: "renamed" } }.to_json,
            headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "updates the provider" do
      patch "/api/v1/system/providers/#{provider.id}",
            params: { provider: { name: "Renamed-#{SecureRandom.hex(3)}" } }.to_json,
            headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(provider.reload.name).to start_with("Renamed-")
    end
  end

  describe "DELETE /api/v1/system/providers/:id" do
    it "returns 403 without delete perm" do
      delete "/api/v1/system/providers/#{provider.id}", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "deletes the provider" do
      target = create(:system_provider, account: account, name: "deletable-#{SecureRandom.hex(3)}")
      expect {
        delete "/api/v1/system/providers/#{target.id}", headers: auth_headers_for(delete_user)
      }.to change { ::System::Provider.where(account: account).count }.by(-1)
    end
  end

  # NOTE: providers_controller.rb has a `test` action but it's NOT routed
  # (the actual test action lives on provider_connections_controller). The
  # method appears to be dead code in providers_controller; flagged here
  # for a future audit sweep. The spec deliberately omits it.
end
