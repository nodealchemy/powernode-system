# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects NodeCertificates approaching expiry. Two thresholds:
      #   - 7 days → medium severity (advisory)
      #   - 24 hours → high severity (urgent)
      #
      # The expected response is a system.cert_rotate auto-approve action;
      # the high-severity threshold exists because rotation can fail for
      # network/CA-availability reasons and the operator should know.
      class CertificateExpirySensor < BaseSensor
        ADVISORY_WINDOW = 7.days
        URGENT_WINDOW   = 24.hours

        def sense
          now = Time.current
          ::System::NodeCertificate
            .joins(node_instance: :node)
            .where(system_nodes: { account_id: account.id })
            .where(revoked_at: nil)
            .where("not_after IS NOT NULL AND not_after < ?", now + ADVISORY_WINDOW)
            .find_each.map do |cert|
            signal(
              kind: "system.cert_expiring",
              severity: cert.not_after < now + URGENT_WINDOW ? :high : :medium,
              payload: {
                certificate_id: cert.id,
                instance_id: cert.node_instance_id,
                not_after: cert.not_after.iso8601,
                days_remaining: ((cert.not_after - now) / 86_400.0).round(1)
              },
              fingerprint: "cert_expiring:#{cert.id}"
            )
          end
        end
      end
    end
  end
end
