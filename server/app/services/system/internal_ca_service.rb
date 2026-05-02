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

      def issue_certificate(csr_pem:, ttl_seconds: DEFAULT_TTL_SECONDS, common_name: nil)
        adapter.issue_certificate(
          csr_pem: csr_pem,
          ttl_seconds: ttl_seconds,
          common_name: common_name
        )
      end

      def ca_chain_pem
        adapter.ca_chain_pem
      end

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

      def initialize(mount: nil, role: nil)
        @mount = mount || ENV.fetch("POWERNODE_PKI_MOUNT", DEFAULT_PKI_MOUNT)
        @role  = role  || ENV.fetch("POWERNODE_PKI_ROLE", DEFAULT_ROLE)
        @vault = ::Security::VaultClient.new
      end

      def issue_certificate(csr_pem:, ttl_seconds:, common_name: nil)
        params = {
          csr: csr_pem,
          ttl: "#{ttl_seconds}s",
          format: "pem"
        }
        params[:common_name] = common_name if common_name

        path = "#{@mount}/sign/#{@role}"
        result = @vault.write_secret(path, params)
        # The vault gem returns a Vault::Secret — extract the data hash.
        data = result.respond_to?(:data) ? result.data : result

        {
          cert_pem:     data[:certificate]    || data["certificate"],
          ca_chain_pem: data[:ca_chain]       || data["ca_chain"] || data[:issuing_ca] || data["issuing_ca"],
          serial:       data[:serial_number]  || data["serial_number"],
          not_before:   nil, # Vault doesn't always return — caller can parse cert
          not_after:    nil,
          subject:      common_name
        }
      rescue ::Security::VaultClient::VaultError => e
        raise CaError, "Vault PKI sign failed: #{e.message}"
      end

      def ca_chain_pem
        path = "#{@mount}/ca/pem"
        result = @vault.read_secret(path)
        result.is_a?(String) ? result : result.to_s
      rescue ::Security::VaultClient::VaultError => e
        raise CaError, "Vault PKI ca_chain fetch failed: #{e.message}"
      end
    end
  end
end
