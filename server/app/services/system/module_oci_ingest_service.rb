# frozen_string_literal: true

require "tempfile"
require "net/http"
require "uri"
require "json"
require "base64"

module System
  # Ingests an OCI module artifact: pulls the manifest descriptors, verifies
  # the cosign signature, records one System::ModuleArtifact per architecture,
  # and denormalizes the canonical (oci_digest, fsverity_root_hash, sbom_uri,
  # provenance_uri, vex_uri) fields onto the parent NodeModuleVersion.
  #
  # Adapter pattern mirrors InternalCaService:
  # - LocalOciAdapter (test/dev) — returns deterministic stub manifests
  # - OrasOciAdapter   (production) — shells out to `oras` CLI for manifest fetch + cosign verify
  #
  # Reference: Golden Eclipse plan M1 supply chain, ModuleArtifact schema (M0.L).
  class ModuleOciIngestService
    Result = Struct.new(:ok?, :error, :node_module_version, :module_artifacts,
                        keyword_init: true)

    class IngestError < StandardError; end

    SUPPORTED_ARCHS = %w[amd64 arm64].freeze

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

      def ingest!(node_module_version:, oci_ref:, expected_signers: nil)
        new.ingest!(
          node_module_version: node_module_version,
          oci_ref: oci_ref,
          expected_signers: expected_signers
        )
      end

      # Native single-arch build path (see instance method below).
      def ingest_native!(node_module_version:, oci_ref:, account:, fsverity_root: nil, architecture: nil)
        new.ingest_native!(
          node_module_version: node_module_version,
          oci_ref: oci_ref,
          account: account,
          fsverity_root: fsverity_root,
          architecture: architecture
        )
      end

      private

      def build_adapter
        mode = ENV.fetch("POWERNODE_OCI_MODE", default_mode_for_env)
        case mode
        when "oras"  then OrasOciAdapter.new
        when "local" then LocalOciAdapter.new
        else raise IngestError, "Unknown POWERNODE_OCI_MODE: #{mode.inspect}"
        end
      end

      def default_mode_for_env
        Rails.env.production? ? "oras" : "local"
      end
    end

    def ingest!(node_module_version:, oci_ref:, expected_signers: nil)
      return failure("oci_ref required") if oci_ref.blank?
      return failure("node_module_version required") unless node_module_version

      adapter = self.class.adapter
      manifest = adapter.fetch_manifest(oci_ref)
      return failure("manifest fetch failed: #{manifest[:error]}") if manifest[:error]

      # Pull cosign trust policy from the parent NodeModule. Per-module
      # pinning means each module source (internal CI, third-party publisher)
      # can have its own accepted Sigstore identity/issuer pair.
      mod = node_module_version.node_module
      identity_regexp = mod.cosign_identity_regexp.presence
      issuer_regexp   = mod.cosign_issuer_regexp.presence
      effective_signers = expected_signers || (identity_regexp ? [ identity_regexp ] : nil)

      verification = adapter.verify_signature(
        oci_ref,
        expected_signers: effective_signers,
        issuer_regexp: issuer_regexp
      )
      return failure("cosign verify failed: #{verification[:error]}") if verification[:error]

      created = []
      ::ActiveRecord::Base.transaction do
        manifest[:per_arch_descriptors].each do |arch_desc|
          arch = arch_desc.fetch(:architecture)
          unless SUPPORTED_ARCHS.include?(arch)
            raise IngestError, "unsupported architecture in manifest: #{arch.inspect}"
          end

          artifact = ::System::ModuleArtifact.find_or_initialize_by(
            node_module_version: node_module_version,
            architecture: arch
          )
          artifact.assign_attributes(
            oci_ref:             oci_ref,
            oci_digest:          arch_desc.fetch(:oci_digest),
            media_type:          arch_desc.fetch(:media_type, ::System::ModuleArtifact::DEFAULT_MEDIA_TYPE),
            size_bytes:          arch_desc.fetch(:size_bytes, 0),
            fsverity_root_hash:  arch_desc[:fsverity_root_hash],
            cosign_bundle:       verification[:bundle],
            sbom_uri:            arch_desc[:sbom_uri],
            provenance_uri:      arch_desc[:provenance_uri],
            vex_uri:             arch_desc[:vex_uri],
            built_at:            arch_desc.fetch(:built_at, Time.current)
          )
          artifact.save!
          created << artifact
        end

        # Denormalize the "canonical" arch (prefer amd64, fallback to first)
        canonical = created.find { |a| a.architecture == "amd64" } || created.first
        if canonical
          node_module_version.update!(
            oci_digest:          canonical.oci_digest,
            fsverity_root_hash:  canonical.fsverity_root_hash,
            sbom_uri:            canonical.sbom_uri,
            provenance_uri:      canonical.provenance_uri,
            vex_uri:             canonical.vex_uri
          )
        end
      end

      Result.new(
        ok?: true,
        node_module_version: node_module_version.reload,
        module_artifacts: created
      )
    rescue IngestError => e
      failure(e.message)
    rescue ::ActiveRecord::RecordInvalid => e
      failure("artifact persistence failed: #{e.record.errors.full_messages.join('; ')}")
    rescue StandardError => e
      Rails.logger.error("[ModuleOciIngestService] #{e.class}: #{e.message}")
      failure("ingest failed: #{e.message}")
    end

    # ----------------------------------------------------------------------
    # Native single-arch build path (campaign hub-durable-modules).
    #
    # The ephemeral module-forge builder pushes a PLAIN single-arch image
    # manifest (one erofs layer + module.meta/module.packages sidecar
    # descriptors), NOT the multi-arch OCI index the OrasOciAdapter path
    # expects — so ingest! (which selects the dev LocalOciAdapter stub in
    # RAILS_ENV=development, or the index-shaped OrasOciAdapter in prod) is
    # wrong here on both counts: the stub FABRICATES the digest/size/fsverity
    # (bricking every node that pulls it), and the oras adapter errors "no
    # per-arch descriptors" on a plain manifest.
    #
    # This records the artifact from the erofs LAYER descriptor resolved
    # straight from the registry — layer[0].digest is the sha256 of the erofs
    # BLOB, which is EXACTLY what the agent verifies (sha256(downloaded blob)
    # == oci.digest during pull). The builder-reported oci_digest is the
    # MANIFEST descriptor digest (a different sha256) and must NEVER be stored
    # as the artifact digest. fs-verity root comes from the agent build result
    # (the builder computed it from the erofs bytes); size + media_type come
    # from the resolved layer descriptor.
    #
    # UNSIGNED by design: native pushes defer cosign (signing is a follow-up),
    # so there is no cosign_bundle and no signature verification on this path.
    # The agent's blob-hash + fs-verity is the integrity gate. The Gitea /
    # production webhook ingest! path (multi-arch index + cosign verify) is
    # left entirely untouched.
    def ingest_native!(node_module_version:, oci_ref:, account:, fsverity_root: nil, architecture: nil)
      return failure("oci_ref required") if oci_ref.blank?
      return failure("node_module_version required") unless node_module_version

      layer = resolve_erofs_layer(oci_ref, account, arch: native_arch(architecture))
      return failure("erofs layer resolution failed: #{layer[:error]}") if layer[:error]

      arch    = native_arch(architecture)
      created = []
      ::ActiveRecord::Base.transaction do
        artifact = ::System::ModuleArtifact.find_or_initialize_by(
          node_module_version: node_module_version,
          architecture: arch
        )
        artifact.assign_attributes(
          oci_ref:            oci_ref,
          oci_digest:         layer[:digest],
          media_type:         layer[:media_type].presence || ::System::ModuleArtifact::DEFAULT_MEDIA_TYPE,
          size_bytes:         layer[:size].to_i,
          fsverity_root_hash: fsverity_root.presence,
          cosign_bundle:      nil,
          built_at:           Time.current
        )
        artifact.save!
        created << artifact

        node_module_version.update!(
          oci_digest:         artifact.oci_digest,
          fsverity_root_hash: artifact.fsverity_root_hash
        )
      end

      Result.new(
        ok?: true,
        node_module_version: node_module_version.reload,
        module_artifacts: created
      )
    rescue ::ActiveRecord::RecordInvalid => e
      failure("artifact persistence failed: #{e.record.errors.full_messages.join('; ')}")
    rescue StandardError => e
      Rails.logger.error("[ModuleOciIngestService] native #{e.class}: #{e.message}")
      failure("native ingest failed: #{e.message}")
    end

    private

    def failure(msg)
      Result.new(ok?: false, error: msg, module_artifacts: [])
    end

    def native_arch(architecture)
      SUPPORTED_ARCHS.include?(architecture) ? architecture : "amd64"
    end

    # OCI Accept covering both single-arch image manifests (the native case)
    # and index manifests (defensive fallback — a native push should never be
    # an index).
    NATIVE_MANIFEST_ACCEPT = [
      "application/vnd.oci.image.manifest.v1+json",
      "application/vnd.oci.image.index.v1+json",
      "application/vnd.docker.distribution.manifest.v2+json",
      "application/vnd.docker.distribution.manifest.list.v2+json"
    ].join(", ").freeze

    NATIVE_INDEX_MEDIA_TYPES = %w[
      application/vnd.oci.image.index.v1+json
      application/vnd.docker.distribution.manifest.list.v2+json
    ].freeze

    # Resolves the erofs LAYER descriptor {digest:, size:, media_type:} for a
    # single-arch native push by GET-ing the OCI manifest at oci_ref. Returns
    # {error:} on any failure so the caller fails-closed (never records a
    # partial/guessed digest).
    #
    # Auth reuses System::DiskImageRegistryConfig — the SAME host + credentials
    # ModuleSigningService authenticated this exact ref with moments earlier in
    # the native path. HTTP Basic (user:token) is what the Gitea container
    # registry accepts (mirrors System::OciBlobProxyService and
    # System::OciLayerDigestFetcher). No new credential surface is introduced.
    def resolve_erofs_layer(oci_ref, account, arch: "amd64")
      m = oci_ref.match(%r{\A([^/]+)/(.+):([^:]+)\z})
      return { error: "unparseable oci_ref #{oci_ref.inspect}" } unless m

      registry, repo, tag = m[1], m[2], m[3]
      auth = native_registry_auth(account)

      fetched = fetch_native_manifest(registry, repo, tag, auth)
      return fetched if fetched[:error]

      doc = fetched[:doc]
      if NATIVE_INDEX_MEDIA_TYPES.include?(doc["mediaType"]) || (doc["layers"].nil? && doc["manifests"])
        entry = Array(doc["manifests"]).find { |x| x.dig("platform", "architecture") == arch } ||
                Array(doc["manifests"]).first
        return { error: "index manifest carried no sub-manifest" } unless entry

        fetched = fetch_native_manifest(registry, repo, entry["digest"], auth)
        return fetched if fetched[:error]

        doc = fetched[:doc]
      end

      layers = Array(doc["layers"])
      return { error: "manifest has no layers array" } if layers.empty?

      # The erofs FILESYSTEM layer (media type application/vnd.powernode.erofs)
      # — NOT the sibling application/vnd.powernode.module.meta /
      # .module.packages descriptor layers. Selector mirrors
      # OciLayerDigestFetcher / OciBlobProxyService exactly.
      erofs = layers.find { |l| l["mediaType"].to_s =~ /erofs/ } || layers.first
      {
        digest:     erofs["digest"].to_s,
        size:       erofs["size"].to_i,
        media_type: erofs["mediaType"].to_s
      }
    end

    def fetch_native_manifest(registry, repo, reference, auth)
      uri = URI("https://#{registry}/v2/#{repo}/manifests/#{reference}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 5
      http.read_timeout = 15
      req = Net::HTTP::Get.new(uri.request_uri)
      req["Accept"] = NATIVE_MANIFEST_ACCEPT
      req["Authorization"] = auth if auth
      res = http.request(req)
      return { error: "manifest fetch HTTP #{res.code}" } unless res.is_a?(Net::HTTPSuccess)

      { doc: JSON.parse(res.body) }
    rescue JSON::ParserError => e
      { error: "manifest JSON parse failed: #{e.message}" }
    rescue StandardError => e
      { error: "manifest fetch failed: #{e.class}: #{e.message}" }
    end

    # HTTP Basic header from the resolved registry user + token (NEVER logged).
    # Returns nil when the registry is unconfigured — the GET then goes out
    # unauthenticated, matching ModuleSigningService's "unconfigured registry
    # falls through" posture (dev fixtures / public registries).
    def native_registry_auth(account)
      user  = ::System::DiskImageRegistryConfig.registry_user(account: account)
      token = ::System::DiskImageRegistryConfig.registry_token(account: account)
      return nil if user.blank? || token.blank?

      "Basic " + ::Base64.strict_encode64("#{user}:#{token}")
    end

    # ----------------------------------------------------------------------
    # Local adapter — test/dev. Returns a deterministic stub manifest so
    # specs don't need a real registry or oras binary on PATH.
    # ----------------------------------------------------------------------
    class LocalOciAdapter
      attr_accessor :stub_manifest, :stub_verification

      def initialize
        # Default: emit a multi-arch (amd64+arm64) manifest with deterministic
        # digests derived from the oci_ref. Tests can override via accessors.
        @stub_manifest = nil
        @stub_verification = nil
      end

      def fetch_manifest(oci_ref)
        return @stub_manifest if @stub_manifest

        digest_suffix = ::Digest::SHA256.hexdigest(oci_ref)
        {
          per_arch_descriptors: SUPPORTED_ARCHS.map.with_index do |arch, i|
            {
              architecture:       arch,
              oci_digest:         "sha256:#{digest_suffix[0, 60]}#{i.to_s.rjust(4, '0')}",
              media_type:         ::System::ModuleArtifact::DEFAULT_MEDIA_TYPE,
              size_bytes:         12_345_000 + i,
              fsverity_root_hash: "fsv-#{digest_suffix[0, 40]}#{i}",
              sbom_uri:           "#{oci_ref}.sbom",
              provenance_uri:     "#{oci_ref}.prov",
              vex_uri:            "#{oci_ref}.vex",
              built_at:           Time.current
            }
          end
        }
      end

      def verify_signature(_oci_ref, expected_signers: nil, issuer_regexp: nil)
        return @stub_verification if @stub_verification

        { ok: true, bundle: "stub-cosign-bundle", signers: expected_signers || [],
          issuer: issuer_regexp }
      end
    end

    # ----------------------------------------------------------------------
    # Oras adapter — production. Shells out to `oras manifest fetch` for
    # multi-arch index + `cosign verify --bundle` for signature verification.
    # Reads `oras` and `cosign` from $PATH; returns errors when binaries are
    # absent so the caller can surface a clear config issue.
    # ----------------------------------------------------------------------
    class OrasOciAdapter
      def fetch_manifest(oci_ref)
        ensure_binary!("oras")
        out, err, status = Open3.capture3("oras", "manifest", "fetch", oci_ref)
        # oras may echo the auth header or `Authorization: Bearer …`
        # snippet in its error output (esp. on 401/403). Sanitize before
        # the err string lands in the operator-facing error: payload.
        return { error: ::System::ShellOutputSanitizer.redact(err.presence) || "oras exit #{status.exitstatus}" } unless status.success?

        parsed = JSON.parse(out)
        # Expect an OCI index manifest with `manifests` array (one per arch).
        manifests = Array(parsed["manifests"])
        return { error: "manifest had no per-arch descriptors" } if manifests.empty?

        per_arch = manifests.map do |m|
          arch = m.dig("platform", "architecture")
          {
            architecture:       arch,
            oci_digest:         m["digest"],
            media_type:         m["mediaType"],
            size_bytes:         m["size"].to_i,
            fsverity_root_hash: m.dig("annotations", "io.powernode.fsverity_root_hash"),
            sbom_uri:           m.dig("annotations", "io.powernode.sbom_uri"),
            provenance_uri:     m.dig("annotations", "io.powernode.provenance_uri"),
            vex_uri:            m.dig("annotations", "io.powernode.vex_uri"),
            built_at:           parse_built_at(m.dig("annotations", "io.powernode.built_at"))
          }
        end
        { per_arch_descriptors: per_arch }
      rescue JSON::ParserError => e
        { error: "manifest JSON parse failed: #{e.message}" }
      end

      # Trusted-key list, ordered Vault-key-first / legacy-Gitea-key-second
      # (campaign 019f5885 inc8 — migration window while builds cut over
      # from the static Gitea cosign key to platform-side Vault-transit
      # signing). Each entry is a PEM public key string.
      TRUSTED_KEYS_SETTING = "system.module_signing.trusted_public_keys"

      def verify_signature(oci_ref, expected_signers: nil, issuer_regexp: nil)
        ensure_binary!("cosign")

        keys = trusted_public_keys
        if keys.any?
          verify_with_trusted_keys(oci_ref, keys)
        else
          # Keyless fallback path — only works for modules signed by
          # an issuer Sigstore Fulcio trusts (GitHub, GitLab.com, etc).
          # Unchanged by the multi-key trusted-key path above: no
          # trusted key configured at all (neither the Vault key nor
          # the legacy static key) is exactly the pre-existing
          # "nothing configured" case.
          verify_keyless(oci_ref, expected_signers: expected_signers, issuer_regexp: issuer_regexp)
        end
      end

      private

      # Ordered: Vault-transit key(s) from SiteSetting FIRST (new,
      # preferred), legacy static Gitea key SECOND (env-configured,
      # kept only as a migration-window fallback entry). Verification
      # tries each in order and succeeds on the first match — this is
      # what lets both legacy-Gitea-signed and new-Vault-signed
      # artifacts verify while the fleet migrates. Public keys are not
      # secret; any read failure degrades to "no trusted keys from this
      # source" rather than raising, so a SiteSetting hiccup can't block
      # ingest (it just narrows verification to whatever other source is
      # configured, or keyless if none are).
      def trusted_public_keys
        (site_setting_trusted_keys + [ legacy_static_key ]).compact.uniq
      end

      def site_setting_trusted_keys
        raw = ::SiteSetting.get(TRUSTED_KEYS_SETTING)
        Array(raw).map(&:presence).compact
      rescue StandardError => e
        Rails.logger.warn("[OrasOciAdapter] trusted_public_keys SiteSetting read failed: #{e.message}")
        []
      end

      # The pre-inc8 verification path — a single static cosign public
      # key provisioned via POWERNODE_COSIGN_PUBLIC_KEY (inline) or
      # POWERNODE_COSIGN_PUBLIC_KEY_FILE (path). Kept as the trailing
      # fallback entry in the trusted-key list so operators who haven't
      # yet migrated the legacy key into the SiteSetting list keep
      # verifying exactly as before.
      def legacy_static_key
        if (inline = ENV["POWERNODE_COSIGN_PUBLIC_KEY"]).present?
          inline
        elsif (path = ENV["POWERNODE_COSIGN_PUBLIC_KEY_FILE"]).present? && File.exist?(path)
          File.read(path)
        end
      end

      def verify_with_trusted_keys(oci_ref, keys)
        last_error = nil
        keys.each do |pubkey_pem|
          result = verify_with_key(oci_ref, pubkey_pem)
          return result if result[:ok]

          last_error = result[:error]
        end

        { error: "no trusted key verified this artifact (tried #{keys.size} key(s)); last error: #{last_error}" }
      end

      # Verifies against one candidate public key. The PEM is written to
      # a tempfile (public keys are NOT secret — no special handling
      # needed beyond normal tempfile cleanup) and passed via `--key
      # <path>`, one cosign invocation per candidate. Using a tempfile
      # (rather than the old single-key path's global `ENV[...] =`
      # mutation) keeps concurrent verifications on different threads
      # from stepping on each other's key value.
      def verify_with_key(oci_ref, pubkey_pem)
        Tempfile.create([ "cosign_pub", ".pem" ]) do |f|
          f.write(pubkey_pem)
          f.flush
          cmd = [ "cosign", "verify", "--output", "json", "--key", f.path, oci_ref ]
          out, err, status = Open3.capture3(*cmd)
          unless status.success?
            return { error: ::System::ShellOutputSanitizer.redact(err.presence) || "cosign exit #{status.exitstatus}" }
          end

          { ok: true, bundle: out, signers: [], issuer: nil }
        end
      end

      def verify_keyless(oci_ref, expected_signers:, issuer_regexp:)
        cmd = [ "cosign", "verify", "--output", "json" ]
        if expected_signers&.any?
          cmd += [ "--certificate-identity-regexp", expected_signers.join("|") ]
        end
        if issuer_regexp.present?
          cmd += [ "--certificate-oidc-issuer-regexp", issuer_regexp ]
        end
        cmd << oci_ref

        out, err, status = Open3.capture3(*cmd)
        # cosign's verify failures often quote the certificate body,
        # which is fine to surface; sanitizer strips anything
        # secret-shaped regardless. nil-safe for the empty-err exit path.
        return { error: ::System::ShellOutputSanitizer.redact(err.presence) || "cosign exit #{status.exitstatus}" } unless status.success?

        { ok: true, bundle: out, signers: expected_signers || [], issuer: issuer_regexp }
      end

      def ensure_binary!(name)
        # Array-form Open3 (no shell) — matches the rest of this adapter's
        # shell-outs (Open3.capture3("oras", …)). `name` is a static literal
        # today ("oras"/"cosign"), but array form removes any shell-injection
        # surface and keeps the convention consistent. capture3 suppresses the
        # `which` output the same way the old `> /dev/null 2>&1` did.
        _out, _err, status = ::Open3.capture3("which", name)
        return if status.success?

        raise IngestError, "#{name} binary not found on PATH (required for OrasOciAdapter)"
      end

      def parse_built_at(value)
        return Time.current if value.blank?

        Time.parse(value)
      rescue ArgumentError
        Time.current
      end
    end
  end
end
