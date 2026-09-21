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
      # row's identifying + lifecycle attributes plus a `vault_paths_present`
      # boolean (IMP-3b0e956d1d5e) -- never the literal `vault_path_*` paths,
      # one of which points at the certificate's PRIVATE KEY. Mirrors
      # system_acme_tool.rb's own read action, which already generalizes
      # this the same way.
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
            # IMP-3b0e956d1d5e — was vault_path_certificate/_private_key/
            # _chain (:string each); this declared contract still advertised
            # the literal paths, including the private-key one, after the
            # body itself was fixed. Mirrors system_acme_tool.rb's own
            # vault_paths_present shape.
            vault_paths_present: :boolean
          }
        )

        # HIER-P2D: issuance is the Ingress Manager's (system.acme_certificate_provision
        # moved off Fleet Autonomy with the ingress group). Fleet Autonomy is
        # dropped: no SIGNAL_BINDINGS entry routes to this executor — the
        # sensor-routed system.acme_cert_rotate renewal lane fires
        # PlatformMaintenanceExecutor and stays Fleet Autonomy's. System
        # Concierge keeps the operator-chat door.
        binds_to "ingress_manager", "concierge"

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

          # Re-provision idempotency. `common_name` uniqueness is scoped to
          # NON-terminal rows (only `revoked` is terminal), so a leftover
          # `failed` / `pending` / `issuing` row from a previous aborted or
          # failed issuance would block a fresh `create!` for the same CN
          # ("Common name has already been taken"). Find any non-terminal
          # row first and reuse it instead of creating a duplicate.
          existing = ::System::AcmeCertificate
                     .active_certs
                     .find_by(account: @account, common_name: common_name)

          if existing
            # A valid + unexpired cert is already serving — reuse it as-is,
            # no ACME work needed.
            return success(certificate_attrs(existing)) if reusable_valid?(existing)

            # Otherwise re-use the dead/in-flight row: refresh the mutable
            # request fields and re-drive issuance through the same path.
            return reissue_existing(existing, issuer:, challenge_type:, sans:,
                                              dns_credential:, acme_email:)
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

          drive_issuance(cert)
        rescue ActiveRecord::RecordInvalid => e
          failure("Could not create certificate: #{e.message}")
        rescue StandardError => e
          failure("Certificate issuance error: #{e.message}")
        end

        private

        # True when the row is already a live, unexpired certificate that can
        # be handed back as-is. Anything else (pending/issuing/failed/expired)
        # needs (re-)issuance.
        def reusable_valid?(cert)
          cert.status == "valid" && !cert.expired?
        end

        # The set of statuses from which a fresh issuance can be (re-)driven.
        # `pending`/`failed` transition straight to `issuing`; a stuck
        # `issuing` row (crashed mid-issuance) is recovered via `failed` first
        # (the only state-machine edge that leads back into issuance).
        REISSUABLE_STATUSES = %w[pending failed issuing].freeze

        # Refresh the mutable request fields onto an existing non-terminal,
        # non-valid row, ensure it is in a state the CertificateManager will
        # accept, then re-drive issuance. A `valid`/`renewing`/`expired` row
        # has no `→ issuing` edge in the state machine — renewing it is the
        # renewal job's job, not this provision skill's — so we refuse rather
        # than fight the state machine or create a duplicate.
        def reissue_existing(cert, issuer:, challenge_type:, sans:, dns_credential:, acme_email:)
          unless REISSUABLE_STATUSES.include?(cert.status)
            return failure(
              "An existing certificate for #{cert.common_name} is in status " \
              "'#{cert.status}'; use the renewal flow rather than re-provisioning."
            )
          end

          attrs = {
            issuer: issuer,
            challenge_type: challenge_type,
            sans: Array(sans),
            dns_credential: dns_credential
          }
          metadata = cert.metadata.is_a?(Hash) ? cert.metadata.dup : {}
          metadata["acme_email"] = acme_email if acme_email.present?
          attrs[:metadata] = metadata

          cert.update!(attrs)

          # CertificateManager#issue! requires `can_transition_to?("issuing")`.
          # `pending` and `failed` already satisfy that. A stuck `issuing` row
          # cannot transition to issuing again, so move it to `failed` first.
          unless cert.can_transition_to?("issuing")
            cert.transition_to!("failed", error_message: "re-provision: recovering stalled issuance")
          end

          drive_issuance(cert)
        end

        # Drive a (new or reused) row through issuance via the shared
        # CertificateManager path and translate the Result into the executor's
        # success/failure shape.
        def drive_issuance(cert)
          result = ::Acme::CertificateManager.issue!(certificate: cert)
          cert.reload

          unless result.ok?
            # IMP-1a5c145c24eb — reviewer finding A2: system_acme_provision_
            # certificate maps here (system_ingress_tool.rb) with run_executor
            # returning this Hash directly as the tool result — the same
            # Result-path leak already fixed at SystemAcmeTool#renew_
            # certificate/#revoke_certificate, unguarded here.
            if result.caller_safe == false
              Rails.logger.error("[AcmeCertificateProvisionExecutor] #{result.error}")
              return failure("Certificate issuance failed")
            end
            return failure("Certificate issuance failed: #{result.error}")
          end

          success(certificate_attrs(cert))
        end

        def certificate_attrs(cert)
          {
            certificate_id: cert.id,
            common_name: cert.common_name,
            issuer: cert.issuer,
            challenge_type: cert.challenge_type,
            status: cert.status,
            issued_at: cert.issued_at&.iso8601,
            expires_at: cert.expires_at&.iso8601,
            # IMP-3b0e956d1d5e — this action (system_acme_provision_certificate)
            # was returning the 3 literal Vault paths, including the pointer
            # to the certificate's PRIVATE KEY, on the same tool whose OWN
            # read action (system_acme_tool.rb#serialize_certificate) already
            # generalizes this to a boolean and says so in its class comment
            # and action description. Mirrors that exact shape rather than
            # inventing a new one -- the defect was two actions on one tool
            # disagreeing. Traced both non-MCP callers of this method
            # (run_executor via SystemIngressTool, and
            # ExposeServicePubliclyExecutor#ensure_certificate's internal
            # executor-to-executor call) -- neither reads vault_path_* at
            # all, only certificate_id/status, so nothing legitimate needs
            # the literal paths and no split-by-boundary is required.
            vault_paths_present: cert.vault_path_certificate.present?
          }
        end
      end
    end
  end
end
