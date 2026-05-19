# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for node_module_versions.
#
# Only one operator-facing action: POST :id/promote. The promotion state
# machine itself lives on NodeModuleVersion#promote_to! — this controller
# just authorizes + delegates. Cross-account scoping joins through
# NodeModule#account_id, not through a direct association.
RSpec.describe "Api::V1::System::NodeModuleVersions", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:update_user) { user_with_permissions("system.modules.update", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform, category: category)
  end
  let!(:version) { create(:system_node_module_version, node_module: node_module, version_number: 1) }

  describe "POST /api/v1/system/node_module_versions/:id/promote" do
    it "returns 401 without auth" do
      post "/api/v1/system/node_module_versions/#{version.id}/promote",
           params: { target_state: "staging" }.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without update perm" do
      post "/api/v1/system/node_module_versions/#{version.id}/promote",
           params: { target_state: "staging" }.to_json,
           headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 400 when target_state is missing" do
      post "/api/v1/system/node_module_versions/#{version.id}/promote",
           params: {}.to_json,
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:bad_request)
    end

    it "returns 422 when target_state is invalid" do
      post "/api/v1/system/node_module_versions/#{version.id}/promote",
           params: { target_state: "bogus" }.to_json,
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
    end

    it "returns 404 for another account's version" do
      foreign_platform = create(:system_node_platform, account: other_account)
      foreign_category = create(:system_node_module_category, account: other_account)
      foreign_module = create(:system_node_module, account: other_account,
                                                    node_platform: foreign_platform, category: foreign_category)
      foreign_version = create(:system_node_module_version, node_module: foreign_module)

      post "/api/v1/system/node_module_versions/#{foreign_version.id}/promote",
           params: { target_state: "staging" }.to_json,
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:not_found)
    end

    it "promotes a version through the state machine" do
      post "/api/v1/system/node_module_versions/#{version.id}/promote",
           params: { target_state: "staging" }.to_json,
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(version.reload.promotion_state).to eq("staging")
    end
  end
end
