# frozen_string_literal: true

require "rails_helper"

# IMP-b1191457a091 — the audience of the GitOps repository read verbs.
#
# THE FINDING. IMP-f07be27ba0b0 added system_gitops_get_repository /
# system_gitops_list_repositories and gated both on system.modules.read, because
# the name their REST twin uses — system.gitops.read — was registered
# `grant: { system_worker: true }` and nothing else, so no operator role held
# it. IMP-0f914db2c7cf had already put vault_credential_path and
# required_credential_keys into serialize_gitops_repository, and these two verbs
# are the first MCP surface to return that projection. The net effect was that
# reading a repository's Vault KV PATH moved from {system_worker, super_admin}
# to {admin, system_worker, super_admin}, and every agent principal holding
# system.modules.read for ordinary module work could enumerate every GitOps
# repository's Vault path.
#
# THE FIX ASSERTED HERE is the permission model, not the symptom: a read
# permission that NO human role holds is itself the defect, and it is what
# forced the divergence. engine.rb now grants system.gitops.read to `admin` as
# well, and both verbs gate on it — matching REST exactly.
#
# WHY REAL ROLES for the admin case. `user_with_permissions` proves a gate
# admits a holder and says nothing about whether any assignable role IS one;
# that is precisely how the 428f84ce defect (and this one) survived. See the
# same argument at the head of system_fleet_tool_action_permission_spec.rb.
#
# WHY A STATE ORACLE. The primary assertion on a denied call is that the
# response carries the repository's Vault path NOWHERE — the property the
# finding is about. The error text is asserted second, and only to tie the
# example to THIS action's ACTION_PERMISSIONS entry: required_perm_for falls
# back to REQUIRED_PERMISSION for an unrecognised name, so "success is false"
# alone stays green with the verb deleted.
#
# The two verbs are asserted in SEPARATE describe blocks with duplicated bodies
# rather than a shared loop, so mutating one verb's ACTION_PERMISSIONS entry
# reddens only that verb's examples. A combined oracle would let either gate
# mask the other.
RSpec.describe Ai::Tools::SystemFleetTool, "GitOps read audience (IMP-b1191457a091)" do
  let(:account)    { create(:account) }
  let(:vault_path) { "secret/data/powernode/gitops/deploy" }

  let!(:repo) do
    ::System::GitopsRepository.create!(
      account: account, name: "fleet-config",
      repo_url: "https://git.example.test/fleet.git", branch: "main",
      path_prefix: "clusters/prod", enabled: true, auto_apply: false,
      vault_credential_path: vault_path
    )
  end

  # The population the finding is about: an agent principal granted module read
  # for ordinary module work, holding nothing else. `permissions:` mints a role
  # carrying exactly these names (User#assign_permissions_after_create) —
  # PermissionTestHelpers#user_with_permissions is the same call, but it is only
  # included for :request/:controller/:model specs, not this one.
  let(:module_reader) { create(:user, account: account, permissions: [ "system.modules.read" ]) }
  let(:gitops_reader) { create(:user, account: account, permissions: [ "system.gitops.read" ]) }
  let(:admin)         { create(:user, :admin, account: account) }

  def call_as(user, action, **rest)
    described_class.new(account: account, user: user)
                   .execute(params: { action: action }.merge(rest))
  end

  # ---------------------------------------------------------------------------
  # The permission MODEL — the root defect, independent of either verb.
  # ---------------------------------------------------------------------------
  describe "system.gitops.read grants" do
    it "is held by the admin role the REST read and the GitOps tab were built for" do
      expect(::Permissions.permissions_for_role("admin")).to include("system.gitops.read")
    end

    it "is still held by system_worker (regression: the grant was widened, not moved)" do
      expect(::Permissions.permissions_for_role("system_worker")).to include("system.gitops.read")
    end

    it "does not reach the non-operator user roles" do
      %w[manager member].each do |role|
        expect(::Permissions.permissions_for_role(role)).not_to include("system.gitops.read")
      end
    end

    # THIS task's blast radius was bounded to the READ name. It no longer
    # describes the catalog, because the operator decided otherwise for one of
    # the two names this task left alone.
    #
    # The rationale that used to sit here — "the reconcile tick and the sync
    # trigger, which are worker verbs by design" — was only ever true of
    # .reconcile. Its sole consumer is the worker tick
    # (api/v1/system/worker_api/gitops_controller.rb:14), so it stays
    # worker-only and the first example still pins that.
    #
    # .sync is not a worker verb: the only thing gating on it is sync_now
    # (gitops_repositories_controller.rb:65), a REST action behind an operator
    # button (GitopsTab.tsx:35) — the same modelling defect this task fixed for
    # .read. IMP-e313a4a72309 granted it (and system.gitops.write) to `admin`
    # on an explicit operator decision of 2026-09-01, so the second example is
    # inverted rather than deleted: it now pins the widening, and the audience
    # is asserted in full in
    # spec/requests/api/v1/system/gitops_repositories_admin_grant_spec.rb.
    it "leaves system.gitops.reconcile worker-only" do
      expect(::Permissions.permissions_for_role("admin")).not_to include("system.gitops.reconcile")
    end

    it "no longer holds system.gitops.sync back from admin (IMP-e313a4a72309)" do
      expect(::Permissions.permissions_for_role("admin")).to include("system.gitops.sync")
    end
  end

  # ---------------------------------------------------------------------------
  # system_gitops_get_repository
  # ---------------------------------------------------------------------------
  describe "system_gitops_get_repository" do
    it "refuses a principal holding only system.modules.read, disclosing no Vault path" do
      r = call_as(module_reader, "system_gitops_get_repository", id: repo.id)

      expect(r[:success]).to be false
      expect(r.to_s).not_to include(vault_path)
      expect(r[:error]).to include("system.gitops.read")
    end

    it "admits a principal holding system.gitops.read" do
      r = call_as(gitops_reader, "system_gitops_get_repository", id: repo.id)

      expect(r[:success]).to be true
      expect(r[:data][:repository][:vault_credential_path]).to eq(vault_path)
    end

    it "admits the real admin role" do
      expect(call_as(admin, "system_gitops_get_repository", id: repo.id)[:success]).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # system_gitops_list_repositories
  # ---------------------------------------------------------------------------
  describe "system_gitops_list_repositories" do
    it "refuses a principal holding only system.modules.read, disclosing no Vault path" do
      r = call_as(module_reader, "system_gitops_list_repositories")

      expect(r[:success]).to be false
      expect(r.to_s).not_to include(vault_path)
      expect(r[:error]).to include("system.gitops.read")
    end

    it "admits a principal holding system.gitops.read" do
      r = call_as(gitops_reader, "system_gitops_list_repositories")

      expect(r[:success]).to be true
      expect(r[:data][:repositories].map { |x| x[:vault_credential_path] }).to eq([ vault_path ])
    end

    it "admits the real admin role" do
      expect(call_as(admin, "system_gitops_list_repositories")[:success]).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # Parity with the REST twin — the divergence this task closes.
  # ---------------------------------------------------------------------------
  describe "REST parity" do
    it "gates both verbs on the permission the REST controller requires" do
      %w[system_gitops_get_repository system_gitops_list_repositories].each do |action|
        expect(described_class::ACTION_PERMISSIONS[action]).to eq("system.gitops.read")
      end
    end
  end
end
