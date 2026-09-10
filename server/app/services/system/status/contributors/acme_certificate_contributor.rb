# frozen_string_literal: true

module System
  module Status
    module Contributors
      # One component per ACME certificate (campaign 01a08c9b B3).
      #
      # ── SCOPE ───────────────────────────────────────────────────────────
      # `revoked` and nothing else. It is the model's own TERMINAL_STATUSES,
      # and the model already treats it that way: the account-scoped uniqueness
      # guard on common_name excludes terminal rows, so a revoked certificate is
      # a historical record rather than a live one. `expired` and `failed` are
      # NOT gone — they are the rows an operator has to act on.
      #
      # ── EXPIRY IS ITS OWN CONDITION ─────────────────────────────────────
      # `status` says what the issuance state machine last concluded; expires_at
      # says how long the certificate has left. A valid certificate three days
      # from expiry is `valid` and in trouble, and one column cannot say both.
      # The window is the model's own RENEWAL_WINDOW, so the condition and the
      # renewal scope cannot disagree about what "soon" means.
      class AcmeCertificateContributor < ::Platform::Status::Contributor
        include ::System::Status::ConditionHelpers

        KIND  = "acme_certificate"
        MODEL = ::System::AcmeCertificate

        GONE_STATUSES = MODEL::TERMINAL_STATUSES

        EXPIRY = "Expiry"

        LIFECYCLE = {
          "valid"    => { status: true,  reason: "Valid" },
          "pending"  => { status: true,  reason: "Pending" },
          "issuing"  => { status: true,  reason: "Issuing" },
          "renewing" => { status: true,  reason: "Renewing" },
          "failed"   => { status: false, reason: "IssuanceFailed" },
          "expired"  => { status: false, reason: "Expired",
                          severity: ::Platform::Status::Condition::SEVERITY_DOWN },
          # Never enumerated; mapped so a scope defect cannot read as healthy.
          "revoked"  => { status: false, reason: "Revoked",
                          severity: ::Platform::Status::Condition::SEVERITY_DOWN }
        }.freeze

        PROGRESSING = { "pending" => "Pending", "issuing" => "Issuing", "renewing" => "Renewing" }.freeze

        def kind = KIND

        def account_scoped? = true

        # CertExpirySensor already escalates this kind
        # (system.acme_cert_expiring) and claims through
        # SignalState.claim_notification!.
        def escalates? = false

        def each_component(account)
          return if account.blank?

          MODEL.where(account_id: account.id)
               .where.not(status: GONE_STATUSES)
               .find_each { |cert| yield cert }
        end

        def ref_for(record) = record.id.to_s

        def display_name_for(record)
          record.common_name.presence || record.id.to_s
        end

        def observed_generation_for(record) = record.updated_at&.iso8601

        def presentation
          { "icon" => "ShieldCheck", "label" => "Certificate", "group_order" => 90 }
        end

        def links_for(_record)
          [ { "label" => "ACME", "path" => "/app/system/acme" } ]
        end

        # A certificate depends on nothing this plane models. The services that
        # terminate on it declare `requires` toward it, and the rollup
        # reverse-walks those.
        def dependencies_for(_record) = []

        def actions_for(_record) = []

        def conditions_for(record)
          now = Time.current
          [
            enum_condition(type: "Lifecycle", mapping: LIFECYCLE, value: record.status,
                           evidence: { "issuer" => record.issuer.to_s,
                                       "last_renewal_error" => record.last_renewal_error },
                           now: now),
            progressing_condition(cause: PROGRESSING[record.status.to_s], now: now),
            expiry_condition(record, now)
          ].compact
        end

        private

        # Omitted where there is nothing to measure — a certificate that has
        # never issued has no expiry, and asserting `unknown` there would rank
        # every pending certificate above a held component while it is doing
        # exactly what it should.
        def expiry_condition(record, now)
          return nil if record.expires_at.blank?

          window = MODEL::RENEWAL_WINDOW
          remaining = (record.expires_at - now).to_i
          evidence = { "expires_at" => record.expires_at.iso8601,
                       "seconds_remaining" => remaining,
                       "renewal_window_seconds" => window.to_i }

          if remaining <= 0
            return CONDITION.build(type: EXPIRY, status: false, reason: "Expired",
                                   severity: CONDITION::SEVERITY_DOWN,
                                   message: "expired #{-remaining}s ago",
                                   evidence: evidence, now: now)
          end

          within = remaining <= window.to_i

          CONDITION.build(
            type: EXPIRY, status: !within,
            reason: within ? "ExpiringSoon" : "Current",
            message: within ? "expires in #{remaining}s, inside the renewal window" : nil,
            evidence: evidence, now: now
          )
        end
      end
    end
  end
end
