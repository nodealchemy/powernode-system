# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects ACME (Let's Encrypt / internal-CA) platform certificates
      # approaching expiry — the TLS certs Traefik terminates on the
      # platform's public listeners (System::AcmeCertificate rows).
      #
      # Distinct from CertificateExpirySensor, which watches on-node
      # System::NodeCertificate rows (agent-issued node identity certs).
      # Both emit a rotation signal, but they target different stores and
      # different remediation paths, so they carry different signal kinds:
      #
      #   - CertificateExpirySensor  → system.cert_expiring     → NodeCertificate#rotate
      #   - CertExpirySensor (this)  → system.acme_cert_expiring → platform_maintenance cert_rotate
      #
      # Two thresholds, matching the model's RENEWAL_WINDOW:
      #   - 30 days → medium severity (advisory; the renewal sweep handles it)
      #   - 7 days  → high severity   (urgent; a renewal has been failing,
      #               operator should know — rotation can fail on
      #               CA-availability or DNS-01 propagation issues)
      #
      # The sensor is pure read-side (per BaseSensor contract): it senses
      # and emits, it NEVER renews. The DecisionEngine routes the emitted
      # signal to the existing platform_maintenance `cert_rotate` capability
      # (which renews via AcmeCertificate.needs_renewal + Acme::CertificateManager.renew!).
      class CertExpirySensor < BaseSensor
        ADVISORY_WINDOW = ::System::AcmeCertificate::RENEWAL_WINDOW # 30.days
        URGENT_WINDOW   = 7.days

        def sense
          return [] unless defined?(::System::AcmeCertificate)

          now = Time.current
          ::System::AcmeCertificate
            .where(account_id: account.id)
            .needs_renewal(ADVISORY_WINDOW)
            .find_each.map do |cert|
              days_remaining = ((cert.expires_at - now) / 86_400.0).round(1)
              signal(
                kind: "system.acme_cert_expiring",
                severity: cert.expires_at < now + URGENT_WINDOW ? :high : :medium,
                payload: {
                  certificate_id: cert.id,
                  common_name: cert.common_name,
                  issuer: cert.issuer,
                  status: cert.status,
                  expires_at: cert.expires_at.utc.iso8601,
                  days_remaining: days_remaining,
                  remediation_action: "system.acme_cert_rotate"
                },
                fingerprint: "acme_cert_expiring:#{cert.id}"
              )
            end
        end
      end
    end
  end
end
