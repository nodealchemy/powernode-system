# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc8 — platform-side module signing via Vault-transit.
# Every Vault/oras/cosign interaction here is MOCKED — no live Vault, no
# live registry, no real signing key. See ModuleSigningService's header
# comment for the design rationale (D3: builders push unsigned, the
# platform signs server-side against a Vault-transit key, the private key
# never leaves Vault).
RSpec.describe System::ModuleSigningService do
  let(:account) { create(:account) }
  let(:vault_address) { "https://vault.example.internal:8200" }
  let(:vault_token) { "s.faketoken-not-a-real-secret" }
  let(:fake_inner_client) { instance_double(Vault::Client, address: vault_address, token: vault_token) }
  let(:fake_vault_client) { instance_double(Security::VaultClient, client: fake_inner_client) }
  let(:service) { described_class.new(vault_client: fake_vault_client) }

  let(:oci_ref) { "registry.example.com/account/ingest-mod:v1.0.0" }
  let(:digest) { "sha256:#{'a' * 64}" }
  let(:ref_at_digest) { "registry.example.com/account/ingest-mod@#{digest}" }
  let(:expected_vault_env) { { "VAULT_ADDR" => vault_address, "VAULT_TOKEN" => vault_token } }

  def status_double(ok, code: 0)
    instance_double(Process::Status, success?: ok, exitstatus: code)
  end

  before do
    allow(Open3).to receive(:capture3).with("which", "oras").and_return([ "", "", status_double(true) ])
    allow(Open3).to receive(:capture3).with("which", "cosign").and_return([ "", "", status_double(true) ])
    # Default: registry unconfigured → with_registry_auth yields an empty env
    # (no `oras login`), so oras/cosign run with env={} (vault_env for cosign).
    # The authenticated path has its own context below.
    allow(::System::DiskImageRegistryConfig).to receive(:configured?).and_return(false)
  end

  def stub_manifest_fetch(returned_digest: digest, ok: true)
    allow(Open3).to receive(:capture3)
      .with({}, "oras", "manifest", "fetch", "--descriptor", oci_ref)
      .and_return(
        ok ? [ { digest: returned_digest }.to_json, "", status_double(true) ]
           : [ "", "Error: not found", status_double(false, code: 1) ]
      )
  end

  def stub_cosign_sign(ok: true, expected_ref: ref_at_digest, keyname: "powernode-module-signing")
    allow(Open3).to receive(:capture3)
      .with(expected_vault_env, "cosign", "sign", "--yes", "--key", "hashivault://#{keyname}", expected_ref)
      .and_return(
        ok ? [ "Pushing signature to: #{expected_ref}\n", "", status_double(true) ]
           : [ "", "error: signing failed", status_double(false, code: 1) ]
      )
  end

  describe "#sign!" do
    it "fetches the registry descriptor, confirms the digest, signs via hashivault://, and emits an event" do
      stub_manifest_fetch
      stub_cosign_sign

      expect(::System::Fleet::EventBroadcaster).to receive(:emit!)
        .with(
          hash_including(
            account: account,
            kind: "system.module_signed",
            severity: :low,
            payload: hash_including(oci_ref: oci_ref, digest: digest, keyname: "powernode-module-signing")
          )
        ).and_call_original

      result = service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account)

      expect(result.ok?).to be true
      expect(result.digest).to eq(digest)
      expect(result.oci_ref).to eq(oci_ref)
    end

    it "invokes cosign with the exact hashivault:// key-name argv shape (nothing key-shaped in argv)" do
      stub_manifest_fetch
      expect(Open3).to receive(:capture3)
        .with(expected_vault_env, "cosign", "sign", "--yes", "--key", "hashivault://powernode-module-signing", ref_at_digest)
        .and_return([ "signed", "", status_double(true) ])

      service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account)
    end

    it "rejects with a digest mismatch and never invokes cosign (fail-closed digest binding)" do
      stub_manifest_fetch(returned_digest: "sha256:#{'b' * 64}")
      expect(Open3).not_to receive(:capture3).with(anything, "cosign", "sign", any_args)
      expect(::System::Fleet::EventBroadcaster).not_to receive(:emit!)

      result = service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account)

      expect(result.ok?).to be false
      expect(result.error).to match(/digest/i)
      expect(result.error).to match(/does not match/i)
    end

    it "fails clearly when oci_ref is blank" do
      result = service.sign!(oci_ref: "", expected_digest: digest, account: account)
      expect(result.ok?).to be false
      expect(result.error).to match(/oci_ref required/)
    end

    it "fails clearly when expected_digest is blank" do
      result = service.sign!(oci_ref: oci_ref, expected_digest: "", account: account)
      expect(result.ok?).to be false
      expect(result.error).to match(/expected_digest required/)
    end

    it "fails with a typed BinaryNotFoundError message when oras is missing" do
      allow(Open3).to receive(:capture3).with("which", "oras").and_return([ "", "not found", status_double(false) ])

      result = service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account)
      expect(result.ok?).to be false
      expect(result.error).to match(/oras binary not found/)
    end

    it "fails with a typed BinaryNotFoundError message when cosign is missing" do
      allow(Open3).to receive(:capture3).with("which", "cosign").and_return([ "", "not found", status_double(false) ])

      result = service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account)
      expect(result.ok?).to be false
      expect(result.error).to match(/cosign binary not found/)
    end

    it "surfaces a manifest-fetch failure without ever calling cosign" do
      stub_manifest_fetch(ok: false)
      expect(Open3).not_to receive(:capture3).with(anything, "cosign", "sign", any_args)

      result = service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account)
      expect(result.ok?).to be false
      expect(result.error).to match(/manifest fetch/i)
    end

    it "surfaces a cosign sign failure as a typed error" do
      stub_manifest_fetch
      stub_cosign_sign(ok: false)

      result = service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account)
      expect(result.ok?).to be false
      expect(result.error).to match(/cosign sign failed/i)
    end

    it "reads the transit keyname from SiteSetting when configured" do
      ::SiteSetting.set("system.module_signing.keyname", "custom-signing-key", setting_type: "string")
      stub_manifest_fetch
      expect(Open3).to receive(:capture3)
        .with(expected_vault_env, "cosign", "sign", "--yes", "--key", "hashivault://custom-signing-key", ref_at_digest)
        .and_return([ "signed", "", status_double(true) ])

      result = service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account)
      expect(result.ok?).to be true
    end

    it "skips event emission (does not raise) when no account is given" do
      stub_manifest_fetch
      stub_cosign_sign
      expect(::System::Fleet::EventBroadcaster).not_to receive(:emit!)

      result = service.sign!(oci_ref: oci_ref, expected_digest: digest)
      expect(result.ok?).to be true
    end

    context "when the registry is configured (private Gitea OCI)" do
      let(:reg_host)  { "git.powernode.org" }
      let(:reg_user)  { "everett" }
      let(:reg_token) { "gitea-token-not-a-real-secret" }

      before do
        allow(::System::DiskImageRegistryConfig).to receive(:configured?).with(account: account).and_return(true)
        allow(::System::DiskImageRegistryConfig).to receive(:registry_host).with(account: account).and_return(reg_host)
        allow(::System::DiskImageRegistryConfig).to receive(:registry_user).with(account: account).and_return(reg_user)
        allow(::System::DiskImageRegistryConfig).to receive(:registry_token).with(account: account).and_return(reg_token)
      end

      it "logs in with the token via stdin (never argv) into a throwaway DOCKER_CONFIG, and threads it onto oras + cosign" do
        # oras login — token piped via stdin_data, DOCKER_CONFIG-scoped, nothing key/token-shaped in argv
        expect(Open3).to receive(:capture3)
          .with(hash_including("DOCKER_CONFIG"), "oras", "login", reg_host, "--username", reg_user, "--password-stdin", stdin_data: reg_token)
          .and_return([ "Login Succeeded", "", status_double(true) ])
        # manifest fetch + cosign sign both carry the same DOCKER_CONFIG env
        expect(Open3).to receive(:capture3)
          .with(hash_including("DOCKER_CONFIG"), "oras", "manifest", "fetch", "--descriptor", oci_ref)
          .and_return([ { digest: digest }.to_json, "", status_double(true) ])
        expect(Open3).to receive(:capture3)
          .with(hash_including("DOCKER_CONFIG", "VAULT_ADDR" => vault_address, "VAULT_TOKEN" => vault_token),
                "cosign", "sign", "--yes", "--key", "hashivault://powernode-module-signing", ref_at_digest)
          .and_return([ "signed", "", status_double(true) ])

        result = service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account)
        expect(result.ok?).to be true
      end

      it "fails closed (never fetches or signs) when oras login is rejected" do
        allow(Open3).to receive(:capture3)
          .with(hash_including("DOCKER_CONFIG"), "oras", "login", reg_host, "--username", reg_user, "--password-stdin", stdin_data: reg_token)
          .and_return([ "", "unauthorized", status_double(false, code: 1) ])
        expect(Open3).not_to receive(:capture3).with(anything, "oras", "manifest", any_args)
        expect(Open3).not_to receive(:capture3).with(anything, "cosign", "sign", any_args)

        result = service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account)
        expect(result.ok?).to be false
        expect(result.error).to match(/oras login failed/i)
      end
    end
  end

  describe "local signing mode (task #48 — no Vault)" do
    let(:key_path) { "/var/lib/powernode/internal-ca/module-signing/cosign.key" }
    let(:cosign_password) { "local-key-password-not-a-real-secret" }
    let(:local_material) do
      System::ModuleSigningKey::Material.new(
        key_path: key_path,
        password: cosign_password,
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nX\n-----END PUBLIC KEY-----\n"
      )
    end
    # NO injected vault client — proves local mode never resolves Vault at all.
    let(:local_service) { described_class.new }
    # cosign 3.x resolves a signing config from the Sigstore TUF repo and fails
    # hard without one, even for --key signing. Local mode therefore passes an
    # explicit no-transparency-log config kept beside the key.
    let(:signing_config_path) { "/var/lib/powernode/internal-ca/module-signing/signing-config.json" }

    before do
      ::SiteSetting.set("system.module_signing.mode", "local", setting_type: "string")
      allow(System::ModuleSigningKey).to receive(:ensure!).and_return(local_material)
      # Present by default so the sign path does not shell out to generate it;
      # the generate-when-absent branch has its own example below.
      allow(File).to receive(:size?).and_call_original
      allow(File).to receive(:size?).with(signing_config_path).and_return(512)
    end

    it "signs with the on-disk key file (--key <path>) + COSIGN_PASSWORD env, and NEVER resolves Vault" do
      stub_manifest_fetch
      expect(Security::VaultClient).not_to receive(:instance)
      expect(Open3).to receive(:capture3)
        .with({ "COSIGN_PASSWORD" => cosign_password }, "cosign", "sign", "--yes", "--signing-config", signing_config_path, "--key", key_path, ref_at_digest)
        .and_return([ "signed", "", status_double(true) ])

      result = local_service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account)
      expect(result.ok?).to be true
    end

    it "passes the password via env only — nothing key/password-shaped in argv" do
      stub_manifest_fetch
      # Constrained to the cosign call. An unconstrained `receive(:capture3)`
      # block is a catch-all that also swallows the `which oras` / `which
      # cosign` probes, so the first assertion saw env == "which" and this
      # example failed before it ever reached the signing call (pre-existing —
      # it fails the same way on an unmodified tree).
      expect(Open3).to receive(:capture3).with(anything, "cosign", "sign", any_args) do |env, *argv|
        expect(env).to eq("COSIGN_PASSWORD" => cosign_password)
        expect(argv).to eq([ "cosign", "sign", "--yes", "--signing-config", signing_config_path, "--key", key_path, ref_at_digest ])
        expect(argv).not_to include(cosign_password)
        [ "signed", "", status_double(true) ]
      end

      expect(local_service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account).ok?).to be true
    end

    it "generates the signing config when absent, and reuses it when present" do
      stub_manifest_fetch
      # Absent on the entry check, present after create (ensure_signing_config!
      # re-checks size? to confirm the file actually landed).
      allow(File).to receive(:size?).with(signing_config_path).and_return(nil, 512)
      expect(Open3).to receive(:capture3)
        .with("cosign", "signing-config", "create", "--out", signing_config_path)
        .and_return([ "", "", status_double(true) ])
      allow(Open3).to receive(:capture3)
        .with({ "COSIGN_PASSWORD" => cosign_password }, "cosign", "sign", "--yes", "--signing-config", signing_config_path, "--key", key_path, ref_at_digest)
        .and_return([ "signed", "", status_double(true) ])

      expect(local_service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account).ok?).to be true
    end

    it "emits the module_signed event with mode=local and keyname=local" do
      stub_manifest_fetch
      allow(Open3).to receive(:capture3)
        .with({ "COSIGN_PASSWORD" => cosign_password }, "cosign", "sign", "--yes", "--signing-config", signing_config_path, "--key", key_path, ref_at_digest)
        .and_return([ "signed", "", status_double(true) ])
      expect(::System::Fleet::EventBroadcaster).to receive(:emit!)
        .with(hash_including(payload: hash_including(mode: "local", keyname: "local")))
        .and_call_original

      local_service.sign!(oci_ref: oci_ref, expected_digest: digest, account: account)
    end
  end
end
