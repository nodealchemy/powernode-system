# frozen_string_literal: true

require "json"
require "openssl"

module System
  # Renders the powernode-provision v1 document: the single JSON shape every
  # provisioning channel carries (USB file, cloud-init/NoCloud/config-drive,
  # provider metadata, PXE pickup). Schema:
  # docs/schemas/powernode-provision-v1.schema.json; guide:
  # docs/PROVISION_DOCUMENT.md; parser: agent/internal/identity/provision.go.
  #
  # The token plaintext is an ARGUMENT at mint time. It is placed in the
  # returned string and nowhere else: never stored, never logged, never part of
  # an error message. Callers own the returned string (and its lifetime).
  #
  # A document is refused (RenderError) without a CA: ca_fingerprint is always
  # required, so there is no "pin-less" document to render.
  class ProvisioningDocument
    VERSION = 1
    DEFAULT_TTL = 1.hour
    CERT_RE = /-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m
    # https, host (DNS name or [IPv6]), optional :port (range checked in code),
    # optional printable path without '?' or '#'. Mirrors agent/internal/identity/provision.go.
    SERVER_RE = %r{\Ahttps://(?:[A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:.]+\])(?::(?<port>[0-9]{1,5}))?(?:/[\x21\x22\x24-\x3e\x40-\x7e]*)?\z}

    class RenderError < StandardError; end

    class << self
      # @param instance [System::NodeInstance]
      # @param key [String] single-use token plaintext (mint-time argument)
      # @param purpose [String] e.g. "disk_image_enroll"
      # @param expires_at [Time] should match the token's expiry
      # @param ca_pem [String, nil] CA chain; defaults to the configured enroll CA
      # @param server [String, nil] https platform URL; defaults to the configured one
      # @param include_ca_pem [Boolean] embed the chain (needed for private CAs)
      # @return [String] JSON document
      def render(instance:, key:, purpose:, expires_at: nil, ca_pem: nil, server: nil,
                 include_ca_pem: true, issued_at: Time.current)
        raise RenderError, "key is required" if key.to_s.empty?
        raise RenderError, "key must be printable and contain no whitespace" unless key.to_s.match?(/\A[\x21-\x7e]{1,512}\z/)
        raise RenderError, "purpose must match [a-z0-9_.-]{1,64}" unless purpose.to_s.match?(/\A[a-z0-9_.-]{1,64}\z/)

        chain = (ca_pem.presence || configured_ca_pem).to_s
        fingerprint = fingerprint_for(chain)
        url = validated_server(server.presence || configured_server)
        expires_at ||= issued_at + DEFAULT_TTL
        raise RenderError, "expires_at must be after issued_at" unless expires_at > issued_at

        doc = {
          "version" => VERSION,
          "server" => url,
          "instance_id" => instance.id.to_s,
          "key" => key.to_s,
          "ca_fingerprint" => fingerprint,
          "issued_at" => issued_at.utc.iso8601,
          "expires_at" => expires_at.utc.iso8601,
          "purpose" => purpose.to_s
        }
        doc["ca_pem"] = certificates(chain).join("\n") + "\n" if include_ca_pem
        JSON.generate(doc)
      end

      # sha256 of the DER of the LAST certificate in the chain (the top-most /
      # trust anchor as configured). Raises RenderError when there is no usable CA.
      def fingerprint_for(chain)
        last = certificates(chain.to_s).last
        raise RenderError, "no CA certificate configured: refusing to render a pin-less document" if last.nil?

        fp = ::Security::CaFingerprint.of_pem(last)
        raise RenderError, "configured CA chain is not parseable: refusing to render" if fp.nil?

        # The agent trusts the pinned certificate as the anchor of the chain it
        # builds, so it MUST be a self-signed CA (a cross-signed or leaf cert
        # can never be matched by the agent's chain building).
        raise RenderError, "the last certificate of the CA chain must be a self-signed CA (bundle is ordered anchor-last)" unless self_signed_ca?(last)

        fp
      end

      def configured_ca_pem
        ::SiteSetting.get(::System::PhysicalEnrollmentService::ENROLL_CA_SETTING).presence ||
          ENV["POWERNODE_ENROLL_CA_PEM"].presence
      end

      private

      def configured_server
        ::System::PhysicalEnrollmentService.platform_url
      end

      def self_signed_ca?(pem)
        cert = ::OpenSSL::X509::Certificate.new(pem)
        bc = cert.extensions.find { |e| e.oid == "basicConstraints" }
        cert.issuer == cert.subject && bc&.value.to_s.start_with?("CA:TRUE") && cert.verify(cert.public_key)
      rescue ::OpenSSL::X509::CertificateError
        false
      end

      def certificates(chain)
        chain.scan(CERT_RE).map(&:strip)
      end

      # Same rule as the agent (provision.go serverRe) and the JSON Schema.
      def validated_server(url)
        m = SERVER_RE.match(url.to_s)
        raise RenderError, "server must be a plain https URL (host, optional port and path, no credentials, no spaces)" if m.nil? || url.to_s.length > 2048
        raise RenderError, "server port out of range" if m[:port] && !(1..65_535).cover?(m[:port].to_i)

        url.to_s
      end
    end
  end
end
