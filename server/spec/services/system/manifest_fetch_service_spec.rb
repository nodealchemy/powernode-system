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
end
