# frozen_string_literal: true

require "rails_helper"

# Audit F5-10 — SystemPackageRepositoryTool is a direct agent-facing MCP
# dispatch surface (repository CRUD + sync, package discovery/dependency
# resolution, materialize-into-modules) that had no spec. Mirrors
# system_fleet_tool_spec.rb: invoke .execute(params:) directly and assert
# the success_result/error_result contract.
RSpec.describe Ai::Tools::SystemPackageRepositoryTool do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account, permissions: described_class::ACTION_PERMISSIONS.values.uniq) }
  let(:tool)     { described_class.new(account: account, user: user) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  # F5-10 case 1 — dispatch table: every advertised action routes to a
  # handler. A name in ACTION_PERMISSIONS without a `when` branch falls
  # through to "Unknown action", which this catches (registry/handler drift).
  describe "action dispatch table" do
    described_class::ACTION_PERMISSIONS.each_key do |action|
      it "routes #{action} to a handler" do
        result = begin
          call(action)
        rescue StandardError
          # A handler that raises on empty params still PROVED it dispatched
          # — only an unrouted action returns the "Unknown action" string.
          { success: false, error: "handler raised" }
        end
        expect(result[:error].to_s).not_to include("Unknown action")
      end
    end
  end

  # F5-10 case 2 — permission mapping enforced per action.
  describe "permission mapping" do
    described_class::ACTION_PERMISSIONS.each do |action, permission|
      it "permits #{action} for a holder of #{permission}" do
        holder = create(:user, account: account, permissions: [ permission ])
        scoped = described_class.new(account: account, user: holder)
        expect(scoped.send(:action_permitted?, action)).to be true
      end
    end

    it "denies an action when the caller lacks its permission" do
      denied = create(:user, account: account, permissions: %w[system.packages.view])
      scoped = described_class.new(account: account, user: denied)
      r = scoped.execute(params: { action: "system_create_package_repository", name: "x", kind: "apt" })
      expect(r[:success]).to be false
      expect(r[:error]).to include("permission denied")
    end
  end

  # F5-10 case 3 — one mutating happy path per repository action family +
  # invalid params produce a structured error, not an exception.
  describe "repository lifecycle" do
    it "creates a repository and returns a structured payload" do
      r = call("system_create_package_repository", name: "noble-main", kind: "apt",
               base_url: "https://archive.example.com/ubuntu",
               apt_config: { "suite" => "noble", "components" => [ "main" ] })
      expect(r[:success]).to be true
      expect(r[:data][:package_repository][:name]).to eq("noble-main")
      expect(System::PackageRepository.where(account: account, name: "noble-main")).to exist
    end

    it "lists and gets account-scoped repositories" do
      repo = create(:system_package_repository, account: account, name: "listed")

      listed = call("system_list_package_repositories")
      expect(listed[:success]).to be true
      expect(listed[:data][:package_repositories].map { |x| x[:id] }).to include(repo.id)

      got = call("system_get_package_repository", repository_id: repo.id)
      expect(got[:success]).to be true
      expect(got[:data][:package_repository][:id]).to eq(repo.id)
    end

    it "updates a repository via the attributes blob" do
      repo = create(:system_package_repository, account: account, enabled: true)
      r = call("system_update_package_repository", repository_id: repo.id,
               attributes: { "enabled" => false })
      expect(r[:success]).to be true
      expect(repo.reload.enabled).to be false
    end

    it "deletes a repository" do
      repo = create(:system_package_repository, account: account)
      r = call("system_delete_package_repository", repository_id: repo.id)
      expect(r[:success]).to be true
      expect(System::PackageRepository.exists?(repo.id)).to be false
    end

    it "enqueues a background sync (async — never runs the sync inline)" do
      repo = create(:system_package_repository, account: account)
      expect(::System::PackageRepositorySyncService).not_to receive(:call)
      allow(::System::WorkerJobEnqueuer).to receive(:enqueue)

      r = call("system_sync_package_repository", repository_id: repo.id)
      expect(r[:success]).to be true
      expect(r[:data][:queued]).to be true
      expect(repo.reload.sync_status).to eq("syncing")
      expect(::System::WorkerJobEnqueuer).to have_received(:enqueue).with(
        hash_including(job_class: "SystemPackageRepositorySyncJob")
      )
    end

    it "returns a structured error (not an exception) for an unknown repository id" do
      r = call("system_get_package_repository", repository_id: SecureRandom.uuid)
      expect(r[:success]).to be false
      expect(r[:error]).to be_present
    end

    it "returns a structured validation error when create params are invalid" do
      r = call("system_create_package_repository", name: "", kind: "apt")
      expect(r[:success]).to be false
      expect(r[:error]).to be_present
    end
  end

  # IMP-54bf2643f542 — action_permitted? used to read `@user.nil?` as
  # "internal/system caller" and return true. That premise (MCP callers always
  # carry a user) predates instance principals: an mTLS node cert authenticates
  # with NO user, so every per-action permission here was skipped and the
  # peer's per-tool grant glob was the only remaining control. Sibling of the
  # SystemFleetTool fix (IMP-9030413bc292): the bypass is now two EXPLICIT
  # signals and a bare userless call fails closed.
  describe "principal authorization (IMP-54bf2643f542)" do
    let(:gated_action) { "system_create_package_repository" }

    it "denies a bare userless call — no user, no internal flag, no instance grant" do
      bare = described_class.new(account: account, user: nil)

      expect(bare.send(:action_permitted?, gated_action)).to be false
    end

    it "surfaces the denial as an error_result rather than executing the action" do
      bare = described_class.new(account: account, user: nil)

      expect { @result = bare.execute(params: { action: gated_action, name: "bare-repo", kind: "apt" }) }
        .not_to change(::System::PackageRepository, :count)
      expect(@result[:success]).to be false
      expect(@result[:error]).to include("permission denied")
    end

    it "preserves the internal/system bypass when declared explicitly" do
      internal = described_class.new(account: account, user: nil, internal: true)

      expect(internal.send(:action_permitted?, gated_action)).to be true
    end

    # Behaviour preservation for the live instance principal: the streamable
    # controller grant-gates the specific tool name via Mcp::Principal#may_invoke?
    # before dispatch, and the registrar marks the call. That marking — not the
    # nil user — is what carries it through here.
    it "still permits a grant-gated MCP instance principal" do
      instance_call = described_class.new(account: account, user: nil)
      instance_call.instance_authorized = true

      expect(instance_call.send(:action_permitted?, gated_action)).to be true
    end

    it "keeps enforcing per-action permissions for a user principal" do
      unprivileged = create(:user, account: account, permissions: %w[system.package_repositories.view])
      user_tool = described_class.new(account: account, user: unprivileged)

      expect(user_tool.send(:action_permitted?, "system_list_package_repositories")).to be true
      expect(user_tool.send(:action_permitted?, gated_action)).to be false
    end
  end

  # IMP-c33045a39443 — the category lookup used find_by, so a bogus or
  # foreign category_id resolved to nil and the call materialized into the
  # DEFAULT category with a success envelope. An agent that explicitly chose
  # a category got its choice silently ignored, which is worse than an error:
  # the modules land somewhere the caller did not ask for and nothing says so.
  describe "system_create_module_from_package category resolution" do
    let(:repo) { create(:system_package_repository, account: account) }

    it "refuses an unknown category_id instead of falling back to the default" do
      expect(::System::PackageModuleMaterializer).not_to receive(:call)

      r = call("system_create_module_from_package", repository_id: repo.id,
               package_name: "curl", category_id: SecureRandom.uuid)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/category/i)
    end

    it "refuses another account's category_id" do
      foreign = create(:system_node_module_category, account: create(:account))
      expect(::System::PackageModuleMaterializer).not_to receive(:call)

      r = call("system_create_module_from_package", repository_id: repo.id,
               package_name: "curl", category_id: foreign.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/category/i)
    end

    it "still allows the default when no category_id is supplied" do
      # Absent is not the same as wrong: omitting the parameter keeps the
      # materializer's own defaulting behavior, which its spec covers.
      expect(::System::PackageModuleMaterializer).to receive(:call)
        .with(hash_including(category: nil)).and_return(
          instance_double("Result", success?: false, errors: [ "stubbed" ])
        )

      call("system_create_module_from_package", repository_id: repo.id, package_name: "curl")
    end
  end
end
