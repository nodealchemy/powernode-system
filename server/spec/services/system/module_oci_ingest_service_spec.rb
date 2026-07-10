# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M1.A — ModuleOciIngestService (LocalOciAdapter happy path).
RSpec.describe System::ModuleOciIngestService do
  before { described_class.reset! }
  after  { described_class.reset! }

  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "ingest-mod")
  end
  let(:version) do
    System::NodeModuleVersion.create!(
      node_module: node_module, version_number: 1,
      mask: [], file_spec: [], package_spec: [], config: {}
    )
  end

  let(:oci_ref) { "registry.example.com/account/ingest-mod:v1.0.0" }

  describe ".ingest!" do
    it "creates one ModuleArtifact per architecture and denormalizes onto version" do
      result = described_class.ingest!(node_module_version: version, oci_ref: oci_ref)

      expect(result.ok?).to be true
      expect(result.module_artifacts.size).to eq(2)
      arches = result.module_artifacts.map(&:architecture).sort
      expect(arches).to eq(%w[amd64 arm64])

      version.reload
      expect(version.oci_digest).to be_present
      expect(version.fsverity_root_hash).to be_present
      expect(version.sbom_uri).to eq("#{oci_ref}.sbom")
      expect(version.provenance_uri).to eq("#{oci_ref}.prov")
      expect(version.vex_uri).to eq("#{oci_ref}.vex")
    end

    it "is idempotent — running twice updates instead of duplicating" do
      described_class.ingest!(node_module_version: version, oci_ref: oci_ref)
      described_class.ingest!(node_module_version: version, oci_ref: oci_ref)
      expect(System::ModuleArtifact.where(node_module_version: version).count).to eq(2)
    end

    it "fails clearly when oci_ref is blank" do
      result = described_class.ingest!(node_module_version: version, oci_ref: "")
      expect(result.ok?).to be false
      expect(result.error).to match(/oci_ref required/)
    end

    it "fails clearly when version is missing" do
      result = described_class.ingest!(node_module_version: nil, oci_ref: oci_ref)
      expect(result.ok?).to be false
      expect(result.error).to match(/node_module_version required/)
    end

    it "fails when manifest fetch errors" do
      adapter = described_class.adapter
      adapter.stub_manifest = { error: "no such tag" }
      result = described_class.ingest!(node_module_version: version, oci_ref: oci_ref)
      expect(result.ok?).to be false
      expect(result.error).to match(/manifest fetch failed/)
    end

    it "fails when signature verification errors" do
      adapter = described_class.adapter
      adapter.stub_verification = { error: "signature does not match expected identity" }
      result = described_class.ingest!(node_module_version: version, oci_ref: oci_ref)
      expect(result.ok?).to be false
      expect(result.error).to match(/cosign verify failed/)
    end

    it "rolls back on artifact validation failure (mid-loop error)" do
      adapter = described_class.adapter
      adapter.stub_manifest = {
        per_arch_descriptors: [
          { architecture: "amd64", oci_digest: "sha256:#{'a' * 64}", size_bytes: 1, built_at: Time.current },
          { architecture: "powerpc", oci_digest: "sha256:#{'b' * 64}", size_bytes: 1, built_at: Time.current }
        ]
      }
      result = described_class.ingest!(node_module_version: version, oci_ref: oci_ref)
      expect(result.ok?).to be false
      expect(result.error).to match(/unsupported architecture|powerpc/)
      expect(System::ModuleArtifact.where(node_module_version: version).count).to eq(0)
    end
  end

  describe "adapter selection" do
    it "uses LocalOciAdapter in test by default" do
      expect(described_class.adapter).to be_a(described_class::LocalOciAdapter)
    end

    it "honors POWERNODE_OCI_MODE=oras" do
      stub_const("ENV", ENV.to_h.merge("POWERNODE_OCI_MODE" => "oras"))
      described_class.reset!
      expect(described_class.adapter).to be_a(described_class::OrasOciAdapter)
    end
  end

  # IMP-1b9ec6821c25 — ensure_binary! used string-shell `system("which #{name} …")`;
  # the rest of this adapter shells out via array-form Open3.capture3. The PATH check
  # must use the no-shell array form (no injection surface) and still raise IngestError
  # when the binary is absent.
  describe "OrasOciAdapter#ensure_binary! (no-shell PATH check)" do
    let(:adapter) { described_class::OrasOciAdapter.new }

    def status_double(ok)
      instance_double(Process::Status, success?: ok)
    end

    it "checks the binary via array-form Open3.capture3 (not a shell string)" do
      expect(Open3).to receive(:capture3).with("which", "oras").and_return([ "", "", status_double(true) ])
      # If the implementation still used `system("which #{name} …")`, Open3.capture3
      # would never be invoked and this expectation would fail.
      expect { adapter.send(:ensure_binary!, "oras") }.not_to raise_error
    end

    it "raises IngestError when the binary is not on PATH" do
      allow(Open3).to receive(:capture3).with("which", "cosign").and_return([ "", "not found", status_double(false) ])
      expect { adapter.send(:ensure_binary!, "cosign") }
        .to raise_error(described_class::IngestError, /cosign binary not found/)
    end
  end

  # IMP-133388cddd9c — templates/module-repo/.gitea/workflows/build.yaml only ever
  # pushed per-arch-suffixed tags (`<tag>-amd64`, `<tag>-arm64`); nothing was ever
  # published under the bare `<tag>` this adapter fetches, so every real publish
  # 404'd here. Fixed by adding an `assemble` job that builds a real OCI image
  # index (`manifests[]`, one entry per arch) and pushes it under the bare tag —
  # verified end-to-end against the real `oras` CLI (v1.2.0) via an OCI image
  # layout directory (no live registry needed) before wiring it into the
  # workflow. This spec locks the Ruby side of that contract: the bare-tag
  # fetch this adapter performs must resolve to exactly the index shape the
  # fixed CI now produces.
  describe "OrasOciAdapter#fetch_manifest (IMP-133388cddd9c CI ↔ ingest contract)" do
    let(:adapter) { described_class::OrasOciAdapter.new }
    let(:oci_ref) { "registry.example.com/acct/ingest-mod:v1.0.0" }

    def status_double(ok, code: 0)
      instance_double(Process::Status, success?: ok, exitstatus: code)
    end

    before do
      # fetch_manifest checks the binary is on PATH before shelling out to it.
      allow(Open3).to receive(:capture3).with("which", "oras").and_return([ "", "", status_double(true) ])
    end

    it "fails clearly against the pre-fix CI shape (nothing ever published at the bare tag)" do
      allow(Open3).to receive(:capture3).with("oras", "manifest", "fetch", oci_ref)
        .and_return([ "", "Error: #{oci_ref}: not found", status_double(false, code: 1) ])

      result = adapter.fetch_manifest(oci_ref)
      expect(result[:error]).to be_present
    end

    it "parses the fixed CI's multi-arch OCI index into one descriptor per architecture" do
      # Exact shape `oras manifest push` emits for the index built by the new
      # `assemble` job (confirmed via a real oras v1.2.0 run against an
      # OCI image layout dir).
      index = {
        schemaVersion: 2,
        mediaType: "application/vnd.oci.image.index.v1+json",
        manifests: %w[amd64 arm64].map do |arch|
          {
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:#{Digest::SHA256.hexdigest(arch)}",
            size: 959,
            platform: { architecture: arch, os: "linux" },
            annotations: {
              "io.powernode.fsverity_root_hash" => "fsv-#{arch}-abc123",
              "io.powernode.fingerprint" => "fp-#{arch}",
              "io.powernode.module_id" => "mod-1",
              "io.powernode.built_at" => "2026-07-01T00:00:00Z"
            }
          }
        end
      }.to_json
      allow(Open3).to receive(:capture3).with("oras", "manifest", "fetch", oci_ref)
        .and_return([ index, "", status_double(true) ])

      result = adapter.fetch_manifest(oci_ref)
      expect(result[:error]).to be_nil
      arches = result[:per_arch_descriptors].map { |d| d[:architecture] }.sort
      expect(arches).to eq(%w[amd64 arm64])

      amd64 = result[:per_arch_descriptors].find { |d| d[:architecture] == "amd64" }
      expect(amd64[:fsverity_root_hash]).to eq("fsv-amd64-abc123")
      expect(amd64[:oci_digest]).to eq("sha256:#{Digest::SHA256.hexdigest('amd64')}")
    end
  end

  # IMP-8776e1daf159 — found while fixing IMP-133388cddd9c. The `oras push` step
  # generates SBOM (syft) + VEX (grype) files and pushes them as sibling layers in
  # the SAME command as the module artifact, but only ever annotates
  # fsverity_root_hash/fingerprint/module_id/built_at. #fetch_manifest above reads
  # io.powernode.sbom_uri/provenance_uri/vex_uri straight off the per-arch manifest
  # annotations, so ModuleArtifact#sbom_uri/vex_uri stay permanently nil in
  # production. This locks the real CI YAML (not a fixture) against regressing.
  describe "module-repo build.yaml oras push annotations (IMP-8776e1daf159)" do
    let(:workflow_path) do
      Pathname.new(__dir__).join("..", "..", "..", "..", "templates", "module-repo",
                                  ".gitea", "workflows", "build.yaml")
    end
    let(:push_step_script) do
      workflow = YAML.load_file(workflow_path, aliases: true)
      step = workflow["jobs"]["build"]["steps"].find { |s| s["name"] == "Push artifact to OCI registry (oras)" }
      step["run"]
    end

    it "annotates io.powernode.sbom_uri for the SBOM file pushed as a sibling layer" do
      expect(push_step_script).to match(/--annotation\s+"io\.powernode\.sbom_uri=/)
    end

    it "annotates io.powernode.vex_uri for the VEX file pushed as a sibling layer" do
      expect(push_step_script).to match(/--annotation\s+"io\.powernode\.vex_uri=/)
    end
  end
end
