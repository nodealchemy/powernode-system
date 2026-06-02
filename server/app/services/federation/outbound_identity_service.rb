# frozen_string_literal: true

require "openssl"

module Federation
  # Federation mTLS Phase 2 (hierarchical) — the CHILD side of outbound
  # identity.
  #
  # The child generates its OWN keypair (the private key never leaves the
  # child), sends only a CSR to the parent inside the token-authed accept
  # POST, and persists the parent-signed cert as the `outbound_certificate`
  # it presents back on subsequent federation_api calls. The parent forces
  # the real CN (`fed:<peer-id>`) when it signs, so the child cannot choose
  # its own federation identity — see
  # System::Federation::FederationAcceptanceService#sign_federation_csr!.
  #
  # Mirrors the CSR/issue discipline of NodeEnrollmentService and
  # DockerDaemonProvisionerService#issue_client_tls_pair! — one audited path
  # for client identity material, so the Ed25519 footguns (nil digest on
  # sign, private_to_pem) are solved in exactly one place.
  #
  # Cryptographic-safety: the private key is written ONLY to the Vault-backed
  # NodeCertificate.credentials blob. It is never logged, echoed, or returned
  # from #store_issued!.
  class OutboundIdentityService
    # Holds the in-memory keypair + CSR between generation and persistence.
    # `private_key` is an OpenSSL::PKey held by the caller only until
    # #store_issued! seals it into Vault-backed storage.
    Prepared = ::Struct.new(:private_key, :csr_pem, keyword_init: true)

    FEDERATION_CLIENT_CERT_TTL_SECONDS = 90 * 24 * 60 * 60

    class << self
      # Generate an Ed25519 keypair + CSR for the child's federation
      # identity. The CN here is advisory; the parent overrides it at signing
      # time, so a child can never assert another peer's identity.
      def prepare_csr(common_name: "federation-peer")
        key = ::OpenSSL::PKey.generate_key("ED25519")
        csr = ::OpenSSL::X509::Request.new
        csr.version    = 0
        csr.subject    = ::OpenSSL::X509::Name.parse("/CN=#{common_name}")
        csr.public_key = key
        csr.sign(key, nil) # Ed25519 — digest must be nil
        Prepared.new(private_key: key, csr_pem: csr.to_pem)
      end

      # Persist the parent-signed cert + the child's own key as the peer's
      # outbound_certificate (Vault-backed NodeCertificate). The cert is what
      # the child presents when calling this peer's federation_api.
      #
      # Re-enrollment creates a fresh NodeCertificate and repoints the peer;
      # the prior row is left in place so the audit/rotation history survives
      # (same convention as NodeEnrollmentService#refresh!).
      def store_issued!(peer:, cert_pem:, private_key:, ca_chain_pem:)
        leaf = ::OpenSSL::X509::Certificate.new(cert_pem)

        cert = ::System::NodeCertificate.new(
          account_id:     peer.account_id,
          subject_kind:   "federation_peer",
          serial:         leaf.serial.to_s(16),
          subject:        leaf.subject.to_s,
          not_before:     leaf.not_before,
          not_after:      leaf.not_after,
          issuer_subject: leaf.issuer.to_s
        )
        cert.credentials = {
          "cert_pem"        => cert_pem,
          "private_key_pem" => private_key.private_to_pem,
          "ca_chain_pem"    => ca_chain_pem
        }
        cert.save!

        peer.update!(outbound_certificate: cert)
        cert
      end

      # Federation mTLS Phase 2 (SYMMETRIC) — self-issue our outbound cert from
      # OUR OWN CA. Used when neither peer is the other's CA: each side mints
      # the cert it presents, signed by its own CA, with the CN the PEER
      # assigned it during the accept handshake (so the peer resolves us). The
      # peer trusts our CA because we exchanged ca_bundle_pem at accept time.
      #
      # common_name is the inbound_subject the peer told us to present (e.g.
      # "fed:<their-local-peer-id>"). Composes prepare_csr + store_issued! so
      # the key still never leaves this process. Returns the NodeCertificate.
      def self_issue!(peer:, common_name:)
        prepared = prepare_csr(common_name: common_name)
        issued = ::System::InternalCaService.issue_certificate(
          csr_pem: prepared.csr_pem,
          ttl_seconds: FEDERATION_CLIENT_CERT_TTL_SECONDS,
          common_name: common_name
        )
        store_issued!(
          peer: peer,
          cert_pem: issued[:cert_pem],
          private_key: prepared.private_key,
          ca_chain_pem: issued[:ca_chain_pem]
        )
      end
    end
  end
end
