# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "yaml"
require "openssl"

RSpec.describe Acme::TraefikConfigWriter, type: :service do
  let(:account) { create(:account) }
  let(:dns_cred) { create(:system_acme_dns_credential, :valid, account: account) }

  let(:tmp_dynamic_dir) { Dir.mktmpdir("traefik-dynamic") }
  let(:tmp_cert_dir)    { Dir.mktmpdir("traefik-certs") }

  after do
    FileUtils.rm_rf(tmp_dynamic_dir) if Dir.exist?(tmp_dynamic_dir)
    FileUtils.rm_rf(tmp_cert_dir)    if Dir.exist?(tmp_cert_dir)
  end

  # A real self-signed cert + matching key, generated once per spec run (not
  # per example — content doesn't need to be unique, only structurally valid).
  # The writer's cert_materialized? guard runs the SAME structural parse
  # (OpenSSL::X509::Certificate.new / OpenSSL::PKey.read) Traefik effectively
  # requires, so a placeholder string like "-----BEGIN CERTIFICATE-----\nfake"
  # would now be (correctly) rejected as invalid — tests that want a cert to
  # actually render must use real PEM material.
  rsa_key = OpenSSL::PKey::RSA.new(2048)
  name = OpenSSL::X509::Name.parse("/CN=traefik-writer-spec")
  x509 = OpenSSL::X509::Certificate.new
  x509.version = 2
  x509.serial = 1
  x509.subject = name
  x509.issuer = name
  x509.public_key = rsa_key
  x509.not_before = Time.now
  x509.not_after = Time.now + 3600
  x509.sign(rsa_key, OpenSSL::Digest.new("SHA256"))
  VALID_CERT_PEM = x509.to_pem
  VALID_KEY_PEM = rsa_key.to_pem

  # Writes real on-disk PEM material for a cert the way Acme::CertificateManager
  # would after issuance. The writer only advertises certs whose on-disk PEM
  # exists, is non-blank, and structurally parses, so examples that expect a
  # cert in tls.certificates must materialize it first. (A `valid` row with
  # missing/blank/invalid PEM is intentionally skipped — see the
  # "empty-cert guard" examples below.)
  def materialize_cert(cert, cert_dir:, cert_pem: VALID_CERT_PEM, key_pem: VALID_KEY_PEM)
    cert_path = described_class.cert_file_path(cert, cert_dir: cert_dir)
    key_path  = described_class.key_file_path(cert, cert_dir: cert_dir)
    FileUtils.mkdir_p(File.dirname(cert_path))
    File.write(cert_path, cert_pem)
    File.write(key_path, key_pem)
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

      before do
        materialize_cert(cert1, cert_dir: tmp_cert_dir)
        materialize_cert(cert2, cert_dir: tmp_cert_dir)
      end

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

      it "skips a valid cert whose on-disk PEM is blank, without dropping its routers" do
        # Production failure mode: a `valid` row whose materialize wrote an
        # empty/garbage .crt. Traefik would otherwise log "failed to find any
        # PEM data in certificate input" on every reload. cert1 is real PEM
        # (from the before hook); overwrite cert2 with a non-PEM stub.
        stub_path = described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir)
        File.write(stub_path, "stub-cert")

        result = described_class.write!(account: account,
                                         dynamic_dir: tmp_dynamic_dir,
                                         cert_dir: tmp_cert_dir)
        parsed = YAML.load_file(result[:output_path])
        cert_files = parsed["tls"]["certificates"].map { |e| e["certFile"] }

        expect(cert_files).to include(described_class.cert_file_path(cert1, cert_dir: tmp_cert_dir))
        expect(cert_files).not_to include(stub_path)
        # cert_count reflects valid DB rows (unchanged); routers stay for BOTH
        # certs so the read-side ingress projection can't drift from the writer.
        expect(result[:cert_count]).to eq(2)
        expect(parsed["http"]["routers"]).not_to be_empty
      end

      # G3 — empty-cert guard hardening. The blank-cert-file case above
      # predates this campaign increment; these examples cover the rest of
      # the failure surface the increment widens the guard to: missing files,
      # blank/whitespace-only content, and content that carries PEM markers
      # but fails to actually parse (a bad entry Traefik can choke on).
      describe "empty-cert guard hardening (G3)" do
        it "skips a valid cert whose cert file is missing entirely" do
          File.delete(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir))

          result = described_class.write!(account: account, dynamic_dir: tmp_dynamic_dir, cert_dir: tmp_cert_dir)
          parsed = YAML.load_file(result[:output_path])
          cert_files = parsed["tls"]["certificates"].map { |e| e["certFile"] }

          expect(cert_files).to include(described_class.cert_file_path(cert1, cert_dir: tmp_cert_dir))
          expect(cert_files).not_to include(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir))
          expect(parsed["http"]["routers"]).not_to be_empty
        end

        it "skips a valid cert whose key file is missing entirely (cert file itself is fine)" do
          File.delete(described_class.key_file_path(cert2, cert_dir: tmp_cert_dir))

          result = described_class.write!(account: account, dynamic_dir: tmp_dynamic_dir, cert_dir: tmp_cert_dir)
          parsed = YAML.load_file(result[:output_path])
          cert_files = parsed["tls"]["certificates"].map { |e| e["certFile"] }

          expect(cert_files).not_to include(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir))
        end

        it "skips a valid cert whose cert file is empty" do
          File.write(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir), "")

          result = described_class.write!(account: account, dynamic_dir: tmp_dynamic_dir, cert_dir: tmp_cert_dir)
          parsed = YAML.load_file(result[:output_path])
          cert_files = parsed["tls"]["certificates"].map { |e| e["certFile"] }

          expect(cert_files).not_to include(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir))
        end

        it "skips a valid cert whose cert file is whitespace-only" do
          File.write(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir), "   \n\t \n")

          result = described_class.write!(account: account, dynamic_dir: tmp_dynamic_dir, cert_dir: tmp_cert_dir)
          parsed = YAML.load_file(result[:output_path])
          cert_files = parsed["tls"]["certificates"].map { |e| e["certFile"] }

          expect(cert_files).not_to include(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir))
        end

        it "skips a valid cert whose key file is empty/whitespace-only (cert file itself is fine)" do
          # A cert with no usable private key can't terminate TLS no matter
          # how good the cert file is — the guard must inspect the key too,
          # not just the cert.
          File.write(described_class.key_file_path(cert2, cert_dir: tmp_cert_dir), "  \n")

          result = described_class.write!(account: account, dynamic_dir: tmp_dynamic_dir, cert_dir: tmp_cert_dir)
          parsed = YAML.load_file(result[:output_path])
          cert_files = parsed["tls"]["certificates"].map { |e| e["certFile"] }

          expect(cert_files).not_to include(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir))
        end

        it "skips a valid cert whose cert PEM has BEGIN/END markers but fails structural parse" do
          # Carries the "-----BEGIN"/"-----END" substrings a naive marker
          # check would accept, but the body is not valid DER — only an
          # actual OpenSSL::X509::Certificate.new parse catches this.
          File.write(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir),
                     "-----BEGIN CERTIFICATE-----\nnot-valid-base64-der!!\n-----END CERTIFICATE-----\n")

          result = described_class.write!(account: account, dynamic_dir: tmp_dynamic_dir, cert_dir: tmp_cert_dir)
          parsed = YAML.load_file(result[:output_path])
          cert_files = parsed["tls"]["certificates"].map { |e| e["certFile"] }

          expect(cert_files).not_to include(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir))
        end

        it "skips a valid cert whose key PEM has BEGIN/END markers but fails structural parse" do
          File.write(described_class.key_file_path(cert2, cert_dir: tmp_cert_dir),
                     "-----BEGIN PRIVATE KEY-----\nnot-valid-base64-der!!\n-----END PRIVATE KEY-----\n")

          result = described_class.write!(account: account, dynamic_dir: tmp_dynamic_dir, cert_dir: tmp_cert_dir)
          parsed = YAML.load_file(result[:output_path])
          cert_files = parsed["tls"]["certificates"].map { |e| e["certFile"] }

          expect(cert_files).not_to include(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir))
        end

        it "a skipped cert does not affect other certs' tls entry, routers, or the shared services section" do
          File.write(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir), "")

          result = described_class.write!(account: account, dynamic_dir: tmp_dynamic_dir, cert_dir: tmp_cert_dir)
          parsed = YAML.load_file(result[:output_path])

          expect(parsed["tls"]["certificates"]).to eq(
            [
              {
                "certFile" => described_class.cert_file_path(cert1, cert_dir: tmp_cert_dir),
                "keyFile"  => described_class.key_file_path(cert1, cert_dir: tmp_cert_dir),
                "stores"   => [ "default" ]
              }
            ]
          )
          # both certs still get their full router set — skip is cert-entry-only.
          slug1 = described_class.router_slug_for(cert1.common_name)
          slug2 = described_class.router_slug_for(cert2.common_name)
          expect(parsed["http"]["routers"].keys).to include("#{slug1}-frontend", "#{slug2}-frontend")
          expect(parsed["http"]["services"].keys)
            .to contain_exactly("powernode-backend", "powernode-frontend", "powernode-worker-web")
        end

        it "logs a warning identifying the skipped cert id and the reason" do
          File.write(described_class.cert_file_path(cert2, cert_dir: tmp_cert_dir), "")
          allow(Rails.logger).to receive(:warn)

          described_class.write!(account: account, dynamic_dir: tmp_dynamic_dir, cert_dir: tmp_cert_dir)

          expect(Rails.logger).to have_received(:warn).with(
            satisfy { |msg| msg.include?(cert2.id) && msg.match?(/skip/i) }
          )
        end
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

  # Byte-identical regression pin for the G3 empty-cert guard: a cert with
  # good on-disk PEM must render EXACTLY as it did before the guard existed.
  # Increment 8 (core/extension ingress split) diffs writer output across a
  # refactor, so this fixture must stay byte-stable — it asserts the raw
  # file content, not just a parsed-hash shape, so key ordering is pinned too.
  describe "regression: a well-formed cert renders byte-identically" do
    let(:cert) do
      create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                               common_name: "byte-stable.example.test")
    end

    around do |example|
      original = ENV["POWERNODE_PROXY_EXTRA_HOSTS"]
      ENV.delete("POWERNODE_PROXY_EXTRA_HOSTS")
      example.run
    ensure
      original.nil? ? ENV.delete("POWERNODE_PROXY_EXTRA_HOSTS") : (ENV["POWERNODE_PROXY_EXTRA_HOSTS"] = original)
    end

    it "matches the exact expected YAML byte-for-byte" do
      materialize_cert(cert, cert_dir: tmp_cert_dir)
      allow(::AdminSetting).to receive(:reverse_proxy_url_config).and_return({})

      result = described_class.write!(account: account, dynamic_dir: tmp_dynamic_dir, cert_dir: tmp_cert_dir)
      slug = described_class.router_slug_for(cert.common_name)
      host = "Host(`byte-stable.example.test`)"

      expected = {
        "tls" => {
          "certificates" => [
            {
              "certFile" => described_class.cert_file_path(cert, cert_dir: tmp_cert_dir),
              "keyFile"  => described_class.key_file_path(cert, cert_dir: tmp_cert_dir),
              "stores"   => [ "default" ]
            }
          ]
        },
        "http" => {
          "routers" => {
            "#{slug}-node-api"       => { "rule" => "#{host} && PathPrefix(`/api/v1/system/node_api`)", "service" => "powernode-backend", "entryPoints" => [ "websecure" ], "tls" => { "options" => "mtls-optional@file" } },
            "#{slug}-federation-api" => { "rule" => "#{host} && PathPrefix(`/api/v1/system/federation_api`)", "service" => "powernode-backend", "entryPoints" => [ "websecure" ], "tls" => { "options" => "mtls-optional@file" } },
            "#{slug}-internal-api"   => { "rule" => "#{host} && PathPrefix(`/api/v1/internal`)", "service" => "powernode-backend", "entryPoints" => [ "websecure" ], "tls" => { "options" => "mtls-optional@file" } },
            "#{slug}-worker-api"     => { "rule" => "#{host} && PathPrefix(`/api/v1/system/worker_api`)", "service" => "powernode-backend", "entryPoints" => [ "websecure" ], "tls" => { "options" => "mtls-optional@file" } },
            "#{slug}-worker-auth"    => { "rule" => "#{host} && PathPrefix(`/api/v1/worker_auth`)", "service" => "powernode-backend", "entryPoints" => [ "websecure" ], "tls" => { "options" => "mtls-optional@file" } },
            "#{slug}-api"            => { "rule" => "#{host} && PathPrefix(`/api`)", "service" => "powernode-backend", "entryPoints" => [ "websecure" ], "tls" => { "options" => "mtls-optional@file" } },
            "#{slug}-agent"          => { "rule" => "#{host} && PathPrefix(`/agent`)", "service" => "powernode-backend", "entryPoints" => [ "websecure" ], "tls" => { "options" => "mtls-optional@file" } },
            "#{slug}-cable"          => { "rule" => "#{host} && PathPrefix(`/cable`)", "service" => "powernode-backend", "entryPoints" => [ "websecure" ], "tls" => { "options" => "mtls-optional@file" } },
            "#{slug}-sidekiq"        => { "rule" => "#{host} && PathPrefix(`/sidekiq`)", "service" => "powernode-worker-web", "entryPoints" => [ "websecure" ], "tls" => { "options" => "mtls-optional@file" } },
            "#{slug}-frontend"       => { "rule" => host, "service" => "powernode-frontend", "entryPoints" => [ "websecure" ], "tls" => { "options" => "mtls-optional@file" } }
          },
          "services" => {
            "powernode-backend"    => { "loadBalancer" => { "servers" => [ { "url" => described_class.backend_url } ], "passHostHeader" => true } },
            "powernode-frontend"   => { "loadBalancer" => { "servers" => [ { "url" => described_class.frontend_url } ], "passHostHeader" => true } },
            "powernode-worker-web" => { "loadBalancer" => { "servers" => [ { "url" => described_class.worker_web_url } ], "passHostHeader" => true } }
          }
        }
      }

      expect(File.read(result[:output_path])).to eq(YAML.dump(expected))
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

  # Router host matcher — covers the POWERNODE_PROXY_EXTRA_HOSTS path which
  # is critical for deployments behind an external proxy that preserves the
  # public Host header upstream (Traefik v3 rejects multi-arg Host() so
  # this needs the OR'd form, not the v2 comma form).
  describe "router rule with POWERNODE_PROXY_EXTRA_HOSTS" do
    let(:cert) do
      create(:system_acme_certificate, :valid,
             account: account, dns_credential: dns_cred,
             common_name: "internal.example.test")
    end

    around do |example|
      original = ENV["POWERNODE_PROXY_EXTRA_HOSTS"]
      example.run
    ensure
      if original.nil?
        ENV.delete("POWERNODE_PROXY_EXTRA_HOSTS")
      else
        ENV["POWERNODE_PROXY_EXTRA_HOSTS"] = original
      end
    end

    it "emits single-host rules when no extras are configured" do
      ENV.delete("POWERNODE_PROXY_EXTRA_HOSTS")
      cert # touch the let block
      result = described_class.write!(account: account,
                                       dynamic_dir: tmp_dynamic_dir,
                                       cert_dir: tmp_cert_dir)
      parsed = YAML.load_file(result[:output_path])
      rules = parsed["http"]["routers"].values.map { |r| r["rule"] }
      expect(rules).to all(include("Host(`internal.example.test`)"))
      expect(rules).to all(satisfy { |r| !r.include?("||") })
    end

    it "emits OR'd Host() matchers (v3 syntax) when extras are configured" do
      ENV["POWERNODE_PROXY_EXTRA_HOSTS"] = "public.example.org, alias.example.net"
      cert # touch the let block
      result = described_class.write!(account: account,
                                       dynamic_dir: tmp_dynamic_dir,
                                       cert_dir: tmp_cert_dir)
      parsed = YAML.load_file(result[:output_path])
      frontend_rule = parsed["http"]["routers"].values
                        .find { |r| r["service"] == "powernode-frontend" }["rule"]
      expect(frontend_rule).to eq(
        "(Host(`internal.example.test`) || Host(`public.example.org`) || Host(`alias.example.net`))"
      )

      # The /api router (broader path) — matches /api but NOT /api/v1/system/node_api
      # because the node-api router has a longer-rule auto-priority win.
      api_rule = parsed["http"]["routers"].values
                   .find { |r| r["service"] == "powernode-backend" && r["rule"].end_with?("&& PathPrefix(`/api`)") }["rule"]
      # Parentheses are load-bearing — without them, && PathPrefix would
      # bind only to the last Host() call instead of the OR'd group.
      expect(api_rule).to start_with("(Host(")
      expect(api_rule).to end_with("&& PathPrefix(`/api`)")
    end
  end

  # mTLS infrastructure — Stage 1 of the agent-auth mTLS conversion.
  # The shared dynamic config + CA bundle + per-cert node-api router
  # together make BaseController#authenticate_via_mtls! load-bearing.
  describe "mTLS infrastructure" do
    let(:tmp_ca_dir) { Dir.mktmpdir("traefik-ca") }
    after { FileUtils.rm_rf(tmp_ca_dir) if Dir.exist?(tmp_ca_dir) }

    describe ".write_internal_ca!" do
      it "writes the InternalCaService chain to internal-ca.pem" do
        allow(::System::InternalCaService).to receive(:ca_chain_pem)
          .and_return("-----BEGIN CERTIFICATE-----\nMIIfake==\n-----END CERTIFICATE-----\n")
        out = described_class.write_internal_ca!(ca_dir: tmp_ca_dir)
        expect(out).to eq(File.join(tmp_ca_dir, "internal-ca.pem"))
        expect(File.read(out)).to include("-----BEGIN CERTIFICATE-----")
      end

      it "creates the ca_dir if missing (production deploy may run before mkdir)" do
        missing = File.join(tmp_ca_dir, "nested", "deep")
        allow(::System::InternalCaService).to receive(:ca_chain_pem).and_return("X")
        described_class.write_internal_ca!(ca_dir: missing)
        expect(Dir.exist?(missing)).to be true
      end
    end

    describe ".write_mtls_shared_dynamic!" do
      it "points caFiles at the client-auth bundle and forwards the full PEM" do
        out = described_class.write_mtls_shared_dynamic!(dynamic_dir: tmp_dynamic_dir, ca_dir: tmp_ca_dir)
        expect(File.basename(out)).to eq("_mtls.yaml")
        parsed = YAML.load_file(out)
        expect(parsed.dig("tls", "options", "mtls-optional", "clientAuth", "clientAuthType"))
          .to eq("VerifyClientCertIfGiven")
        # caFiles → the bundle (our CA + peer CAs), NOT internal-ca.pem.
        expect(parsed.dig("tls", "options", "mtls-optional", "clientAuth", "caFiles"))
          .to eq([ File.join(tmp_ca_dir, "client-auth-bundle.pem") ])
        mw = parsed.dig("http", "middlewares", "pass-tls-client-cert", "passTLSClientCert")
        expect(mw["pem"]).to be true # full cert forwarded for backend re-verify
        expect(mw.dig("info", "subject", "commonName")).to be true
      end

      it "writes the client-auth bundle alongside the option (coupled)" do
        described_class.write_mtls_shared_dynamic!(dynamic_dir: tmp_dynamic_dir, ca_dir: tmp_ca_dir)
        expect(File.exist?(File.join(tmp_ca_dir, "client-auth-bundle.pem"))).to be true
      end

      # Path B (public TLS-carrying TCP, increment 5) needs a REQUIRED-client-cert
      # counterpart to mtls-optional, for Sdwan::Service#client_auth == "required"
      # under edge_mode terminate. Same shared file, same CA bundle — only the
      # clientAuthType differs, following the existing shared-TLS-option pattern.
      it "also emits a mtls-required option (RequireAndVerifyClientCert) sharing the same CA bundle" do
        out = described_class.write_mtls_shared_dynamic!(dynamic_dir: tmp_dynamic_dir, ca_dir: tmp_ca_dir)
        parsed = YAML.load_file(out)
        expect(parsed.dig("tls", "options", "mtls-required", "clientAuth", "clientAuthType"))
          .to eq("RequireAndVerifyClientCert")
        expect(parsed.dig("tls", "options", "mtls-required", "clientAuth", "caFiles"))
          .to eq([ File.join(tmp_ca_dir, "client-auth-bundle.pem") ])
      end
    end

    describe ".write_client_auth_bundle! (two-file split)" do
      it "bundles our CA PLUS reachable peer CAs, while internal-ca.pem stays our-CA-only" do
        allow(::System::InternalCaService).to receive(:ca_chain_pem)
          .and_return("-----BEGIN CERTIFICATE-----\nOURCA\n-----END CERTIFICATE-----\n")
        peer_ca = "-----BEGIN CERTIFICATE-----\nPEERCA\n-----END CERTIFICATE-----\n"
        create(:system_federation_peer, :active, account: account).tap do |p|
          p.update_columns(inbound_subject: "fed:#{p.id}", trusted_ca_pem: peer_ca)
        end

        bundle = described_class.write_client_auth_bundle!(ca_dir: tmp_ca_dir)
        own    = described_class.write_internal_ca!(ca_dir: tmp_ca_dir)

        expect(File.read(bundle)).to include("OURCA").and include("PEERCA")
        # internal-ca.pem (core's anchor) must NOT contain the peer CA.
        expect(File.read(own)).to include("OURCA")
        expect(File.read(own)).not_to include("PEERCA")
      end
    end

    describe "per-cert node-api router" do
      let(:cert) do
        create(:system_acme_certificate, :valid,
               account: account, dns_credential: dns_cred,
               common_name: "ops.example.test")
      end

      it "emits a node-api router on the websecure entrypoint" do
        cert # touch
        result = described_class.write!(account: account,
                                         dynamic_dir: tmp_dynamic_dir,
                                         cert_dir: tmp_cert_dir)
        parsed = YAML.load_file(result[:output_path])
        node_api = parsed["http"]["routers"].values
                     .find { |r| r["rule"].include?("/api/v1/system/node_api") }
        expect(node_api).not_to be_nil
        expect(node_api["service"]).to eq("powernode-backend")
        expect(node_api["entryPoints"]).to eq([ "websecure" ])
        # Optional mTLS is applied PER-ROUTER (Traefik binds clientAuth options
        # by HostSNI; an entrypoint-level option is ignored). Every router uses
        # the same mtls-optional@file option, so there is no per-SNI conflict.
        expect(node_api.dig("tls", "options")).to eq("mtls-optional@file")
      end

      it "emits ten routers per cert (node-api + federation-api + internal-api + worker-api + worker-auth + api + agent + cable + sidekiq + frontend)" do
        cert
        result = described_class.write!(account: account,
                                         dynamic_dir: tmp_dynamic_dir,
                                         cert_dir: tmp_cert_dir)
        parsed = YAML.load_file(result[:output_path])
        keys = parsed["http"]["routers"].keys
        expect(keys.size).to eq(10)
        # cert-bearing API routers (CN enforced per-route in the backend)
        expect(keys).to include(satisfy { |k| k.end_with?("-node-api") })
        expect(keys).to include(satisfy { |k| k.end_with?("-federation-api") })
        expect(keys).to include(satisfy { |k| k.end_with?("-internal-api") })
        expect(keys).to include(satisfy { |k| k.end_with?("-worker-api") })
        expect(keys).to include(satisfy { |k| k.end_with?("-worker-auth") })
        # the dedicated cable-mtls router is gone — the single -cable router
        # below handles both worker-CN and user-JWT auth.
        expect(keys).not_to include(satisfy { |k| k.end_with?("-cable-mtls") })
        # public / dual-auth routers
        expect(keys).to include(satisfy { |k| k.end_with?("-agent") })
        expect(keys).to include(satisfy { |k| k.end_with?("-cable") })
        expect(keys).to include(satisfy { |k| k.end_with?("-sidekiq") })
        expect(keys).to include(satisfy { |k| k.end_with?("-frontend") })
        # the bare -api router (not one of the longer -*-api suffixes)
        expect(keys).to include(satisfy { |k|
          k.end_with?("-api") &&
            %w[-node-api -federation-api -internal-api -worker-api].none? { |suf| k.end_with?(suf) }
        })
      end

      it "places every router on the single websecure entrypoint" do
        cert
        result = described_class.write!(account: account,
                                         dynamic_dir: tmp_dynamic_dir,
                                         cert_dir: tmp_cert_dir)
        parsed = YAML.load_file(result[:output_path])
        routers = parsed["http"]["routers"].values
        expect(routers.size).to eq(10)
        expect(routers).to all(satisfy { |r| r["entryPoints"] == [ "websecure" ] })
        # No router should declare the retired websecure-mtls entrypoint.
        expect(routers).not_to include(satisfy { |r| r["entryPoints"].to_a.include?("websecure-mtls") })
      end

      it "emits a federation-api router on the websecure entrypoint" do
        cert
        result = described_class.write!(account: account,
                                         dynamic_dir: tmp_dynamic_dir,
                                         cert_dir: tmp_cert_dir)
        parsed = YAML.load_file(result[:output_path])
        fed_api = parsed["http"]["routers"].values
                    .find { |r| r["rule"].include?("/api/v1/system/federation_api") }
        expect(fed_api).not_to be_nil
        expect(fed_api["service"]).to eq("powernode-backend")
        expect(fed_api["entryPoints"]).to eq([ "websecure" ])
      end

      it "routes /sidekiq to the worker-web service (Sidekiq dashboard)" do
        cert
        result = described_class.write!(account: account,
                                         dynamic_dir: tmp_dynamic_dir,
                                         cert_dir: tmp_cert_dir)
        parsed = YAML.load_file(result[:output_path])
        sidekiq = parsed["http"]["routers"].values
                    .find { |r| r["rule"].include?("PathPrefix(`/sidekiq`)") }
        expect(sidekiq).not_to be_nil
        expect(sidekiq["service"]).to eq("powernode-worker-web")
        expect(sidekiq["entryPoints"]).to eq([ "websecure" ])
        # worker-web upstream is wired into services (defaults to :4567)
        url = parsed.dig("http", "services", "powernode-worker-web", "loadBalancer", "servers", 0, "url")
        expect(url).to eq("http://127.0.0.1:4567")
      end
    end
  end

  describe ".trusted_proxy_hosts (manage-proxy-hosts.sh -> Traefik integration)" do
    around do |example|
      original = ENV["POWERNODE_PROXY_EXTRA_HOSTS"]
      ENV.delete("POWERNODE_PROXY_EXTRA_HOSTS")
      example.run
    ensure
      original.nil? ? ENV.delete("POWERNODE_PROXY_EXTRA_HOSTS") : (ENV["POWERNODE_PROXY_EXTRA_HOSTS"] = original)
    end

    it "extracts literal hosts from the allowlist (strips ports, drops wildcards + localhost family)" do
      allow(::AdminSetting).to receive(:reverse_proxy_url_config).and_return(
        trusted_hosts: [ "dev.ipnode.us", "api.example.com:8443", "*.wild.example", "localhost", "127.0.0.1", "::1", "10.0.0.5" ]
      )
      expect(described_class.trusted_proxy_hosts).to contain_exactly("dev.ipnode.us", "api.example.com", "10.0.0.5")
    end

    it "merges allowlist hosts into extra_hosts" do
      allow(::AdminSetting).to receive(:reverse_proxy_url_config).and_return(trusted_hosts: [ "dev.ipnode.us" ])
      expect(described_class.extra_hosts).to include("dev.ipnode.us")
    end

    it "routes an allowlisted host through the bundled proxy (Host OR-group includes it)" do
      allow(::AdminSetting).to receive(:reverse_proxy_url_config).and_return(trusted_hosts: [ "dev.ipnode.us" ])
      create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                               common_name: "ops.example.test")
      result = described_class.write!(account: account, dynamic_dir: tmp_dynamic_dir, cert_dir: tmp_cert_dir)
      parsed = YAML.load_file(result[:output_path])
      frontend_rule = parsed["http"]["routers"].values
                        .find { |r| r["service"] == "powernode-frontend" }["rule"]
      expect(frontend_rule).to include("Host(`dev.ipnode.us`)")
      expect(frontend_rule).to include("Host(`ops.example.test`)")
    end

    it "is resilient (returns []) when AdminSetting is unavailable" do
      allow(::AdminSetting).to receive(:reverse_proxy_url_config)
        .and_raise(ActiveRecord::StatementInvalid.new("relation missing"))
      expect(described_class.trusted_proxy_hosts).to eq([])
      expect { described_class.extra_hosts }.not_to raise_error
    end
  end
end
