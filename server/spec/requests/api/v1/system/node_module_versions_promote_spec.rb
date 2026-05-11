# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator API — Node Module Versions promote", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { user_with_permissions("system.modules.read", "system.modules.update", account: account) }
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "promote-mod")
  end
  let!(:version) do
    create(:system_node_module_version, node_module: node_module, version_number: 1,
           promotion_state: "built")
  end

  describe "POST /api/v1/system/node_module_versions/:id/promote" do
    context "valid transitions" do
      it "advances built → staging and stamps staging_baked_at" do
        post "/api/v1/system/node_module_versions/#{version.id}/promote",
             params: { target_state: "staging" }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body.dig("data", "node_module_version", "promotion_state")).to eq("staging")
        expect(body.dig("data", "node_module_version", "staging_baked_at")).not_to be_nil
      end

      it "advances staging → blessed and stamps blessed_at" do
        version.update!(promotion_state: "staging")

        post "/api/v1/system/node_module_versions/#{version.id}/promote",
             params: { target_state: "blessed" }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        expect(version.reload.promotion_state).to eq("blessed")
        expect(version.reload.blessed_at).not_to be_nil
      end

      it "advances blessed → live and stamps live_at" do
        version.update!(promotion_state: "blessed")

        post "/api/v1/system/node_module_versions/#{version.id}/promote",
             params: { target_state: "live" }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        expect(version.reload.promotion_state).to eq("live")
        expect(version.reload.live_at).not_to be_nil
      end

      it "allows the staging → built rollback transition" do
        version.update!(promotion_state: "staging")

        post "/api/v1/system/node_module_versions/#{version.id}/promote",
             params: { target_state: "built" }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        expect(version.reload.promotion_state).to eq("built")
      end
    end

    context "invalid transitions" do
      it "422s on built → live (illegal skip)" do
        post "/api/v1/system/node_module_versions/#{version.id}/promote",
             params: { target_state: "live" }.to_json, headers: headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to match(/cannot transition/i)
      end

      it "422s on retired → anything" do
        version.update!(promotion_state: "retired")

        post "/api/v1/system/node_module_versions/#{version.id}/promote",
             params: { target_state: "live" }.to_json, headers: headers

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "422s on unknown target_state" do
        post "/api/v1/system/node_module_versions/#{version.id}/promote",
             params: { target_state: "totally-fake" }.to_json, headers: headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to match(/unknown state/i)
      end
    end

    context "input validation" do
      it "400s when target_state is missing" do
        post "/api/v1/system/node_module_versions/#{version.id}/promote",
             params: {}.to_json, headers: headers

        expect(response).to have_http_status(:bad_request)
      end
    end

    context "cross-account isolation" do
      it "404s for a version in another account's module" do
        foreign_platform = create(:system_node_platform, account: other_account)
        foreign_cat = create(:system_node_module_category, account: other_account)
        foreign_module = create(:system_node_module, account: other_account,
                                node_platform: foreign_platform, category: foreign_cat,
                                variety: "subscription", name: "foreign")
        foreign_version = create(:system_node_module_version, node_module: foreign_module,
                                 version_number: 1, promotion_state: "built")

        post "/api/v1/system/node_module_versions/#{foreign_version.id}/promote",
             params: { target_state: "staging" }.to_json, headers: headers

        expect(response).to have_http_status(:not_found)
      end
    end

    context "permissions" do
      it "403s when the user lacks system.modules.update" do
        viewer = user_with_permissions("system.modules.read", account: account)
        viewer_headers = auth_headers_for(viewer).merge("Content-Type" => "application/json")

        post "/api/v1/system/node_module_versions/#{version.id}/promote",
             params: { target_state: "staging" }.to_json, headers: viewer_headers

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
