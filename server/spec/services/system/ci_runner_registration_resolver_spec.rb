# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc3 — resolver is the single source of truth two
# consumers (node_api config_controller + CiRunnerLeaseService) must agree
# on: credential/scope/owner/repo/label/ephemeral resolution, and the
# collision-free runner_name scheme.
RSpec.describe System::CiRunnerRegistrationResolver do
  let(:account) { create(:account) }
  let(:resolver) { described_class.new(account: account) }

  describe "#credential" do
    it "returns nil when the account has no active Gitea credential" do
      expect(resolver.credential).to be_nil
    end

    it "returns the single active Gitea credential" do
      provider = create(:git_provider, :gitea, account: account)
      credential = create(:git_provider_credential, :gitea, account: account, provider: provider)

      expect(resolver.credential).to eq(credential)
    end

    it "ignores inactive Gitea credentials" do
      provider = create(:git_provider, :gitea, account: account)
      create(:git_provider_credential, :gitea, :inactive, account: account, provider: provider)

      expect(resolver.credential).to be_nil
    end

    it "ignores non-Gitea credentials" do
      github_provider = create(:git_provider, :github, account: account)
      create(:git_provider_credential, :github, account: account, provider: github_provider)

      expect(resolver.credential).to be_nil
    end

    it "returns nil (does not guess) when more than one active Gitea credential exists and no override is set" do
      provider = create(:git_provider, :gitea, account: account)
      create(:git_provider_credential, :gitea, account: account, provider: provider)
      create(:git_provider_credential, :gitea, account: account, provider: provider)

      expect(resolver.credential).to be_nil
    end

    it "prefers an explicit ci_runner_git_credential_id override over the single-active fallback" do
      provider = create(:git_provider, :gitea, account: account)
      create(:git_provider_credential, :gitea, account: account, provider: provider) # the "default" one
      explicit = create(:git_provider_credential, :gitea, account: account, provider: provider)

      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("ci_runner_git_credential_id").and_return(explicit.id)

      expect(resolver.credential).to eq(explicit)
    end

    it "returns nil when the override id does not resolve to an active credential" do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("ci_runner_git_credential_id").and_return(SecureRandom.uuid)

      expect(resolver.credential).to be_nil
    end
  end

  describe "#scope" do
    it "defaults to :org" do
      expect(resolver.scope).to eq(:org)
    end

    it "honors the ci_runner_scope SiteSetting override" do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("ci_runner_scope").and_return("repo")

      expect(resolver.scope).to eq(:repo)
    end
  end

  describe "#owner" do
    it "defaults to 'powernode'" do
      expect(resolver.owner).to eq("powernode")
    end

    it "honors the ci_runner_owner SiteSetting override" do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("ci_runner_owner").and_return("acme")

      expect(resolver.owner).to eq("acme")
    end
  end

  describe "#repo" do
    it "defaults to nil" do
      expect(resolver.repo).to be_nil
    end

    it "honors the ci_runner_repo SiteSetting override" do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("ci_runner_repo").and_return("widgets")

      expect(resolver.repo).to eq("widgets")
    end
  end

  describe "#label" do
    it "defaults to LABEL_DEFAULT" do
      expect(resolver.label).to eq(described_class::LABEL_DEFAULT)
    end

    it "honors the ci_runner_label SiteSetting override" do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("ci_runner_label").and_return("fleet-gpu")

      expect(resolver.label).to eq("fleet-gpu")
    end
  end

  describe "#ephemeral?" do
    it "defaults to false" do
      expect(resolver.ephemeral?).to eq(false)
    end

    it "is true when ci_runner_ephemeral SiteSetting is 'true'" do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("ci_runner_ephemeral").and_return("true")

      expect(resolver.ephemeral?).to eq(true)
    end
  end

  describe ".runner_name" do
    # P0-1 collision fix — the platform's uuidv7() overlays the top 32 bits of
    # the 48-bit ms clock into the first 8 hex chars, so two ids minted in the
    # same ~65.5s window share that prefix. The scheme must use the random
    # tail (last 12 hex chars), not id.first(8).
    it "produces DIFFERENT names for two ids that share the first-8-hex-char (ms-clock) window but differ in tail" do
      id_a = "0199f5aa-1234-7abc-8def-aaaaaaaaaaaa"
      id_b = "0199f5aa-1234-7abc-8def-bbbbbbbbbbbb"
      # Sanity: these two ids really do collide under the OLD id.first(8) scheme.
      expect(id_a.delete("-").first(8)).to eq(id_b.delete("-").first(8))

      instance_a = instance_double("System::NodeInstance", id: id_a)
      instance_b = instance_double("System::NodeInstance", id: id_b)

      expect(described_class.runner_name(instance_a)).not_to eq(described_class.runner_name(instance_b))
    end

    it "is deterministic for a given id (stable id -> stable name)" do
      instance = instance_double("System::NodeInstance", id: "0199f5aa-1234-7abc-8def-aaaaaaaaaaaa")

      expect(described_class.runner_name(instance)).to eq(described_class.runner_name(instance))
    end

    it "uses the fleet-<last-12-hex-chars-of-id> format" do
      instance = instance_double("System::NodeInstance", id: "0199f5aa-1234-7abc-8def-aaaaaaaaaaaa")

      expect(described_class.runner_name(instance)).to eq("fleet-aaaaaaaaaaaa")
    end
  end
end
