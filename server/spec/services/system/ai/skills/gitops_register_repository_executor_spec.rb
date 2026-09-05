# frozen_string_literal: true

require "rails_helper"

# HIER-P2F — the GitOps Reconciler's register skill: creates the
# System::GitopsRepository row with the SAME attribute shape the
# system_gitops_register_repository MCP verb inserts, gated on the agent's own
# `system.gitops_register_repository` row (declared require_approval — a new
# declarative source of truth for the fleet).
RSpec.describe System::Ai::Skills::GitopsRegisterRepositoryExecutor do
  let(:account) { create(:account) }
  let(:exec)    { described_class.new(account: account) }

  describe ".descriptor" do
    it "gates on the GitOps Reconciler's declared register category and binds to that agent" do
      d = described_class.descriptor
      expect(d[:name]).to eq("gitops_register_repository")
      expect(d[:requires_approval]).to be true
      expect(d[:inputs].keys).to contain_exactly(:name, :repo_url, :branch, :vault_credential_path,
                                                 :path_prefix, :auto_apply)
      expect(d[:inputs][:name][:required]).to be true
      expect(d[:inputs][:repo_url][:required]).to be true

      expect(described_class.action_category).to eq("system.gitops_register_repository")
      expect(described_class.action_category).to eq(Ai::Tools::SystemFleetTool::GITOPS_REGISTER_REPOSITORY_CATEGORY)
      expect(System::Governance::PolicyDeclarations::GITOPS_RECONCILER_POLICIES)
        .to have_key(described_class.action_category)

      reg = System::Ai::Skills::SkillBindings.all.find { |r| r[:executor] == described_class }
      expect(reg[:agents]).to eq([ "gitops-reconciler" ])
    end
  end

  describe "#execute (policy auto-executes)" do
    before { auto_execute_skill_policy!(account, described_class) }

    it "registers the repository in the account with the reconciler's defaults" do
      r = exec.execute(name: "fleet-config", repo_url: "https://git.example.test/fleet.git")

      expect(r[:success]).to be true
      repo = ::System::GitopsRepository.find_by(account_id: account.id, name: "fleet-config")
      expect(repo).to be_present
      expect(r.dig(:data, :repository_id)).to eq(repo.id)
      expect(repo.branch).to eq("main")
      expect(repo.path_prefix).to eq("")
      expect(repo.auto_apply).to be false
      expect(repo.last_status).to eq("pending")
    end

    it "honours an explicit branch, prefix, credential path and auto_apply" do
      r = exec.execute(name: "fleet-config", repo_url: "https://git.example.test/fleet.git",
                       branch: "release", path_prefix: "clusters/eu", vault_credential_path: "secret/gitops/eu",
                       auto_apply: true)

      expect(r[:success]).to be true
      repo = ::System::GitopsRepository.find(r.dig(:data, :repository_id))
      expect(repo.branch).to eq("release")
      expect(repo.path_prefix).to eq("clusters/eu")
      expect(repo.vault_credential_path).to eq("secret/gitops/eu")
      expect(repo.auto_apply).to be true
      expect(r.dig(:data, :auto_apply)).to be true
    end

    it "surfaces a validation failure (duplicate name) without inserting" do
      create(:system_gitops_repository, account: account, name: "fleet-config")

      expect {
        r = exec.execute(name: "fleet-config", repo_url: "https://git.example.test/fleet.git")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/Name has already been taken/)
      }.not_to change { ::System::GitopsRepository.where(account_id: account.id).count }
    end
  end

  describe "the approval gate" do
    it "parks the registration (no row) when no policy auto-executes it" do
      r = exec.execute(name: "fleet-config", repo_url: "https://git.example.test/fleet.git")

      expect(r[:pending]).to be true
      expect(::System::GitopsRepository.where(account_id: account.id)).to be_empty
    end
  end

  # HIER-P2F review — admission runs BEFORE the approval gate. The MCP door
  # pre-validates the candidate for exactly this reason
  # (SystemFleetTool#gitops_register_repository_gate_context); the skill door
  # now does the same, so a duplicate name is refused instead of parking an
  # approval that could only fail on replay. No auto-execute policy here.
  describe "admission before the approval gate" do
    it "refuses a duplicate name without parking an approval" do
      create(:system_gitops_repository, account: account, name: "fleet-config")

      expect {
        r = exec.execute(name: "fleet-config", repo_url: "https://git.example.test/fleet.git")
        expect(r[:success]).to be false
        expect(r[:pending]).to be_falsey
        expect(r[:error]).to match(/Name has already been taken/)
      }.not_to change { ::System::GitopsRepository.where(account_id: account.id).count }

      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end
  end

end
