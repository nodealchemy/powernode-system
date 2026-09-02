# frozen_string_literal: true

require "rails_helper"

# IMP-e313a4a72309 — the audience of the GitOps repository WRITE and SYNC verbs.
#
# THE FINDING. IMP-b1191457a091 fixed system.gitops.read (registered
# `grant: { system_worker: true }`, held by no assignable role, gating an
# operator-facing REST read) and filed its two neighbours rather than fixing
# them:
#
#   * system.gitops.write was registered `grant: {}` — named by no role's
#     grant at all — while gitops_repositories_controller.rb gates create
#     (:34), update (:44) and destroy (:53) on it and the UI renders its
#     controls behind it (GitopsTab.tsx:34, OperationsHubPage.tsx:64). An
#     empty grant hash is not an empty AUDIENCE: the system.admin holders
#     still reached it (see WHY A REAL ROLE below). Every OTHER role could
#     not, which is the defect.
#   * system.gitops.sync was registered `grant: { system_worker: true }` while
#     the only thing gating on it is sync_now (:65), a REST action behind an
#     operator button (GitopsTab.tsx:35).
#
# Neither name has a worker consumer. The worker's reconcile tick authorizes on
# a DIFFERENT name, system.gitops.reconcile
# (api/v1/system/worker_api/gitops_controller.rb:14), which is a genuine worker
# verb and is deliberately NOT touched here.
#
# THE DECISION. The operator was asked directly (2026-09-01) whether to decide
# the two names separately and chose to grant BOTH to `admin` together, matching
# what .read received in IMP-b1191457a091. This spec is the record of that
# decision as well as its test.
#
# WHY A REAL ROLE. `user_with_permissions` proves a gate admits a holder and
# says nothing about whether any ASSIGNABLE role is one — which is precisely how
# both this defect and IMP-b1191457a091's survived. Every admitted-principal
# example below uses `create(:user, :admin)`, whose permissions come from the
# role_permissions rows Role.sync_from_config! materialises from the catalog
# (spec/rails_helper.rb:170).
#
# The `admin` role does NOT hold system.admin — its list is RESOURCE_PERMISSIONS
# + ADMIN_PERMISSIONS minus admin.maintenance.* (config/permissions.rb:930-940),
# and system.admin is in neither. So User#has_permission? (user.rb:138-141) does
# not short-circuit for it and these examples really do depend on the catalog
# grant. system.admin is NOT exclusive to super_admin (config/permissions.rb
# :947): system_worker holds it too, via the SYSTEM_PERMISSIONS splat at :958 —
# a recorded operator decision pinned by
# server/spec/models/role_privilege_tiers_spec.rb. That is why "worker-only" in
# this codebase names an explicit-GRANT boundary and never an ACCESS one, and
# why `admin` is the only role whose access these grants actually change.
#
# WHY THE TWO NAMES ARE ASSERTED SEPARATELY, never in a shared loop: removing
# `admin: true` from one grant must redden only that name's examples. A combined
# oracle would let either grant mask the other.
#
# WHY THE REFUSAL CONTROLS HOLD system.gitops.read. A principal holding NOTHING
# would be refused by any gate whatsoever, including the wrong one — such an
# example stays green if the controller gates on an unrelated name. The controls
# below hold the SIBLING read permission, so they fail if .read ever starts
# admitting the write or sync surface, which is the entire reason these are
# three separate names.
#
# WHY A ROW ORACLE. Each admitted-principal example asserts the DATABASE effect
# (a row created, a column changed, a row destroyed, a sync_run enqueued), not
# only the status. A guard that renders from an action body does not halt in
# Rails, so a status-only assertion cannot distinguish "admitted" from "refused
# but the write landed anyway". (require_permission raises today —
# concerns/authentication.rb:273-278 — and this keeps the oracle honest if that
# ever changes.)
RSpec.describe "Operator API — GitOps write/sync audience (IMP-e313a4a72309)", type: :request do
  let(:account) { create(:account) }

  let(:admin)   { create(:user, :admin, account: account) }
  let(:headers) { auth_headers_for(admin) }

  let!(:repo) do
    ::System::GitopsRepository.create!(
      account: account, name: "fleet-config",
      repo_url: "https://git.example.test/fleet.git", branch: "main",
      path_prefix: "clusters/prod", enabled: true, auto_apply: false
    )
  end

  # ---------------------------------------------------------------------------
  # The permission MODEL — the root defect, independent of any one endpoint.
  # ---------------------------------------------------------------------------
  describe "catalog grants" do
    it "grants system.gitops.write to the admin role the CRUD controls were built for" do
      expect(::Permissions.permissions_for_role("admin")).to include("system.gitops.write")
    end

    it "grants system.gitops.sync to the admin role the sync_now button was built for" do
      expect(::Permissions.permissions_for_role("admin")).to include("system.gitops.sync")
    end

    # system.gitops.sync was `{ system_worker: true }` before this task. The
    # grant is WIDENED, not moved: nothing here removes an existing audience.
    it "leaves system.gitops.sync on system_worker" do
      expect(::Permissions.permissions_for_role("system_worker")).to include("system.gitops.sync")
    end

    # The blast radius is bounded to the two names the operator decided.
    it "does not reach the non-operator user roles" do
      %w[manager member].each do |role|
        grants = ::Permissions.permissions_for_role(role)

        expect(grants).not_to include("system.gitops.write")
        expect(grants).not_to include("system.gitops.sync")
      end
    end

    # The neighbour that stays worker-only. Its ONLY consumer is the worker tick
    # (worker_api/gitops_controller.rb:14); no controller and no UI gates on it.
    it "leaves system.gitops.reconcile worker-only" do
      expect(::Permissions.permissions_for_role("admin")).not_to include("system.gitops.reconcile")
    end
  end

  # ---------------------------------------------------------------------------
  # system.gitops.write — create / update / destroy
  # ---------------------------------------------------------------------------
  describe "POST /api/v1/system/gitops_repositories (create)" do
    let(:payload) do
      {
        gitops_repository: {
          name: "new-fleet", repo_url: "https://git.example.test/new.git",
          branch: "main", path_prefix: "", enabled: true, auto_apply: false
        }
      }
    end

    it "admits the real admin role and creates the row" do
      expect do
        post "/api/v1/system/gitops_repositories", params: payload.to_json, headers: headers
      end.to change { account.system_gitops_repositories.where(name: "new-fleet").count }.by(1)

      expect(response).to have_http_status(:created)
    end

    it "still refuses a principal holding only system.gitops.read, writing nothing" do
      other = user_with_permissions("system.gitops.read", account: account)

      expect do
        post "/api/v1/system/gitops_repositories",
             params: payload.to_json, headers: auth_headers_for(other)
      end.not_to(change { account.system_gitops_repositories.count })

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /api/v1/system/gitops_repositories/:id (update)" do
    it "admits the real admin role and persists the change" do
      patch "/api/v1/system/gitops_repositories/#{repo.id}",
            params: { gitops_repository: { branch: "release" } }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(repo.reload.branch).to eq("release")
    end

    it "still refuses a principal holding only system.gitops.read, persisting nothing" do
      other = user_with_permissions("system.gitops.read", account: account)

      patch "/api/v1/system/gitops_repositories/#{repo.id}",
            params: { gitops_repository: { branch: "release" } }.to_json,
            headers: auth_headers_for(other)

      expect(response).to have_http_status(:forbidden)
      expect(repo.reload.branch).to eq("main")
    end
  end

  describe "DELETE /api/v1/system/gitops_repositories/:id (destroy)" do
    it "admits the real admin role and removes the row" do
      expect do
        delete "/api/v1/system/gitops_repositories/#{repo.id}", headers: headers
      end.to change { ::System::GitopsRepository.where(id: repo.id).count }.from(1).to(0)

      expect(response).to have_http_status(:ok)
    end

    it "still refuses a principal holding only system.gitops.read, removing nothing" do
      other = user_with_permissions("system.gitops.read", account: account)

      expect do
        delete "/api/v1/system/gitops_repositories/#{repo.id}", headers: auth_headers_for(other)
      end.not_to(change { ::System::GitopsRepository.where(id: repo.id).count })

      expect(response).to have_http_status(:forbidden)
    end
  end

  # ---------------------------------------------------------------------------
  # system.gitops.sync — sync_now
  # ---------------------------------------------------------------------------
  describe "POST /api/v1/system/gitops_repositories/:id/sync_now" do
    before do
      # Class-level stub — the same isolation the sibling sync_now spec uses; no
      # example here asserts on reconcile OUTPUT, only that the action ran.
      allow(::System::Gitops::Reconciler).to receive(:reconcile!).and_return(
        ::System::Gitops::Reconciler::Result.new(
          ok?: true, diff_count: 0, proposal_ids: [],
          applied_proposal_ids: [], failed_proposal_ids: [],
          diff_summary: nil, error: nil
        )
      )
    end

    it "admits the real admin role and enqueues a sync run" do
      expect do
        post "/api/v1/system/gitops_repositories/#{repo.id}/sync_now", headers: headers
      end.to change { repo.sync_runs.count }.by(1)

      expect(response).to have_http_status(:ok)
    end

    it "still refuses a principal holding only system.gitops.read, enqueuing nothing" do
      other = user_with_permissions("system.gitops.read", account: account)

      expect do
        post "/api/v1/system/gitops_repositories/#{repo.id}/sync_now",
             headers: auth_headers_for(other)
      end.not_to(change { repo.sync_runs.count })

      expect(response).to have_http_status(:forbidden)
    end
  end
end
