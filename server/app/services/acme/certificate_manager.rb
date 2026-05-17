# frozen_string_literal: true

module Acme
  # Orchestrates the ACME cert lifecycle: issuance, renewal, revocation.
  # Coordinates DNS provider credentials, the ACME client (Lego), and
  # the AcmeCertificate state machine.
  #
  # Entry points:
  #   - issue!(certificate)  — drives `pending` → `issuing` → `valid`
  #   - renew!(certificate)  — drives `valid` → `renewing` → `valid`
  #   - revoke!(certificate, reason:) — drives any non-terminal → `revoked`
  #
  # Failure handling: any exception during issuance/renewal transitions
  # the certificate to `failed` with `last_renewal_error` set. The
  # renewal worker (P2.5.5) retries on the next 6h tick.
  #
  # ACME protocol calls are delegated to Acme::LegoClient (the
  # integration boundary). Tests inject a stub via
  # `CertificateManager.new(acme_client: spy_client)`.
  #
  # Plan reference: Decentralized Federation §J + P2.5.4.
  class CertificateManager
    Result = Struct.new(:ok?, :error, :certificate, keyword_init: true)

    class << self
      def issue!(certificate:, acme_client: nil)
        new(acme_client: acme_client).issue!(certificate: certificate)
      end

      def renew!(certificate:, acme_client: nil)
        new(acme_client: acme_client).renew!(certificate: certificate)
      end

      def revoke!(certificate:, reason: nil, acme_client: nil)
        new(acme_client: acme_client).revoke!(certificate: certificate, reason: reason)
      end
    end

    def initialize(acme_client: nil)
      @acme_client = acme_client || ::Acme::LegoClient.new
    end

    def issue!(certificate:)
      # Allow `pending → issuing` (initial issuance) and `failed → issuing`
      # (retry after a previous issuance failed). The state machine on
      # AcmeCertificate enforces the valid edges.
      unless certificate.can_transition_to?("issuing")
        return failure(certificate, "certificate not eligible for issuance (got status=#{certificate.status})")
      end

      certificate.transition_to!("issuing")

      cert_material = with_validated_provider(certificate) do |dns_creds_hash|
        @acme_client.issue(
          common_name: certificate.common_name,
          sans: Array(certificate.sans),
          challenge: certificate.challenge_type,
          provider: certificate.dns_credential&.provider,
          credentials: dns_creds_hash,
          issuer: certificate.issuer,
          email: resolve_acme_email(certificate),
          account_key_pem: certificate.metadata&.dig("account_key_pem_snapshot")
        )
      end

      apply_cert_material!(certificate, normalize_keys(cert_material), transition: "valid")
      Result.new(ok?: true, certificate: certificate)
    rescue StandardError => e
      Rails.logger.error("[Acme::CertificateManager#issue!] #{e.class}: #{e.message}")
      certificate.transition_to!("failed", error_message: e.message[0, 1000])
      failure(certificate, e.message)
    end

    def renew!(certificate:)
      unless certificate.status == "valid"
        return failure(certificate, "certificate not in valid state (got #{certificate.status})")
      end

      certificate.transition_to!("renewing")

      cert_material = with_validated_provider(certificate) do |dns_creds_hash|
        # Renew uses the same powernode-acme entry point as issue (lego
        # treats renewal as "obtain with existing account key"); the
        # account key round-trips via Vault so the same ACME account is
        # reused across renewals. P2.5.7.next will split renew into a
        # distinct Lego call once we wire incremental refresh; for v1
        # we always issue fresh.
        @acme_client.renew(
          common_name: certificate.common_name,
          sans: Array(certificate.sans),
          provider: certificate.dns_credential&.provider,
          credentials: dns_creds_hash,
          issuer: certificate.issuer,
          email: resolve_acme_email(certificate),
          account_key_pem: fetch_account_key_pem(certificate)
        )
      end

      apply_cert_material!(certificate, normalize_keys(cert_material), transition: "valid")
      Result.new(ok?: true, certificate: certificate)
    rescue StandardError => e
      Rails.logger.error("[Acme::CertificateManager#renew!] #{e.class}: #{e.message}")
      certificate.transition_to!("failed", error_message: e.message[0, 1000])
      failure(certificate, e.message)
    end

    def revoke!(certificate:, reason: nil)
      if certificate.terminal?
        return failure(certificate, "certificate already in terminal state (#{certificate.status})")
      end

      # Attempt ACME-server revocation if we have material to revoke.
      if certificate.vault_path_certificate.present?
        begin
          material = read_cert_material(certificate)
          cert_pem = material[:cert_pem]
          account_key_pem = material[:account_key_pem]
          if cert_pem.present? && account_key_pem.present?
            @acme_client.revoke(
              certificate_pem: cert_pem,
              account_key_pem: account_key_pem,
              issuer: certificate.issuer,
              email: resolve_acme_email(certificate),
              reason: reason
            )
          else
            Rails.logger.warn("[Acme::CertificateManager#revoke!] missing cert_pem or account_key_pem; skipping ACME-server revoke")
          end
        rescue StandardError => e
          # Revocation is best-effort — if the ACME server is unreachable,
          # we still move the local row to revoked to deny further use.
          Rails.logger.warn("[Acme::CertificateManager#revoke!] ACME revoke failed: #{e.message}; continuing with local revoke")
        end
      end

      certificate.update!(
        status:     "revoked",
        revoked_at: Time.current,
        metadata:   certificate.metadata.merge("revocation_reason" => reason.to_s.presence)
      )

      # Local cleanup. Order matters:
      #   1. Drop the on-disk PEM/key/chain so the cert can't be served
      #      even if Traefik's file-watch lags.
      #   2. Regenerate the dynamic config — TraefikConfigWriter#write!
      #      only emits entries for status="valid" rows, so the revoked
      #      cert disappears from the rendered config.
      #
      # Both are best-effort: a filesystem or writer failure shouldn't
      # roll back the revocation (the DB row is the source of truth).
      cleanup_disk_material!(certificate)
      regenerate_traefik_config!(certificate)

      Result.new(ok?: true, certificate: certificate)
    rescue StandardError => e
      Rails.logger.error("[Acme::CertificateManager#revoke!] #{e.class}: #{e.message}")
      failure(certificate, e.message)
    end

    private

    # Acquires DNS provider credentials from Vault, validates the shape,
    # then yields them to the block. Centralizes the credential
    # lifecycle so issue! and renew! share identical guard logic.
    def with_validated_provider(certificate)
      if certificate.challenge_type == "dns-01"
        dns_cred = certificate.dns_credential
        raise ArgumentError, "dns_credential required for dns-01 challenge" unless dns_cred

        unless ::Acme::DnsProviderRegistry.supported?(dns_cred.provider)
          raise ArgumentError, "Unsupported DNS provider: #{dns_cred.provider.inspect}"
        end

        creds_hash = fetch_dns_credentials(dns_cred)
        ::Acme::DnsProviderRegistry.validate_credential_shape!(
          slug: dns_cred.provider,
          credentials_hash: creds_hash
        )
        yield(creds_hash)
      else
        # http-01 and tls-alpn-01 don't need DNS credentials
        yield({})
      end
    end

    def apply_cert_material!(certificate, cert_material, transition:)
      store_to_vault!(certificate, cert_material)
      disk_paths = materialize_to_disk!(certificate, cert_material)

      attrs = {
        issued_at: cert_material[:issued_at] || Time.current,
        expires_at: cert_material[:expires_at],
        # NOTE: these columns are named `vault_path_*` for historical reasons,
        # but they now hold the on-disk paths Traefik reads. The cert bundle
        # is also stored in Vault under the convention path; that's the
        # source of truth for renewals + remote serving. P2.5.next: rename
        # these columns to `disk_path_*` to remove the misnomer.
        vault_path_certificate: disk_paths[:cert],
        vault_path_private_key: disk_paths[:key],
        vault_path_chain: disk_paths[:chain],
        vault_path_account_key: nil
      }
      certificate.transition_to!(transition, attrs: attrs)

      # Regenerate the Traefik dynamic config so the new cert lands in
      # the file Traefik file-watches. Best-effort: a writer failure must
      # NOT roll back the issuance (the cert + PEMs are valid; the
      # writer can be re-run any time via Acme::TraefikConfigWriter.write!).
      regenerate_traefik_config!(certificate)
    end

    # Pulls cert + key + chain + account_key from cert_material and writes
    # them to the on-disk paths Traefik's dynamic config will reference.
    # Returns the four resolved paths (account_key is intentionally
    # nil — operators never load the ACME account key into Traefik;
    # it lives in Vault only and round-trips on renewal).
    def materialize_to_disk!(certificate, cert_material)
      cert_path  = ::Acme::TraefikConfigWriter.cert_file_path(certificate)
      key_path   = ::Acme::TraefikConfigWriter.key_file_path(certificate)
      chain_path = ::Acme::TraefikConfigWriter.chain_file_path(certificate)

      ::FileUtils.mkdir_p(::File.dirname(cert_path))

      atomic_write(cert_path, cert_material[:cert_pem], mode: 0o644)
      atomic_write(key_path, cert_material[:key_pem], mode: 0o600)
      if cert_material[:chain_pem].present?
        atomic_write(chain_path, cert_material[:chain_pem], mode: 0o644)
      end

      { cert: cert_path, key: key_path, chain: chain_path }
    end

    # Atomic write — temp file in the same dir, then rename. Guarantees
    # readers never see a partial file. Private key gets 0600 perms so
    # only the owner can read it; the cert is 0644 since it's public.
    def atomic_write(path, content, mode:)
      return if content.blank?

      tmp = "#{path}.tmp.#{::Process.pid}"
      ::File.open(tmp, "wb", mode) { |f| f.write(content) }
      ::File.chmod(mode, tmp)
      ::File.rename(tmp, path)
    end

    def regenerate_traefik_config!(certificate)
      ::Acme::TraefikConfigWriter.write!(account: certificate.account)
    rescue StandardError => e
      Rails.logger.warn(
        "[Acme::CertificateManager] Traefik config write failed: #{e.message}. " \
        "Cert is still valid; re-run TraefikConfigWriter.write! to recover."
      )
    end

    # Symmetric inverse of materialize_to_disk!. Removes the cert/key/
    # chain PEMs the writer wrote at issuance time so they can no
    # longer be served (and so the directory doesn't accumulate
    # tombstones). Idempotent: missing files are not an error.
    def cleanup_disk_material!(certificate)
      [
        ::Acme::TraefikConfigWriter.cert_file_path(certificate),
        ::Acme::TraefikConfigWriter.key_file_path(certificate),
        ::Acme::TraefikConfigWriter.chain_file_path(certificate)
      ].each do |path|
        ::File.delete(path) if path.present? && ::File.exist?(path)
      rescue StandardError => e
        Rails.logger.warn(
          "[Acme::CertificateManager] cleanup_disk_material! failed for #{path}: #{e.message}"
        )
      end
    end

    def fetch_dns_credentials(dns_cred)
      vault_provider(dns_cred.account_id).get_credential(
        credential_type: :acme_dns,
        credential_id: dns_cred.id,
        record: dns_cred
      ) || {}
    end

    # Stores cert material as a single VaultCredential entry keyed by the
    # certificate's id. The convention paths returned here are recorded
    # on the AcmeCertificate row so Acme::TraefikConfigWriter can find
    # the material on disk (after CertificateManager materializes it).
    def store_to_vault!(certificate, cert_material)
      data = {
        cert_pem: cert_material[:cert_pem],
        key_pem: cert_material[:key_pem],
        chain_pem: cert_material[:chain_pem],
        account_key_pem: cert_material[:account_key_pem]
      }.compact

      vault_provider(certificate.account_id).store_credential(
        credential_type: :acme_certificate,
        credential_id: certificate.id,
        data: data,
        record: certificate
      )

      base_path = "acme-certificates/#{certificate.account_id}/#{certificate.id}"
      {
        cert: "#{base_path}/cert",
        key: "#{base_path}/key",
        chain: "#{base_path}/chain",
        account_key: "#{base_path}/account_key"
      }
    end

    def read_cert_material(certificate)
      data = vault_provider(certificate.account_id).get_credential(
        credential_type: :acme_certificate,
        credential_id: certificate.id,
        record: certificate
      )
      return {} unless data.is_a?(Hash)
      {
        cert_pem: data[:cert_pem] || data["cert_pem"],
        key_pem: data[:key_pem] || data["key_pem"],
        chain_pem: data[:chain_pem] || data["chain_pem"],
        account_key_pem: data[:account_key_pem] || data["account_key_pem"]
      }
    rescue StandardError
      {}
    end

    # On renew, the ACME account key must be reused — otherwise lego
    # registers a fresh account each time, hitting LE's account-create
    # rate limit and orphaning the previous account. The key was stashed
    # in Vault during the initial issue (see store_to_vault!); we pull
    # it back here.
    def fetch_account_key_pem(certificate)
      data = vault_provider(certificate.account_id).get_credential(
        credential_type: :acme_certificate,
        credential_id: certificate.id,
        record: certificate
      )
      return nil unless data.is_a?(Hash)
      data[:account_key_pem] || data["account_key_pem"]
    rescue StandardError => e
      Rails.logger.warn("[CertificateManager] could not fetch account_key_pem for renewal: #{e.message}")
      nil
    end

    def vault_provider(account_id)
      @vault_providers ||= {}
      @vault_providers[account_id] ||= ::Security::VaultCredentialProvider.new(account_id: account_id)
    end

    # LegoClient (and JSON.parse) returns string-keyed Hashes; older
    # in-tree tests stub with symbol keys. Normalize to symbols so the
    # downstream `cert_material[:cert_pem]` accesses don't depend on
    # which path produced the hash.
    def normalize_keys(material)
      return {} unless material.is_a?(Hash)
      material.transform_keys do |k|
        k.is_a?(Symbol) ? k : k.to_s.to_sym
      end
    end

    # ACME registration needs a contact email. Resolution order:
    #   1. certificate.metadata["acme_email"] — per-cert operator override
    #   2. ENV["POWERNODE_ACME_EMAIL"] — platform-wide default
    #   3. account's first admin-equivalent user's email — fallback.
    #      Accepts the platform's three admin-tier roles in priority
    #      order: owner (account creator), super_admin (full system
    #      privilege), admin (account-scoped admin). Any of these is a
    #      defensible operator contact for cert lifecycle notifications.
    # Raises if none available; LE rejects empty contacts.
    ADMIN_EQUIVALENT_ROLES = %w[owner super_admin admin].freeze

    def resolve_acme_email(certificate)
      explicit = certificate.metadata&.dig("acme_email").presence
      return explicit if explicit

      env_email = ENV["POWERNODE_ACME_EMAIL"].presence
      return env_email if env_email

      admin = certificate.account&.users
                          &.joins(:roles)
                          &.where(roles: { name: ADMIN_EQUIVALENT_ROLES })
                          &.order(:created_at)
                          &.first
      return admin.email if admin&.email.present?

      raise ArgumentError, "No ACME email — set certificate.metadata['acme_email'], " \
                            "POWERNODE_ACME_EMAIL env, or ensure the account has a " \
                            "user with one of these roles: #{ADMIN_EQUIVALENT_ROLES.join(', ')}."
    end

    def failure(certificate, message)
      Result.new(ok?: false, certificate: certificate, error: message)
    end
  end
end
