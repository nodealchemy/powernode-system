# frozen_string_literal: true

require "openssl"

# Shared fixtures for the platform-injected enrolment seed specs (D12): a real
# self-signed CA (ProvisioningDocument refuses anything else) and a stub of the
# two SiteSettings the seed reads. All key strings in specs are low-entropy
# placeholders.
module EnrollmentCaHelpers
  def self_signed_ca_pem(cn = "powernode-test-ca")
    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(1..1_000_000)
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{cn}")
    cert.public_key = key
    cert.not_before = 1.hour.ago
    cert.not_after = 1.day.from_now
    ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    cert.to_pem
  end

  # ca: nil simulates "no CA configured".
  def stub_enroll_settings(ca:, url: "https://platform.example.test")
    allow(::SiteSetting).to receive(:get).and_call_original
    allow(::SiteSetting).to receive(:get).with("system.ci_builder.enroll_ca_pem").and_return(ca)
    allow(::SiteSetting).to receive(:get).with("system.ci_builder.enroll_platform_url").and_return(url)
    allow(::System::PhysicalEnrollmentService).to receive(:platform_url).and_return(url)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("POWERNODE_ENROLL_CA_PEM").and_return(nil) if ca.nil?
  end
end

RSpec.configure { |c| c.include EnrollmentCaHelpers }
