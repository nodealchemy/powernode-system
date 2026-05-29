# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill: provision (issue) a new ACME TLS certificate.
      #
      # Creates a `System::AcmeCertificate` row in `pending` and drives it
      # through issuance via `::Acme::CertificateManager.issue!`. The
      # certificate material (PEM / private key / chain / ACME account key)
      # is written to Vault + on-disk by the manager; this skill returns the
      # row's identifying + lifecycle attributes (including the operator-
      # visible `vault_path_*` labels) so the caller can locate the bundle.
      #
      # Issuance is approval-gated (`requires_approval: true`) — a real ACME
      # transaction reaches out to Let's Encrypt and publishes DNS / HTTP
      # validation records, so an operator (or the autonomy gate) signs off
      # before the skill runs.
      #
      # Plan reference: Decentralized Federation §J + P2.5 (ACME lifecycle).
      class AcmeCertificateProvisionExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "acme_certificate_provision",
          description: "Provision (issue) a new ACME TLS certificate for the platform's public listeners. Creates the certificate record and drives it through issuance via the ACME server (Let's Encrypt by default). Use this skill when the operator asks to obtain a new TLS cert for a hostname — specify the common name, the issuer, and the challenge type (dns-01 needs a DNS provider credential).",
          category: "devops",
          requires_approval: true,
          inputs: {
            common_name: { type: "string", required: true,
                           description: "Primary hostname the cert secures (e.g. ops.example.com)" },
            sans: { type: "array", required: false,
                    description: "Subject Alternative Names — additional hostnames the cert also secures" },
            issuer: { type: "string", required: true,
                      description: "ACME issuer; one of: #{::System::AcmeCertificate::ISSUERS.join(', ')}" },
            challenge_type: { type: "string", required: true,
                              description: "ACME challenge; one of: #{::System::AcmeCertificate::CHALLENGE_TYPES.join(', ')}" },
            dns_credential_id: { type: "string", required: false,
                                 description: "System::AcmeDnsCredential id — REQUIRED when challenge_type is dns-01 (publishes the validation record)" },
            acme_email: { type: "string", required: false,
                          description: "Operator contact email for ACME registration; falls back to platform/account default if omitted" }
          },
          outputs: {
            certificate_id: :string,
            common_name: :string,
            issuer: :string,
            challenge_type: :string,
            status: :string,
            issued_at: :string,
            expires_at: :string,
            vault_path_certificate: :string,
            vault_path_private_key: :string,
            vault_path_chain: :string
          }
        )

        binds_to "Fleet Autonomy", "System Concierge"

        protected

        def perform(common_name:, issuer:, challenge_type:, sans: nil,
                    dns_credential_id: nil, acme_email: nil, **)
          unless ::System::AcmeCertificate::ISSUERS.include?(issuer.to_s)
            return failure("Invalid issuer: #{issuer.inspect}; allowed: #{::System::AcmeCertificate::ISSUERS.inspect}")
          end
          unless ::System::AcmeCertificate::CHALLENGE_TYPES.include?(challenge_type.to_s)
            return failure("Invalid challenge_type: #{challenge_type.inspect}; allowed: #{::System::AcmeCertificate::CHALLENGE_TYPES.inspect}")
          end

          dns_credential = nil
          if challenge_type.to_s == "dns-01"
            return failure("dns_credential_id is required for dns-01 challenge") if dns_credential_id.blank?

            dns_credential = ::System::AcmeDnsCredential.find_by(id: dns_credential_id, account: @account)
            return failure("DNS credential not found: #{dns_credential_id}") unless dns_credential
          end

          metadata = {}
          metadata["acme_email"] = acme_email if acme_email.present?

          cert = ::System::AcmeCertificate.create!(
            account: @account,
            common_name: common_name,
            sans: Array(sans),
            issuer: issuer,
            challenge_type: challenge_type,
            dns_credential: dns_credential,
            status: "pending",
            metadata: metadata
          )

          result = ::Acme::CertificateManager.issue!(certificate: cert)
          cert.reload

          unless result.ok?
            return failure("Certificate issuance failed: #{result.error}")
          end

          success(certificate_attrs(cert))
        rescue ActiveRecord::RecordInvalid => e
          failure("Could not create certificate: #{e.message}")
        rescue StandardError => e
          failure("Certificate issuance error: #{e.message}")
        end

        private

        def certificate_attrs(cert)
          {
            certificate_id: cert.id,
            common_name: cert.common_name,
            issuer: cert.issuer,
            challenge_type: cert.challenge_type,
            status: cert.status,
            issued_at: cert.issued_at&.iso8601,
            expires_at: cert.expires_at&.iso8601,
            vault_path_certificate: cert.vault_path_certificate,
            vault_path_private_key: cert.vault_path_private_key,
            vault_path_chain: cert.vault_path_chain
          }
        end
      end
    end
  end
end
