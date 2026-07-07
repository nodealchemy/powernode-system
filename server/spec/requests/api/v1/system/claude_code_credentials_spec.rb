# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::ClaudeCodeCredentials", type: :request do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node) { create(:system_node, account: account, node_template: node_template) }
  let(:instance) { create(:system_node_instance, node: node) }

  let(:reader)  { user_with_permissions("system.node_instance_credentials.read", account: account) }
  let(:manager) do
    user_with_permissions("system.node_instance_credentials.read",
                           "system.node_instance_credentials.manage", account: account)
  end

  let(:base_path) { "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/claude_code_credential" }

  # Vault stubbing — never touch real Vault from request specs, and never
  # let the fake secret value leak into an assertion by accident.
  let(:fake_vault) { instance_double("Security::VaultCredentialProvider") }
  before do
    allow(::Security::VaultCredentialProvider).to receive(:new).and_return(fake_vault)
    allow(fake_vault).to receive(:store_credential).and_return(true)
    allow(fake_vault).to receive(:rotate_credential).and_return(true)
    allow(fake_vault).to receive(:delete_credential).and_return(true)
  end

  describe "GET (show)" do
    it "returns 404 when no credential has been configured yet" do
      get base_path, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:not_found)
    end

    it "returns the index card (never plaintext) when configured" do
      create(:system_claude_code_credential, node_instance: instance)
      get base_path, headers: auth_headers_for(reader)

      expect(response).to have_http_status(:ok)
      cred = JSON.parse(response.body)["data"]["credential"]
      expect(cred["node_instance_id"]).to eq(instance.id)
      expect(cred["configured"]).to eq(false) # vault_path unset in this fixture
      expect(response.body).not_to include("api_key")
    end

    it "rejects requests without read permission" do
      anon = create(:user, account: account)
      get base_path, headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST (create)" do
    it "creates the row and stores the plaintext in Vault, never in the response" do
      expect(fake_vault).to receive(:store_credential).with(
        hash_including(credential_type: :claude_code_api_key, data: { "api_key" => "sk-ant-TEST-VALUE" })
      )

      expect {
        post base_path, params: { api_key: "sk-ant-TEST-VALUE" }.to_json,
                         headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      }.to change { System::ClaudeCodeCredential.count }.by(1)

      expect(response).to have_http_status(:created)
      expect(response.body).not_to include("sk-ant-TEST-VALUE")
    end

    it "rejects a blank api_key" do
      post base_path, params: { api_key: "" }.to_json,
                       headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "409s when a credential already exists (use rotate instead)" do
      create(:system_claude_code_credential, node_instance: instance)
      post base_path, params: { api_key: "sk-ant-TEST-VALUE" }.to_json,
                       headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:conflict)
    end

    it "forbids users without manage permission" do
      post base_path, params: { api_key: "sk-ant-TEST-VALUE" }.to_json,
                       headers: auth_headers_for(reader).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST rotate" do
    it "rotates the credential in Vault" do
      credential = create(:system_claude_code_credential, node_instance: instance)
      expect(fake_vault).to receive(:rotate_credential).with(
        hash_including(credential_type: :claude_code_api_key, credential_id: credential.id,
                        new_data: { "api_key" => "sk-ant-NEW-VALUE" })
      )

      post "#{base_path}/rotate", params: { api_key: "sk-ant-NEW-VALUE" }.to_json,
                                   headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("sk-ant-NEW-VALUE")
    end
  end

  describe "DELETE (destroy)" do
    it "deletes from Vault and removes the row" do
      create(:system_claude_code_credential, node_instance: instance)
      expect(fake_vault).to receive(:delete_credential)

      expect {
        delete base_path, headers: auth_headers_for(manager)
      }.to change { System::ClaudeCodeCredential.count }.by(-1)
      expect(response).to have_http_status(:ok)
    end

    it "forbids users without manage permission" do
      create(:system_claude_code_credential, node_instance: instance)
      delete base_path, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
