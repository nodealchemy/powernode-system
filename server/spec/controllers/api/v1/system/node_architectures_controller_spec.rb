# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — operator controller spec for node_architectures.
#
# Important: NodeArchitecture went PLATFORM-WIDE (i-would-like-to-zesty-glade
# Tier 1) — the catalog is shared across every account and is queried via
# ::System::NodeArchitecture.all (not account-scoped). Two permission families:
# system.architectures.read for index/show, system.architectures.manage for
# create/update/destroy. Canonical rows are immutable via the API (403 on
# update/destroy via #protected_canonical?).
RSpec.describe "Api::V1::System::NodeArchitectures", type: :request do
  let(:account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.architectures.read",   account: account) }
  let(:manage_user) { user_with_permissions("system.architectures.manage", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let!(:architecture) { create(:system_node_architecture) }

  describe "GET /api/v1/system/node_architectures" do
    it "returns 401 without auth" do
      get "/api/v1/system/node_architectures"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/node_architectures", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns the platform-wide architecture catalog (not account-scoped)" do
      get "/api/v1/system/node_architectures", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      ids = json_response_data["node_architectures"].map { |a| a["id"] }
      expect(ids).to include(architecture.id)
    end
  end

  describe "GET /api/v1/system/node_architectures/:id" do
    it "returns the architecture" do
      get "/api/v1/system/node_architectures/#{architecture.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["node_architecture"]["id"]).to eq(architecture.id)
    end

    it "returns 404 for unknown id" do
      get "/api/v1/system/node_architectures/nonexistent-id", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/node_architectures" do
    let(:create_params) do
      { node_architecture: { name: "spec_arch_#{SecureRandom.hex(3)}", family: "other" } }
    end

    it "returns 403 without manage perm" do
      post "/api/v1/system/node_architectures", params: create_params.to_json,
                                                headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a non-canonical architecture (canonical flag is forced to false)" do
      post "/api/v1/system/node_architectures",
           params: { node_architecture: { name: "spec_arch_#{SecureRandom.hex(3)}", family: "other", is_canonical: true } }.to_json,
           headers: auth_headers_for(manage_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:created)
      arch_id = json_response_data["node_architecture"]["id"]
      expect(::System::NodeArchitecture.find(arch_id).is_canonical).to be(false)
    end

    it "returns 422 on missing name" do
      post "/api/v1/system/node_architectures",
           params: { node_architecture: { family: "other" } }.to_json,
           headers: auth_headers_for(manage_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /api/v1/system/node_architectures/:id" do
    it "updates a non-canonical architecture" do
      patch "/api/v1/system/node_architectures/#{architecture.id}",
            params: { node_architecture: { description: "spec-updated" } }.to_json,
            headers: auth_headers_for(manage_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(architecture.reload.description).to eq("spec-updated")
    end

    it "returns 403 when attempting to mutate a canonical architecture" do
      canonical = create(:system_node_architecture, :canonical)
      patch "/api/v1/system/node_architectures/#{canonical.id}",
            params: { node_architecture: { description: "should-fail" } }.to_json,
            headers: auth_headers_for(manage_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/system/node_architectures/:id" do
    it "deletes a non-canonical architecture" do
      victim = create(:system_node_architecture)
      expect {
        delete "/api/v1/system/node_architectures/#{victim.id}", headers: auth_headers_for(manage_user)
      }.to change { ::System::NodeArchitecture.where(id: victim.id).count }.by(-1)
      expect(response).to have_http_status(:ok)
    end

    it "returns 403 for canonical architectures (DB-migration-only)" do
      canonical = create(:system_node_architecture, :canonical)
      delete "/api/v1/system/node_architectures/#{canonical.id}", headers: auth_headers_for(manage_user)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
