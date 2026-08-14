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

    # IMP-6e52d6aa53da — the inverse of the context above, and the reason
    # registration is worth removing rather than leaving as tidy-up.
    # `system.runtime_docker_tls_rotate` was registered but seeded nowhere: the
    # 2026-05-19 audit deleted its policy row because no executor backed it and
    # left the registration standing, so this endpoint — whose only category
    # check is `category_registered?` — would `find_or_initialize_by` and
    # CREATE a row for it on demand, giving the operator a durable control for
    # an action nothing can execute.
    #
    # Asserts the EFFECT (no row exists afterwards), not just the message: the
    # concern collects errors and keeps going, so a batch can be rejected as a
    # whole while individual rows in it have already been written.
    context "with a category whose capability was removed" do
      let(:removed_category) { "system.runtime_docker_tls_rotate" }
      let(:live_sibling)     { "system.runtime_docker_provision" }

      it "rejects the update and creates no policy row for it" do
        patch "/api/v1/system/autonomy",
              params: { updates: [
                { action_category: removed_category, policy: "auto_approve" },
                { action_category: live_sibling,     policy: "auto_approve" }
              ] }.to_json,
              headers: auth_headers_for(manage_user).merge("Content-Type" => "application/json")

        expect(response).to have_http_status(:unprocessable_content)
        expect(Array(json_response.dig("details", "errors")).join(" "))
          .to include("unknown category #{removed_category}")

        expect(Ai::InterventionPolicy.where(account: account, action_category: removed_category))
          .to be_empty

        # Positive twin: the batch was otherwise well-formed and its live
        # sibling persisted, so the rejection is about THIS category and not
        # about the request shape or the account setup.
        expect(Ai::InterventionPolicy.where(account: account, action_category: live_sibling))
          .to exist
      end
    end

    # IMP-eb60db901f5f — three more registrations of the same shape, decided
    # per-category rather than swept. Each turned out to be a second SPELLING of
    # a capability that already had one, not a capability of its own: the
    # 2026-05-10 five-agent split (d579be93) wrote BOTH the seeded policy name
    # and the executor CLASS name for the same action into one `concat`, so
    # `system.runtime_docker_host_provision` (the shape of
    # System::Executors::Runtime::ProvisionDockerHost) shipped beside the seeded
    # `system.runtime_docker_provision` that names the same operation.
    #
    # Those executor classes DO exist and are real implementations, not stubs —
    # `git grep -l ProvisionDockerHost` returns
    # app/services/system/executors/runtime/{provision,decommission}_docker_host.rb
    # and bootstrap_k3s_cluster.rb. They are named here because that is the
    # trap: the removed category names grep to nothing, but the CLASS names grep
    # to working code, and a maintainer could read that as evidence the removed
    # spelling was backed. It is not. An executor declares no category — the
    # link is the `executor_class:` string at a gate site — and nothing in the
    # tree passes any of those three class names, so they are evidence of the
    # vocabulary, not of a backing. (The seeded spellings below have no gate
    # site either; the only runtime executor with a call site is
    # DecommissionK3sCluster, under system.runtime_k8s_cluster_decommission.
    # That gap is a separate finding — it does not make either spelling more
    # backed than the other, and the seeded one is the survivor because it is
    # the one with policy rows.)
    #
    # `git log -S <name> --all` over every path finds each of the three in
    # exactly two commits: d579be93 (added) and eac08d0b (annotated in
    # autonomy_categories_registration_spec.rb). Never seeded, never gated,
    # never executed. Live powernode_production held zero
    # ai_intervention_policies / ai_deferred_operations /
    # system_fleet_remediation_outcomes rows for any of them at removal time
    # (its 7 `system.runtime_%` policy rows match the seed exactly), so no
    # operator data was stranded.
    context "with categories that were duplicate spellings of a live capability" do
      # removed duplicate => the seeded spelling of the SAME capability, which
      # must keep working. Pairing them makes the twin per-NAME: a mutant that
      # deletes the wrong side of a pair reds on the surviving half.
      let(:duplicate_to_live) do
        {
          "system.runtime_docker_host_provision"    => "system.runtime_docker_provision",
          "system.runtime_docker_host_decommission" => "system.runtime_docker_decommission",
          "system.runtime_k8s_cluster_create"       => "system.runtime_k8s_cluster_bootstrap"
        }
      end

      it "rejects every duplicate spelling, persists none of them, and still accepts each live one" do
        updates = duplicate_to_live.flat_map do |duplicate, live|
          [ { action_category: duplicate, policy: "auto_approve" },
            { action_category: live,      policy: "auto_approve" } ]
        end

        patch "/api/v1/system/autonomy",
              params: { updates: updates }.to_json,
              headers: auth_headers_for(manage_user).merge("Content-Type" => "application/json")

        expect(response).to have_http_status(:unprocessable_content)

        reported = Array(json_response.dig("details", "errors")).join(" ")
        unreported = duplicate_to_live.keys.reject { |cat| reported.include?("unknown category #{cat}") }
        expect(unreported).to be_empty,
                              "PATCH /api/v1/system/autonomy did not reject #{unreported.join(', ')} as an " \
                              "unknown category, so the registry still accepts a spelling nothing can execute"

        # The EFFECT, not the message: the concern collects errors and keeps
        # going, so a 422 for the batch is compatible with rows having been
        # written for individual entries in it.
        persisted_duplicates = Ai::InterventionPolicy
          .where(account: account, action_category: duplicate_to_live.keys)
          .pluck(:action_category)
        expect(persisted_duplicates).to be_empty,
                                        "the bulk PATCH created durable operator controls for #{persisted_duplicates.join(', ')} " \
                                        "— actions no executor, seed or gate site backs"

        # Positive twin, one per removed name: each live spelling in the same
        # batch persisted, so the rejections are about those three names and not
        # about the request shape, the account, or a registry that lost the
        # whole `system.runtime_` family.
        expect(Ai::InterventionPolicy.where(account: account, action_category: duplicate_to_live.values)
                                     .pluck(:action_category))
          .to match_array(duplicate_to_live.values)
      end
    end
  end
end
