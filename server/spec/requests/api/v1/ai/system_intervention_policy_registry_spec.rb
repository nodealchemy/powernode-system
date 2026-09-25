# frozen_string_literal: true

require "rails_helper"

# The System extension's categories against core's bulk policy save
# (PATCH /api/v1/ai/intervention_policies/bulk, Ai::InterventionPolicies::BulkUpdate).
#
# That save admits exactly the categories Ai::InterventionPolicy.category_registered?
# knows, and this extension's engine does the registering. These examples pin
# the registrations themselves: seeded categories that were once missing (the
# operator saw the row and could not save it), and removed or duplicate
# spellings that must stay unregistered (the save would mint a durable control
# for an action nothing executes). The endpoint's generic behaviour (absent
# keys, defaults, the person-session mark) is core's, pinned in
# server/spec/requests/api/v1/ai/intervention_policies_grouped_spec.rb.
RSpec.describe "System categories through core's bulk policy save", type: :request do
  let(:account) { create(:account) }
  let(:manage_user) { user_with_permissions("ai.intervention_policies.manage", account: account) }

  describe "PATCH /api/v1/ai/intervention_policies/bulk" do
    # IMP-097a267b50b7. Core's bulk save rejects any update whose action_category is
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

        patch "/api/v1/ai/intervention_policies/bulk",
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
    # bulk save collects errors and keeps going, so a batch can be rejected as a
    # whole while individual rows in it have already been written.
    context "with a category whose capability was removed" do
      let(:removed_category) { "system.runtime_docker_tls_rotate" }
      let(:live_sibling)     { "system.runtime_docker_provision" }

      it "rejects the update and creates no policy row for it" do
        patch "/api/v1/ai/intervention_policies/bulk",
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

        patch "/api/v1/ai/intervention_policies/bulk",
              params: { updates: updates }.to_json,
              headers: auth_headers_for(manage_user).merge("Content-Type" => "application/json")

        expect(response).to have_http_status(:unprocessable_content)

        reported = Array(json_response.dig("details", "errors")).join(" ")
        unreported = duplicate_to_live.keys.reject { |cat| reported.include?("unknown category #{cat}") }
        expect(unreported).to be_empty,
                              "PATCH /api/v1/ai/intervention_policies/bulk did not reject #{unreported.join(', ')} as an " \
                              "unknown category, so the registry still accepts a spelling nothing can execute"

        # The EFFECT, not the message: the bulk save collects errors and keeps
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
