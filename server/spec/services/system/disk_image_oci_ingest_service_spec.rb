# frozen_string_literal: true

require "rails_helper"

# Audit F5-11 — OCI ingest is the verify gate between CI-published
# artifacts and fleet boot images. Note the architecture: this service
# verifies and pulls ONLY — it never creates or mutates publication
# rows. Failures return an error Result and the CALLER
# (DiskImagePublicationProcessor, separately specced) marks the
# publication failed; there is no partial row to roll back here.
RSpec.describe System::DiskImageOciIngestService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }

  after { described_class.reset! }

  describe ".verify_and_pull! argument gates" do
    it "fails without a publication" do
      result = described_class.verify_and_pull!(publication: nil)

      expect(result.ok?).to be false
      expect(result.error).to match(/publication required/)
    end

    it "fails when the publication has no oci_ref" do
      pub = create(:system_disk_image_publication, account: account,
                   node_platform: platform, oci_ref: nil)

      result = described_class.verify_and_pull!(publication: pub)

      expect(result.ok?).to be false
      expect(result.error).to match(/oci_ref required/)
    end

    it "refuses the production adapter when the platform has no cosign trust policy" do
      described_class.adapter = described_class::OrasDiskImageAdapter.new
      pub = create(:system_disk_image_publication, account: account, node_platform: platform)

      result = described_class.verify_and_pull!(publication: pub)

      expect(result.ok?).to be false
      expect(result.error).to match(/no cosign trust policy configured/)
    end
  end

  describe "digest verification (local adapter, real files)" do
    let(:image_bytes) { "powernode-disk-image-#{SecureRandom.hex(8)}" }
    let(:image_file) do
      f = Tempfile.new([ "disk-image-", ".img" ])
      f.binmode
      f.write(image_bytes)
      f.close
      f
    end

    after { image_file.unlink }

    def publication_for(sha256)
      create(:system_disk_image_publication, account: account, node_platform: platform,
             oci_ref: "local://#{image_file.path}", sha256: sha256,
             size_bytes: image_bytes.bytesize)
    end

    it "rejects a sha256 digest mismatch" do
      pub = publication_for("f" * 64)

      result = described_class.verify_and_pull!(publication: pub)

      expect(result.ok?).to be false
      expect(result.error).to match(/sha256 mismatch/)
      # No row mutation from this layer — the publication stays queued for
      # the processor to mark failed.
      expect(pub.reload.status).to eq("queued")
    end

    it "accepts a matching digest and returns the local path" do
      pub = publication_for(Digest::SHA256.hexdigest(image_bytes))

      result = described_class.verify_and_pull!(publication: pub)

      expect(result.ok?).to be true
      expect(result.error).to be_nil
      expect(File.read(result.local_path)).to eq(image_bytes)
    end
  end

  # Layer 4 of the disk-image publish pipeline: run 990 pushed the OCI
  # artifact successfully but the platform-side `verify_and_pull!` 401ed
  # ("failed to resolve manifest") because `oras pull` never authenticated
  # to the private Gitea registry — only the CI push side had an `oras
  # login` step. This covers the smoke-mode fallback path (LocalDiskImageAdapter,
  # the default adapter outside production — matches the failing publications'
  # "oras pull failed (smoke-mode)" error), stubbing Open3 so no real oras
  # binary or registry is touched.
  describe "registry authentication before oras pull (smoke-mode fallback)" do
    let(:image_bytes) { "fake-disk-image-bytes-#{SecureRandom.hex(4)}" }
    let(:pub) do
      create(:system_disk_image_publication, account: account, node_platform: platform,
             oci_ref: "git.powernode.org/powernode/disk-images/ubuntu-24.04-amd64-uefi:0279b76",
             sha256: Digest::SHA256.hexdigest(image_bytes))
    end

    # Stubs Open3.capture3 to fake `oras login` / `oras pull`, routing on
    # the command name (ignoring a leading env hash, which the adapter
    # passes positionally). `oras pull` writes image_bytes into the
    # requested --output dir so the caller's sha256 check passes.
    def stub_oras(login_calls:, pull_calls:)
      allow(Open3).to receive(:capture3) do |*args, **kwargs|
        cmd = args.reject { |a| a.is_a?(Hash) }
        case cmd[0..1]
        when %w[oras login]
          login_calls << { cmd: cmd, stdin_data: kwargs[:stdin_data] }
          [ "", "", instance_double(Process::Status, success?: true) ]
        when %w[oras pull]
          pull_calls << { cmd: cmd }
          output_dir = cmd[cmd.index("--output") + 1]
          FileUtils.mkdir_p(output_dir)
          File.binwrite(File.join(output_dir, "disk.img"), image_bytes)
          [ "", "", instance_double(Process::Status, success?: true) ]
        else
          raise "unexpected Open3.capture3 call: #{cmd.inspect}"
        end
      end
    end

    context "when DiskImageRegistryConfig is configured for the account" do
      before do
        allow(System::DiskImageRegistryConfig).to receive(:configured?).with(account: account).and_return(true)
        allow(System::DiskImageRegistryConfig).to receive(:registry_host).with(account: account).and_return("git.powernode.org")
        allow(System::DiskImageRegistryConfig).to receive(:registry_user).with(account: account).and_return("ci-bot")
        allow(System::DiskImageRegistryConfig).to receive(:registry_token).with(account: account).and_return("s3cr3t-token")
      end

      it "logs in via stdin (--registry-config) before pulling, and never puts the token in argv" do
        login_calls = []
        pull_calls  = []
        stub_oras(login_calls: login_calls, pull_calls: pull_calls)

        result = described_class.verify_and_pull!(publication: pub)

        expect(login_calls.size).to eq(1)
        login_cmd = login_calls.first[:cmd]
        expect(login_cmd).to include("oras", "login", "git.powernode.org", "--username", "ci-bot", "--password-stdin")
        expect(login_calls.first[:stdin_data]).to eq("s3cr3t-token")
        # The token must never appear as a literal argv element.
        expect(login_cmd).not_to include("s3cr3t-token")

        expect(pull_calls.size).to eq(1)
        pull_cmd = pull_calls.first[:cmd]
        expect(pull_cmd).to include("--registry-config")
        registry_config_path = pull_cmd[pull_cmd.index("--registry-config") + 1]
        expect(login_cmd[login_cmd.index("--registry-config") + 1]).to eq(registry_config_path)

        expect(result.ok?).to be true
        expect(result.error).to be_nil
      end
    end

    context "when DiskImageRegistryConfig is not configured for the account" do
      before do
        allow(System::DiskImageRegistryConfig).to receive(:configured?).with(account: account).and_return(false)
      end

      it "still pulls unauthenticated (public registries / fixtures keep working)" do
        login_calls = []
        pull_calls  = []
        stub_oras(login_calls: login_calls, pull_calls: pull_calls)

        result = described_class.verify_and_pull!(publication: pub)

        expect(login_calls).to be_empty
        expect(pull_calls.size).to eq(1)
        expect(pull_calls.first[:cmd]).not_to include("--registry-config")

        expect(result.ok?).to be true
        expect(result.error).to be_nil
      end
    end
  end

  # Hardening (d3b634f1 review): the key-based cosign gate must actually GATE.
  # Prove it fails CLOSED on (a) an untrusted key, (b) a subject-digest
  # mismatch, and (c) a missing attestation, and that the keyless fallback
  # stays wired. Exercises OrasDiskImageAdapter's private cosign methods with
  # Open3 stubbed (no real cosign binary, no network, no Rekor).
  describe "OrasDiskImageAdapter cosign key-verify gate (negative paths)" do
    let(:adapter)         { described_class::OrasDiskImageAdapter.new }
    let(:trusted_key_pem) { "-----BEGIN PUBLIC KEY-----\nMFkwEwYHtrusted\n-----END PUBLIC KEY-----" }
    let(:img_file)    { Tempfile.new([ "img-", ".img" ]).tap { |f| f.write("disk"); f.close } }
    let(:bundle_file) { Tempfile.new([ "sig-", ".cosign-bundle" ]).tap { |f| f.write("{}"); f.close } }
    let(:attest_file) { Tempfile.new([ "att-", ".attestation-bundle" ]).tap { |f| f.write("{}"); f.close } }

    after { [ img_file, bundle_file, attest_file ].each { |f| f.close! rescue nil } }

    def status(ok)
      instance_double(Process::Status, success?: ok)
    end

    it "fails closed when no trusted key validates the signature (untrusted/wrong key)" do
      allow(Open3).to receive(:capture3).and_return([ "", "error: no matching signatures", status(false) ])

      result = adapter.send(:verify_signed_blob_with_keys, "verify-blob", bundle_file.path,
                            [ trusted_key_pem ], [ img_file.path ])

      expect(result[:ok]).to be false
      expect(result[:error]).to match(/no trusted public key verified/)
    end

    it "fails closed on a subject-digest mismatch, pinning --check-claims=true + --digest on the key-verify" do
      real_sha     = "a" * 64
      tampered_sha = "b" * 64
      captured = []
      allow(Open3).to receive(:capture3) do |*args|
        cmd = args.reject { |a| a.is_a?(Hash) }
        captured << cmd
        passed = cmd.include?("--digest") ? cmd[cmd.index("--digest") + 1] : nil
        ok = passed == real_sha # only the correct subject digest verifies
        [ "", ok ? "" : "error: no matching attestations: subject digest mismatch", status(ok) ]
      end

      result = adapter.send(:run_cosign_verify_attestation, img_file.path, attest_file.path,
                            "id-re", "iss-re", nil, [ trusted_key_pem ], tampered_sha)

      expect(result[:ok]).to be false
      keyed = captured.find { |c| c.include?("verify-blob-attestation") && c.include?("--key") }
      expect(keyed).not_to be_nil
      expect(keyed).to include("--check-claims=true", "--digest", tampered_sha, "--digestAlg", "sha256")
    end

    it "fails closed when the .attestation-bundle layer is missing" do
      result = adapter.send(:run_cosign_verify_attestation, img_file.path, nil,
                            "id-re", "iss-re", nil, [ trusted_key_pem ], "a" * 64)

      expect(result[:ok]).to be false
      expect(result[:error]).to match(/missing \.attestation-bundle/)
    end

    it "falls back to the keyless identity/issuer policy when no trusted keys are configured" do
      captured = []
      allow(Open3).to receive(:capture3) do |*args|
        cmd = args.reject { |a| a.is_a?(Hash) }
        captured << cmd
        [ "", "", status(true) ]
      end

      result = adapter.send(:run_cosign_verify_blob, img_file.path, bundle_file.path, "id-re", "iss-re", [])

      expect(result[:ok]).to be true
      expect(captured.last).to include("cosign", "verify-blob", "--certificate-identity-regexp", "id-re")
      expect(captured.last).not_to include("--key")
    end
  end

  # IMP-b260339283bb — the same unguarded stub-adapter override that detonated
  # on 2026-07-16, on this service's SEPARATE call path.
  #
  # NOTE THE DIFFERENCE FROM THE SIBLING. LocalDiskImageAdapter does NOT
  # fabricate artifact identity the way LocalOciAdapter does: it verifies
  # sha256(bytes) == expected_sha256 for real. Its hazard is narrower but the
  # same class — it skips cosign verification ENTIRELY, and returns
  # attestation_bundle_b64 built from the CALLER'S OWN expected_payload_json
  # echoed back. DiskImagePublicationProcessor (:166-171) then persists that as
  # the publication's attestation_bundle and promotes the image onto the
  # NodePlatform. So an unsigned image whose bytes happen to match a
  # caller-supplied digest is recorded as if its attestation had been verified.
  # The gate MECHANISM mirrors the sibling exactly; only the wording differs,
  # because "fabricated identity" would be an inaccurate description here.
  #
  # WHICH ENVIRONMENTS THE PERSIST GATE ADMITS: test, and ONLY test. It refuses
  # in development, staging, production and any custom env. Deliberately NOT
  # "outside production" — 2026-07-16 detonated in DEVELOPMENT, where local IS
  # the default adapter, so a production-scoped guard would have permitted the
  # very incident it exists to prevent.
  describe "refuses the unverified stub adapter outside test (IMP-b260339283bb)" do
    def in_env!(name)
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new(name))
    end

    # A REAL file whose digest matches, so the adapter reaches its success path
    # and the only thing missing is cosign verification — the exact shape of
    # the hazard.
    let(:image_bytes) { "not-a-real-disk-image" }
    let(:image_file) do
      f = Tempfile.new([ "disk-image", ".img" ])
      f.write(image_bytes)
      f.flush
      f
    end
    let(:publication) do
      create(:system_disk_image_publication, account: account, node_platform: platform,
             oci_ref: "local://#{image_file.path}",
             sha256: Digest::SHA256.hexdigest(image_bytes))
    end

    after { image_file.close! }

    describe "adapter selection" do
      before { described_class.reset! }

      it "refuses POWERNODE_DISK_IMAGE_INGEST_MODE=local in production, naming the misconfiguration" do
        in_env!("production")
        stub_const("ENV", ENV.to_h.merge("POWERNODE_DISK_IMAGE_INGEST_MODE" => "local"))

        expect { described_class.adapter }
          .to raise_error(described_class::IngestError, /cosign|unverified/i)
      end

      it "still selects the oras adapter in production by default" do
        in_env!("production")
        stub_const("ENV", ENV.to_h.except("POWERNODE_DISK_IMAGE_INGEST_MODE"))

        expect(described_class.adapter).to be_a(described_class::OrasDiskImageAdapter)
      end

      # Selection stays permissive outside production, or every dev flow and
      # every spec breaks. The persist gate is what catches development.
      it "still selects the local adapter outside production" do
        in_env!("development")
        stub_const("ENV", ENV.to_h.except("POWERNODE_DISK_IMAGE_INGEST_MODE"))

        expect(described_class.adapter).to be_a(described_class::LocalDiskImageAdapter)
      end
    end

    describe "returning a verified-looking result" do
      before { described_class.adapter = described_class::LocalDiskImageAdapter.new }

      it "refuses in production even when the adapter is injected directly" do
        in_env!("production")

        result = described_class.verify_and_pull!(publication: publication)

        expect(result.ok?).to be false
        expect(result.error).to match(/unverified stub/i)
      end

      # THE 2026-07-16 LESSON. A `unless Rails.env.production?` guard would
      # permit exactly this.
      it "refuses in DEVELOPMENT too — the environment that actually detonated" do
        in_env!("development")

        result = described_class.verify_and_pull!(publication: publication)

        expect(result.ok?).to be false
        expect(result.error).to match(/unverified stub/i)
      end

      it "names the environment and the adapter in the refusal" do
        in_env!("staging")

        result = described_class.verify_and_pull!(publication: publication)

        expect(result.error).to include("staging")
        expect(result.error).to include("LocalDiskImageAdapter")
      end

      it "carries no attestation bundle back to the caller when it refuses" do
        in_env!("development")

        result = described_class.verify_and_pull!(publication: publication)

        expect(result.attestation_bundle_b64).to be_nil
        expect(result.local_path).to be_nil
      end

      it "returns ok in test, where an unverified pull is harmless" do
        result = described_class.verify_and_pull!(publication: publication)

        expect(result.ok?).to be true
        expect(result.local_path).to eq(image_file.path)
      end
    end
  end
end
