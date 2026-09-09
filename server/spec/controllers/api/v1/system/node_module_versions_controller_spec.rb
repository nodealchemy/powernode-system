# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for node_module_versions.
#
# Only one operator-facing action: POST :id/promote. It names the environment
# it promotes INTO and moves that plane's pin (Environment campaign, increment
# 4b — the decorative state machine it used to advance is gone); the rules live
# in NodeModule#ladder_refusal and this controller authorizes + delegates.
# Cross-account scoping joins through NodeModule#account_id, not through a
# direct association.
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
  # Mountable, which #ladder_refusal requires, and made current so the bottom
  # pinned rung (staging) will take it.
  let!(:version) do
    create(:system_node_module_version, node_module: node_module, version_number: 1,
           oci_digest: "sha256:#{'a' * 64}",
           artifacts: { "erofs" => { "oci_digest" => "sha256:#{'a' * 64}", "size" => 12_345_000 } })
  end
  let(:staging) { account.environments.find_by!(slug: "staging") }

  before { node_module.promote_to_version!(version) }

  describe "POST /api/v1/system/node_module_versions/:id/promote" do
    it "returns 401 without auth" do
      post "/api/v1/system/node_module_versions/#{version.id}/promote",
           params: { environment: "staging" }.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without update perm" do
      post "/api/v1/system/node_module_versions/#{version.id}/promote",
           params: { environment: "staging" }.to_json,
           headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 400 when the environment is missing" do
      post "/api/v1/system/node_module_versions/#{version.id}/promote",
           params: {}.to_json,
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:bad_request)
    end

    it "returns 404 for an environment this account does not have" do
      post "/api/v1/system/node_module_versions/#{version.id}/promote",
           params: { environment: "bogus" }.to_json,
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:not_found)
    end

    it "returns 422 for a FOLLOWING plane, which is never promoted into" do
      post "/api/v1/system/node_module_versions/#{version.id}/promote",
           params: { environment: "dev" }.to_json,
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/follows publishes/)
    end

    it "returns 404 for another account's version" do
      foreign_platform = create(:system_node_platform, account: other_account)
      foreign_category = create(:system_node_module_category, account: other_account)
      foreign_module = create(:system_node_module, account: other_account,
                                                    node_platform: foreign_platform, category: foreign_category)
      foreign_version = create(:system_node_module_version, node_module: foreign_module)

      post "/api/v1/system/node_module_versions/#{foreign_version.id}/promote",
           params: { environment: "staging" }.to_json,
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:not_found)
    end

    it "moves the named plane's pin onto the version and reports it" do
      post "/api/v1/system/node_module_versions/#{version.id}/promote",
           params: { environment: "staging" }.to_json,
           headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["environment"]).to eq("staging")
      expect(data.dig("node_module_version", "pinned_in")).to eq([ "staging" ])
      expect(node_module.served_version_for(staging)).to eq(version)
    end

    # IMP-d6826c872d88 — this endpoint promoted without ever evaluating
    # PromotionCriteria, so an operator could pin a plane to a version no
    # instance on the rung below had run, with nothing in the response or the
    # audit log saying the automated lane would have refused. Operator ruling
    # D17 (2026-09-02): consult and WARN, never refuse — the operator keeps the
    # authority, the silence is what goes.
    describe "promotion-criteria advisory" do
      def promote(environment = "staging")
        post "/api/v1/system/node_module_versions/#{version.id}/promote",
             params: { environment: environment }.to_json,
             headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")
      end

      it "still promotes an unqualified version, and says the criteria would have refused" do
        promote

        expect(response).to have_http_status(:ok)
        expect(node_module.served_version_for(staging)).to eq(version)

        body = JSON.parse(response.body)
        data = body["data"] || body
        expect(data.dig("promotion_criteria", "eligible")).to be false
        expect(data["promotion_criteria_warning"]).to match(/running_count 0 < required/)
      end

      it "records the override as an auditable FleetEvent naming the operator" do
        promote

        events = ::System::FleetEvent.where(
          account_id: account.id,
          kind: ::System::Fleet::ManualPromotionAdvisory::EVENT_KIND
        )
        expect(events.count).to eq(1)
        expect(events.first.source).to eq(::System::Fleet::ManualPromotionAdvisory::REST_SOURCE)
        expect(events.first.node_module_version_id).to eq(version.id)
        expect(events.first.payload["actor_id"]).to eq(update_user.id)
        # A User id and an Ai::Agent id are both bare UUIDs; the producer says
        # which kind this was so an auditor need not infer it from `source`.
        expect(events.first.payload["actor_type"]).to eq("user")
      end

      it "annotates and audits nothing when the ladder refused the promotion" do
        promote("dev")

        expect(response).to have_http_status(:unprocessable_content)
        expect(::System::FleetEvent.where(
          account_id: account.id,
          kind: ::System::Fleet::ManualPromotionAdvisory::EVENT_KIND
        ).count).to eq(0)
      end
    end
  end
end
