# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for autonomy.
#
# Singular resource: GET /api/v1/system/autonomy + PATCH /api/v1/system/autonomy
# (no :id). Read gated by system.infra_tasks.read; update by
# system.infra_tasks.control. Logic lives in the AutonomyActions concern; the
# controller just gates permissions.
RSpec.describe "Api::V1::System::Autonomy", type: :request do
  let(:account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.infra_tasks.read",    account: account) }
  let(:manage_user) { user_with_permissions("system.infra_tasks.control", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  describe "GET /api/v1/system/autonomy" do
    it "returns 401 without auth" do
      get "/api/v1/system/autonomy"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/autonomy", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns the 3-pivot payload (by_action/by_agent/by_domain)" do
      get "/api/v1/system/autonomy", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      data = json_response_data
      expect(data).to have_key("agents")
      expect(data).to have_key("chains")
      expect(data).to have_key("policies")
      expect(data["policies"]).to have_key("by_action")
      expect(data["policies"]).to have_key("by_agent")
      expect(data["policies"]).to have_key("by_domain")
    end
  end

  describe "PATCH /api/v1/system/autonomy" do
    it "returns 403 without control perm" do
      patch "/api/v1/system/autonomy",
            params: { updates: [] }.to_json,
            headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 400 when updates is missing" do
      patch "/api/v1/system/autonomy",
            params: {}.to_json,
            headers: auth_headers_for(manage_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:bad_request)
    end

    # IMP-097a267b50b7. The concern rejects any update whose action_category is
    # not `Ai::InterventionPolicy.category_registered?`, and fourteen categories
    # whose policy rows the agent seeds ship were missing from the engine's
    # registration block — so the operator saw the row in the Autonomy modal and
    # could not save a change to it.
    #
    # Asserts the EFFECT (the rows persist), not the branch: a registration that
    # got the category NAME subtly wrong would still take the "registered"
    # branch for its own string while leaving these rejected.
    context "with seeded categories that were unregistered" do
      # Five reach the operator through DecisionEngine::SIGNAL_BINDINGS...
      let(:sensor_gated_categories) do
        %w[
          system.sdwan_service_health_investigate
          system.disk_image_publication_investigate
          system.node_boot_image_drift
          system.package_repository.sync
          system.module_critical_upgrade_ready
        ]
      end

      # ...and nine never pass through SIGNAL_BINDINGS at all — they gate from
      # the executor/MCP path, which is why a bindings-only enumeration missed
      # them while their seeded rows sat un-saveable in the modal.
      let(:non_sensor_categories) do
        %w[
          system.architecture.propose
          system.architecture.create
          system.architecture.update
          system.architecture.delete
          system.package_module.create
          system.package_module.refresh
          system.gitops_apply_proposal
          system.gitops_register_repository
          system.gitops_sync_repository
        ]
      end

      let(:previously_unregistered) { sensor_gated_categories + non_sensor_categories }

      it "accepts and persists a policy for each of them" do
        updates = previously_unregistered.map do |cat|
          { action_category: cat, policy: "require_approval" }
        end

        patch "/api/v1/system/autonomy",
              params: { updates: updates }.to_json,
              headers: auth_headers_for(manage_user).merge("Content-Type" => "application/json")

        expect(response).to have_http_status(:ok)

        persisted = Ai::InterventionPolicy
          .where(account: account, action_category: previously_unregistered)
          .pluck(:action_category)

        expect(persisted).to match_array(previously_unregistered)
      end
    end
  end
end
