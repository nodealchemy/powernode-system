# frozen_string_literal: true

module Ai
  module Tools
    # MCP tool surface for the System extension's ACME (TLS certificate)
    # lifecycle. Exposes read + renew + revoke on `System::AcmeCertificate`
    # and create on `System::AcmeDnsCredential` to operators + AI agents.
    #
    # Mirrors SystemFleetTool in shape (BaseTool subclass, REQUIRED_PERMISSION
    # floor + per-action ACTION_PERMISSIONS, self.action_definitions, a `call`
    # dispatch switch, and direct private handlers) so the operator approval UI
    # + agent invocation paths work uniformly. Behavior mirrors
    # Api::V1::System::AcmeCertificatesController (show/renew/revoke) and
    # Api::V1::System::AcmeDnsCredentialsController (create) — the underlying
    # services (::Acme::CertificateManager, ::Security::VaultCredentialProvider)
    # are REUSED, not reimplemented.
    #
    # CRYPTO-MATERIAL SAFETY (CLAUDE.md, ABSOLUTE):
    #   - Certificate serialization NEVER emits PEMs, private keys, or Vault
    #     secret values — only a `vault_paths_present` boolean.
    #   - DNS credential create receives the provider API token plaintext in
    #     `credentials` and hands it STRAIGHT to
    #     ::Security::VaultCredentialProvider#store_credential. The secret is
    #     never assigned to the model, never logged, and never serialized in
    #     the result (which carries only the public index: name, provider,
    #     status).
    #
    # Plan reference: Decentralized Federation §J + P2.5.
    class SystemAcmeTool < BaseTool
      # Floor permission: every caller needs at least system.acme.read to use
      # the tool at all. Per-action permissions in ACTION_PERMISSIONS gate
      # mutating actions to higher levels.
      REQUIRED_PERMISSION = "system.acme.read"

      # Per-action permission map. Aligned with the seeded
      # `system.acme.*` / `system.acme_dns.*` naming used by the
      # AcmeCertificatesController + AcmeDnsCredentialsController.
      # Internal callers (system services, autonomy reconcilers) bypass
      # this check by passing user: nil to .new.
      ACTION_PERMISSIONS = {
        "system_acme_get_certificate"    => "system.acme.read",
        "system_acme_renew_certificate"  => "system.acme.renew",
        "system_acme_revoke_certificate" => "system.acme.revoke",
        "system_acme_create_dns_credential" => "system.acme_dns.manage"
      }.freeze

      # APO-1a (IMP-1e58753b3b6c) — governance declarations for every action
      # this tool advertises. NON-ENFORCING: `mutating:` alone leaves
      # BaseTool#gated_action? false, so #execute still routes to #call and
      # behaviour is unchanged. Gate wiring (categories/executors) is APO-1e.
      declare_action "system_acme_create_dns_credential", mutating: true
      declare_action "system_acme_get_certificate", mutating: false
      declare_action "system_acme_renew_certificate", mutating: true
      declare_action "system_acme_revoke_certificate", mutating: true

      def self.definition
        {
          name: "system_acme",
          description: "System extension ACME TLS lifecycle: read/renew/revoke certificates, create DNS-01 provider credentials",
          parameters: {
            action: { type: "string", required: true, description: "Action to perform" },
            certificate_id: { type: "string", required: false },
            reason: { type: "string", required: false },
            name: { type: "string", required: false },
            provider: { type: "string", required: false },
            credentials: { type: "object", required: false },
            metadata: { type: "object", required: false }
          }
        }
      end

      def self.action_definitions
        {
          "system_acme_get_certificate" => {
            description: "Fetch a single ACME certificate's non-secret detail (status, issuer, expiry, vault_paths_present). " \
                         "NEVER returns PEMs, private keys, or Vault secret values.",
            parameters: { certificate_id: { type: "string", required: true,
                                            description: "UUID of the ACME certificate to fetch" } }
          },
          "system_acme_renew_certificate" => {
            description: "Renew an ACME certificate currently in status=valid. Drives valid → renewing → valid via " \
                         "Acme::CertificateManager.renew!. Returns the reloaded non-secret cert detail on success.",
            parameters: { certificate_id: { type: "string", required: true,
                                            description: "UUID of the ACME certificate to renew (must be in status=valid)" } }
          },
          "system_acme_revoke_certificate" => {
            description: "Revoke a non-terminal ACME certificate via Acme::CertificateManager.revoke!. Drives any " \
                         "non-terminal status → revoked. Optionally records a revocation reason.",
            parameters: {
              certificate_id: { type: "string", required: true,
                                description: "UUID of the non-terminal ACME certificate to revoke" },
              reason: { type: "string", required: false, description: "Optional ACME revocation reason" }
            }
          },
          "system_acme_create_dns_credential" => {
            description: "Register a new ACME DNS-01 provider credential (Cloudflare, Route53, etc.). The provider API " \
                         "token in `credentials` is handed straight to Vault — NEVER stored on the model, logged, or " \
                         "returned. The result serializes only the public index (name, provider, status).",
            parameters: {
              name: { type: "string", required: true, description: "Human-readable name for the DNS-01 credential record" },
              provider: { type: "string", required: true, description: "DNS provider slug (cloudflare|route53|gcloud|digitalocean|hetzner|porkbun|ovh)" },
              credentials: { type: "object", required: true, description: "Provider-specific secret token fields (SENSITIVE — stored in Vault only)" },
              metadata: { type: "object", required: false, description: "Optional non-secret metadata stored on the credential record" }
            }
          }
        }
      end

      def self.permitted?(agent:)
        return false unless defined?(::System)
        super
      end

      protected

      def call(params)
        return error_result("permission denied: #{required_perm_for(params[:action])} required") unless action_permitted?(params[:action])

        case params[:action]
        when "system_acme_get_certificate"       then get_certificate(params)
        when "system_acme_renew_certificate"     then renew_certificate(params)
        when "system_acme_revoke_certificate"    then revoke_certificate(params)
        when "system_acme_create_dns_credential" then create_dns_credential(params)
        else
          error_result("Unknown action: #{params[:action]}")
        end
      end

      private

      # === Permission helpers (mirror SystemFleetTool) ===
      # Two bypasses, both EXPLICIT (IMP-54bf2643f542, sibling of the
      # SystemFleetTool fix IMP-9030413bc292 — its ladder carries the full note):
      #
      #   internal?            in-process system callers (autonomy reconcilers,
      #                        skill executors running without a user) that
      #                        opted in with `internal: true`.
      #   instance_authorized? an MCP instance principal (mTLS node cert, no
      #                        User) whose specific tool name already cleared
      #                        Mcp::Principal#may_invoke? — that per-tool grant
      #                        stands in for authorization. It is NAME-scoped
      #                        while this tool runs the action the caller
      #                        supplies, so treat it as provenance, not a fence.
      #
      # The old comment here claimed "MCP-invoked callers always carry @user
      # from the dispatch layer" and bypassed on `@user.nil?`. That predates
      # instance principals — an mTLS node cert authenticates with no User — so
      # an instance skipped this map, including revoke. A nil user with neither
      # flag now fails CLOSED.
      def required_perm_for(action)
        ACTION_PERMISSIONS[action] || REQUIRED_PERMISSION
      end

      def action_permitted?(action)
        return true if internal?
        return true if instance_authorized?
        return false if @user.nil?
        return true unless @user.respond_to?(:has_permission?)

        @user.has_permission?(required_perm_for(action))
      end

      # === Certificates ===

      # Mirrors AcmeCertificatesController#show + set_certificate scoping.
      # Serializes NON-SECRET fields only (controller serialize(full: true)
      # minus the credential plumbing) — never PEMs / keys / Vault values.
      def get_certificate(params)
        cert = find_certificate(params[:certificate_id])
        return error_result("Certificate not found") unless cert

        success_result(certificate: serialize_certificate(cert))
      end

      # Mirrors AcmeCertificatesController#renew: guard status=valid, then
      # reuse Acme::CertificateManager.renew!. Result.ok? → reload + serialize.
      def renew_certificate(params)
        cert = find_certificate(params[:certificate_id])
        return error_result("Certificate not found") unless cert

        unless cert.status == "valid"
          return error_result("Can only renew certs in status=valid (got #{cert.status}).")
        end

        result = ::Acme::CertificateManager.renew!(certificate: cert)
        if result.ok?
          success_result(renewed: true, certificate: serialize_certificate(cert.reload))
        else
          error_result("Renewal failed: #{result.error}")
        end
      rescue StandardError => e
        ::Rails.logger.error("[SystemAcmeTool#renew_certificate] #{e.class}: #{e.message}")
        error_result("Renewal raised: #{e.message}")
      end

      # Mirrors AcmeCertificatesController#revoke: guard !terminal?, then
      # reuse Acme::CertificateManager.revoke! with an optional reason.
      def revoke_certificate(params)
        cert = find_certificate(params[:certificate_id])
        return error_result("Certificate not found") unless cert

        if cert.terminal?
          return error_result("Already #{cert.status}")
        end

        result = ::Acme::CertificateManager.revoke!(
          certificate: cert,
          reason: params[:reason].to_s.presence
        )
        if result.ok?
          success_result(revoked: true, certificate: serialize_certificate(cert.reload))
        else
          error_result("Revoke failed: #{result.error}")
        end
      rescue StandardError => e
        ::Rails.logger.error("[SystemAcmeTool#revoke_certificate] #{e.class}: #{e.message}")
        error_result("Revoke raised: #{e.message}")
      end

      # === DNS credentials ===

      # Mirrors AcmeDnsCredentialsController#create EXACTLY:
      #   1. validate provider via DnsProviderRegistry.supported?
      #   2. inside a transaction, build the row with public fields ONLY
      #      (name, provider, status, metadata) — NEVER the secret
      #   3. hand the plaintext `credentials` STRAIGHT to Vault via
      #      VaultCredentialProvider#store_credential
      # The secret is never assigned to the model, never logged, and never
      # serialized in the result.
      def create_dns_credential(params)
        provider_slug = params[:provider].to_s
        unless ::Acme::DnsProviderRegistry.supported?(provider_slug)
          return error_result(
            "Unsupported provider: #{provider_slug.inspect}. " \
            "Supported: #{::Acme::DnsProviderRegistry::PROVIDERS.keys.inspect}"
          )
        end

        credentials = sanitize_credential_payload(params[:credentials], provider_slug)
        missing = required_fields(provider_slug) - credentials.keys
        unless missing.empty?
          return error_result(
            "Missing required credential field(s) for #{provider_slug}: #{missing.join(', ')}"
          )
        end

        cred = nil
        ::ActiveRecord::Base.transaction do
          cred = ::System::AcmeDnsCredential.new(
            account: @account,
            name: params[:name].to_s,
            provider: provider_slug,
            status: "untested",
            metadata: params[:metadata].is_a?(Hash) ? params[:metadata] : {}
          )

          unless cred.save
            raise ::ActiveRecord::Rollback,
                  "validation: #{cred.errors.full_messages.join('; ')}"
          end

          # Hand the plaintext directly to Vault — never assign to model.
          vault_provider.store_credential(
            credential_type: :acme_dns,
            credential_id: cred.id,
            data: credentials.transform_keys(&:to_s),
            record: cred
          )
        end

        if cred&.persisted?
          success_result(credential: serialize_credential(cred))
        else
          error_result(cred ? cred.errors.full_messages.join("; ") : "Create failed")
        end
      end

      # === Scoping ===

      # Account-scoped lookup mirroring the controllers' set_certificate /
      # where(account:).find_by(id:). Returns nil (not a 404 render) so the
      # handler emits a uniform error_result.
      def find_certificate(certificate_id)
        ::System::AcmeCertificate
          .where(account: @account)
          .find_by(id: certificate_id)
      end

      # === Serialization (NON-SECRET ONLY) ===

      # Mirrors AcmeCertificatesController#serialize(full: true) but emits
      # only non-secret identification + lifecycle fields. The presence of
      # Vault-stored cert material is surfaced as a boolean; the actual
      # paths / PEMs / private keys are NEVER included.
      def serialize_certificate(cert)
        {
          id: cert.id,
          common_name: cert.common_name,
          hostname: cert.common_name,
          sans: cert.sans || [],
          status: cert.status,
          issuer: cert.issuer,
          challenge_type: cert.challenge_type,
          dns_credential_id: cert.dns_credential_id,
          dns_credential_name: cert.dns_credential&.name,
          dns_credential_provider: cert.dns_credential&.provider,
          issued_at: cert.issued_at&.iso8601,
          expires_at: cert.expires_at&.iso8601,
          revoked_at: cert.revoked_at&.iso8601,
          days_until_expiry: days_until_expiry(cert),
          terminal: cert.terminal?,
          last_renewal_error: cert.last_renewal_error,
          # Boolean only — operators learn the cert has been materialized in
          # Vault without ever seeing the paths or secret values.
          vault_paths_present: cert.vault_path_certificate.present?,
          created_at: cert.created_at.iso8601,
          updated_at: cert.updated_at.iso8601
        }
      end

      def days_until_expiry(cert)
        return nil unless cert.expires_at

        ((cert.expires_at - Time.current) / 1.day).round
      end

      # Public index card only — mirrors AcmeDnsCredentialsController#serialize
      # (non-full). NEVER includes credential plaintext.
      def serialize_credential(cred)
        {
          id: cred.id,
          name: cred.name,
          provider: cred.provider,
          status: cred.status
        }
      end

      # === Credential payload handling (mirror controller) ===

      def required_fields(provider_slug)
        ::Acme::DnsProviderRegistry::PROVIDERS[provider_slug.to_s][:required_fields]
      end

      # Strict allowlist — accept only the fields the registry declares for
      # this provider. Extras get silently dropped so operator typos don't
      # get written into Vault (which would later confuse Lego).
      def sanitize_credential_payload(payload, provider_slug)
        allowed = required_fields(provider_slug)
        hash = payload.is_a?(Hash) ? payload : {}
        hash.each_with_object({}) do |(k, v), out|
          key = k.to_s
          out[key] = v.to_s if allowed.include?(key) && v.to_s.strip != ""
        end
      end

      def vault_provider
        @vault_provider ||= ::Security::VaultCredentialProvider.new(
          account_id: @account.id
        )
      end
    end
  end
end
