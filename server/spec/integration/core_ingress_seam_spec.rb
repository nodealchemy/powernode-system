# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "yaml"
require "openssl"

# Byte-identical regression pin for campaign 019f3458 increment 8 (the
# core/extension ingress provider seam, docs/operations/reverse-proxy.md
# §7-8). With the system extension loaded, Core::IngressConfigWriter.write!
# must delegate the ENTIRE per-account write to Acme::TraefikConfigWriter and
# produce output that is BYTE-IDENTICAL to calling Acme::TraefikConfigWriter
# directly (the exact pre-seam code path) — this is the automated twin of the
# manual scratch-dir `diff -r` evidence gathered for the increment.
RSpec.describe "Core ingress seam — extension-mode byte-identical delegation" do
  let(:account) { create(:account) }
  let(:dns_cred) { create(:system_acme_dns_credential, :valid, account: account) }
  let!(:cert) do
    create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                             common_name: "seam-check.example.test")
  end

  let(:dynamic_dir_direct) { Dir.mktmpdir("seam-direct-dynamic") }
  let(:cert_dir_direct)    { Dir.mktmpdir("seam-direct-certs") }
  let(:dynamic_dir_seam)   { Dir.mktmpdir("seam-core-dynamic") }
  let(:cert_dir_seam)      { Dir.mktmpdir("seam-core-certs") }

  after do
    [ dynamic_dir_direct, cert_dir_direct, dynamic_dir_seam, cert_dir_seam ].each do |d|
      FileUtils.rm_rf(d) if Dir.exist?(d)
    end
  end

  # Real self-signed cert + matching key (locals, not top-level constants —
  # avoids leaking VALID_CERT_PEM/VALID_KEY_PEM into the global namespace
  # alongside traefik_config_writer_spec.rb's own copies of the same names).
  let(:cert_pair) do
    rsa_key = OpenSSL::PKey::RSA.new(2048)
    name = OpenSSL::X509::Name.parse("/CN=seam-check.example.test")
    x509 = OpenSSL::X509::Certificate.new
    x509.version = 2
    x509.serial = 1
    x509.subject = name
    x509.issuer = name
    x509.public_key = rsa_key
    x509.not_before = Time.now
    x509.not_after = Time.now + 3600
    x509.sign(rsa_key, OpenSSL::Digest.new("SHA256"))
    { cert_pem: x509.to_pem, key_pem: rsa_key.to_pem }
  end

  def materialize(cert, cert_dir:)
    cert_path = Acme::TraefikConfigWriter.cert_file_path(cert, cert_dir: cert_dir)
    key_path  = Acme::TraefikConfigWriter.key_file_path(cert, cert_dir: cert_dir)
    FileUtils.mkdir_p(File.dirname(cert_path))
    File.write(cert_path, cert_pair[:cert_pem])
    File.write(key_path, cert_pair[:key_pem])
  end

  it "Core::IngressConfigWriter.write! output matches Acme::TraefikConfigWriter.write! called directly, byte-for-byte" do
    materialize(cert, cert_dir: cert_dir_direct)
    materialize(cert, cert_dir: cert_dir_seam)

    direct = Acme::TraefikConfigWriter.write!(account: account, dynamic_dir: dynamic_dir_direct, cert_dir: cert_dir_direct)
    seam   = Core::IngressConfigWriter.write!(account: account, dynamic_dir: dynamic_dir_seam, cert_dir: cert_dir_seam)

    expect(File.basename(seam[:output_path])).to eq(File.basename(direct[:output_path]))
    expect(seam[:cert_count]).to eq(direct[:cert_count])

    # Byte-identical modulo the cert/key absolute paths, which legitimately
    # differ because each run used its own scratch cert_dir — everything
    # else (router names/rules/entryPoints/tls options, services) must match
    # exactly.
    direct_body = File.read(direct[:output_path]).gsub(cert_dir_direct, "CERT_DIR")
    seam_body   = File.read(seam[:output_path]).gsub(cert_dir_seam, "CERT_DIR")
    expect(seam_body).to eq(direct_body)
  end

  it "delegates write_static_config!/backend_url/frontend_url/worker_web_url identically through the seam" do
    expect(Acme::TraefikConfigWriter.backend_url).to eq(Core::IngressConfigWriter.backend_url)
    expect(Acme::TraefikConfigWriter.frontend_url).to eq(Core::IngressConfigWriter.frontend_url)
    expect(Acme::TraefikConfigWriter.worker_web_url).to eq(Core::IngressConfigWriter.worker_web_url)

    direct_static = Acme::TraefikConfigWriter.write_static_config!(
      dynamic_dir: dynamic_dir_direct, output_path: File.join(dynamic_dir_direct, "..", "direct.yaml")
    )
    seam_static = Core::IngressConfigWriter.write_static_config!(
      dynamic_dir: dynamic_dir_seam, output_path: File.join(dynamic_dir_seam, "..", "seam.yaml")
    )
    direct_body = File.read(direct_static).gsub(dynamic_dir_direct, "DYNAMIC_DIR")
    seam_body   = File.read(seam_static).gsub(dynamic_dir_seam, "DYNAMIC_DIR")
    expect(seam_body).to eq(direct_body)
  end
end
