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

    it "syncs a repository through PackageRepositorySyncService" do
      repo = create(:system_package_repository, account: account)
      allow(::System::PackageRepositorySyncService).to receive(:call)
        .with(repository: repo)
        .and_return(::System::PackageRepositorySyncService::Result.new(
                      success: true, package_count: 12, upserted: 12, obsoleted: 0, error: nil
                    ))

      r = call("system_sync_package_repository", repository_id: repo.id)
      expect(r[:success]).to be true
      expect(r[:data][:package_count]).to eq(12)
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
end
