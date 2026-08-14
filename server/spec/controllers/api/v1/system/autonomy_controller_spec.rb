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

    # IMP-0874acd5b50c. The Autonomy modal now renders its rows from `by_domain`
    # instead of a list literal-ed into SystemSettingsPanel.tsx, which had
    # drifted to omit 28 of the 119 seeded categories. To show a row's CURRENT
    # verb the client has to know which by_agent bucket that row belongs to, and
    # re-deriving the rule (scope == "agent" && agent present) in TypeScript
    # would reintroduce the very second-source-of-truth this change removes. So
    # every serialized row carries `agent_bucket`, produced by the same method
    # `by_agent_pivot` groups with.
    #
    # These examples assert the EFFECT — the emitted value and its agreement
    # with the other pivot — not that a particular branch was taken.
    context "agent_bucket on serialized rows" do
      let!(:fleet_agent) { create(:ai_agent, account: account, name: "Fleet Autonomy") }
      # NOT a member of SYSTEM_AGENT_NAMES, so `by_agent_pivot` builds no bucket
      # for it and drops its rows entirely — the case that makes shipping the
      # bucket on the row load-bearing rather than convenient.
      let!(:unlisted_agent) { create(:ai_agent, account: account, name: "GitOps Reconciler") }

      def policy!(category, scope:, agent: nil)
        Ai::InterventionPolicy.create!(
          account: account, action_category: category, scope: scope,
          ai_agent_id: agent&.id, policy: "notify_and_proceed", priority: 5, is_active: true
        )
      end

      def payload
        get "/api/v1/system/autonomy", headers: auth_headers_for(read_user)
        expect(response).to have_http_status(:ok)
        json_response_data["policies"]
      end

      def domain_rows(pivot)
        pivot["by_domain"].values.flatten
      end

      it "names the owning agent for an agent-scoped row and Manual Operations for an agent-less one" do
        agent_row  = policy!("system.cert_rotate", scope: "agent", agent: fleet_agent)
        global_row = policy!("system.task.start", scope: "global")

        buckets = domain_rows(payload).to_h { |r| [ r["id"], r["agent_bucket"] ] }

        expect(buckets[agent_row.id]).to eq("Fleet Autonomy")
        expect(buckets[global_row.id]).to eq("Manual Operations")
      end

      it "still carries the bucket for a row by_agent drops" do
        row = policy!("system.gitops_apply_proposal", scope: "agent", agent: unlisted_agent)

        pivot = payload

        expect(pivot["by_agent"]).not_to have_key("GitOps Reconciler")
        expect(pivot["by_agent"].values.flatten.map { |r| r["id"] }).not_to include(row.id)

        dropped = domain_rows(pivot).find { |r| r["id"] == row.id }
        expect(dropped).to be_present
        expect(dropped["agent_bucket"]).to eq("GitOps Reconciler")
        expect(dropped["policy"]).to eq("notify_and_proceed")
      end

      it "partitions by_agent exactly as agent_bucket says, for every bucket that view keeps" do
        policy!("system.cert_rotate", scope: "agent", agent: fleet_agent)
        policy!("system.instance_reboot", scope: "agent", agent: fleet_agent)
        policy!("system.task.start", scope: "global")
        policy!("system.gitops_apply_proposal", scope: "agent", agent: unlisted_agent)

        pivot = payload
        rows  = domain_rows(pivot)

        mismatched = pivot["by_agent"].reject do |bucket, kept|
          kept.map { |r| r["id"] }.sort ==
            rows.select { |r| r["agent_bucket"] == bucket }.map { |r| r["id"] }.sort
        end

        expect(mismatched.keys).to be_empty,
                                   "by_agent bucket(s) #{mismatched.keys.join(', ')} hold a different set of " \
                                   "rows than agent_bucket claims — a modal reading by_domain would show the " \
                                   "wrong current verb for them"
        # Positive twin: the comparison above is vacuous if every kept bucket is
        # empty, which is the state the endpoint returns for a bare account.
        expect(pivot["by_agent"]["Fleet Autonomy"].size).to eq(2)
        expect(pivot["by_agent"]["Manual Operations"].size).to eq(1)
      end
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
