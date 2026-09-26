# frozen_string_literal: true

require "rails_helper"

# The one registry-manifest read both OciLayerDigestFetcher (the publications
# controller's layer backfill) and the native build's stale re-tag guard use.
RSpec.describe System::OciManifestClient do
  let(:account) { create(:account) }
  let(:node_module) { create(:system_node_module, account: account, name: "powernode-system-base") }
  let(:oci_ref) { "registry.example.com/powernode/powernode-system-base:abc1234" }
  let(:url) { "https://registry.example.com/v2/powernode/powernode-system-base/manifests/abc1234" }
  let(:erofs_digest) { "sha256:#{'e' * 64}" }
  let(:meta_digest) { "sha256:#{'a' * 64}" }

  let(:manifest) do
    {
      "schemaVersion" => 2,
      "layers" => [
        { "mediaType" => "application/vnd.powernode.module.meta", "digest" => meta_digest, "size" => 120 },
        { "mediaType" => "application/vnd.powernode.module.erofs", "digest" => erofs_digest, "size" => 6_000_000 }
      ]
    }
  end

  def with_pat
    provider = create(:git_provider, :gitea, account: account)
    cred = create(:git_provider_credential, :gitea, account: account, provider: provider,
                                                    auth_type: "personal_access_token")
    expect(cred.access_token).to be_present # the fixture must actually carry a PAT
    cred
  end

  describe ".fetch" do
    it "returns nil without a PAT, and makes no request" do
      expect(described_class.fetch(node_module: node_module, oci_ref: oci_ref)).to be_nil
      expect(a_request(:get, url)).not_to have_been_made
    end

    context "with a PAT" do
      before { with_pat }

      it "authenticates with the PAT and asks for an OCI or Docker v2 manifest" do
        stub = stub_request(:get, url)
               .with(basic_auth: [ "ci", Devops::GitProviderCredential.last.access_token ],
                     headers: { "Accept" => /application\/vnd\.oci\.image\.manifest\.v1\+json/ })
               .to_return(status: 200, body: manifest.to_json)

        described_class.fetch(node_module: node_module, oci_ref: oci_ref)

        expect(stub).to have_been_requested
      end

      it "takes the manifest digest from Docker-Content-Digest" do
        stub_request(:get, url).to_return(status: 200, body: manifest.to_json,
                                          headers: { "Docker-Content-Digest" => "sha256:#{'d' * 64}" })

        result = described_class.fetch(node_module: node_module, oci_ref: oci_ref)

        expect(result.manifest_digest).to eq("sha256:#{'d' * 64}")
      end

      it "falls back to the sha256 of the manifest body when the header is absent" do
        body = manifest.to_json
        stub_request(:get, url).to_return(status: 200, body: body)

        result = described_class.fetch(node_module: node_module, oci_ref: oci_ref)

        expect(result.manifest_digest).to eq("sha256:#{Digest::SHA256.hexdigest(body)}")
      end

      it "picks the erofs layer, not the first one" do
        stub_request(:get, url).to_return(status: 200, body: manifest.to_json)

        result = described_class.fetch(node_module: node_module, oci_ref: oci_ref)

        expect(result.erofs_layer).to include("digest" => erofs_digest, "size" => 6_000_000)
        expect(result.layer_digest).to eq(erofs_digest)
      end

      it "falls back to the first layer when none is erofs-typed" do
        manifest["layers"] = [ { "mediaType" => "application/octet-stream", "digest" => meta_digest, "size" => 9 } ]
        stub_request(:get, url).to_return(status: 200, body: manifest.to_json)

        expect(described_class.fetch(node_module: node_module, oci_ref: oci_ref).layer_digest).to eq(meta_digest)
      end

      it "returns nil on a non-2xx" do
        stub_request(:get, url).to_return(status: 404, body: "")

        expect(described_class.fetch(node_module: node_module, oci_ref: oci_ref)).to be_nil
      end

      it "returns nil on a manifest with no layers" do
        stub_request(:get, url).to_return(status: 200, body: { "layers" => [] }.to_json)

        expect(described_class.fetch(node_module: node_module, oci_ref: oci_ref)).to be_nil
      end

      it "returns nil on an unparseable body or a network error" do
        stub_request(:get, url).to_return(status: 200, body: "not json")
        expect(described_class.fetch(node_module: node_module, oci_ref: oci_ref)).to be_nil

        stub_request(:get, url).to_timeout
        expect(described_class.fetch(node_module: node_module, oci_ref: oci_ref)).to be_nil
      end

      it "returns nil for a ref it cannot split into registry/repo:tag" do
        expect(described_class.fetch(node_module: node_module, oci_ref: "no-tag-here")).to be_nil
      end
    end
  end

  describe ".lookup" do
    it "is :unavailable without a PAT (nothing could be measured)" do
      expect(described_class.lookup(node_module: node_module, oci_ref: oci_ref).status).to eq(:unavailable)
    end

    context "with a PAT" do
      before { with_pat }

      it "is :found with the manifest on a 200" do
        stub_request(:get, url).to_return(status: 200, body: manifest.to_json)

        result = described_class.lookup(node_module: node_module, oci_ref: oci_ref)

        expect(result.status).to eq(:found)
        expect(result.manifest.layer_digest).to eq(erofs_digest)
      end

      it "is :not_found on a 404 — a definitive absence, not an outage" do
        stub_request(:get, url).to_return(status: 404, body: { errors: [ { code: "MANIFEST_UNKNOWN" } ] }.to_json)

        result = described_class.lookup(node_module: node_module, oci_ref: oci_ref)

        expect(result.status).to eq(:not_found)
        expect(result.manifest).to be_nil
      end

      it "is :unavailable on a 5xx, a 401 or a timeout" do
        stub_request(:get, url).to_return(status: 503)
        expect(described_class.lookup(node_module: node_module, oci_ref: oci_ref).status).to eq(:unavailable)

        stub_request(:get, url).to_return(status: 401)
        expect(described_class.lookup(node_module: node_module, oci_ref: oci_ref).status).to eq(:unavailable)

        stub_request(:get, url).to_timeout
        expect(described_class.lookup(node_module: node_module, oci_ref: oci_ref).status).to eq(:unavailable)
      end
    end
  end

  describe "OciLayerDigestFetcher on top of it" do
    before { with_pat }

    it "keeps its {digest, size, media_type} contract" do
      stub_request(:get, url).to_return(status: 200, body: manifest.to_json)

      expect(System::OciLayerDigestFetcher.new.fetch_oci_layer_digest(node_module, oci_ref)).to eq(
        digest: erofs_digest, size: 6_000_000, media_type: "application/vnd.powernode.module.erofs"
      )
    end

    it "keeps returning nil for a blank ref or a failed read" do
      stub_request(:get, url).to_return(status: 500)

      expect(System::OciLayerDigestFetcher.new.fetch_oci_layer_digest(node_module, "")).to be_nil
      expect(System::OciLayerDigestFetcher.new.fetch_oci_layer_digest(node_module, oci_ref)).to be_nil
    end
  end
end
