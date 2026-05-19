# frozen_string_literal: true

require "openssl"

module System
  # Issues mTLS certificates for NodeInstances against the platform's
  # internal Certificate Authority. Two adapters:
  #
  # - LocalCaAdapter (test/dev) : generates an in-memory Ed25519 CA on first
  #   use, caches it per-process. Used when Vault is unavailable or we're in
  #   a test environment.
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

      def issue_certificate(csr_pem:, ttl_seconds: DEFAULT_TTL_SECONDS, common_name: nil)
        result = adapter.issue_certificate(
          csr_pem: csr_pem,
          ttl_seconds: ttl_seconds,
          common_name: common_name
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
          event_type: event_type,
          resource_type: "InternalCaCertificate",
          resource_id: serial.to_s,
          metadata: {
            adapter: adapter.class.name,
            common_name: common_name,
            ttl_seconds: ttl_seconds
          }.compact
        )
      rescue StandardError => e
        Rails.logger.warn("[InternalCaService] audit log emit failed: #{e.class}: #{e.message}")
      end

      public

      private

      def build_adapter
        mode = ENV.fetch("POWERNODE_CA_MODE", default_mode_for_env)
        case mode
        when "vault"
          VaultCaAdapter.new
        when "local"
          LocalCaAdapter.new
        else
          raise CaError, "Unknown POWERNODE_CA_MODE: #{mode.inspect} (expected 'vault' or 'local')"
        end
      end

      def default_mode_for_env
        # Test and dev default to local adapter (no Vault dependency).
        # Staging/production default to vault adapter.
        Rails.env.production? ? "vault" : "local"
      end
    end

    # ----------------------------------------------------------------------
    # Local CA adapter (in-memory, test + dev)
    # ----------------------------------------------------------------------
    class LocalCaAdapter
      attr_reader :ca_cert, :ca_key

      def initialize
        @ca_key = OpenSSL::PKey.generate_key("ED25519")
        @ca_cert = build_self_signed_root(@ca_key)
      end

      def issue_certificate(csr_pem:, ttl_seconds:, common_name: nil)
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
        cert.add_extension(ef.create_extension("extendedKeyUsage", "clientAuth", false))
        cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
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

      def preflight_check
        {
          status: :ok,
          message: "LocalCaAdapter active (dev/test). Ephemeral in-memory CA.",
          details: {
            adapter: "local",
            subject: ca_cert.subject.to_s,
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
        cert.subject    = OpenSSL::X509::Name.parse("/CN=Powernode Internal CA (local-dev)")
        cert.issuer     = cert.subject # self-signed

        ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
        cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
        cert.add_extension(ef.create_extension("keyUsage", "keyCertSign, cRLSign", true))
        cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
        cert.sign(key, nil)
        cert
      end

      def subject_for(csr, common_name:)
        return csr.subject unless common_name

        OpenSSL::X509::Name.parse("/CN=#{common_name}")
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

      def issue_certificate(csr_pem:, ttl_seconds:, common_name: nil)
        data = @pki.sign(csr_pem: csr_pem, ttl_seconds: ttl_seconds, common_name: common_name)

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
