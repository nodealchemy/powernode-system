# frozen_string_literal: true

require "rails_helper"

# IMP-217f4496a0a2 — the MCP-side twin of the REST fix that made
# PackageRepositoriesController refuse `vault_credential_path` with a 422.
# system_create_package_repository applied an explicit attribute list and
# dropped everything else, so the same key sent through the tool returned
# success while configuring nothing. BaseTool (core) now refuses a key outside
# the action's advertised schema, and this extension tool inherits that: there
# is no extension-side BaseTool, and the one core helper IS the shared pattern.
RSpec.describe Ai::Tools::SystemPackageRepositoryTool, "unknown parameters" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account, permissions: described_class::ACTION_PERMISSIONS.values.uniq) }
  let(:tool)    { described_class.new(account: account, user: user) }
  let(:valid) do
    { action: "system_create_package_repository", name: "strict-params-repo", kind: "apt",
      base_url: "https://repo.example.test/debian",
      apt_config: { suite: "stable", components: ["main"] } }
  end

  it "creates the repository from declared keys only" do
    expect(tool.execute(params: valid)[:success]).to be true
  end

  it "refuses vault_credential_path instead of reporting success and applying nothing" do
    expect(tool.execute(params: valid.merge(vault_credential_path: "secret/repo"))).to include(success: false, error: /vault_credential_path/)
  end

  it "creates nothing when it refuses" do
    expect { tool.execute(params: valid.merge(vault_credential_path: "secret/repo")) }
      .not_to change(System::PackageRepository, :count)
  end

  it "does not echo the supplied value, only the key name" do
    result = tool.execute(params: valid.merge(vault_credential_path: "secret/very-private-path"))

    expect(result[:error]).not_to include("very-private-path")
  end
end
