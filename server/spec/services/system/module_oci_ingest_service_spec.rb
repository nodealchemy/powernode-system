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

  # Campaign 019f5885 inc8 — platform-side module signing via Vault-transit.
  # OrasOciAdapter#verify_signature now tries an ORDERED list of trusted
  # public keys (Vault key first, legacy static Gitea key second) instead
  # of a single static key, so both legacy-Gitea-signed and new
  # Vault-signed artifacts verify during the migration window. All
  # cosign/registry interaction here is mocked — no live cosign, no live
  # Vault, no real keys (the PEMs below are inert placeholder text, not
  # cryptographic material).
  describe "OrasOciAdapter#verify_signature (multi-key trust window, campaign 019f5885 inc8)" do
    let(:adapter) { described_class::OrasOciAdapter.new }
    let(:oci_ref) { "registry.example.com/acct/ingest-mod:v1.0.0" }
    let(:vault_pem)  { "-----BEGIN PUBLIC KEY-----\nVAULTKEYDATA\n-----END PUBLIC KEY-----\n" }
    let(:legacy_pem) { "-----BEGIN PUBLIC KEY-----\nLEGACYKEYDATA\n-----END PUBLIC KEY-----\n" }
    let(:trusted_keys_setting) { described_class::OrasOciAdapter::TRUSTED_KEYS_SETTING }

    def status_double(ok, code: 0)
      instance_double(Process::Status, success?: ok, exitstatus: code)
    end

    before do
      allow(Open3).to receive(:capture3).with("which", "cosign").and_return([ "", "", status_double(true) ])
    end

    after { ::SiteSetting.where(key: trusted_keys_setting).delete_all }

    # Fakes `cosign verify --output json --key <tempfile-path> <ref>` as
    # succeeding only when the tempfile's content is one of `matching_pems`
    # (mirrors how a real cosign binary would only verify against the
    # correct public key). Fakes the keyless invocation (no --key flag) per
    # `keyless_ok`. Optionally records the attempted PEM content (in call
    # order) into `attempts` so tests can assert the Vault-key-first /
    # legacy-key-second ordering, not just the end result.
    def stub_cosign_verify(matching_pems:, keyless_ok: false, attempts: nil)
      allow(Open3).to receive(:capture3) do |*args|
        next [ "", "", status_double(true) ] if args == [ "which", "cosign" ]

        if args.include?("--key")
          key_path = args[args.index("--key") + 1]
          content = File.read(key_path)
          attempts << content if attempts
          if matching_pems.include?(content)
            [ '{"critical":{}}', "", status_double(true) ]
          else
            [ "", "Error: no matching signatures", status_double(false, code: 1) ]
          end
        else
          keyless_ok ? [ '{"critical":{}}', "", status_double(true) ] : [ "", "Error: no keyless match", status_double(false, code: 1) ]
        end
      end
    end

    it "verifies a Vault-key-signed artifact via the SiteSetting-configured trusted key list" do
      ::SiteSetting.set(trusted_keys_setting, [ vault_pem ].to_json, setting_type: "json")
      stub_cosign_verify(matching_pems: [ vault_pem ])

      result = adapter.verify_signature(oci_ref)
      expect(result[:ok]).to be true
    end

    it "verifies a legacy-Gitea-key-signed artifact via the POWERNODE_COSIGN_PUBLIC_KEY env fallback" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(legacy_pem)
      stub_cosign_verify(matching_pems: [ legacy_pem ])

      result = adapter.verify_signature(oci_ref)
      expect(result[:ok]).to be true
    end

    it "tries the Vault key FIRST, the legacy key SECOND, and succeeds on the legacy match" do
      ::SiteSetting.set(trusted_keys_setting, [ vault_pem ].to_json, setting_type: "json")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(legacy_pem)
      attempts = []
      stub_cosign_verify(matching_pems: [ legacy_pem ], attempts: attempts)

      result = adapter.verify_signature(oci_ref)
      expect(result[:ok]).to be true
      expect(attempts).to eq([ vault_pem, legacy_pem ])
    end

    it "fails when neither trusted key matches (unsigned or badly-signed artifact)" do
      ::SiteSetting.set(trusted_keys_setting, [ vault_pem ].to_json, setting_type: "json")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(legacy_pem)
      stub_cosign_verify(matching_pems: [])

      result = adapter.verify_signature(oci_ref)
      expect(result[:ok]).to be_nil
      expect(result[:error]).to match(/no trusted key verified/)
    end

    it "falls back to the keyless path (unchanged) when no trusted keys are configured at all" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)
      stub_cosign_verify(matching_pems: [], keyless_ok: true)

      result = adapter.verify_signature(
        oci_ref,
        expected_signers: [ "https://github.com/acme/repo/.*" ],
        issuer_regexp: "https://token.actions.githubusercontent.com"
      )
      expect(result[:ok]).to be true
    end

    # Fable #9 (task #48): R6's `cosign verify` must PULL the manifest + .sig from
    # the PRIVATE registry (401s anonymous), so the verify subprocess MUST carry
    # the registry auth env (DOCKER_CONFIG) threaded down from the ingest service.
    # The R6 unit tests stub verify_signature wholesale, which is why the missing
    # auth stayed green — this asserts the env actually reaches the cosign
    # subprocess at the verify_with_key level.
    it "threads registry_env (DOCKER_CONFIG) onto the cosign verify subprocess" do
      ::SiteSetting.set(trusted_keys_setting, [ vault_pem ].to_json, setting_type: "json")
      captured_env = nil
      allow(Open3).to receive(:capture3) do |*args|
        next [ "", "", status_double(true) ] if args == [ "which", "cosign" ]

        captured_env = args.first
        [ '{"critical":{}}', "", status_double(true) ]
      end

      result = adapter.verify_signature(oci_ref, registry_env: { "DOCKER_CONFIG" => "/tmp/verify-auth-xyz" })
      expect(result[:ok]).to be true
      expect(captured_env).to eq("DOCKER_CONFIG" => "/tmp/verify-auth-xyz")
    end
  end

  # Campaign hub-durable-modules — native single-arch build path. The
  # module-forge builder pushes a PLAIN image manifest (erofs layer +
  # module.meta/module.packages sidecars), and reports the MANIFEST descriptor
  # digest + fs-verity root. The recorded artifact digest MUST be the erofs
  # BLOB (layer) digest the agent verifies on pull — never the manifest digest
  # and never the LocalOciAdapter dev stub's fabricated value.
  describe ".ingest_native!" do
    # Real base-os:e4806f2 shape (verified live against git.powernode.org).
    let(:erofs_digest)    { "sha256:59ddd433e3712fe2edb10c717773140b2417b7ec35369b86be9a0491bf80ffa7" }
    let(:manifest_digest) { "sha256:6c7ae5bdd2a3eca8db8d9e8408fabf9a59911f8e9b79e256a0d00d1ee5107cd8" }
    let(:meta_digest)     { "sha256:295c76ff1f99519015f0781ba576a440de800b515748a8ca5cf07d0293df0e67" }
    let(:agent_fsverity)  { "sha256:70615610329859e27ff3fd7bf26e4d9573e9d012e289fc262d2e3b549201f684" }
    let(:native_ref)      { "git.powernode.org/powernode/base-os-ubuntu-noble:e4806f2" }

    # Three-layer plain image manifest: erofs FS + two powernode.module.*
    # descriptor sidecars. The erofs layer is NOT first-by-media-prefix, so
    # this catches a selector that keys off application/vnd.powernode.module.*.
    let(:manifest_doc) do
      {
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "layers" => [
          { "mediaType" => "application/vnd.powernode.erofs",          "digest" => erofs_digest, "size" => 140_546_048 },
          { "mediaType" => "application/vnd.powernode.module.meta",     "digest" => meta_digest,  "size" => 101 },
          { "mediaType" => "application/vnd.powernode.module.packages", "digest" => "sha256:185f2839076f833272d77c401c52173c915ed5e9590759b3e139b3c843029b92", "size" => 5181 }
        ]
      }
    end

    before do
      # Stub the registry manifest GET; exercise the REAL layer selection +
      # persistence. Auth resolution is bypassed (no network).
      allow_any_instance_of(described_class)
        .to receive(:fetch_native_manifest).and_return(doc: manifest_doc)
    end

    it "records the erofs LAYER (blob) digest — not the manifest digest, not the stub" do
      result = described_class.ingest_native!(
        node_module_version: version, oci_ref: native_ref,
        account: account, fsverity_root: agent_fsverity, architecture: nil
      )

      expect(result.ok?).to be true
      expect(result.module_artifacts.size).to eq(1)
      artifact = result.module_artifacts.first

      expect(artifact.architecture).to eq("amd64")
      expect(artifact.oci_digest).to eq(erofs_digest)         # the blob the agent hashes
      expect(artifact.oci_digest).not_to eq(manifest_digest)  # NOT the reported manifest digest
      expect(artifact.oci_digest).not_to eq(meta_digest)      # NOT the module.meta sidecar
      expect(artifact.size_bytes).to eq(140_546_048)
      expect(artifact.media_type).to eq("application/vnd.powernode.erofs")
      expect(artifact.fsverity_root_hash).to eq(agent_fsverity)
      expect(artifact.cosign_bundle).to be_nil                # native pushes are unsigned

      # NOT the LocalOciAdapter stub shape (…"0000" digest / "fsv-…" fsverity).
      expect(artifact.oci_digest).not_to end_with("0000")
      expect(artifact.fsverity_root_hash).not_to start_with("fsv-")
    end

    it "denormalizes the erofs blob digest onto the NodeModuleVersion column" do
      described_class.ingest_native!(
        node_module_version: version, oci_ref: native_ref,
        account: account, fsverity_root: agent_fsverity
      )
      version.reload
      expect(version.oci_digest).to eq(erofs_digest)
      expect(version.fsverity_root_hash).to eq(agent_fsverity)
    end

    it "is idempotent — a re-run updates the single arch row instead of duplicating" do
      2.times do
        described_class.ingest_native!(
          node_module_version: version, oci_ref: native_ref,
          account: account, fsverity_root: agent_fsverity
        )
      end
      expect(System::ModuleArtifact.where(node_module_version: version).count).to eq(1)
    end

    it "fails closed when the erofs layer can't be resolved (no fabricated digest)" do
      allow_any_instance_of(described_class)
        .to receive(:fetch_native_manifest).and_return(error: "manifest fetch HTTP 404")

      result = described_class.ingest_native!(
        node_module_version: version, oci_ref: native_ref,
        account: account, fsverity_root: agent_fsverity
      )
      expect(result.ok?).to be false
      expect(result.error).to match(/erofs layer resolution failed/)
      expect(System::ModuleArtifact.where(node_module_version: version).count).to eq(0)
    end

    context "R6 signature re-verification (task #48)" do
      # These unit tests exercise the R6 GATE, not the registry auth: with the
      # registry unconfigured, with_registry_docker_config yields {} (no oras
      # login), so verify_signature is called with registry_env: {}. The auth
      # threading itself is locked by OrasOciAdapter's registry_env spec above.
      before { allow(::System::DiskImageRegistryConfig).to receive(:configured?).and_return(false) }

      # resolve_erofs_layer works via the stubbed fetch_native_manifest above;
      # only R6 touches the adapter, so a two-method double is safe.
      def adapter_double(available:, verify:)
        instance_double(described_class::OrasOciAdapter,
                        key_verification_available?: available, verify_signature: verify)
      end

      it "fails closed (no artifact, no promote) when trusted keys are set and the signature doesn't verify" do
        described_class.adapter = adapter_double(available: true, verify: { error: "no trusted key verified this artifact" })
        result = described_class.ingest_native!(
          node_module_version: version, oci_ref: native_ref, account: account, fsverity_root: agent_fsverity
        )
        expect(result.ok?).to be false
        expect(result.error).to match(/R6 signature verification failed/)
        expect(System::ModuleArtifact.where(node_module_version: version).count).to eq(0)
      end

      it "records the artifact when the just-made signature verifies" do
        described_class.adapter = adapter_double(available: true, verify: { ok: true })
        result = described_class.ingest_native!(
          node_module_version: version, oci_ref: native_ref, account: account, fsverity_root: agent_fsverity
        )
        expect(result.ok?).to be true
        expect(result.module_artifacts.size).to eq(1)
      end

      it "skips verification (legacy unsigned) when no trusted key is configured" do
        adapter = adapter_double(available: false, verify: { error: "must not be called" })
        expect(adapter).not_to receive(:verify_signature)
        described_class.adapter = adapter
        result = described_class.ingest_native!(
          node_module_version: version, oci_ref: native_ref, account: account, fsverity_root: agent_fsverity
        )
        expect(result.ok?).to be true
      end
    end
  end
end
