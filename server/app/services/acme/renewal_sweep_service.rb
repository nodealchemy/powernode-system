# frozen_string_literal: true

module Acme
  # Sweeps eligible AcmeCertificate rows and triggers renewal /
  # retry-issue via Acme::CertificateManager. Called periodically
  # (every 6 hours) by AcmeCertificateRenewalJob in the worker.
  #
  # Eligibility:
  #   - status="valid" with expires_at within RENEWAL_WINDOW (30 days)
  #     → action: renew
  #   - status="failed" with last_renewal_attempt_at older than
  #     FAILED_RETRY_COOLDOWN (30 minutes) — long enough to avoid
  #     tight-loop collisions with ACME rate limits
  #     → action: renew (if previously issued) OR retry-issue (if never issued)
  #
  # Per-account scoping: pass `account:` to sweep one tenant; pass nil
  # to sweep every account (called by the global tick).
  #
  # Plan reference: Decentralized Federation §J + P2.5.5.
  class RenewalSweepService
    Result = Struct.new(:ok?, :renewed_count, :failed_count, :skipped_count,
                        :findings, :ran_at, keyword_init: true)

    FAILED_RETRY_COOLDOWN = 30.minutes

    class << self
      def run!(account: nil, acme_client: nil)
        new(acme_client: acme_client).run!(account: account)
      end
    end

    def initialize(acme_client: nil)
      @acme_client = acme_client
    end

    def run!(account: nil)
      certs = certs_due_for_action(account: account)
      renewed = 0
      failed = 0
      skipped = 0
      findings = []

      certs.find_each do |cert|
        case decide_action(cert)
        when :renew
          result = ::Acme::CertificateManager.renew!(certificate: cert, acme_client: @acme_client)
          if result.ok?
            renewed += 1
            findings << finding("renewed", cert)
          else
            failed += 1
            findings << finding("renew_failed", cert, error: result.error)
          end
        when :retry_issue
          result = ::Acme::CertificateManager.issue!(certificate: cert, acme_client: @acme_client)
          if result.ok?
            renewed += 1
            findings << finding("issued_retry", cert)
          else
            failed += 1
            findings << finding("issue_retry_failed", cert, error: result.error)
          end
        when :skip
          skipped += 1
        end
      end

      Result.new(
        ok?: true,
        renewed_count: renewed,
        failed_count: failed,
        skipped_count: skipped,
        findings: findings,
        ran_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.error("[Acme::RenewalSweepService] #{e.class}: #{e.message}")
      Result.new(ok?: false, renewed_count: 0, failed_count: 0, skipped_count: 0,
                 findings: [ { kind: "sweep_error", error: e.message } ],
                 ran_at: Time.current)
    end

    private

    def certs_due_for_action(account: nil)
      window = ::System::AcmeCertificate::RENEWAL_WINDOW
      cooldown_before = FAILED_RETRY_COOLDOWN.ago

      scope = ::System::AcmeCertificate.where(
        "(status = ? AND expires_at < ?) OR " \
        "(status = ? AND (last_renewal_attempt_at IS NULL OR last_renewal_attempt_at < ?))",
        "valid", window.from_now,
        "failed", cooldown_before
      )
      scope = scope.where(account_id: account.id) if account
      scope
    end

    # `:renew` when the cert was previously issued; `:retry_issue` when
    # it never reached `valid` (initial issuance still pending after a
    # failure); `:skip` when the cooldown hasn't elapsed yet.
    def decide_action(cert)
      case cert.status
      when "valid"
        :renew
      when "failed"
        last_attempt = cert.last_renewal_attempt_at
        return :skip if last_attempt && last_attempt > FAILED_RETRY_COOLDOWN.ago

        cert.issued_at.present? ? :renew : :retry_issue
      else
        :skip
      end
    end

    def finding(kind, cert, error: nil)
      base = { kind: kind, cert_id: cert.id, common_name: cert.common_name }
      base[:error] = error if error
      base
    end
  end
end
