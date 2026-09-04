# frozen_string_literal: true

require "rails_helper"

# The ONE resolver for "which module-signing public keys does this platform
# trust". Served to nodes (node_api modules#signing_keys, the download
# envelope) and used by OrasOciAdapter at ingest — one list, so a node cannot
# trust a key the platform's own ingest would not, or vice versa.
RSpec.describe System::ModuleSigningTrust do
  let(:vault_pem)  { "-----BEGIN PUBLIC KEY-----\nVAULT\n-----END PUBLIC KEY-----\n" }
  let(:legacy_pem) { "-----BEGIN PUBLIC KEY-----\nLEGACY\n-----END PUBLIC KEY-----\n" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
    allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)
  end

  it "is empty when nothing is configured" do
    expect(described_class.public_keys).to eq([])
  end

  it "lists the SiteSetting keys first, then the legacy static key, verbatim and de-duplicated" do
    ::SiteSetting.set(described_class::TRUSTED_KEYS_SETTING, [ vault_pem, vault_pem, "" ], setting_type: "json")
    allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(legacy_pem)

    expect(described_class.public_keys).to eq([ vault_pem, legacy_pem ])
  end

  it "reads the legacy key from a file path when the inline env is unset" do
    Tempfile.create([ "cosign", ".pub" ]) do |f|
      f.write(legacy_pem)
      f.flush
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(f.path)
      expect(described_class.public_keys).to eq([ legacy_pem ])
    end
  end

  it "degrades to the other source when the SiteSetting read raises" do
    allow(::SiteSetting).to receive(:get).with(described_class::TRUSTED_KEYS_SETTING).and_raise(StandardError, "db down")
    allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(legacy_pem)
    expect(described_class.public_keys).to eq([ legacy_pem ])
  end

  it "is what OrasOciAdapter verifies against at ingest (single oracle)" do
    ::SiteSetting.set(described_class::TRUSTED_KEYS_SETTING, [ vault_pem ], setting_type: "json")
    adapter = System::ModuleOciIngestService::OrasOciAdapter.new
    expect(adapter.send(:trusted_public_keys)).to eq(described_class.public_keys)
    expect(adapter.key_verification_available?).to be true
  end
end
