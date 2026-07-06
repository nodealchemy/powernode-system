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
end
