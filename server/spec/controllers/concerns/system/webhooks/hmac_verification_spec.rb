# frozen_string_literal: true

require "rails_helper"

# Unit characterization of the shared, policy-free HMAC primitives.
# These prove the standardization (ActiveSupport::SecurityUtils.secure_compare)
# behaves exactly as the per-controller logic it replaced: a valid hex
# digest matches, a tampered one does not, a "sha256=" prefix is tolerated,
# and a malformed / length-mismatched signature returns false (never raises).
RSpec.describe System::Webhooks::HmacVerification do
  let(:harness) do
    Class.new do
      include System::Webhooks::HmacVerification
    end.new
  end

  let(:secret) { "shared-webhook-secret" }
  let(:body) { '{"hello":"world"}' }
  let(:digest) { OpenSSL::HMAC.hexdigest("sha256", secret, body) }

  describe "#hmac_hex" do
    it "produces the SHA-256 HMAC hex of the body" do
      expect(harness.send(:hmac_hex, secret, body)).to eq(digest)
    end

    it "is case-insensitive on the digest name (matches an uppercase SHA256 signer)" do
      expect(harness.send(:hmac_hex, secret, body))
        .to eq(OpenSSL::HMAC.hexdigest("SHA256", secret, body))
    end
  end

  describe "#secure_match?" do
    it "returns true for the correct hex digest" do
      expect(harness.send(:secure_match?, digest, digest)).to be(true)
    end

    it "tolerates a leading sha256= prefix on the provided signature" do
      expect(harness.send(:secure_match?, digest, "sha256=#{digest}")).to be(true)
    end

    it "returns false for a tampered signature of equal length" do
      tampered = digest.dup
      tampered[0] = tampered[0] == "a" ? "b" : "a"
      expect(harness.send(:secure_match?, digest, tampered)).to be(false)
    end

    it "returns false (never raises) for a short / length-mismatched signature" do
      expect(harness.send(:secure_match?, digest, "deadbeef")).to be(false)
    end

    it "returns false (never raises) for a nil signature" do
      expect(harness.send(:secure_match?, digest, nil)).to be(false)
    end

    it "returns false for a blank signature" do
      expect(harness.send(:secure_match?, digest, "")).to be(false)
    end
  end
end
