# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ManifestFetchService::GiteaFetchAdapter do
  describe "#fetch_file" do
    subject(:adapter) { described_class.new }

    let(:node_module) { create(:system_node_module, gitea_repo_full_name: "powernode/dev-cell") }

    context "with an active gitea credential configured" do
      let!(:credential) { create(:git_provider_credential, :gitea, :default) }

      it "resolves the credential through Devops::GitProvider + Devops::GitProviderCredential and fetches the file" do
        fake_client = instance_double(Devops::Git::GiteaApiClient)
        allow(Devops::Git::GiteaApiClient).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:get_file_content)
          .with("powernode", "dev-cell", "manifest.yaml", "abc123")
          .and_return(content: "schema_version: 1\nname: dev-cell\n", is_binary: false)

        result = adapter.fetch_file(owner: "powernode", repo: "dev-cell", path: "manifest.yaml", ref: "abc123")

        expect(Devops::Git::GiteaApiClient).to have_received(:new).with(credential)
        expect(result).to eq("schema_version: 1\nname: dev-cell\n")
      end
    end

    context "when no gitea provider is configured" do
      it "returns nil rather than raising" do
        result = adapter.fetch_file(owner: "powernode", repo: "dev-cell", path: "manifest.yaml", ref: "abc123")
        expect(result).to be_nil
      end
    end

    context "when a gitea provider exists but has no active credential" do
      before { create(:git_provider, :gitea) }

      it "returns nil rather than raising" do
        result = adapter.fetch_file(owner: "powernode", repo: "dev-cell", path: "manifest.yaml", ref: "abc123")
        expect(result).to be_nil
      end
    end
  end

  describe "#fetch (via ManifestFetchService.fetch)" do
    let(:node_module) { create(:system_node_module, gitea_repo_full_name: "powernode/dev-cell") }

    around do |example|
      original = System::ManifestFetchService.adapter
      System::ManifestFetchService.adapter = System::ManifestFetchService::GiteaFetchAdapter.new
      example.run
      System::ManifestFetchService.adapter = original
    end

    it "never raises NameError even when Devops::GitProvider resolution fails outright" do
      allow(Devops::GitProvider).to receive(:find_by).and_raise(StandardError, "boom")

      expect do
        result = System::ManifestFetchService.fetch(node_module: node_module, ref: "abc123")
        expect(result).to be_nil
      end.not_to raise_error
    end
  end

  # PLATFORM modules carry no gitea_repo_full_name — their manifest lives in the
  # shared module source repo under modules/<name>/. Returning nil for them made
  # ModulePublicationProcessor's "refresh manifest FIRST" step a silent no-op for
  # every platform module, so their ModuleService/user/group rows froze at
  # whatever the first import saw. Observed live: reverse-proxy-traefik had ZERO
  # ModuleService rows, so a build that ADDED a service could not be described to
  # any node.
  describe "#fetch for platform modules (no gitea_repo_full_name)" do
    let(:node_module) { create(:system_node_module, name: "reverse-proxy-traefik", gitea_repo_full_name: nil) }
    let(:adapter) { System::ManifestFetchService::LocalFetchAdapter.new }

    around do |example|
      original = System::ManifestFetchService.adapter
      System::ManifestFetchService.adapter = adapter
      example.run
      System::ManifestFetchService.adapter = original
    end

    it "reads modules/<name>/manifest.yaml from the platform module source repo" do
      adapter.stub_yaml = "schema_version: 1\nname: reverse-proxy-traefik\n"

      result = System::ManifestFetchService.fetch(node_module: node_module, ref: "e952ad9")

      expect(result).to include("reverse-proxy-traefik")
      expect(adapter.last_request).to include(
        owner: "powernode",
        repo:  "powernode-system",
        path:  "modules/reverse-proxy-traefik/manifest.yaml",
        ref:   "e952ad9"
      )
    end

    # The ref is the build tag, so the manifest imported is by construction the
    # one module-forge-build.sh built the blob from — not a later revision.
    it "reads at the REF it was given, not a floating branch" do
      adapter.stub_yaml = "schema_version: 1\n"
      System::ManifestFetchService.fetch(node_module: node_module, ref: "deadbee")
      expect(adapter.last_request[:ref]).to eq("deadbee")
    end

    it "honours the operator-configured source repo" do
      allow(SiteSetting).to receive(:get).and_call_original
      allow(SiteSetting).to receive(:get).with("ci_build_source_repo").and_return("acme/forks")
      adapter.stub_yaml = "schema_version: 1\n"

      System::ManifestFetchService.fetch(node_module: node_module, ref: "abc1234")

      expect(adapter.last_request).to include(owner: "acme", repo: "forks")
    end

    it "leaves an explicit non-default path verbatim" do
      adapter.stub_yaml = "x: 1\n"
      System::ManifestFetchService.fetch(node_module: node_module, ref: "abc1234", path: "other/file.yaml")
      expect(adapter.last_request[:path]).to eq("other/file.yaml")
    end

    it "still prefers gitea_repo_full_name when the module declares one" do
      per_repo = create(:system_node_module, name: "dev-cell", gitea_repo_full_name: "powernode/dev-cell")
      adapter.stub_yaml = "schema_version: 1\n"

      System::ManifestFetchService.fetch(node_module: per_repo, ref: "abc1234")

      expect(adapter.last_request).to include(
        owner: "powernode", repo: "dev-cell", path: "manifest.yaml"
      )
    end
  end
end
