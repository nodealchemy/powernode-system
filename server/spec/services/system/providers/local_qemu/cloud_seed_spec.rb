# frozen_string_literal: true

require "rails_helper"

# CloudSeed resolves the platform CA that gets baked into a provisioned VM's
# fw-cfg identity package. There was no spec file for this at all, which is how
# the fixture-fallback below survived: the old code answered a CA outage with a
# literal "-----BEGIN CERTIFICATE-----\nFIXTURE-fallback\n..." string, so the
# VM provisioned "successfully" and failed much later with an unexplained x509
# error during enrollment. Trust material must never be substituted.
RSpec.describe System::Providers::LocalQemu::CloudSeed do
  subject(:seed) { described_class.new }

  def resolve = seed.send(:resolve_ca_pem)

  describe "#resolve_ca_pem" do
    it "returns the platform CA chain when the CA is healthy" do
      allow(::System::InternalCaService).to receive(:ca_chain_pem).and_return("-----BEGIN CERTIFICATE-----\nreal\n-----END CERTIFICATE-----\n")

      expect(resolve).to include("real")
    end

    it "RAISES instead of substituting a placeholder when the CA raises" do
      allow(::System::InternalCaService)
        .to receive(:ca_chain_pem)
        .and_raise(::System::InternalCaService::CaError, "store is DAMAGED")

      expect { resolve }.to raise_error(described_class::CloudSeedError, /refusing to seed.*DAMAGED/m)
    end

    # The specific regression: the failure mode was not an exception but a
    # PEM-shaped string that is not a certificate. Assert on the ABSENCE of that
    # shape, not just on the raise — a future rescue that returns some other
    # placeholder would pass a raise-only assertion.
    it "never returns a FIXTURE placeholder on any CA failure" do
      allow(::System::InternalCaService)
        .to receive(:ca_chain_pem)
        .and_raise(StandardError, "vault unreachable")

      result = begin
        resolve
      rescue described_class::CloudSeedError
        :raised
      end

      expect(result).to eq(:raised)
    end

    context "with the POWERNODE_CA_PEM operator override" do
      before do
        hide_const("System::InternalCaService")
      end

      it "uses a valid operator-supplied anchor" do
        key  = OpenSSL::PKey::RSA.new(2048)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 1
        cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=Operator Anchor")
        cert.public_key = key.public_key
        cert.not_before = Time.current - 60
        cert.not_after  = Time.current + 3600
        cert.sign(key, OpenSSL::Digest::SHA256.new)

        stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_PEM" => cert.to_pem))
        expect(resolve).to eq(cert.to_pem)
      end

      it "refuses an override that is not a parseable certificate" do
        stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_PEM" => "not a certificate"))

        expect { resolve }.to raise_error(described_class::CloudSeedError, /not a parseable certificate/)
      end

      it "refuses when no override is set and the service is absent" do
        stub_const("ENV", ENV.to_h.reject { |k, _| k == "POWERNODE_CA_PEM" })

        expect { resolve }.to raise_error(described_class::CloudSeedError, /no platform CA available/)
      end
    end
  end
end
