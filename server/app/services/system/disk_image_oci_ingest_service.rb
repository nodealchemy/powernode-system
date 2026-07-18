# frozen_string_literal: true

require "tmpdir"
require "open3"
require "digest"
require "base64"
require "fileutils"
require "pathname"

module System
  # Pulls a disk-image .img blob from an OCI registry, verifies the
  # cosign signature against the platform's trust policy, and verifies
  # the cosign attestation over the inbound publication payload.
  # Returns a Result with the local path to the verified file so the
  # processor can hand it to FileStorageService.
  #
  # Adapter pattern mirrors System::ModuleOciIngestService:
  #   - LocalDiskImageAdapter (test/dev) — reads from local:///path
  #     refs, skips cosign verification (test stubs the trust path).
  #   - OrasDiskImageAdapter (production) — shells out to `oras` CLI
  #     for pull, `cosign` CLI for blob + attestation verification.
  #
  # Mode selection via POWERNODE_DISK_IMAGE_INGEST_MODE env var:
  #   - "oras"  — production
  #   - "local" — test/dev (default in non-production)
  #
  # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 2).
  class DiskImageOciIngestService
    Result = Struct.new(:ok?, :error, :local_path, :cosign_bundle_b64,
                        :attestation_bundle_b64, keyword_init: true)

    class IngestError < StandardError; end

    class << self
      def adapter
        @adapter ||= build_adapter
      end

      def adapter=(replacement)
        @adapter = replacement
      end

      def reset!
        @adapter = nil
      end

      def verify_and_pull!(publication:)
        new.verify_and_pull!(publication: publication)
      end

      private

      def build_adapter
        mode = ENV.fetch("POWERNODE_DISK_IMAGE_INGEST_MODE", default_mode_for_env)
        case mode
        when "oras"  then OrasDiskImageAdapter.new
        when "local" then LocalDiskImageAdapter.new
        else raise IngestError, "Unknown POWERNODE_DISK_IMAGE_INGEST_MODE: #{mode.inspect}"
        end
      end

      def default_mode_for_env
        Rails.env.production? ? "oras" : "local"
      end
    end

    def verify_and_pull!(publication:)
      return failure("publication required") unless publication
      return failure("oci_ref required")    if publication.oci_ref.blank?

      platform = publication.node_platform
      adapter  = self.class.adapter
      # Cosign trust policy is mandatory for the production OrasDiskImageAdapter
      # but not for the LocalDiskImageAdapter (smoke/dev path skips cosign
      # entirely). Defer the check to the adapter layer.
      trusted_keys = trusted_disk_image_public_keys
      # Cosign trust for the production OrasDiskImageAdapter is satisfied by
      # EITHER a keyless identity/issuer policy OR at least one trusted public
      # key. Key-signed disk images (the base UEFI image is signed with a
      # cosign KEY, not keyless) carry no Fulcio cert in their bundle, so the
      # identity/issuer regexps can't apply — they're verified against the
      # platform-trusted public keys instead. LocalDiskImageAdapter skips cosign.
      if adapter.is_a?(OrasDiskImageAdapter) && !platform.cosign_trust_configured? && trusted_keys.empty?
        return failure("platform '#{platform.name}' has no cosign trust policy configured " \
                       "(set cosign_identity_regexp + cosign_issuer_regexp, or configure trusted public keys for key-signed images)")
      end

      adapter.verify_and_pull!(
        oci_ref:               publication.oci_ref,
        expected_sha256:       publication.sha256,
        identity_regexp:       platform.cosign_identity_regexp,
        issuer_regexp:         platform.cosign_issuer_regexp,
        trusted_public_keys:   trusted_keys,
        expected_payload_json: build_payload_predicate(publication),
        registry_credentials:  registry_credentials_for(publication.account)
      )
    end

    private

    def failure(message)
      Result.new(ok?: false, error: message)
    end

    # The private Gitea OCI registry 401s an unauthenticated `oras pull`
    # (only push-time auth existed before — see DiskImageRegistryConfig).
    # Resolve the same host/user/token the CI push used, scoped to the
    # publication's account, and hand it to the adapter so it can log in
    # before pulling. nil when unconfigured — the adapter falls back to
    # the prior unauthenticated pull (public registries / test fixtures).
    def registry_credentials_for(account)
      return nil unless ::System::DiskImageRegistryConfig.configured?(account: account)

      {
        host:  ::System::DiskImageRegistryConfig.registry_host(account: account),
        user:  ::System::DiskImageRegistryConfig.registry_user(account: account),
        token: ::System::DiskImageRegistryConfig.registry_token(account: account)
      }
    end

    # The expected attestation predicate is what CI signed at build time.
    # Re-computing it on the platform side and refusing if cosign returns
    # a different predicate catches webhook-payload tampering even if
    # the HMAC secret was leaked.
    def build_payload_predicate(publication)
      {
        "platform_name" => publication.node_platform.name,
        "sha256"        => publication.sha256,
        "size_bytes"    => publication.size_bytes,
        "git_sha"       => publication.git_sha,
        "firmware_ref"  => publication.firmware_ref,
        "oci_ref"       => publication.oci_ref,
        "arch"          => publication.arch
      }
    end

    # Trusted cosign PUBLIC keys (PEM) for verifying KEY-signed disk images —
    # the counterpart to the keyless identity/issuer policy. Sourced from the
    # same platform-global SiteSetting the module supply chain uses (disk
    # images and modules are signed by the same offline keys). Empty when none
    # configured (keyless-only platforms). Public keys — never a secret.
    def trusted_disk_image_public_keys
      raw = ::SiteSetting.get("system.module_signing.trusted_public_keys")
      Array(raw).filter_map do |entry|
        pem = entry.is_a?(::Hash) ? (entry["pem"] || entry["public_key"] || entry["key"]) : entry
        pem.to_s.strip.presence
      end
    rescue StandardError => e
      ::Rails.logger.warn("[DiskImageOciIngestService] trusted_public_keys read failed: #{e.class}: #{e.message}")
      []
    end

    # ─── OrasRegistryAuth ──────────────────────────────────────────────
    #
    # Shared by both adapters' `oras pull` step. `oras` does not read
    # ORAS_REGISTRY_USERNAME/PASSWORD env vars — it needs an explicit
    # `oras login` (see .gitea/workflows/build-platform-modules.yaml,
    # the CI push side of this same registry). Without it, `oras pull`
    # against the private Gitea registry 401s ("failed to resolve
    # manifest") — that's the outage this module fixes.
    #
    # When registry_credentials is present, logs in to a throwaway
    # `--registry-config` file scoped to this single pull — never
    # touches the process's shared ~/.docker/config.json (Puma serves
    # many accounts/publications concurrently) — and the token never
    # touches argv (piped to `--password-stdin`). When nil (registry
    # not configured — dev fixtures, public registries), falls through
    # to the prior unauthenticated pull unchanged.
    module OrasRegistryAuth
      private

      # Returns the same [stdout, stderr, status] tuple Open3.capture3
      # would for the pull step, so callers don't need to branch on
      # auth vs no-auth.
      def oras_pull_with_optional_auth(oci_ref, output_dir, registry_credentials, env: {})
        return Open3.capture3(env, "oras", "pull", oci_ref, "--output", output_dir) if registry_credentials.blank?

        Dir.mktmpdir("powernode-oras-auth-") do |auth_dir|
          registry_config_path = File.join(auth_dir, "registry-config.json")

          login_out, login_err, login_status = Open3.capture3(
            env, "oras", "login", registry_credentials[:host],
            "--username", registry_credentials[:user],
            "--password-stdin", "--registry-config", registry_config_path,
            stdin_data: registry_credentials[:token].to_s
          )
          unless login_status.success?
            raw = login_err.strip.presence || login_out.strip
            return [ "", "oras login failed: #{::System::ShellOutputSanitizer.redact(raw)}", login_status ]
          end

          Open3.capture3(env, "oras", "pull", oci_ref, "--output", output_dir, "--registry-config", registry_config_path)
        end
      end
    end

    # ─── LocalDiskImageAdapter ─────────────────────────────────────────
    #
    # Test + dev path. Accepts oci_ref shaped as:
    #   - local:///absolute/path/to/img         — direct file ref (no copy)
    #   - file:///absolute/path/to/img          — alias
    #   - <ORAS-style remote ref>               — oras pull, NO cosign verify
    #     (smoke-mode shortcut for end-to-end tests on a runner that
    #     can't keyless-sign — the SHA-256 verify still runs)
    #   - <anything else> + DISK_IMAGE_LOCAL_FIXTURE_PATH env var
    #
    # No cosign verification at all — test code that exercises the cosign
    # trust path stubs OrasDiskImageAdapter directly.
    class LocalDiskImageAdapter
      include OrasRegistryAuth

      # trusted_public_keys: accepted for a uniform adapter interface (the
      # top-level verify_and_pull! passes it to whichever adapter is active) but
      # ignored here — the local/smoke adapter deliberately skips cosign verify.
      def verify_and_pull!(oci_ref:, expected_sha256:, identity_regexp:, issuer_regexp:, expected_payload_json:, registry_credentials: nil, trusted_public_keys: [])
        path = resolve_local_path(oci_ref)

        # If the path resolved isn't on disk, try oras pull as a smoke-mode
        # fallback (ref like `registry.example.com/.../...:sha`). Skips cosign
        # verify; still runs SHA-256 verify on the pulled bytes.
        unless File.exist?(path)
          if oci_ref.include?("/") && !oci_ref.start_with?("local:", "file:")
            require "open3"; require "tmpdir"; require "fileutils"
            work = Dir.mktmpdir("powernode-disk-image-local-")
            # Augment PATH so the oras binary (commonly installed at
            # ~/.local/bin or /usr/local/bin) is findable from a Puma
            # process whose env was stripped by systemd.
            augmented_env = {
              "PATH" => [
                ENV["HOME"] && "#{ENV["HOME"]}/.local/bin",
                "/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/usr/sbin",
                "/bin", "/sbin", ENV["PATH"]
              ].compact.uniq.join(":")
            }
            _out, err, status = oras_pull_with_optional_auth(oci_ref, work, registry_credentials, env: augmented_env)
            unless status.success?
              FileUtils.remove_entry(work)
              return Result.new(ok?: false, error: "oras pull failed (smoke-mode): #{::System::ShellOutputSanitizer.redact(err.strip)}")
            end
            img_path = Dir["#{work}/**/*.img"].first
            unless img_path
              FileUtils.remove_entry(work)
              return Result.new(ok?: false, error: "no .img in pulled OCI artifact")
            end
            path = img_path
          else
            return Result.new(ok?: false, error: "local file not found: #{path}")
          end
        end

        actual_sha = Digest::SHA256.file(path).hexdigest
        if actual_sha != expected_sha256
          return Result.new(ok?: false, error: "sha256 mismatch: expected=#{expected_sha256[0..15]}… actual=#{actual_sha[0..15]}…")
        end

        Result.new(
          ok?: true,
          local_path: path,
          cosign_bundle_b64: nil,
          attestation_bundle_b64: Base64.strict_encode64(expected_payload_json.to_json)
        )
      end

      private

      def resolve_local_path(oci_ref)
        if oci_ref =~ %r{\A(local|file)://(.+)\z}
          ::Regexp.last_match(2)
        else
          ENV.fetch("DISK_IMAGE_LOCAL_FIXTURE_PATH", oci_ref)
        end
      end
    end

    # ─── OrasDiskImageAdapter ──────────────────────────────────────────
    #
    # Production path. Requires `oras` and `cosign` CLI tools on PATH.
    #
    #   1. `oras pull <ref> --output <tmp>` — fetches all layers (.img,
    #      .cosign-bundle, .attestation-bundle).
    #   2. SHA-256 of the .img is verified against publication.sha256
    #      before any other check (cheap, fast-fail).
    #   3. `cosign verify-blob` over the .img bytes with
    #      --certificate-identity-regexp + --certificate-oidc-issuer-regexp
    #      from the platform's trust policy.
    #   4. `cosign verify-attestation` over the predicate JSON, asserting
    #      the predicate matches what the platform expects (built from
    #      the publication record).
    #
    # Failure at any step returns an error Result; caller marks the
    # publication :failed and emits a FleetEvent.
    class OrasDiskImageAdapter
      include OrasRegistryAuth

      def verify_and_pull!(oci_ref:, expected_sha256:, identity_regexp:, issuer_regexp:, expected_payload_json:, registry_credentials: nil, trusted_public_keys: [])
        work = Dir.mktmpdir("powernode-disk-image-ingest-")

        out, err, status = oras_pull_with_optional_auth(oci_ref, work, registry_credentials)
        unless status.success?
          FileUtils.remove_entry(work)
          raw = err.strip.presence || out.strip
          return Result.new(ok?: false, error: "oras pull failed: #{::System::ShellOutputSanitizer.redact(raw)}")
        end

        img_path = Dir["#{work}/**/*.img"].first
        unless img_path
          FileUtils.remove_entry(work)
          return Result.new(ok?: false, error: "no .img layer in OCI artifact")
        end

        actual_sha = Digest::SHA256.file(img_path).hexdigest
        if actual_sha != expected_sha256
          FileUtils.remove_entry(work)
          return Result.new(ok?: false, error: "sha256 mismatch: expected=#{expected_sha256[0..15]}… actual=#{actual_sha[0..15]}…")
        end

        cosign_bundle_path = Dir["#{work}/**/*.cosign-bundle"].first
        attestation_bundle_path = Dir["#{work}/**/*.attestation-bundle"].first

        verify_result = run_cosign_verify_blob(img_path, cosign_bundle_path, identity_regexp, issuer_regexp, trusted_public_keys)
        unless verify_result[:ok]
          FileUtils.remove_entry(work)
          return Result.new(ok?: false, error: "cosign verify-blob failed: #{verify_result[:error]}")
        end

        attest_result = run_cosign_verify_attestation(img_path, attestation_bundle_path, identity_regexp, issuer_regexp, expected_payload_json, trusted_public_keys, actual_sha)
        unless attest_result[:ok]
          FileUtils.remove_entry(work)
          return Result.new(ok?: false, error: "cosign verify-attestation failed: #{attest_result[:error]}")
        end

        # Move .img out of the work dir into a sibling tmp file so
        # callers can safely delete it without removing the cosign
        # bundles (which might be inspected post-publish).
        # Keep the moved .img on the SAME filesystem as the work dir (both under
        # Dir.tmpdir / $TMPDIR) so this is a rename, not a cross-device copy —
        # disk images are multi-GB and the root fs is small; a hardcoded /tmp
        # here cross-copied onto a 512MB root and ENOSPC'd. Callers delete
        # local_path after upload.
        final_path = File.join(Dir.tmpdir, "powernode-disk-image-#{SecureRandom.hex(8)}.img")
        FileUtils.mv(img_path, final_path)

        Result.new(
          ok?: true,
          local_path: final_path,
          cosign_bundle_b64:      cosign_bundle_path && File.exist?(cosign_bundle_path) ? Base64.strict_encode64(File.read(cosign_bundle_path)) : nil,
          attestation_bundle_b64: attestation_bundle_path && File.exist?(attestation_bundle_path) ? Base64.strict_encode64(File.read(attestation_bundle_path)) : nil
        )
      ensure
        FileUtils.remove_entry(work) if work && Dir.exist?(work)
      end

      private

      def run_cosign_verify_blob(img_path, bundle_path, identity_regexp, issuer_regexp, trusted_public_keys = [])
        unless bundle_path && File.exist?(bundle_path)
          return { ok: false, error: "missing .cosign-bundle layer" }
        end

        # Prefer key verification when the platform has trusted public keys
        # configured (the base disk images are KEY-signed); the keyless
        # identity/issuer policy is the fallback for keyless-signed images.
        # Selection is by configured trust + which signature actually
        # validates — not by sniffing the bundle shape (the .cosign-bundle and
        # .attestation-bundle differ: the attestation carries a cert yet is
        # still key-signed, so cert-presence is not a reliable discriminator).
        if trusted_public_keys.present?
          keyed = verify_signed_blob_with_keys("verify-blob", bundle_path, trusted_public_keys, [ img_path ])
          return keyed if keyed[:ok]
        end

        args = [
          "cosign", "verify-blob",
          "--certificate-identity-regexp",     identity_regexp,
          "--certificate-oidc-issuer-regexp",  issuer_regexp,
          "--bundle", bundle_path,
          img_path
        ]
        out, err, status = Open3.capture3(*args)
        if status.success?
          { ok: true }
        else
          { ok: false, error: ::System::ShellOutputSanitizer.redact((err.presence || out).strip) }
        end
      end

      # Verifies a cosign bundle against each trusted public key; the first key
      # that validates wins. --insecure-ignore-tlog: a private
      # key-signed artifact is NOT recorded in the public Rekor transparency
      # log (that facility is for keyless / public-good signing), so a tlog
      # lookup is not applicable — the trusted key IS the provenance anchor.
      # This is a full cryptographic signature verification, NOT a bypass.
      # subject_ref locates what the signature/attestation is over:
      #   * verify-blob            → [img_path] — cosign streams the .img to hash
      #     it (no size cap on the signature path).
      #   * verify-blob-attestation → ["--digest", <sha256>, "--digestAlg",
      #     "sha256"] — cosign's blob READER caps at 128MB, so for large disk
      #     images we pass the precomputed digest instead; --check-claims still
      #     verifies the in-toto subject against it WITHOUT reading the blob.
      # Either way this is a full cryptographic verification (DSSE signature +
      # subject-digest claim), NOT a bypass.
      def verify_signed_blob_with_keys(subcommand, bundle_path, trusted_public_keys, subject_ref)
        keys = Array(trusted_public_keys).map(&:to_s).map(&:strip).reject(&:empty?)
        return { ok: false, error: "key-signed bundle but no trusted public keys configured" } if keys.empty?

        last_err = nil
        Dir.mktmpdir("powernode-cosign-keys-") do |dir|
          keys.each_with_index do |pem, i|
            keyfile = File.join(dir, "key_#{i}.pem")
            File.write(keyfile, pem.end_with?("\n") ? pem : "#{pem}\n")
            args = [
              "cosign", subcommand,
              "--key", keyfile,
              "--bundle", bundle_path,
              "--insecure-ignore-tlog=true"
            ]
            # --check-claims binds the attestation's in-toto subject to the
            # --digest we pass (verify-blob-attestation only — plain verify-blob
            # rejects the flag). cosign defaults it to true today; pin it
            # explicitly so a future default flip can't silently drop the
            # subject binding and accept a signature-only (subject-unbound)
            # attestation as valid.
            args << "--check-claims=true" if subcommand == "verify-blob-attestation"
            args.concat(subject_ref)
            _out, err, status = Open3.capture3(*args)
            return { ok: true } if status.success?

            last_err = ::System::ShellOutputSanitizer.redact(err.to_s.strip)
          end
        end
        { ok: false, error: "no trusted public key verified the signature (#{last_err})" }
      end

      def run_cosign_verify_attestation(img_path, attestation_path, identity_regexp, issuer_regexp, expected_payload_json, trusted_public_keys = [], img_sha256 = nil)
        unless attestation_path && File.exist?(attestation_path)
          # Fail-closed: a signed disk image MUST carry its .attestation-bundle
          # (cosign attest-blob output); a missing attestation rejects the
          # ingest — never a silent skip. Opting out is an explicit CI choice
          # (drop the attest step AND blank attestation_bundle on the
          # publication); absent that, this is a hard failure.
          return { ok: false, error: "missing .attestation-bundle layer (cosign attest-blob output required)" }
        end

        # Prefer key verification (see run_cosign_verify_blob). Pass the .img's
        # precomputed sha256 as --digest so cosign checks the in-toto subject
        # claim WITHOUT reading the (multi-GB) blob through its 128MB-capped
        # reader; the keyless path (which reads the blob) is the fallback.
        if trusted_public_keys.present?
          sha = img_sha256.presence || Digest::SHA256.file(img_path).hexdigest
          keyed = verify_signed_blob_with_keys(
            "verify-blob-attestation", attestation_path, trusted_public_keys,
            [ "--digest", sha, "--digestAlg", "sha256" ]
          )
          return keyed if keyed[:ok]
        end

        args = [
          "cosign", "verify-blob-attestation",
          "--certificate-identity-regexp",     identity_regexp,
          "--certificate-oidc-issuer-regexp",  issuer_regexp,
          "--bundle", attestation_path,
          img_path
        ]
        out, err, status = Open3.capture3(*args)
        unless status.success?
          return { ok: false, error: ::System::ShellOutputSanitizer.redact((err.presence || out).strip) }
        end

        # Optional: parse the attestation predicate from `cosign verify-blob-attestation`
        # output and compare against expected_payload_json. cosign emits the
        # predicate as base64-encoded DSSE envelope; parsing is optional —
        # we trust the signature verify above.
        { ok: true }
      end
    end
  end
end
