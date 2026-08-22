# frozen_string_literal: true

require "openssl"
require "ipaddr"
require "socket"
require "securerandom"

module System
  # Issues mTLS certificates for NodeInstances against the platform's
  # internal Certificate Authority. Two adapters:
  #
  # - LocalCaAdapter (test/dev + Vault-less production) : generates an Ed25519
  #   CA on first use and PERSISTS it (root.key 0600, root.crt) under
  #   POWERNODE_CA_LOCAL_DIR so it is stable across process restarts. Selected
  #   when POWERNODE_CA_MODE=local, in non-production, or when Vault is
  #   unconfigured/unavailable (a Vault-less hub mints its own node certs).
  #
  # - VaultCaAdapter (production) : delegates to HashiCorp Vault's PKI
  #   secrets engine via Security::VaultClient. The CA root key never
  #   leaves Vault. Sealing model is whatever the platform's Vault is
  #   configured for (cloud KMS auto-unseal or transit; manual unseals
  #   are explicitly NOT supported per Golden Eclipse Decision 5).
  #
  # Both adapters implement the same surface:
  #   InternalCaService.issue_certificate(csr_pem:, ttl_seconds:, common_name:)
  #     -> { cert_pem:, ca_chain_pem:, serial:, not_before:, not_after: }
  #
  # Reference: Golden Eclipse plan — Security Architecture (Key Custody),
  # M0.N (Vault PKI bootstrap + InternalCaService).
  class InternalCaService
    class CaError < StandardError; end
    class CsrError < CaError; end

    DEFAULT_TTL_SECONDS = 90 * 24 * 3600 # 90 days

    # Fully-qualified audit-action tokens this service emits. Registered
    # into AuditActions.all_actions by the system engine initializer
    # (single source of truth, mirrors
    # System::LifecycleAuditable::AUDITED_ACTIONS).
    AUDITED_ACTIONS = %w[
      system.internal_ca.issue
      system.internal_ca.revoke
    ].freeze

    class << self
      def adapter
        @adapter ||= build_adapter
      end

      # Test seam: lets specs swap the adapter (and reset between examples).
      def adapter=(replacement)
        @adapter = replacement
      end

      def reset!
        @adapter = nil
      end

      # Operator-facing preflight that verifies the configured adapter can
      # actually issue certificates before any caller tries. Returns
      #   { status: :ok | :error, message: String, details: Hash }
      # so operators / bootstrap tooling can fail fast with an actionable
      # error rather than discovering misconfiguration on first issue.
      # See Golden Eclipse plan M0.N + project_vault_pki_state for the
      # production Vault PKI bootstrap context.
      def preflight_check
        adapter.preflight_check
      rescue StandardError => e
        {
          status: :error,
          message: "InternalCaService.preflight_check raised #{e.class}: #{e.message}",
          details: { adapter: adapter.class.name }
        }
      end

      # sans: optional Subject Alternative Names for SERVER certs (e.g. a
      # localhost/overlay serving cert). Go (and modern TLS stacks) require a
      # SAN match — CN alone no longer satisfies verification — so any cert a
      # daemon will verify by hostname/IP must carry them. Node CLIENT certs
      # (CN = instance id) don't need SANs and pass [] (the default).
      def issue_certificate(csr_pem:, ttl_seconds: DEFAULT_TTL_SECONDS, common_name: nil, sans: [])
        result = adapter.issue_certificate(
          csr_pem: csr_pem,
          ttl_seconds: ttl_seconds,
          common_name: common_name,
          sans: sans
        )
        emit_audit_event!(
          event_type: "system.internal_ca.issue",
          serial: result[:serial],
          common_name: common_name,
          ttl_seconds: ttl_seconds
        )
        result
      end

      def ca_chain_pem
        adapter.ca_chain_pem
      end

      # SHA-256 fingerprint of our root — the value an operator should compare
      # when asking "is this the same CA?", and the one federation
      # diagnostics quote. A subject DN cannot answer that question: hubs
      # provisioned before hub-specific subjects all present the identical
      # "CN=Powernode Internal CA (local-dev)" over different keys.
      def ca_fingerprint
        adapter.ca_fingerprint
      end

      # Audit plan P1.4 — surface adapter#revoke through the service. LocalCaAdapter
      # returns a no-op `{ ok: true, mode: "local-noop" }`; VaultCaAdapter actually
      # POSTs to `<pki_int>/revoke`. Audit log entry recorded for both paths.
      def revoke_certificate(serial:)
        raise ArgumentError, "serial is required" if serial.to_s.strip.empty?

        result = adapter.revoke(serial: serial)
        emit_audit_event!(
          event_type: "system.internal_ca.revoke",
          serial: serial,
          common_name: nil,
          ttl_seconds: nil
        )
        result
      end

      # Audit plan P1.4 — parsed OpenSSL::X509::Certificate of the root CA.
      # Distinct from `ca_chain_pem` which returns the PEM string. Callers
      # that need to verify cert chains in Ruby (e.g., NodeCertificate
      # validation) want the parsed form.
      def root_cert
        pem = ca_chain_pem
        OpenSSL::X509::Certificate.new(pem.to_s.lines.take_while { |l| !l.start_with?("-----END") }.join + "-----END CERTIFICATE-----\n")
      rescue OpenSSL::X509::CertificateError => e
        raise CaError, "Could not parse CA root certificate from ca_chain_pem: #{e.message}"
      end

      private

      # Crypto-safety rule: log only the SERIAL + COMMON_NAME + TTL.
      # NEVER include the cert_pem, key, or CSR contents in audit log
      # metadata — they're not needed for audit and risk leaking material.
      def emit_audit_event!(event_type:, serial:, common_name:, ttl_seconds:)
        return unless defined?(::AuditLog)
        ::AuditLog.create!(
          account: audit_account,
          action: event_type,
          resource_type: "InternalCaCertificate",
          resource_id: serial.to_s,
          source: "system",
          metadata: {
            adapter: adapter.class.name,
            common_name: common_name,
            ttl_seconds: ttl_seconds
          }.compact
        )
      rescue StandardError => e
        Rails.logger.warn("[InternalCaService] audit log emit failed: #{e.class}: #{e.message}")
      end

      # InternalCaService is a platform-wide singleton (one CA per install,
      # not per-account), so there's no account to thread through
      # issue_certificate/revoke_certificate — mirrors AuditLog.log_system_event's
      # fallback-account resolution.
      def audit_account
        ::Account.find_by(name: "System") || ::Account.first
      end

      public

      private

      def build_adapter
        mode = ENV["POWERNODE_CA_MODE"].presence || resolve_default_mode
        case mode
        when "vault"
          VaultCaAdapter.new
        when "local"
          LocalCaAdapter.new
        else
          raise CaError, "Unknown POWERNODE_CA_MODE: #{mode.inspect} (expected 'vault' or 'local')"
        end
      end

      # Adapter chosen when POWERNODE_CA_MODE is unset. Non-production keeps the
      # local adapter (no Vault dependency). Production PREFERS Vault, but only
      # when it is genuinely configured + reachable — a Vault-less hub (no Vault
      # deployment) auto-selects the local adapter so it can still mint node
      # mTLS certs from its own on-disk CA instead of 500ing on first issue with
      # a Vault error. An explicit POWERNODE_CA_MODE always overrides this.
      #
      # CAVEAT: vault_usable? is a live probe, so a Vault-BACKED deployment that
      # leaves POWERNODE_CA_MODE unset could transiently flip to the local
      # adapter during a Vault outage (minting certs from a different CA). A
      # deployment committed to Vault should set POWERNODE_CA_MODE=vault
      # EXPLICITLY so an outage surfaces as a clear error rather than a silent
      # CA switch. (A Vault-less hub like ops-hub is unaffected — always local.)
      def resolve_default_mode
        return "local" unless Rails.env.production?

        vault_usable? ? "vault" : "local"
      end

      # Fail-closed Vault probe: ANY inability to confirm a healthy, reachable
      # Vault resolves to "not usable" so we fall back to local rather than
      # raise. Uses the core class-level Security::VaultClient.healthy? (an
      # extension may depend on core security). That predicate is fail-closed
      # once fix/vault-unconfigured-failsafe lands; the rescue keeps an
      # unconfigured-Vault raise on current code resolving to false as well.
      def vault_usable?
        return false unless defined?(::Security::VaultClient)

        ::Security::VaultClient.healthy?
      rescue StandardError => e
        Rails.logger.warn("[InternalCaService] Vault probe failed; defaulting to local CA: #{e.class}: #{e.message}") if defined?(Rails)
        false
      end
    end

    # ----------------------------------------------------------------------
    # Local CA adapter (on-disk persisted; test/dev + Vault-less production)
    # ----------------------------------------------------------------------
    class LocalCaAdapter
      attr_reader :ca_cert, :ca_key

      # On-disk persistence path. Without persistence, each rails-runner /
      # rails-server / rake-task process generates its own CA — so a cert
      # minted in one process can't be verified by a Traefik that loaded
      # the CA from a different process. Persistence makes the local CA
      # behave like a real CA: stable across process restarts. Operator-
      # overridable via POWERNODE_CA_LOCAL_DIR. Default lives under the
      # platform's storage tree so it's not lost on /tmp cleanup.
      DEFAULT_PERSIST_DIR = "/var/lib/powernode/internal-ca"

      # Subject components for a NEWLY generated root. The old value —
      # "/CN=Powernode Internal CA (local-dev)" — was both hub-agnostic AND
      # misleading on deployed hubs (the local adapter is the normal posture
      # for any Vault-less hub, not a dev-only fallback).
      CA_SUBJECT_ORG       = "Powernode"
      CA_SUBJECT_CN_PREFIX = "Powernode Internal CA"

      def initialize
        @persist_dir = ENV.fetch("POWERNODE_CA_LOCAL_DIR", DEFAULT_PERSIST_DIR)
        load_or_create_root
      end

      # An EXISTING persisted root is loaded verbatim and never rewritten —
      # not its subject, not its extensions, not one byte. Every worker,
      # agent, node and federation cert on a running hub chains to it, so
      # re-minting it (e.g. to adopt the hub-specific subject below) would
      # de-authenticate the whole fleet on every /api/v1/internal route.
      # Adopting a new subject on an already-provisioned hub is a deliberate
      # CA ROTATION — new key, trust-bundle overlap window, re-issue of every
      # leaf — and is explicitly NOT what this method does.
      #
      # A HALF-PRESENT pair fails closed. The generate branch below writes
      # BOTH files unconditionally, so reaching it with one of the two still
      # on disk would overwrite the survivor — destroying the live root (or
      # its key) exactly as a subject rewrite would. A directory holding one
      # half of a CA is a damaged restore, never a "please mint a fresh root"
      # signal, so refuse and make an operator look at it.
      def load_or_create_root
        key_path  = File.join(@persist_dir, "root.key")
        cert_path = File.join(@persist_dir, "root.crt")
        key_present  = File.exist?(key_path)
        cert_present = File.exist?(cert_path)

        if key_present && cert_present
          @ca_key  = OpenSSL::PKey.read(File.read(key_path))
          @ca_cert = OpenSSL::X509::Certificate.new(File.read(cert_path))
          return
        end

        if key_present || cert_present
          present, missing = key_present ? [ key_path, cert_path ] : [ cert_path, key_path ]
          raise CaError,
                "refusing to generate a new internal CA: #{present} exists but #{missing} is missing. " \
                "Generating would overwrite the surviving half of an existing CA and de-authenticate " \
                "every certificate chained to it. Restore the missing file, or move the whole " \
                "directory aside deliberately if a NEW CA is genuinely intended."
        end

        @ca_key  = OpenSSL::PKey.generate_key("ED25519")
        @ca_cert = build_self_signed_root(@ca_key)
        begin
          FileUtils.mkdir_p(@persist_dir, mode: 0o700)
          File.write(key_path,  @ca_key.private_to_pem, mode: "w", perm: 0o600)
          File.write(cert_path, @ca_cert.to_pem,         mode: "w", perm: 0o644)
        rescue StandardError => e
          # Persistence is best-effort — if /var/lib/powernode isn't
          # writable (e.g. unprivileged test env), keep the in-memory CA
          # so the process still works. Cross-process verification will
          # break until persistence is fixed.
          Rails.logger.warn("[LocalCaAdapter] CA persistence failed: #{e.class}: #{e.message}") if defined?(Rails)
        end
      end

      def issue_certificate(csr_pem:, ttl_seconds:, common_name: nil, sans: [])
        csr = begin
          OpenSSL::X509::Request.new(csr_pem)
        rescue OpenSSL::X509::RequestError, ArgumentError, TypeError => e
          raise CsrError, "malformed CSR PEM: #{e.message}"
        end
        raise CsrError, "CSR signature invalid" unless csr.verify(csr.public_key)

        cert = OpenSSL::X509::Certificate.new
        cert.serial = SecureRandom.random_number(2**127)
        cert.version = 2
        cert.not_before = Time.current
        cert.not_after  = Time.current + ttl_seconds
        cert.public_key = csr.public_key
        cert.subject    = subject_for(csr, common_name: common_name)
        cert.issuer     = ca_cert.subject

        ef = OpenSSL::X509::ExtensionFactory.new(ca_cert, cert)
        cert.add_extension(ef.create_extension("basicConstraints", "CA:FALSE", true))
        cert.add_extension(ef.create_extension("keyUsage", "digitalSignature, keyEncipherment", true))
        # clientAuth: node calls the platform + peers. serverAuth: node also
        # ACCEPTS inbound agent-to-agent (A2A) MCP calls (substrate L2.5), where
        # it presents this same cert as its TLS server cert. (The Vault PKI role
        # used in prod needs server_flag=true for the same reason.)
        cert.add_extension(ef.create_extension("extendedKeyUsage", "clientAuth, serverAuth", false))
        cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
        san_value = san_extension_value(sans)
        cert.add_extension(ef.create_extension("subjectAltName", san_value, false)) if san_value
        cert.sign(ca_key, nil) # Ed25519 — no digest (must be nil)

        {
          cert_pem: cert.to_pem,
          ca_chain_pem: ca_cert.to_pem,
          serial: cert.serial.to_s(16),
          not_before: cert.not_before,
          not_after:  cert.not_after,
          subject:    cert.subject.to_s
        }
      end

      def ca_chain_pem
        ca_cert.to_pem
      end

      # THE identity of this CA. The subject is a label the CA names itself;
      # only the fingerprint distinguishes two roots (and every hub
      # provisioned before hub-specific subjects landed still shares one DN
      # with every other such hub).
      def ca_fingerprint
        ::Security::CaFingerprint.of(ca_cert)
      end

      def preflight_check
        {
          status: :ok,
          message: "LocalCaAdapter active. On-disk CA persisted at #{@persist_dir}.",
          details: {
            adapter: "local",
            persist_dir: @persist_dir,
            subject: ca_cert.subject.to_s,
            fingerprint: ca_fingerprint,
            not_after: ca_cert.not_after.iso8601
          }
        }
      end

      # No-op revocation for the in-memory adapter. The local CA has no
      # CRL/OCSP responder — issued certs simply remain valid until their
      # not_after. Returns a structured result for parity with VaultCaAdapter.
      def revoke(serial:)
        { ok: true, mode: "local-noop", serial: serial }
      end

      private

      def build_self_signed_root(key)
        cert = OpenSSL::X509::Certificate.new
        cert.serial = 1
        cert.version = 2
        cert.not_before = Time.current
        cert.not_after  = Time.current + (10 * 365 * 24 * 3600) # 10 years
        cert.public_key = key
        cert.subject    = new_root_subject
        cert.issuer     = cert.subject # self-signed

        ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
        cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
        cert.add_extension(ef.create_extension("keyUsage", "keyCertSign, cRLSign", true))
        cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
        cert.sign(key, nil)
        cert
      end

      # Subject stamped on a NEWLY GENERATED root. Never applied to a root
      # already on disk — load_or_create_root returns an existing root
      # untouched, because rewriting a live CA's subject invalidates every
      # worker/agent/node cert chaining to it (see the class comment).
      #
      # Every hub used to mint "/CN=Powernode Internal CA (local-dev)", so
      # separately-generated roots were indistinguishable BY NAME while having
      # different keys. That is not cosmetic: OpenSSL resolves a leaf's issuer
      # by subject DN, so two same-named roots in one federated client-auth
      # bundle collide and the second one's leaves are rejected outright.
      # A hub-specific subject makes the collision structurally impossible for
      # new CAs; Security::CaFingerprint remains the identity of record.
      def new_root_subject
        OpenSSL::X509::Name.new(
          [ [ "O",  CA_SUBJECT_ORG,                                  OpenSSL::ASN1::UTF8STRING ],
            [ "OU", ca_instance_token,                               OpenSSL::ASN1::UTF8STRING ],
            [ "CN", "#{CA_SUBJECT_CN_PREFIX} #{ca_host_identity}",   OpenSSL::ASN1::UTF8STRING ] ]
        )
      end

      # The hub's own name, as peers address it. Deliberately drawn from
      # process-level sources ONLY: the local CA is generated lazily on first
      # `InternalCaService.adapter` — which happens from rake tasks, the
      # reverse-proxy writer and boot-time config paths — so a DB-backed
      # identifier is not dependably reachable that early. Specifically NOT
      # used, and why:
      #   - NodeInstance id: a hub has no "self" NodeInstance row; the closest
      #     thing (SiteSetting system.self_hosting_node_id) is DB-backed AND
      #     unset by default (SelfManagementFence's inert default).
      #   - Account id: the CA is a platform-wide singleton, not per-account
      #     (see #audit_account) — there is no one account to name.
      # POWERNODE_INGRESS_HOST is the same value Core::IngressConfigWriter
      # already treats as this hub's identity, so the CA name matches the name
      # peers reach us by.
      def ca_host_identity
        raw = ENV["POWERNODE_CA_SUBJECT_HOST"].presence ||
              ENV["POWERNODE_INGRESS_HOST"].presence ||
              hostname ||
              "unidentified-hub"
        sanitize_dn_value(raw)
      end

      # Minted once, at generation, and frozen into the persisted root. Two
      # hubs that genuinely share a hostname (a cloned image, an unset
      # POWERNODE_INGRESS_HOST) would otherwise still collide; this guarantees
      # distinctness without needing any external identifier to be correct.
      def ca_instance_token
        @ca_instance_token ||= SecureRandom.uuid
      end

      def hostname
        Socket.gethostname.presence
      rescue StandardError
        nil
      end

      # A DN travels into logs, TLS acceptable-CA lists and forwarded headers,
      # so keep it to characters that survive all of them, and inside X.509's
      # 64-char upper bound for a CN (prefix included).
      def sanitize_dn_value(raw)
        cleaned = raw.to_s.scrub("-").strip.gsub(/[^A-Za-z0-9._:-]+/, "-").gsub(/\A-+|-+\z/, "")
        cleaned = "unidentified-hub" if cleaned.empty?
        cleaned[0, 64 - CA_SUBJECT_CN_PREFIX.length - 1]
      end

      def subject_for(csr, common_name:)
        return csr.subject unless common_name

        OpenSSL::X509::Name.parse("/CN=#{common_name}")
      end

      # Build an OpenSSL subjectAltName value (e.g. "DNS:localhost,IP:127.0.0.1")
      # from a list of names. Entries that parse as an IP become IP: SANs, the
      # rest DNS:. Returns nil when there are no SANs so the caller skips the
      # extension entirely.
      def san_extension_value(sans)
        entries = Array(sans).map(&:to_s).map(&:strip).reject(&:empty?).uniq
        return nil if entries.empty?

        entries.map { |name| ip_literal?(name) ? "IP:#{name}" : "DNS:#{name}" }.join(",")
      end

      def ip_literal?(name)
        IPAddr.new(name)
        true
      rescue IPAddr::InvalidAddressError, ArgumentError
        false
      end
    end

    # ----------------------------------------------------------------------
    # Vault PKI adapter (production)
    # ----------------------------------------------------------------------
    class VaultCaAdapter
      DEFAULT_PKI_MOUNT = "pki_int"
      DEFAULT_ROLE      = "node"

      # Audit plan P1.4 — accepts an optional pki_client kwarg so smoke
      # tests can inject a Security::VaultPkiClient pointing at a dev
      # vault without authenticating through Security::VaultClient's
      # AppRole login flow. Production callers leave it nil and get the
      # default client (which reads VAULT_ADDR + VAULT_TOKEN from env).
      def initialize(mount: nil, role: nil, pki_client: nil)
        @mount = mount || ENV.fetch("POWERNODE_PKI_MOUNT", DEFAULT_PKI_MOUNT)
        @role  = role  || ENV.fetch("POWERNODE_PKI_ROLE", DEFAULT_ROLE)
        @pki   = pki_client || ::Security::VaultPkiClient.new(mount: @mount, role: @role)
      end

      def issue_certificate(csr_pem:, ttl_seconds:, common_name: nil, sans: [])
        data = @pki.sign(csr_pem: csr_pem, ttl_seconds: ttl_seconds, common_name: common_name, sans: sans)

        # ca_chain_pem can be either a single ca cert or full chain;
        # join multi-element chains into one PEM stream for callers.
        chain_pems = Array(data[:ca_chain])
        chain_pems << data[:issuing_ca] if chain_pems.empty? && data[:issuing_ca]

        {
          cert_pem:     data[:certificate],
          ca_chain_pem: chain_pems.compact.join("\n"),
          serial:       data[:serial_number],
          not_before:   nil, # Vault doesn't return — caller parses the PEM if needed
          not_after:    data[:expiration] ? Time.at(data[:expiration].to_i) : nil,
          subject:      common_name
        }
      rescue ::Security::VaultPkiClient::PkiError => e
        raise CaError, "Vault PKI sign failed: #{e.message}"
      end

      def ca_chain_pem
        @pki.root_certificate_pem
      rescue ::Security::VaultPkiClient::PkiError => e
        raise CaError, "Vault PKI ca_chain fetch failed: #{e.message}"
      end

      # Parity with LocalCaAdapter#ca_fingerprint so callers never have to ask
      # which adapter is live before they can identify the CA.
      def ca_fingerprint
        ::Security::CaFingerprint.of_pem(ca_chain_pem)
      end

      # Audit plan P1.4 — revoke a previously-issued cert by serial.
      # Returns the revocation_time epoch + RFC3339 form per Vault response.
      # Idempotent: revoking an already-revoked serial returns the original
      # revocation_time without erroring.
      def revoke(serial:)
        result = @pki.revoke(serial_number: serial)
        { ok: true,
          serial: serial,
          revocation_time: result[:revocation_time],
          revocation_time_rfc3339: result[:revocation_time_rfc3339] }
      rescue ::Security::VaultPkiClient::PkiError => e
        raise CaError, "Vault PKI revoke failed: #{e.message}"
      end

      # Probes the configured PKI role to verify Vault is reachable AND
      # the PKI engine is mounted AND the issuing role exists. Specific
      # error classes drive specific operator messaging so failure mode
      # (network vs mount vs role) is visible without enabling debug logs.
      def preflight_check
        @pki.role_config
        {
          status: :ok,
          message: "VaultCaAdapter active. PKI mount '#{@mount}' role '#{@role}' is reachable.",
          details: { adapter: "vault", mount: @mount, role: @role }
        }
      rescue ::Security::VaultPkiClient::PkiError => e
        {
          status: :error,
          message: "Vault PKI preflight failed: #{e.message}. " \
                   "Bootstrap the PKI engine + role, or override via " \
                   "POWERNODE_PKI_MOUNT / POWERNODE_PKI_ROLE. " \
                   "To run without Vault, set POWERNODE_CA_MODE=local.",
          details: { adapter: "vault", mount: @mount, role: @role }
        }
      end
    end
  end
end
