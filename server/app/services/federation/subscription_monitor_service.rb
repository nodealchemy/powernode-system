# frozen_string_literal: true

module Federation
  # Periodic sweep over the subscriber's active ServiceSubscription
  # rows. Tick cadence: hourly (called by FederationSubscriptionMonitorJob
  # in the worker via HTTP).
  #
  # Three reconciliation passes per tick:
  #
  #   1. **Expired-grant suspension** — Active subscriptions whose
  #      FederationGrant.expires_at is in the past get suspended. The
  #      Traefik route is left in place (suspended subscriptions stop
  #      seeing traffic via the active-status filter in
  #      ServiceRouteWriter on its next write). Operator-initiated
  #      grant renewal returns the subscription to active.
  #
  #   2. **Failed-cert retry** — Active subscriptions whose linked
  #      AcmeCertificate is in `failed` state past the cool-down
  #      (30 minutes) get a renewal attempt via Acme::CertificateManager.
  #      Successful retry leaves the subscription untouched (cert just
  #      moves to valid); failure stays in failed and waits for the
  #      next tick.
  #
  #   3. **Stale-suspension auto-cancel** — Subscriptions suspended for
  #      more than SUSPENSION_AUTO_CANCEL_AFTER (30 days) auto-cancel.
  #      Prevents indefinite "zombie subscriptions" from accumulating
  #      after grant expiry that the operator never renewed.
  #
  # Per-account scoping: pass `account:` to sweep one tenant; nil sweeps
  # all accounts (called by the global worker tick).
  #
  # Plan reference: Decentralized Federation §L + P4.6.6.
  class SubscriptionMonitorService
    Result = Struct.new(:ok?, :suspended_count, :cert_retried_count,
                        :auto_cancelled_count, :findings, :ran_at,
                        keyword_init: true)

    # Match Acme::RenewalSweepService.FAILED_RETRY_COOLDOWN to avoid
    # tight-loop retries against ACME rate limits.
    FAILED_CERT_COOLDOWN = 30.minutes

    # How long a subscription stays in `suspended` before the monitor
    # auto-cancels it. Long enough for an operator to renew a grant
    # they meant to keep, short enough to prevent indefinite zombies.
    SUSPENSION_AUTO_CANCEL_AFTER = 30.days

    class << self
      def run!(account: nil, acme_client: nil)
        new(acme_client: acme_client).run!(account: account)
      end
    end

    def initialize(acme_client: nil)
      @acme_client = acme_client
    end

    def run!(account: nil)
      findings = []
      suspended = sweep_expired_grants(account: account, findings: findings)
      cert_retries = sweep_failed_certs(account: account, findings: findings)
      cancelled = sweep_stale_suspensions(account: account, findings: findings)

      Result.new(
        ok?: true,
        suspended_count: suspended,
        cert_retried_count: cert_retries,
        auto_cancelled_count: cancelled,
        findings: findings,
        ran_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.error("[Federation::SubscriptionMonitorService] #{e.class}: #{e.message}")
      Result.new(
        ok?: false,
        suspended_count: 0,
        cert_retried_count: 0,
        auto_cancelled_count: 0,
        findings: [ { kind: "monitor_error", error: e.message } ],
        ran_at: Time.current
      )
    end

    private

    # Active subscriptions whose grant has expired → suspend.
    def sweep_expired_grants(account:, findings:)
      count = 0
      subscriptions_with_expired_grants(account: account).find_each do |sub|
        if sub.suspend!(reason: "federation_grant_expired")
          count += 1
          findings << {
            kind: "suspended_expired_grant",
            subscription_id: sub.id,
            local_hostname: sub.local_hostname,
            offering_slug: sub.service_offering_slug
          }
        end
      end
      count
    end

    # Active subscriptions whose cert is in `failed` state past the
    # cool-down → re-issue via Acme::CertificateManager.
    def sweep_failed_certs(account:, findings:)
      count = 0
      subscriptions_with_failed_certs(account: account).find_each do |sub|
        result = ::Acme::CertificateManager.issue!(
          certificate: sub.acme_certificate,
          acme_client: @acme_client
        )
        if result.ok?
          count += 1
          findings << {
            kind: "cert_retried_success",
            subscription_id: sub.id,
            cert_id: sub.acme_certificate.id
          }
        else
          findings << {
            kind: "cert_retried_failure",
            subscription_id: sub.id,
            cert_id: sub.acme_certificate.id,
            error: result.error
          }
        end
      end
      count
    end

    # Subscriptions suspended past the auto-cancel window → cancel.
    def sweep_stale_suspensions(account:, findings:)
      count = 0
      stale_suspended_subscriptions(account: account).find_each do |sub|
        if sub.cancel!(reason: "auto_cancel_stale_suspension")
          count += 1
          findings << {
            kind: "auto_cancelled_stale_suspension",
            subscription_id: sub.id,
            suspended_for_days: ((Time.current - sub.suspended_at) / 1.day).round
          }
        end
      end
      count
    end

    def subscriptions_with_expired_grants(account:)
      scope = ::System::Federation::ServiceSubscription
                .where(status: "active")
                .joins(:federation_grant)
                .where("system_federation_grants.expires_at < ?", Time.current)
      scope = scope.where(account_id: account.id) if account
      scope
    end

    def subscriptions_with_failed_certs(account:)
      scope = ::System::Federation::ServiceSubscription
                .where(status: "active")
                .joins(:acme_certificate)
                .where(system_acme_certificates: { status: "failed" })
                .where(
                  "system_acme_certificates.last_renewal_attempt_at IS NULL OR " \
                  "system_acme_certificates.last_renewal_attempt_at < ?",
                  FAILED_CERT_COOLDOWN.ago
                )
      scope = scope.where(account_id: account.id) if account
      scope
    end

    def stale_suspended_subscriptions(account:)
      scope = ::System::Federation::ServiceSubscription
                .where(status: "suspended")
                .where("suspended_at < ?", SUSPENSION_AUTO_CANCEL_AFTER.ago)
      scope = scope.where(account_id: account.id) if account
      scope
    end
  end
end
