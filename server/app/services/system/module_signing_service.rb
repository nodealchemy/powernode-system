# frozen_string_literal: true

require "tempfile"
require "tmpdir"

module System
  # Signs a pushed OCI module artifact against the platform's Vault-held
  # transit signing key. Ephemeral fleet builders (campaign 019f5885 inc7)
  # push UNSIGNED artifacts — this service is the ONLY place a cosign
  # signature gets attached, and it runs here (server-side) because this is
  # where the already-authenticated Vault AppRole session lives.
  #
  # cosign's `--key hashivault://<name>` scheme means cosign talks to Vault
  # directly and asks the transit engine to perform the signature — the
  # private key material never leaves Vault, never transits this process,
  # and is never written to argv, logs, or disk. This service only ever
  # passes cosign the Vault ADDRESS and an already-issued Vault AUTH TOKEN
  # (via subprocess env, never argv) plus the transit KEY NAME (config, not
  # a secret) — see #vault_env and campaign design doc §D3 (private plan,
  # not committed to this repo) for the full rationale.
  #
  # Digest binding: before signing, this service re-fetches the pushed
  # artifact's manifest descriptor straight from the registry (`oras
  # manifest fetch --descriptor`) and asserts its digest matches what the
  # caller expects. The caller's `expected_digest` is what the leased
  # builder REPORTED it pushed; re-deriving the digest from the registry
  # itself (rather than trusting the report) closes the gap where a
  # builder reports one digest but something else landed in the registry.
  # A mismatch is a hard reject — this service never signs bytes it hasn't
  # independently confirmed are the expected ones (fail-closed).
  class ModuleSigningService
    Result = Struct.new(:ok?, :error, :oci_ref, :digest, :cosign_output, keyword_init: true)

    class SigningError < StandardError; end
    class DigestMismatchError < SigningError; end
    class BinaryNotFoundError < SigningError; end
    class ManifestFetchError < SigningError; end
    class CosignError < SigningError; end

    # SiteSetting key for the transit keyname — this is CONFIG, not a
    # secret (the keyname alone grants no signing capability; only the
    # server's already-authenticated Vault session can invoke transit/sign
    # against it). Never hardcode the keyname elsewhere — route through
    # .keyname so an operator-driven rename/rotation-to-new-name is a
    # single SiteSetting update.
    KEYNAME_SETTING = "system.module_signing.keyname"
    DEFAULT_KEYNAME = "powernode-module-signing"

    # Signing MODE (task #48): "vault" (default — sign via the platform's Vault
    # transit key, unchanged) or "local" (sign with a self-generated on-box
    # cosign key, for a plane with NO Vault — e.g. ops-hub). Operator-driven via
    # SiteSetting; defaults to "vault" so every existing plane's behavior is
    # byte-identical. See System::ModuleSigningKey for the local key custody.
    MODE_SETTING    = "system.module_signing.mode"
    DEFAULT_MODE    = "vault"

    def self.sign!(oci_ref:, expected_digest:, account: nil, node_module_id: nil, node_module_version_id: nil)
      new.sign!(
        oci_ref: oci_ref,
        expected_digest: expected_digest,
        account: account,
        node_module_id: node_module_id,
        node_module_version_id: node_module_version_id
      )
    end

    def initialize(vault_client: nil)
      # LAZY: do NOT eagerly resolve Security::VaultClient.instance here — its
      # AppRole login raises "VAULT_ROLE_ID not configured" on a Vault-less plane
      # (ops-hub), which would break local-mode signing before a mode is even
      # chosen. The client is resolved only inside #vault_env (vault mode only).
      @vault_client = vault_client
    end

    # @param oci_ref [String] the pushed artifact reference (registry/name:tag)
    # @param expected_digest [String] the digest the caller believes was pushed
    # @param account [Account, nil] for FleetEvent correlation — event emission
    #   is skipped (not an error) when omitted, since signing itself has no
    #   inherent tenant scope beyond the module being signed.
    # @param node_module_id [String, nil] optional correlation id for the event
    # @param node_module_version_id [String, nil] optional correlation id for the event
    def sign!(oci_ref:, expected_digest:, account: nil, node_module_id: nil, node_module_version_id: nil)
      return failure("oci_ref required") if oci_ref.blank?
      return failure("expected_digest required") if expected_digest.blank?

      ensure_binary!("oras")
      ensure_binary!("cosign")

      # Both the manifest fetch (below) and cosign's signature PUSH target the
      # private Gitea OCI registry, which 401s anonymous requests. Log in ONCE
      # into a throwaway DOCKER_CONFIG scoped to this sign (never the shared
      # ~/.docker/config.json — Puma serves many accounts concurrently); oras
      # AND cosign both honor DOCKER_CONFIG, so one login authenticates both.
      # Token piped via stdin, never argv. Unconfigured registry (dev/public)
      # falls through unauthenticated, exactly like DiskImageOciIngestService.
      with_registry_auth(account) do |reg_env|
        registry_digest = fetch_registry_digest(oci_ref, env: reg_env)
        if registry_digest != expected_digest
          raise DigestMismatchError,
                "registry digest #{registry_digest.inspect} does not match expected digest " \
                "#{expected_digest.inspect} for #{oci_ref} — refusing to sign"
        end

        ref_at_digest = "#{strip_tag(oci_ref)}@#{registry_digest}"
        cosign_output = cosign_sign!(ref_at_digest, env: reg_env)

        emit_signed_event!(
          account: account,
          oci_ref: oci_ref,
          digest: registry_digest,
          node_module_id: node_module_id,
          node_module_version_id: node_module_version_id
        )

        Result.new(ok?: true, oci_ref: oci_ref, digest: registry_digest, cosign_output: cosign_output)
      end
    rescue SigningError => e
      failure(e.message)
    rescue StandardError => e
      sanitized = ::System::ShellOutputSanitizer.redact(e.message)
      Rails.logger.error("[ModuleSigningService] #{e.class}: #{sanitized}")
      failure("signing failed: #{sanitized}")
    end

    private

    def failure(msg)
      Result.new(ok?: false, error: msg)
    end

    def keyname
      ::SiteSetting.get(KEYNAME_SETTING).presence || DEFAULT_KEYNAME
    end

    # Resolves the platform's Gitea OCI registry credentials (the SAME ones
    # config_controller#ci_build_context hands leased builders for push.sh's
    # `oras login`) and logs in to a throwaway DOCKER_CONFIG for the duration
    # of the block, yielding the env hash to thread onto oras + cosign. Returns
    # an empty env (unauthenticated) when the registry is unconfigured — dev
    # fixtures / public registries — matching DiskImageOciIngestService.
    def with_registry_auth(account)
      creds = registry_credentials(account)
      return yield({}) if creds.blank?

      Dir.mktmpdir("powernode-sign-auth-") do |dir|
        env = { "DOCKER_CONFIG" => dir }
        login_out, login_err, login_status = ::Open3.capture3(
          env, "oras", "login", creds[:host],
          "--username", creds[:user], "--password-stdin",
          stdin_data: creds[:token].to_s
        )
        unless login_status.success?
          raw = login_err.strip.presence || login_out.strip
          raise ManifestFetchError, "oras login failed: #{::System::ShellOutputSanitizer.redact(raw)}"
        end
        yield env
      end
    end

    def registry_credentials(account)
      return nil unless account && ::System::DiskImageRegistryConfig.configured?(account: account)

      {
        host:  ::System::DiskImageRegistryConfig.registry_host(account: account),
        user:  ::System::DiskImageRegistryConfig.registry_user(account: account),
        token: ::System::DiskImageRegistryConfig.registry_token(account: account)
      }
    end

    def fetch_registry_digest(oci_ref, env: {})
      out, err, status = ::Open3.capture3(env, "oras", "manifest", "fetch", "--descriptor", oci_ref)
      unless status.success?
        raise ManifestFetchError,
              "oras manifest fetch --descriptor failed: " \
              "#{::System::ShellOutputSanitizer.redact(err.presence) || "exit #{status.exitstatus}"}"
      end

      parsed = JSON.parse(out)
      digest = parsed["digest"]
      raise ManifestFetchError, "oras descriptor had no digest field" if digest.blank?

      digest
    rescue JSON::ParserError => e
      raise ManifestFetchError, "oras descriptor JSON parse failed: #{e.message}"
    end

    def cosign_sign!(ref_at_digest, env: {})
      key_flag, sign_env = signing_key_flag_and_env
      cmd = [ "cosign", "sign", "--yes", "--key", key_flag, ref_at_digest ]
      # sign_env carries the signing credential (vault: VAULT_ADDR/VAULT_TOKEN;
      # local: COSIGN_PASSWORD for the on-disk 0600 key) — ALWAYS via Open3's env
      # hash, NEVER argv. env carries DOCKER_CONFIG for the registry auth cosign
      # needs to PUSH the signature.
      out, err, status = ::Open3.capture3(sign_env.merge(env), *cmd)
      unless status.success?
        raise CosignError,
              "cosign sign failed: #{::System::ShellOutputSanitizer.redact(err.presence) || "exit #{status.exitstatus}"}"
      end

      ::System::ShellOutputSanitizer.redact(out)
    end

    def signing_mode
      ::SiteSetting.get(MODE_SETTING).presence || DEFAULT_MODE
    end

    # Returns [cosign --key value, subprocess env]. The VAULT branch is
    # byte-identical to the historical path (hashivault:// + the server's Vault
    # session). The LOCAL branch points cosign at the self-generated on-box key
    # file (0600) and hands its password via env ONLY (never argv) — the private
    # key stays on disk, the password never reaches a process listing.
    def signing_key_flag_and_env
      if signing_mode == "local"
        material = ::System::ModuleSigningKey.ensure!
        [ material.key_path, { "COSIGN_PASSWORD" => material.password } ]
      else
        [ "hashivault://#{keyname}", vault_env ]
      end
    end

    # Builds the subprocess ENV hash cosign's hashivault:// KMS provider
    # needs: VAULT_ADDR + VAULT_TOKEN. Deliberately reuses the SAME
    # already-authenticated Vault session this server holds (AppRole
    # login result) rather than minting anything new — "the server's
    # existing Vault env." VAULT_TOKEN here is a short-lived Vault AUTH
    # token (not transit key material); cosign forwards it straight to
    # Vault's own HTTP API to authenticate the sign request. Passed as
    # Open3's env-hash argument (never argv, never interpolated into the
    # command string) so it never touches process listings or shell
    # history, and this method never logs its return value.
    def vault_env
      client = (@vault_client ||= ::Security::VaultClient.instance).client
      { "VAULT_ADDR" => client.address, "VAULT_TOKEN" => client.token }
    end

    # oci_ref may be "registry/name:tag" — cosign wants the digest form
    # "registry/name@sha256:...". Strips a trailing ":tag" without
    # touching the registry host (which may itself contain a ":port").
    def strip_tag(oci_ref)
      oci_ref.sub(%r{:[^:@/]+\z}, "")
    end

    def ensure_binary!(name)
      _out, _err, status = ::Open3.capture3("which", name)
      return if status.success?

      raise BinaryNotFoundError, "#{name} binary not found on PATH (required for ModuleSigningService)"
    end

    def emit_signed_event!(account:, oci_ref:, digest:, node_module_id:, node_module_version_id:)
      return unless account

      ::System::Fleet::EventBroadcaster.emit!(
        account: account,
        kind: "system.module_signed",
        severity: :low,
        source: "module_signing_service",
        node_module_id: node_module_id,
        node_module_version_id: node_module_version_id,
        payload: {
          oci_ref: oci_ref,
          digest: digest,
          mode: signing_mode,
          keyname: (signing_mode == "local" ? "local" : keyname)
        }
      )
    end
  end
end
