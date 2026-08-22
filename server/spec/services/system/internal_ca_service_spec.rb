# frozen_string_literal: true

require "rails_helper"
require "openssl"

# Golden Eclipse M0.N — InternalCaService (LocalCaAdapter test path).
# VaultCaAdapter is exercised against a real Vault deployment in integration
# tests; these unit specs cover the local-CA happy path + error cases.
RSpec.describe System::InternalCaService do
  before { described_class.reset! }
  after  { described_class.reset! }

  let(:keypair) { OpenSSL::PKey.generate_key("ED25519") }
  let(:csr_pem) do
    csr = OpenSSL::X509::Request.new
    csr.version = 0
    csr.subject = OpenSSL::X509::Name.parse("/CN=test-instance-uuid")
    csr.public_key = keypair
    csr.sign(keypair, nil)
    csr.to_pem
  end

  describe ".issue_certificate (local adapter)" do
    it "issues a leaf cert signed by the in-memory CA" do
      result = described_class.issue_certificate(
        csr_pem: csr_pem, ttl_seconds: 3600, common_name: "test-instance-uuid"
      )

      expect(result[:cert_pem]).to include("BEGIN CERTIFICATE")
      expect(result[:ca_chain_pem]).to include("BEGIN CERTIFICATE")
      expect(result[:serial]).to be_present
      expect(result[:not_before]).to be_within(60.seconds).of(Time.current)
      expect(result[:not_after]).to be_within(60.seconds).of(1.hour.from_now)
    end

    it "issued cert verifies against the CA chain" do
      result = described_class.issue_certificate(
        csr_pem: csr_pem, ttl_seconds: 3600, common_name: "test"
      )
      cert = OpenSSL::X509::Certificate.new(result[:cert_pem])
      ca   = OpenSSL::X509::Certificate.new(result[:ca_chain_pem])
      expect(cert.verify(ca.public_key)).to be true
    end

    it "adds a subjectAltName extension (DNS + IP) when sans are supplied" do
      result = described_class.issue_certificate(
        csr_pem: csr_pem, ttl_seconds: 3600, common_name: "localhost",
        sans: [ "localhost", "127.0.0.1" ]
      )
      cert = OpenSSL::X509::Certificate.new(result[:cert_pem])
      san  = cert.extensions.find { |e| e.oid == "subjectAltName" }
      expect(san).to be_present
      expect(san.value).to include("DNS:localhost")
      expect(san.value).to include("IP Address:127.0.0.1")
    end

    it "omits subjectAltName when no sans are supplied (client certs stay SAN-free)" do
      result = described_class.issue_certificate(
        csr_pem: csr_pem, ttl_seconds: 3600, common_name: "test-instance-uuid"
      )
      cert = OpenSSL::X509::Certificate.new(result[:cert_pem])
      expect(cert.extensions.map(&:oid)).not_to include("subjectAltName")
    end

    it "rejects a malformed CSR PEM" do
      expect {
        described_class.issue_certificate(csr_pem: "this is not a CSR", ttl_seconds: 60)
      }.to raise_error(described_class::CsrError, /malformed CSR/)
    end

    it "rejects a CSR whose signature does not verify against its public_key" do
      # Build a CSR signed by one key, then swap its public_key to a different
      # key — signature no longer verifies.
      other = OpenSSL::PKey.generate_key("ED25519")
      csr = OpenSSL::X509::Request.new(csr_pem)
      csr.public_key = other # invalidates the existing signature
      expect {
        described_class.issue_certificate(csr_pem: csr.to_pem, ttl_seconds: 60)
      }.to raise_error(described_class::CsrError, /signature invalid/)
    end

    it "uses the CN from common_name when supplied" do
      result = described_class.issue_certificate(
        csr_pem: csr_pem, ttl_seconds: 3600, common_name: "override-cn"
      )
      cert = OpenSSL::X509::Certificate.new(result[:cert_pem])
      expect(cert.subject.to_s).to eq("/CN=override-cn")
    end
  end

  describe ".ca_chain_pem" do
    it "returns the same root across calls" do
      first  = described_class.ca_chain_pem
      second = described_class.ca_chain_pem
      expect(first).to eq(second)
      expect(first).to include("BEGIN CERTIFICATE")
    end
  end

  describe "adapter selection" do
    it "uses LocalCaAdapter in test environment by default" do
      expect(described_class.adapter).to be_a(described_class::LocalCaAdapter)
    end

    it "honors an explicit POWERNODE_CA_MODE=local override" do
      stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_MODE" => "local"))
      described_class.reset!
      expect(described_class.adapter).to be_a(described_class::LocalCaAdapter)
    end

    it "raises on an unknown mode" do
      stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_MODE" => "wat"))
      described_class.reset!
      expect { described_class.adapter }.to raise_error(described_class::CaError, /Unknown POWERNODE_CA_MODE/)
    end

    context "in production with POWERNODE_CA_MODE unset (Vault-less auto-detect)" do
      before do
        stub_const("ENV", ENV.to_h.tap { |h| h.delete("POWERNODE_CA_MODE") })
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        described_class.reset!
      end

      it "falls back to LocalCaAdapter when Vault is unconfigured/unavailable" do
        allow(::Security::VaultClient).to receive(:healthy?).and_return(false)
        expect(described_class.adapter).to be_a(described_class::LocalCaAdapter)
      end

      it "treats a raising Vault probe as unusable and still uses local (fail-closed)" do
        allow(::Security::VaultClient).to receive(:healthy?).and_raise(StandardError, "no VAULT_ADDR")
        expect(described_class.adapter).to be_a(described_class::LocalCaAdapter)
      end

      it "selects VaultCaAdapter when Vault is configured + healthy" do
        allow(::Security::VaultClient).to receive(:healthy?).and_return(true)
        fake = instance_double(described_class::VaultCaAdapter)
        allow(described_class::VaultCaAdapter).to receive(:new).and_return(fake)
        expect(described_class.adapter).to be(fake)
      end

      it "an explicit POWERNODE_CA_MODE=vault still wins over auto-detect" do
        stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_MODE" => "vault"))
        described_class.reset!
        fake = instance_double(described_class::VaultCaAdapter)
        allow(described_class::VaultCaAdapter).to receive(:new).and_return(fake)
        # healthy? must NOT be consulted when the mode is explicit
        expect(::Security::VaultClient).not_to receive(:healthy?)
        expect(described_class.adapter).to be(fake)
      end
    end
  end

  describe "LocalCaAdapter on-disk persistence" do
    it "generates + persists a root (key 0600) on first use, then reloads the SAME root" do
      Dir.mktmpdir do |dir|
        stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_LOCAL_DIR" => dir))
        first = described_class::LocalCaAdapter.new

        key_path  = File.join(dir, "root.key")
        cert_path = File.join(dir, "root.crt")
        expect(File.exist?(key_path)).to be(true)
        expect(File.exist?(cert_path)).to be(true)
        expect(format("%o", File.stat(key_path).mode & 0o777)).to eq("600")

        # A second adapter over the same dir loads the persisted root rather
        # than generating a new one — cross-process stability.
        second = described_class::LocalCaAdapter.new
        expect(second.ca_cert.to_pem).to eq(first.ca_cert.to_pem)
      end
    end

    it "signs a CSR that verifies against the persisted CA root (gen→sign→verify)" do
      Dir.mktmpdir do |dir|
        stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_LOCAL_DIR" => dir))
        adapter = described_class::LocalCaAdapter.new
        result  = adapter.issue_certificate(csr_pem: csr_pem, ttl_seconds: 3600, common_name: "node-x")

        leaf  = OpenSSL::X509::Certificate.new(result[:cert_pem])
        store = OpenSSL::X509::Store.new
        store.add_cert(adapter.ca_cert)
        expect(store.verify(leaf)).to be(true)
      end
    end
  end

  # IMP-01a02b0c — every hub minting the local CA stamped the SAME subject
  # ("/CN=Powernode Internal CA (local-dev)") over a DIFFERENT key, so nothing
  # observable distinguished one hub's root from another's. That is not
  # cosmetic: OpenSSL resolves a leaf's issuer BY SUBJECT DN, so two same-named
  # roots in one federated client-auth bundle collide and only the first is
  # ever tried.
  describe "CA identity (a subject DN is not an identity)" do
    def legacy_subject
      "/CN=Powernode Internal CA (local-dev)"
    end

    # Generate a root exactly the way a separate deployment would: its own
    # persist dir, its own ingress host, no shared state.
    def generate_hub_ca(dir, host)
      stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_LOCAL_DIR" => dir,
                                       "POWERNODE_INGRESS_HOST" => host))
      described_class::LocalCaAdapter.new
    end

    def issue_leaf(adapter, cn)
      key = OpenSSL::PKey.generate_key("ED25519")
      csr = OpenSSL::X509::Request.new
      csr.version    = 0
      csr.subject    = OpenSSL::X509::Name.parse("/CN=#{cn}")
      csr.public_key = key
      csr.sign(key, nil)
      issued = adapter.issue_certificate(csr_pem: csr.to_pem, ttl_seconds: 3600, common_name: cn)
      OpenSSL::X509::Certificate.new(issued[:cert_pem])
    end

    it "gives two independently generated hub CAs different SUBJECTS and different FINGERPRINTS" do
      Dir.mktmpdir do |a_dir|
        Dir.mktmpdir do |b_dir|
          hub_a = generate_hub_ca(a_dir, "ops-hub.example.test")
          hub_b = generate_hub_ca(b_dir, "ops-hub-b.example.test")

          expect(hub_a.ca_cert.subject.to_s).not_to eq(hub_b.ca_cert.subject.to_s)
          expect(hub_a.ca_fingerprint).not_to eq(hub_b.ca_fingerprint)
          expect(hub_a.ca_cert.subject.to_s).to include("ops-hub.example.test")
          expect(hub_b.ca_cert.subject.to_s).to include("ops-hub-b.example.test")

          # A root is also its own issuer — the collision has to be gone from
          # BOTH names, since the acceptable-CA list a peer sees is the issuer.
          expect(hub_a.ca_cert.issuer.to_s).to eq(hub_a.ca_cert.subject.to_s)
          expect(hub_a.ca_cert.issuer.to_s).not_to eq(hub_b.ca_cert.issuer.to_s)

          # "(local-dev)" is a lie on a deployed Vault-less hub, which runs
          # this adapter as its NORMAL posture.
          [ hub_a, hub_b ].each do |hub|
            expect(hub.ca_cert.subject.to_s).not_to include("local-dev")
          end
        end
      end
    end

    it "still distinguishes two hubs that share a hostname (cloned image, unset ingress host)" do
      Dir.mktmpdir do |a_dir|
        Dir.mktmpdir do |b_dir|
          hub_a = generate_hub_ca(a_dir, "powernode-hub")
          hub_b = generate_hub_ca(b_dir, "powernode-hub")

          expect(hub_a.ca_cert.subject.to_s).not_to eq(hub_b.ca_cert.subject.to_s)
          expect(hub_a.ca_fingerprint).not_to eq(hub_b.ca_fingerprint)
        end
      end
    end

    # THE point of the task. Federating two hubs concatenates both roots into
    # one client-auth-bundle.pem; a leaf from EACH must verify, and the result
    # must say which anchor it chained to. With colliding DNs the second hub's
    # leaf is rejected outright ("certificate signature failure") and the
    # verified result cannot name its anchor at all.
    it "verifies a leaf from EACH hub out of one combined bundle, and names the matching anchor" do
      Dir.mktmpdir do |a_dir|
        Dir.mktmpdir do |b_dir|
          hub_a = generate_hub_ca(a_dir, "ops-hub.example.test")
          hub_b = generate_hub_ca(b_dir, "ops-hub-b.example.test")
          leaf_a = issue_leaf(hub_a, "fed:peer-a")
          leaf_b = issue_leaf(hub_b, "fed:peer-b")
          bundle = [ hub_a.ca_chain_pem, hub_b.ca_chain_pem ].join("\n")

          result_a = ::Security::MtlsClientVerifier.verify(cert_pem: leaf_a.to_pem, anchors: [ bundle ])
          result_b = ::Security::MtlsClientVerifier.verify(cert_pem: leaf_b.to_pem, anchors: [ bundle ])

          expect(result_a.verified?).to be(true)
          expect(result_b.verified?).to be(true)
          expect(result_a.subject_cn).to eq("fed:peer-a")
          expect(result_b.subject_cn).to eq("fed:peer-b")

          # WHICH anchor matched — the assertion that could not even be
          # expressed before, because the result carried no anchor identity.
          expect(result_a.anchor_fingerprint).to eq(hub_a.ca_fingerprint)
          expect(result_b.anchor_fingerprint).to eq(hub_b.ca_fingerprint)
          expect(result_a.anchor_fingerprint).not_to eq(result_b.anchor_fingerprint)
        end
      end
    end

    describe "the hub identity stamped into a new subject" do
      def subject_for_env(dir, env)
        stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_LOCAL_DIR" => dir).merge(env))
        described_class::LocalCaAdapter.new.ca_cert.subject.to_s
      end

      it "prefers POWERNODE_CA_SUBJECT_HOST over POWERNODE_INGRESS_HOST" do
        Dir.mktmpdir do |dir|
          subject = subject_for_env(dir, "POWERNODE_CA_SUBJECT_HOST" => "explicit.example.test",
                                         "POWERNODE_INGRESS_HOST"   => "ingress.example.test")
          expect(subject).to include("explicit.example.test")
          expect(subject).not_to include("ingress.example.test")
        end
      end

      it "falls back to the system hostname when neither env var is set" do
        Dir.mktmpdir do |dir|
          env = ENV.to_h
          env.delete("POWERNODE_CA_SUBJECT_HOST")
          env.delete("POWERNODE_INGRESS_HOST")
          stub_const("ENV", env.merge("POWERNODE_CA_LOCAL_DIR" => dir))
          allow(Socket).to receive(:gethostname).and_return("fallback-host")

          expect(described_class::LocalCaAdapter.new.ca_cert.subject.to_s).to include("fallback-host")
        end
      end

      it "still produces a usable subject when no identity is resolvable at all" do
        Dir.mktmpdir do |dir|
          env = ENV.to_h
          env.delete("POWERNODE_CA_SUBJECT_HOST")
          env.delete("POWERNODE_INGRESS_HOST")
          stub_const("ENV", env.merge("POWERNODE_CA_LOCAL_DIR" => dir))
          allow(Socket).to receive(:gethostname).and_return("")

          expect(described_class::LocalCaAdapter.new.ca_cert.subject.to_s).to include("unidentified-hub")
        end
      end

      # X.509 caps a CN at 64 chars and OpenSSL ENFORCES it — one char over
      # and Name#new raises, taking CA generation down.
      it "keeps the CN inside the 64-char X.509 bound for an absurdly long hostname" do
        Dir.mktmpdir do |dir|
          subject = subject_for_env(dir, "POWERNODE_CA_SUBJECT_HOST" => "#{'a' * 200}.example.test")
          cn = OpenSSL::X509::Name.parse(subject).to_a.find { |n, _, _| n == "CN" }[1]
          expect(cn.length).to be <= 64
          expect(cn).to start_with("Powernode Internal CA ")
        end
      end

      it "strips characters that would not survive a log line or a DN" do
        Dir.mktmpdir do |dir|
          subject = subject_for_env(dir, "POWERNODE_CA_SUBJECT_HOST" => "ops hub/CN=evil,O=x")
          cn = OpenSSL::X509::Name.parse(subject).to_a.find { |n, _, _| n == "CN" }[1]
          expect(cn).to eq("Powernode Internal CA ops-hub-CN-evil-O-x")
        end
      end
    end

    # THE FLEET-PROTECTING NEGATIVE. ops-hub is live RIGHT NOW on the legacy
    # DN with worker/agent/node/federation certs chained to it. Adopting the
    # new subject on an existing root would invalidate every one of them —
    # the dev-sentinel over-clear failure class. An existing root must load
    # byte-identical, forever.
    describe "an EXISTING persisted root is loaded untouched" do
      # Writes a root exactly as the pre-change code produced it, so the
      # fixture is a faithful stand-in for what is on ops-hub's disk today.
      def write_legacy_root!(dir)
        key  = OpenSSL::PKey.generate_key("ED25519")
        cert = OpenSSL::X509::Certificate.new
        cert.serial     = 1
        cert.version    = 2
        cert.not_before = Time.current
        cert.not_after  = Time.current + (10 * 365 * 24 * 3600)
        cert.public_key = key
        cert.subject    = OpenSSL::X509::Name.parse(legacy_subject)
        cert.issuer     = cert.subject
        ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
        cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
        cert.add_extension(ef.create_extension("keyUsage", "keyCertSign, cRLSign", true))
        cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
        cert.sign(key, nil)

        File.write(File.join(dir, "root.key"), key.private_to_pem, mode: "w", perm: 0o600)
        File.write(File.join(dir, "root.crt"), cert.to_pem, mode: "w", perm: 0o644)
        cert
      end

      it "leaves the legacy root byte-identical — same bytes on disk, same fingerprint, same subject" do
        Dir.mktmpdir do |dir|
          fixture   = write_legacy_root!(dir)
          cert_path = File.join(dir, "root.crt")
          key_path  = File.join(dir, "root.key")
          cert_bytes_before = File.binread(cert_path)
          key_bytes_before  = File.binread(key_path)

          # A hub identity IS available here — it must simply be ignored for
          # an already-persisted root.
          stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_LOCAL_DIR"  => dir,
                                           "POWERNODE_INGRESS_HOST" => "ops-hub.example.test"))
          adapter = described_class::LocalCaAdapter.new

          expect(File.binread(cert_path)).to eq(cert_bytes_before)
          expect(File.binread(key_path)).to  eq(key_bytes_before)
          expect(adapter.ca_cert.to_der).to eq(fixture.to_der)
          expect(adapter.ca_cert.subject.to_s).to eq(legacy_subject)
          expect(adapter.ca_fingerprint).to eq(::Security::CaFingerprint.of(fixture))
          expect(adapter.ca_cert.subject.to_s).not_to include("ops-hub.example.test")
        end
      end

      # The generate branch writes BOTH files unconditionally, so reaching it
      # with one half still on disk would overwrite the survivor — destroying
      # the live root exactly as a subject rewrite would. A damaged restore
      # must never be mistaken for "please mint a fresh root".
      it "REFUSES to generate when root.crt survives but root.key is gone, leaving the cert intact" do
        Dir.mktmpdir do |dir|
          write_legacy_root!(dir)
          cert_path = File.join(dir, "root.crt")
          cert_bytes_before = File.binread(cert_path)
          File.delete(File.join(dir, "root.key"))

          stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_LOCAL_DIR" => dir))

          expect { described_class::LocalCaAdapter.new }
            .to raise_error(described_class::CaError, /root\.key is missing/)
          expect(File.binread(cert_path)).to eq(cert_bytes_before)
        end
      end

      it "REFUSES to generate when root.key survives but root.crt is gone, leaving the key intact" do
        Dir.mktmpdir do |dir|
          write_legacy_root!(dir)
          key_path = File.join(dir, "root.key")
          key_bytes_before = File.binread(key_path)
          File.delete(File.join(dir, "root.crt"))

          stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_LOCAL_DIR" => dir))

          expect { described_class::LocalCaAdapter.new }
            .to raise_error(described_class::CaError, /root\.crt is missing/)
          expect(File.binread(key_path)).to eq(key_bytes_before)
        end
      end

      it "keeps issuing certs that chain to the LEGACY root (the live fleet keeps authenticating)" do
        Dir.mktmpdir do |dir|
          fixture = write_legacy_root!(dir)
          stub_const("ENV", ENV.to_h.merge("POWERNODE_CA_LOCAL_DIR"  => dir,
                                           "POWERNODE_INGRESS_HOST" => "ops-hub.example.test"))
          adapter = described_class::LocalCaAdapter.new
          leaf    = issue_leaf(adapter, "worker-1")

          result = ::Security::MtlsClientVerifier.verify(cert_pem: leaf.to_pem,
                                                         anchors: [ fixture.to_pem ])
          expect(result.verified?).to be(true)
          expect(result.subject_cn).to eq("worker-1")
          expect(result.anchor_fingerprint).to eq(::Security::CaFingerprint.of(fixture))
        end
      end
    end
  end

  # Regression: emit_audit_event! passed `event_type:` to AuditLog.create!,
  # but the column is `action` — every call raised ActiveRecord::RecordInvalid /
  # NoMethodError, silently swallowed by the surrounding rescue, so no CA
  # issue/revoke event was ever actually recorded to the audit log despite
  # ALL key operations being required to be audited.
  describe "audit logging" do
    before { create(:account, name: "System") }

    it "records an audit log entry with action (not event_type) on issue" do
      expect {
        described_class.issue_certificate(csr_pem: csr_pem, ttl_seconds: 3600, common_name: "test-instance-uuid")
      }.to change(AuditLog, :count).by(1)

      log = AuditLog.last
      expect(log.action).to eq("system.internal_ca.issue")
      expect(log.resource_type).to eq("InternalCaCertificate")
      expect(log.resource_id).to be_present
      expect(log.source).to eq("system")
    end

    it "records an audit log entry on revoke" do
      issued = described_class.issue_certificate(csr_pem: csr_pem, ttl_seconds: 3600, common_name: "test")

      expect {
        described_class.revoke_certificate(serial: issued[:serial])
      }.to change(AuditLog, :count).by(1)

      log = AuditLog.last
      expect(log.action).to eq("system.internal_ca.revoke")
      expect(log.resource_id).to eq(issued[:serial].to_s)
    end

    it "never blocks certificate issuance even if no account can be resolved for the audit row" do
      Account.destroy_all

      result = nil
      expect {
        result = described_class.issue_certificate(csr_pem: csr_pem, ttl_seconds: 3600, common_name: "test")
      }.not_to raise_error

      expect(result[:cert_pem]).to include("BEGIN CERTIFICATE")
    end
  end
end
