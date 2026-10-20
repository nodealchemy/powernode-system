# frozen_string_literal: true

require "rails_helper"
require "json-schema"

RSpec.describe System::ProvisioningDocument do
  # self-signed CA by default; ca: false drops basicConstraints CA:TRUE;
  # issuer: signs with another key (=> not self-signed).
  def make_cert(cn, ca: true, issuer: nil)
    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(1..1_000_000)
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{cn}")
    cert.issuer = issuer ? OpenSSL::X509::Name.parse("/CN=#{issuer}") : cert.subject
    cert.public_key = key
    cert.not_before = 1.hour.ago
    cert.not_after = 1.day.from_now
    ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    cert.add_extension(ef.create_extension("basicConstraints", ca ? "CA:TRUE" : "CA:FALSE", true))
    cert.sign(issuer ? OpenSSL::PKey::EC.generate("prime256v1") : key, OpenSSL::Digest.new("SHA256"))
    cert
  end

  let(:intermediate) { make_cert("intermediate", issuer: "root") }
  let(:root) { make_cert("root") }
  let(:chain) { intermediate.to_pem + root.to_pem }
  let(:instance) { instance_double(System::NodeInstance, id: "0198f3a2-7b1c-7d2e-9a4f-1234567890ab") }
  let(:key) { "SECRET-PLAINTEXT-TOKEN-abc123" }
  let(:schema) do
    path = File.expand_path("../../../../docs/schemas/powernode-provision-v1.schema.json", __dir__)
    JSON.parse(File.read(path)).except("$schema") # offline: do not fetch the metaschema
  end

  def render(**over)
    described_class.render(instance: instance, key: key, purpose: "disk_image_enroll",
                           ca_pem: chain, server: "https://platform.example.test", **over)
  end

  it "emits every required field and validates against the published JSON Schema" do
    doc = JSON.parse(render)
    expect(doc.keys).to match_array(%w[version server instance_id key ca_fingerprint issued_at expires_at purpose ca_pem])
    expect(doc).to include("version" => 1, "instance_id" => instance.id, "key" => key,
                           "purpose" => "disk_image_enroll", "server" => "https://platform.example.test")
    expect(JSON::Validator.fully_validate(schema, doc)).to eq([])
  end

  it "omits ca_pem on request but still carries the pin" do
    doc = JSON.parse(render(include_ca_pem: false))
    expect(doc).not_to have_key("ca_pem")
    expect(doc["ca_fingerprint"]).to match(/\Asha256:[0-9a-f]{64}\z/)
    expect(JSON::Validator.fully_validate(schema, doc)).to eq([])
  end

  it "computes ca_fingerprint as sha256 of the DER of the last certificate in the chain" do
    expect(JSON.parse(render)["ca_fingerprint"]).to eq("sha256:#{OpenSSL::Digest::SHA256.hexdigest(root.to_der)}")
  end

  it "accepts ISO8601 timestamps with expires_at after issued_at" do
    doc = JSON.parse(render)
    expect(Time.iso8601(doc["expires_at"])).to be > Time.iso8601(doc["issued_at"])
  end

  describe "refusals" do
    it "refuses without a CA" do
      allow(described_class).to receive(:configured_ca_pem).and_return(nil)
      expect { described_class.render(instance: instance, key: key, purpose: "x", server: "https://p.example.test") }
        .to raise_error(described_class::RenderError, /no CA/)
    end

    it "refuses an unparseable CA" do
      bad = "-----BEGIN CERTIFICATE-----\nZZZZ\n-----END CERTIFICATE-----"
      expect { render(ca_pem: bad) }.to raise_error(described_class::RenderError, /not parseable/)
    end

    it "refuses a pinned (last) certificate that is not a self-signed CA" do
      expect { render(ca_pem: root.to_pem + intermediate.to_pem) }
        .to raise_error(described_class::RenderError, /self-signed CA/)
      expect { render(ca_pem: make_cert("leaf", ca: false).to_pem) }
        .to raise_error(described_class::RenderError, /self-signed CA/)
    end

    it "accepts an anchor-last bundle [intermediate, root]" do
      expect { render(ca_pem: intermediate.to_pem + root.to_pem) }.not_to raise_error
    end

    it "refuses out-of-range ports, spaces and control characters in the server URL" do
      ["https://p.example.test:99999", "https://p.example.test:0", "https://p.example.test/a b",
       "https://p.example.test/\n", "https://p_x.example.test"].each do |bad|
        expect { render(server: bad) }.to raise_error(described_class::RenderError), bad
      end
      expect { render(server: "https://p.example.test:8443/base") }.not_to raise_error
    end

    it "refuses a non-https or credentialed server" do
      expect { render(server: "http://p.example.test") }.to raise_error(described_class::RenderError, /https/)
      expect { render(server: "https://u:p@p.example.test") }.to raise_error(described_class::RenderError, /https/)
    end

    it "refuses an empty key or unprintable key, without echoing it" do
      expect { render(key: "") }.to raise_error(described_class::RenderError)
      expect { render(key: "a b") }.to raise_error(described_class::RenderError) { |e| expect(e.message).not_to include("a b") }
    end

    it "refuses a bad purpose" do
      expect { described_class.render(instance: instance, key: key, purpose: "Bad Purpose", ca_pem: chain, server: "https://p.example.test") }
        .to raise_error(described_class::RenderError, /purpose/)
    end
  end

  describe "key handling" do
    it "never logs the key, on success or failure" do
      logged = []
      logger = Rails.logger
      %i[debug info warn error fatal].each { |lvl| allow(logger).to receive(lvl) { |*a, &b| logged << (a.first || b&.call).to_s } }
      render
      begin
        render(server: "http://nope")
      rescue described_class::RenderError => e
        logged << e.message
      end
      expect(logged.join).not_to include(key)
    end

    it "never persists the key" do
      expect { render }.not_to change { [ System::BootstrapToken.count, System::NodeInstance.count ] }
    end
  end

  it "resolves the configured enroll CA and platform URL by default" do
    allow(::SiteSetting).to receive(:get).and_call_original
    allow(::SiteSetting).to receive(:get).with(System::PhysicalEnrollmentService::ENROLL_CA_SETTING).and_return(chain)
    allow(System::PhysicalEnrollmentService).to receive(:platform_url).and_return("https://configured.example.test")
    doc = JSON.parse(described_class.render(instance: instance, key: key, purpose: "usb"))
    expect(doc["server"]).to eq("https://configured.example.test")
    expect(doc["ca_fingerprint"]).to eq("sha256:#{OpenSSL::Digest::SHA256.hexdigest(root.to_der)}")
  end
end
