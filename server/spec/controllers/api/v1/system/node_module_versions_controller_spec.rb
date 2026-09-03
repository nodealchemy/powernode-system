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
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_content)
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

    # IMP-d6826c872d88 — this endpoint promoted straight through
    # NodeModuleVersion#promote_to! and never evaluated PromotionCriteria, so
    # an operator could bless a version no instance had run for the dwell with
    # nothing in the response or the audit log saying the automated lane would
    # have refused. Operator ruling D17 (2026-09-02): consult and WARN, never
    # refuse — the operator keeps the authority, the silence is what goes.
    describe "promotion-criteria advisory" do
      let!(:staged) do
        create(:system_node_module_version, node_module: node_module, version_number: 7,
               oci_digest: "sha256:#{'c' * 64}", promotion_state: "staging")
      end

      def promote(target_state)
        post "/api/v1/system/node_module_versions/#{staged.id}/promote",
             params: { target_state: target_state }.to_json,
             headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      end

      it "still blesses an unqualified version, and says the criteria would have refused" do
        promote("blessed")

        expect(response).to have_http_status(:ok)
        expect(staged.reload.promotion_state).to eq("blessed")

        body = JSON.parse(response.body)
        data = body["data"] || body
        expect(data.dig("promotion_criteria", "eligible")).to be false
        expect(data["promotion_criteria_warning"]).to match(/running_count 0 < required/)
      end

      it "records the override as an auditable FleetEvent naming the operator" do
        promote("blessed")

        events = ::System::FleetEvent.where(
          account_id: account.id,
          kind: ::System::Fleet::ManualPromotionAdvisory::EVENT_KIND
        )
        expect(events.count).to eq(1)
        expect(events.first.source).to eq(::System::Fleet::ManualPromotionAdvisory::REST_SOURCE)
        expect(events.first.node_module_version_id).to eq(staged.id)
        expect(events.first.payload["actor_id"]).to eq(update_user.id)
        # A User id and an Ai::Agent id are both bare UUIDs; the producer says
        # which kind this was so an auditor need not infer it from `source`.
        expect(events.first.payload["actor_type"]).to eq("user")
      end

      it "leaves an ungated target state (retired) unannotated and unaudited" do
        promote("retired")

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        data = body["data"] || body
        expect(data).not_to have_key("promotion_criteria")
        expect(::System::FleetEvent.where(
          account_id: account.id,
          kind: ::System::Fleet::ManualPromotionAdvisory::EVENT_KIND
        ).count).to eq(0)
      end
    end
  end
end
