# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# Task #48 — self-generated LOCAL cosign signing key for a Vault-less plane.
# cosign is MOCKED (no real keygen); the file custody + trusted-key registration
# are exercised for real. Mirrors System::InternalCaService::LocalCaAdapter.
RSpec.describe System::ModuleSigningKey do
  around { |ex| Dir.mktmpdir("msk-spec-") { |d| @dir = d; ex.run } }
  let(:instance) { described_class.new(dir: @dir) }
  let(:pub_pem) { "-----BEGIN PUBLIC KEY-----\nFAKEPUB\n-----END PUBLIC KEY-----\n" }

  def stub_cosign_keygen(ok: true)
    allow(Open3).to receive(:capture3) do |env, *argv|
      expect(env).to have_key("COSIGN_PASSWORD")
      expect(argv.first(2)).to eq([ "cosign", "generate-key-pair" ])
      prefix = argv[argv.index("--output-key-prefix") + 1]
      if ok
        File.write("#{prefix}.key", "-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----\nfake\n-----END-----\n")
        File.write("#{prefix}.pub", pub_pem)
        [ "", "", instance_double(Process::Status, success?: true, exitstatus: 0) ]
      else
        [ "", "keygen boom", instance_double(Process::Status, success?: false, exitstatus: 1) ]
      end
    end
  end

  def mode_of(k) = format("%o", File.stat(File.join(@dir, k)).mode & 0o777)
  def trusted = Array(::SiteSetting.get("system.module_signing.trusted_public_keys"))

  it "generates 0600 key + pass files and returns Material" do
    stub_cosign_keygen
    material = instance.ensure!

    expect(File).to exist(File.join(@dir, "cosign.key"))
    expect(mode_of("cosign.key")).to eq("600")
    expect(mode_of("cosign.pass")).to eq("600")
    expect(mode_of("cosign.pub")).to eq("644")
    expect(material.key_path).to eq(File.join(@dir, "cosign.key"))
    expect(material.password).to be_present
    expect(material.public_key_pem).to include("BEGIN PUBLIC KEY")
  end

  it "appends the PUBLIC key to trusted_public_keys as a JSON array element" do
    stub_cosign_keygen
    instance.ensure!
    expect(trusted).to be_an(Array)
    expect(trusted.any? { |k| k.include?("FAKEPUB") }).to be true
  end

  it "retains a pre-existing trusted key when appending (rotation-safe, never replaces)" do
    ::SiteSetting.set("system.module_signing.trusted_public_keys",
                      [ "-----BEGIN PUBLIC KEY-----\nDEVKEY\n-----END PUBLIC KEY-----\n" ], setting_type: "json")
    stub_cosign_keygen
    instance.ensure!
    expect(trusted.any? { |k| k.include?("DEVKEY") }).to be true
    expect(trusted.any? { |k| k.include?("FAKEPUB") }).to be true
    expect(trusted.size).to eq(2)
  end

  it "is idempotent — a second ensure! neither regenerates nor duplicates the trusted key" do
    stub_cosign_keygen
    instance.ensure!
    key_mtime = File.mtime(File.join(@dir, "cosign.key"))

    expect(Open3).not_to receive(:capture3) # cosign keygen must NOT run again
    described_class.new(dir: @dir).ensure!

    expect(File.mtime(File.join(@dir, "cosign.key"))).to eq(key_mtime)
    expect(trusted.count { |k| k.include?("FAKEPUB") }).to eq(1)
  end

  it "raises a typed KeyError and writes no key file when cosign keygen fails" do
    stub_cosign_keygen(ok: false)
    expect { instance.ensure! }.to raise_error(described_class::KeyError, /generate-key-pair failed/)
    expect(File).not_to exist(File.join(@dir, "cosign.key"))
  end

  # Fable #2 — a fresh plane where the pubkey append silently failed would leave
  # trusted_public_keys EMPTY → R6's key_verification_available? false → native
  # promote SKIPS verification (fail-OPEN). The append MUST fail LOUD instead.
  it "raises KeyError (does NOT fail-open) when the trusted-key store write errors" do
    stub_cosign_keygen
    allow(::SiteSetting).to receive(:set).and_raise(ActiveRecord::StatementInvalid.new("db down"))
    expect { instance.ensure! }.to raise_error(described_class::KeyError, /registration failed/)
  end

  it "raises KeyError when the pubkey is written but does not land in the trusted list (post-write read-back)" do
    stub_cosign_keygen
    allow(::SiteSetting).to receive(:get).and_call_original
    allow(::SiteSetting).to receive(:get).with("system.module_signing.trusted_public_keys").and_return([])
    allow(::SiteSetting).to receive(:set).and_return(nil) # write silently no-ops
    expect { instance.ensure! }.to raise_error(described_class::KeyError, /failed to register/)
  end

  # Fable #5 — the regen guard must include the PUBLIC key; a missing pub would
  # let register_public_key! skip (feeding #2), so an absent pub forces regenerate.
  it "regenerates when the pub file is missing even though key+pass exist" do
    stub_cosign_keygen
    instance.ensure!
    File.delete(File.join(@dir, "cosign.pub"))

    regenerated = false
    allow(Open3).to receive(:capture3) do |_env, *argv|
      regenerated = true
      prefix = argv[argv.index("--output-key-prefix") + 1]
      File.write("#{prefix}.key", "k")
      File.write("#{prefix}.pub", pub_pem)
      [ "", "", instance_double(Process::Status, success?: true, exitstatus: 0) ]
    end
    described_class.new(dir: @dir).ensure!
    expect(regenerated).to be true
    expect(File).to exist(File.join(@dir, "cosign.pub"))
  end

  # Fable #8 — Material must never echo the password (log line / exception dump).
  it "redacts the password in Material#inspect and #to_s" do
    material = described_class::Material.new(
      key_path: "/x/cosign.key", password: "super-secret-pw", public_key_pem: "PUB"
    )
    expect(material.inspect).not_to include("super-secret-pw")
    expect(material.inspect).to include("[REDACTED]")
    expect(material.to_s).not_to include("super-secret-pw")
  end
end
