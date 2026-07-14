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
  end

  def stub_manifest_fetch(returned_digest: digest, ok: true)
    allow(Open3).to receive(:capture3)
      .with("oras", "manifest", "fetch", "--descriptor", oci_ref)
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
  end
end
