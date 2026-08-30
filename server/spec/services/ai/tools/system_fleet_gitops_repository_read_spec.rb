# frozen_string_literal: true

require "rails_helper"

# IMP-f07be27ba0b0 — serialize_gitops_repository had exactly ONE call site,
# `system_gitops_register_repository` (a create). The system_gitops_* family was
# register / sync / get_sync_run / get_drift_report / apply_proposal, none of
# which returns a repository. So over MCP an operator could see a GitOps
# repository's configuration only for one it had just created and whose values
# it had supplied itself; there was no way to read an existing one back and no
# way to discover the ids at all.
#
# That made the credential contract added by IMP-0f914db2c7cf
# (vault_credential_path + required_credential_keys, extensions/system 489801d4)
# REST-only in practice: the projection carried both fields, but nothing
# reachable returned the projection for a repository the caller did not create.
#
# WHAT IS ASSERTED HERE, and why in this shape:
#
#   * REACHABILITY, not projection. The credential-surface spec
#     (spec/requests/api/v1/system/gitops_repositories_credential_surface_spec.rb)
#     already pins the projection's CONTENT, but it reaches it via
#     `tool.send(:serialize_gitops_repository, repo)` — a private-method send
#     asserts the shape and says nothing about whether any caller can get it.
#     Every example below goes through `tool.execute(params:)` with an action
#     name, which is the path an MCP caller actually has.
#
#   * EQUALITY against the serializer, not "includes the two fields". The
#     acceptance criterion is that the read verb returns the SAME contract the
#     serializer defines — a second shape assembled inline is how the REST and
#     MCP halves drifted in the first place. Comparing the whole hash to
#     serialize_gitops_repository's output is what makes a hand-rolled
#     divergent projection fail; an `include(:vault_credential_path)` check
#     would pass a copy that dropped everything else.
#
#   * A CLOSED key set on the projection. `not_to include(:password)` only
#     rules out the key you thought of. Asserting the exact key set fails on
#     ANY new key, which is the assertion that survives someone later adding a
#     convenience field carrying credential material.
#
# NOT asserted, deliberately: no Vault credential-path PROBE is exposed over
# MCP by this change. That was the operator's explicit default when this task
# was approved — an agent principal naming arbitrary KV paths is a materially
# different exposure from an operator doing it in the admin UI — and the probe
# stays on the REST surface (POST /api/v1/admin_settings/vault/test). The
# "no probe verb" example below pins that decision so a later widening is a
# deliberate edit rather than a drift.
RSpec.describe Ai::Tools::SystemFleetTool, "GitOps repository read verbs (IMP-f07be27ba0b0)" do
  let(:account) { create(:account) }
  let(:tool)    { described_class.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  # Created directly, NOT through system_gitops_register_repository: the whole
  # finding is that the projection was reachable only for a repository the
  # caller had just minted. A fixture built by the create verb would reproduce
  # the very reachability the verb already had.
  let!(:repo) do
    ::System::GitopsRepository.create!(
      account: account, name: "fleet-config",
      repo_url: "https://git.example.test/fleet.git", branch: "main",
      path_prefix: "clusters/prod", enabled: true, auto_apply: false,
      vault_credential_path: "secret/data/powernode/gitops/deploy"
    )
  end

  describe "system_gitops_get_repository" do
    it "returns the serializer's projection for a repository this caller did not create" do
      r = call("system_gitops_get_repository", id: repo.id)

      expect(r[:success]).to be true
      expect(r[:data][:repository]).to eq(tool.send(:serialize_gitops_repository, repo))
    end

    # The point of the whole thread: an operator whose sync fails on credentials
    # can now see WHICH path it is configured with and WHICH key names that path
    # must carry, without having created the repository.
    it "carries the credential contract added by IMP-0f914db2c7cf" do
      r = call("system_gitops_get_repository", id: repo.id)

      expect(r[:data][:repository][:vault_credential_path])
        .to eq("secret/data/powernode/gitops/deploy")
      expect(r[:data][:repository][:required_credential_keys]).to eq(%w[password username])
    end

    # A closed key set, not a denylist — see the header note.
    it "returns key NAMES and configuration only, never credential material" do
      r = call("system_gitops_get_repository", id: repo.id)

      expect(r[:data][:repository].keys).to match_array(
        %i[id name repo_url branch path_prefix vault_credential_path
           required_credential_keys auto_apply enabled last_status
           last_synced_at last_synced_revision last_diff_count last_error
           created_at]
      )
    end

    # TRIPWIRE, not an oracle. Before the verb existed this passed for the
    # wrong reason — an unknown action already returns success:false. It is
    # kept because it becomes a real account-scoping oracle the moment the
    # action is dispatched, and it is the example that would catch a handler
    # written against `GitopsRepository.find` instead of the account scope.
    # The `not_to include` on the error text is what distinguishes the two
    # states: an unknown action says so by name.
    it "is account-scoped (TRIPWIRE until the action dispatches)" do
      other = ::System::GitopsRepository.create!(
        account: create(:account), name: "someone-elses",
        repo_url: "https://git.example.test/other.git", branch: "main"
      )

      r = call("system_gitops_get_repository", id: other.id)

      expect(r[:success]).to be false
      expect(r[:error].to_s).not_to include("Unknown action")
    end
  end

  describe "system_gitops_list_repositories" do
    # A second in-account repository that is DISABLED, and a third that sorts
    # before `repo` by name. With a single enabled fixture the list examples
    # stayed green under three cheap regressions — adding `.enabled` to the
    # scope, `limit(1)`, and dropping `.order(:name)` — so cardinality,
    # filtering and ordering were all unpinned. The disabled one is not a
    # contrived case: an operator debugging a failing sync is the caller most
    # likely to have disabled the repository they need to inspect, which is
    # exactly who this verb was added for.
    let!(:disabled_repo) do
      ::System::GitopsRepository.create!(
        account: account, name: "zz-retired-config",
        repo_url: "https://git.example.test/retired.git", branch: "main",
        enabled: false
      )
    end

    let!(:first_by_name) do
      ::System::GitopsRepository.create!(
        account: account, name: "aa-edge-config",
        repo_url: "git@git.example.test:powernode/edge.git", branch: "main",
        vault_credential_path: "secret/data/powernode/gitops/edge"
      )
    end

    # Without a list there is no way to LEARN an id, so `get` alone would be
    # reachable only for a repository whose id arrived out of band — which is
    # the same unreachability one step removed.
    it "lists every repository, name-ordered, using the same projection" do
      r = call("system_gitops_list_repositories")

      expect(r[:success]).to be true
      expect(r[:data][:repositories]).to eq(
        [ first_by_name, repo, disabled_repo ].map { |x| tool.send(:serialize_gitops_repository, x) }
      )
    end

    it "includes a DISABLED repository — the sync it fails is why you are reading it" do
      ids = call("system_gitops_list_repositories")[:data][:repositories].map { |x| x[:id] }

      expect(ids).to include(disabled_repo.id)
    end

    it "excludes another account's repositories" do
      ::System::GitopsRepository.create!(
        account: create(:account), name: "someone-elses",
        repo_url: "https://git.example.test/other.git", branch: "main"
      )

      r = call("system_gitops_list_repositories")

      expect(r[:data][:repositories].map { |x| x[:id] })
        .to match_array([ repo.id, disabled_repo.id, first_by_name.id ])
    end
  end

  describe "registration and discoverability" do
    it "routes both actions to SystemFleetTool in the core registry" do
      %w[system_gitops_get_repository system_gitops_list_repositories].each do |action|
        expect(Ai::Tools::PlatformApiToolRegistry::TOOLS[action])
          .to eq("Ai::Tools::SystemFleetTool")
      end
    end

    # An action dispatched but absent from action_definitions falls back to the
    # generic union schema, so its real contract is undiscoverable to the agent
    # deciding whether to call it (the F8-05 defect, pinned in
    # system_fleet_tool_spec.rb).
    it "declares both action contracts" do
      defs = described_class.action_definitions

      expect(defs.fetch("system_gitops_get_repository")[:parameters][:id][:required]).to be true
      expect(defs).to have_key("system_gitops_list_repositories")
    end

    # IMP-b1191457a091 — this used to assert parity with
    # system_gitops_get_drift_report (system.modules.read). That was the wrong
    # anchor: the drift report does not return serialize_gitops_repository, and
    # these two verbs do, so following it put a Vault KV path in front of every
    # module-read holder. The anchor is now the REST twin, which is the surface
    # whose audience this projection was designed for. The audience oracle
    # itself lives in system_fleet_gitops_read_gate_spec.rb.
    it "gates both reads on the permission its REST twin requires" do
      %w[system_gitops_get_repository system_gitops_list_repositories].each do |action|
        expect(described_class::ACTION_PERMISSIONS[action]).to eq("system.gitops.read")
      end
    end

    # DECISION PIN. It passed before this change too — nothing was built to
    # satisfy it — so it is not evidence of work; it is here so that exposing a
    # Vault path probe over MCP later reddens a spec whose comment states the
    # decision, instead of sliding in as an unremarked widening. The REST
    # credential probe (POST /api/v1/admin_settings/vault/test) stays the only
    # surface for it.
    #
    # Asserted against the SOURCE, not against action names. A name grep
    # (/vault.*probe/) is satisfied by calling any verb something else, and the
    # constraint that actually matters is behavioural: no path in this tool may
    # reach Security::VaultClient#read_secret, which opens with
    # check_circuit_breaker! and records failures against the SHARED vault
    # breaker (threshold 3, 5-minute reset). Repeatedly probing an unreadable
    # path through it takes Vault offline platform-wide. #probe_secret is the
    # uninstrumented read that a diagnostic must use if one is ever added here.
    it "reaches no Vault read path at all (DECISION PIN — no MCP credential probe)" do
      source = File.read(
        File.expand_path("../../../../app/services/ai/tools/system_fleet_tool.rb", __dir__)
      )
      # Comments are stripped first: this file DISCUSSES read_secret and
      # probe_secret at length, and a naive scan would match its own prose.
      code_only = source.lines.reject { |l| l.strip.start_with?("#") }.join

      expect(code_only).not_to match(/VaultClient|read_secret/)
    end
  end

  # REAL ROLES, not user_with_permissions — the same argument
  # system_fleet_tool_action_permission_spec.rb makes at its head: granting the
  # permission synthetically proves the gate lets a holder through and says
  # nothing about whether any role a human can actually be assigned holds it.
  # `admin` is the operator role these reads are for.
  describe "permission gating" do
    let(:admin)  { create(:user, :admin, account: account) }
    let(:nobody) { create(:user, account: account, permissions: []) }

    it "admits the admin role" do
      gated = described_class.new(account: account, user: admin)

      expect(gated.execute(params: { action: "system_gitops_get_repository", id: repo.id })[:success]).to be true
    end

    # The permission gate runs BEFORE the dispatch case, and required_perm_for
    # falls back to REQUIRED_PERMISSION for an unrecognised name — so asserting
    # only "permission denied" would stay green with both verbs deleted, having
    # measured the fallback. Naming the permission in the message is what ties
    # this example to the ACTION_PERMISSIONS entry actually existing.
    it "denies a user holding no permissions, on THIS action's permission" do
      gated = described_class.new(account: account, user: nobody)

      r = gated.execute(params: { action: "system_gitops_list_repositories" })

      expect(r[:success]).to be false
      expect(r[:error]).to include("permission denied: system.gitops.read")
      expect(r[:error]).not_to include(described_class::REQUIRED_PERMISSION)
    end
  end
end
