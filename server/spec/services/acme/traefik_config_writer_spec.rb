# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "yaml"

RSpec.describe Acme::TraefikConfigWriter, type: :service do
  let(:account) { create(:account) }
  let(:dns_cred) { create(:system_acme_dns_credential, :valid, account: account) }

  let(:tmp_dynamic_dir) { Dir.mktmpdir("traefik-dynamic") }
  let(:tmp_cert_dir)    { Dir.mktmpdir("traefik-certs") }

  after do
    FileUtils.rm_rf(tmp_dynamic_dir) if Dir.exist?(tmp_dynamic_dir)
    FileUtils.rm_rf(tmp_cert_dir)    if Dir.exist?(tmp_cert_dir)
  end

  describe ".write!" do
    context "with no valid certs" do
      it "writes an empty TLS config (no certificates entry has 0 items)" do
        result = described_class.write!(account: account,
                                         dynamic_dir: tmp_dynamic_dir,
                                         cert_dir: tmp_cert_dir)
        expect(result[:cert_count]).to eq(0)
        expect(File.exist?(result[:output_path])).to be true
        parsed = YAML.load_file(result[:output_path])
        expect(parsed["tls"]["certificates"]).to eq([])
      end
    end

    context "with two valid certs" do
      let!(:cert1) { create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred) }
      let!(:cert2) { create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred) }
      let!(:pending_cert) { create(:system_acme_certificate, account: account, dns_credential: dns_cred) }

      it "includes only the valid certs" do
        result = described_class.write!(account: account,
                                         dynamic_dir: tmp_dynamic_dir,
                                         cert_dir: tmp_cert_dir)
        expect(result[:cert_count]).to eq(2)
        parsed = YAML.load_file(result[:output_path])
        cert_files = parsed["tls"]["certificates"].map { |e| e["certFile"] }
        expect(cert_files).to include(described_class.cert_file_path(cert1, cert_dir: tmp_cert_dir))
        expect(cert_files).to include(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir))
        expect(cert_files).not_to include(described_class.cert_file_path(pending_cert, cert_dir: tmp_cert_dir))
      end

      it "names the output file per account id" do
        result = described_class.write!(account: account,
                                         dynamic_dir: tmp_dynamic_dir,
                                         cert_dir: tmp_cert_dir)
        expect(File.basename(result[:output_path])).to eq("acme-#{account.id}.yaml")
      end

      it "uses absolute paths derived from cert_dir + account_id" do
        result = described_class.write!(account: account,
                                         dynamic_dir: tmp_dynamic_dir,
                                         cert_dir: tmp_cert_dir)
        parsed = YAML.load_file(result[:output_path])
        first = parsed["tls"]["certificates"].first
        expect(first["certFile"]).to start_with(tmp_cert_dir)
        expect(first["certFile"]).to include(account.id)
        expect(first["keyFile"]).to end_with(".key")
        expect(first["stores"]).to eq([ "default" ])
      end
    end

    it "creates the dynamic_dir if missing" do
      missing_dir = File.join(tmp_dynamic_dir, "nested", "subdir")
      result = described_class.write!(account: account,
                                       dynamic_dir: missing_dir,
                                       cert_dir: tmp_cert_dir)
      expect(Dir.exist?(missing_dir)).to be true
      expect(File.exist?(result[:output_path])).to be true
    end
  end

  describe ".cert_file_path / .key_file_path" do
    let(:cert) { create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred) }

    it "puts each account's certs in their own subdir" do
      expect(described_class.cert_file_path(cert, cert_dir: tmp_cert_dir))
        .to eq(File.join(tmp_cert_dir, account.id, "#{cert.id}.crt"))
      expect(described_class.key_file_path(cert, cert_dir: tmp_cert_dir))
        .to eq(File.join(tmp_cert_dir, account.id, "#{cert.id}.key"))
    end
  end
end
