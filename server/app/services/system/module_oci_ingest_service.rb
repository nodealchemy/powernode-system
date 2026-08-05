# frozen_string_literal: true

require "tempfile"
require "tmpdir"
require "open3"
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
        when "local" then build_local_adapter!
        else raise IngestError, "Unknown POWERNODE_OCI_MODE: #{mode.inspect}"
        end
      end

      # The production default is "oras", but the mode is an ENV OVERRIDE —
      # so POWERNODE_OCI_MODE=local exported into a production environment
      # silently selected LocalOciAdapter, which FABRICATES artifact identity
      # (oci_digest / fsverity_root_hash / sizes are derived from the ref
      # string, never from a registry) and returns ok:true from every
      # verify_signature call. Nothing at the call site distinguished that
      # from a real ingest: the fabricated digest is a well-formed 64-hex
      # sha256 that satisfies ModuleArtifact's format validation, the
      # fabricated "stub-cosign-bundle" is persisted verbatim and makes the
      # artifact report `signed: true` to operators (ModuleBuildBatchSerializer),
      # and every node that later pulls the blob fails the agent's
      # sha256(blob) == oci.digest check — turning a misconfigured env var into
      # a fleet-wide mount outage. Selecting the stub against a real registry
      # has no legitimate use (an air-gapped install still needs REAL digests,
      # so it wants "oras" pointed at a local mirror, not a fabricator), so
      # this fails closed and names the misconfiguration.
      def build_local_adapter!
        if Rails.env.production?
          raise IngestError,
                "POWERNODE_OCI_MODE=local selects LocalOciAdapter, which fabricates " \
                "artifact identity and reports every signature as verified. Refusing " \
                "in production. Unset POWERNODE_OCI_MODE (production defaults to " \
                "\"oras\"), or point the oras adapter at a local/mirror registry."
        end

        LocalOciAdapter.new
      end

      def default_mode_for_env
        Rails.env.production? ? "oras" : "local"
      end
    end

    def ingest!(node_module_version:, oci_ref:, expected_signers: nil)
      return failure("oci_ref required") if oci_ref.blank?
      return failure("node_module_version required") unless node_module_version

      adapter = self.class.adapter

      # Pull cosign trust policy from the parent NodeModule. Per-module
      # pinning means each module source (internal CI, third-party publisher)
      # can have its own accepted Sigstore identity/issuer pair.
      mod = node_module_version.node_module
      identity_regexp = mod.cosign_identity_regexp.presence
      issuer_regexp   = mod.cosign_issuer_regexp.presence
      effective_signers = expected_signers || (identity_regexp ? [ identity_regexp ] : nil)

      # Authenticate to the registry for BOTH the manifest fetch and the cosign
      # verify. This path used to do neither: fetch_manifest shelled out to
      # `oras manifest fetch` with no login at all, relying on an ambient
      # credential that exists on a developer laptop and on no control plane,
      # and verify_signature was called without the registry_env keyword it
      # already accepts. Against the platform's own private Gitea registry that
      # fails at the first call with a bare "unauthorized", which reads like a
      # permissions problem rather than a missing login. ingest_native! had it
      # right already — same helper, same shape.
      #
      # BOTH calls must happen INSIDE the block: with_registry_docker_config
      # logs into a Dir.mktmpdir DOCKER_CONFIG that is deleted when the block
      # returns, so hoisting the env out and using it afterwards would point
      # oras and cosign at a directory that no longer exists.
      fetched = with_registry_docker_config(mod&.account) do |reg_env|
        manifest = adapter.fetch_manifest(oci_ref, registry_env: reg_env)
        next { error: "manifest fetch failed: #{manifest[:error]}" } if manifest[:error]

        verification = adapter.verify_signature(
          oci_ref,
          expected_signers: effective_signers,
          issuer_regexp: issuer_regexp,
          registry_env: reg_env
        )
        next { error: "cosign verify failed: #{verification[:error]}" } if verification[:error]

        { manifest: manifest, verification: verification }
      end
      return failure(fetched[:error]) if fetched.is_a?(Hash) && fetched[:error]

      manifest     = fetched.fetch(:manifest)
      verification = fetched.fetch(:verification)

      # Second, independent gate on the SAME hazard build_local_adapter! closes
      # at selection time. `adapter=` is public, so a console, an initializer,
      # or a future third adapter can put a fabricating adapter in place without
      # ever going through build_adapter. Rather than pattern-matching the
      # fabricated digest — which is indistinguishable from a real one BY DESIGN
      # (a genuine sha256 can end in "0000" too) — LocalOciAdapter stamps its
      # DEFAULT fabricated output with an explicit `stub: true` marker, and
      # persisting anything carrying that marker is refused outside TEST. The
      # @stub_manifest/@stub_verification overrides are deliberately NOT marked:
      # those carry caller-supplied, real-shaped fixtures and keep working
      # unchanged, which is also the escape hatch if a dev flow genuinely needs
      # a recorded artifact.
      #
      # Outside TEST rather than merely outside production, because DEVELOPMENT
      # is the environment that actually detonated: on 2026-07-16 the dev backend
      # (RAILS_ENV=development) re-ingested a native build through this stub,
      # fabricated the artifact metadata, and the poisoned versions were promoted
      # to fleet `current` — leaving base-os and hub-frontend unpullable
      # (sha256(blob) never matches a fabricated digest), wedging the
      # ci-native-builders pool and putting ops-hub one reboot from bricking to
      # initramfs. A fabricated artifact row has no legitimate purpose OUTSIDE a
      # spec run, so test is the only env where recording one is safe.
      if !Rails.env.test? && (manifest[:stub] || verification[:stub])
        return failure(
          "refusing to persist fabricated stub artifact identity in " \
          "#{Rails.env} (adapter #{adapter.class.name} returned stub-marked " \
          "descriptors); no artifact recorded and no version promoted"
        )
      end

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

      # R6 (task #48, Fable): the native promote path must VERIFY the signature it
      # just made — otherwise the signature is write-only and anchors nothing.
      # Enforced fail-closed ONLY when a trusted-key list is configured
      # (LocalOciAdapter/dev has none → skipped, preserving the legacy "unsigned
      # by design" behavior). Both the ops-hub LOCAL pubkey and the DEV Vault-
      # transit pubkey live in trusted_public_keys, so DEV-built ingested
      # artifacts pass too. Signing happens upstream (finalize_success! →
      # ModuleSigningService.sign!) BEFORE this ingest.
      adapter = self.class.adapter
      if adapter.respond_to?(:key_verification_available?) && adapter.key_verification_available?
        # Fable #1: cosign verify must PULL the manifest + .sig from the registry,
        # which 401s anonymous on the private Gitea OCI registry. Thread the SAME
        # throwaway-DOCKER_CONFIG registry auth ModuleSigningService.sign! used to
        # PUSH the signature moments earlier, so the just-made signature can
        # actually be fetched + verified. An auth-setup failure returns {error} →
        # fail-closed (never a silent skip that would promote an unverified build).
        verification = with_registry_docker_config(account) do |reg_env|
          adapter.verify_signature(oci_ref, registry_env: reg_env)
        end
        if verification[:error]
          return failure("R6 signature verification failed for #{oci_ref}: #{verification[:error]}")
        end
      end

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

    # Logs in to the platform's Gitea OCI registry into a THROWAWAY DOCKER_CONFIG
    # for the duration of the block and yields { "DOCKER_CONFIG" => dir } to thread
    # onto the R6 `cosign verify` (cosign honors DOCKER_CONFIG). Mirrors
    # ModuleSigningService#with_registry_auth exactly — same creds resolver, same
    # throwaway scope (never the shared ~/.docker/config.json; Puma serves many
    # accounts concurrently), token piped via stdin (never argv). Yields an empty
    # env when the registry is unconfigured (dev/public), matching the rest of
    # this service. A login FAILURE returns {error:} (fail-closed) so R6 never
    # records an artifact whose signature it could not fetch to verify.
    def with_registry_docker_config(account)
      # The suite must never authenticate against a real registry. This shells
      # out to `oras login <host>`, and a SUBPROCESS is the one network
      # boundary WebMock cannot intercept — rails_helper's `webmock/rspec`
      # blocks Net::HTTP everywhere (including this service's own native
      # manifest GET), so every other outbound path in this file is already
      # unreachable from a spec. This one escaped, and nothing below it was
      # environment-scoped.
      #
      # Keyed on TEST, deliberately not on production. `configured?` already
      # answers a production question ("is a registry configured") and a spec
      # fixture satisfies it trivially: a Gitea provider credential makes
      # registry_user resolve from external_username and registry_token from
      # access_token. Adding a second production-scoped check would leave the
      # suite exactly where it was. Writing it `unless Rails.env.production?`
      # would also silently disable registry auth in DEVELOPMENT, which is a
      # real environment that should still log in.
      #
      # Yields the same empty env as the unconfigured path, so an ingest spec
      # exercises everything except the shell-out (IMP-44b2b8e873fa).
      return yield({}) if Rails.env.test?

      return yield({}) unless account && ::System::DiskImageRegistryConfig.configured?(account: account)

      host  = ::System::DiskImageRegistryConfig.registry_host(account: account)
      user  = ::System::DiskImageRegistryConfig.registry_user(account: account)
      token = ::System::DiskImageRegistryConfig.registry_token(account: account)
      return yield({}) if host.blank? || user.blank? || token.blank?

      Dir.mktmpdir("powernode-verify-auth-") do |dir|
        env = { "DOCKER_CONFIG" => dir }
        _out, login_err, login_status = ::Open3.capture3(
          env, "oras", "login", host,
          "--username", user, "--password-stdin",
          stdin_data: token.to_s
        )
        if login_status.success?
          yield env
        else
          { error: "registry login for verify failed: " \
                   "#{::System::ShellOutputSanitizer.redact(login_err.presence) || "exit #{login_status.exitstatus}"}" }
        end
      end
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

      def fetch_manifest(oci_ref, registry_env: {})
        _ = registry_env # stub: no registry involved
        return @stub_manifest if @stub_manifest

        digest_suffix = ::Digest::SHA256.hexdigest(oci_ref)
        {
          # Self-identifying marker: everything below is FABRICATED from the ref
          # string, not read from a registry. ingest! refuses to persist marked
          # output in production (see the stub gate there). Only the default
          # fabrication is marked — @stub_manifest overrides are caller-supplied
          # fixtures and stay unmarked.
          stub: true,
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

      def verify_signature(_oci_ref, expected_signers: nil, issuer_regexp: nil, registry_env: {})
        return @stub_verification if @stub_verification

        # `stub: true` for the same reason as fetch_manifest: this is an
        # unconditional ok:true that verified nothing, and the bundle below is
        # a literal placeholder that would otherwise persist onto the artifact
        # and read as a real signature downstream.
        { ok: true, stub: true, bundle: "stub-cosign-bundle",
          signers: expected_signers || [], issuer: issuer_regexp }
      end
    end

    # ----------------------------------------------------------------------
    # Oras adapter — production. Shells out to `oras manifest fetch` for
    # multi-arch index + `cosign verify --bundle` for signature verification.
    # Reads `oras` and `cosign` from $PATH; returns errors when binaries are
    # absent so the caller can surface a clear config issue.
    # ----------------------------------------------------------------------
    class OrasOciAdapter
      # The erofs blob's mediaType within a single-arch image manifest's
      # `layers` array — see fetch_manifest_single_arch.
      EROFS_LAYER_MEDIA_TYPE = "application/vnd.powernode.erofs"

      def fetch_manifest(oci_ref, registry_env: {})
        ensure_binary!("oras")
        out, err, status = Open3.capture3(registry_env, "oras", "manifest", "fetch", oci_ref)
        # oras may echo the auth header or `Authorization: Bearer …`
        # snippet in its error output (esp. on 401/403). Sanitize before
        # the err string lands in the operator-facing error: payload.
        return { error: ::System::ShellOutputSanitizer.redact(err.presence) || "oras exit #{status.exitstatus}" } unless status.success?

        parsed = JSON.parse(out)
        # Expect an OCI index manifest with `manifests` array (one per arch).
        manifests = Array(parsed["manifests"])
        if manifests.empty?
          # scripts/module-build/push.sh (the bootstrap CI pipeline —
          # .gitea/workflows/build-platform-modules.yaml) pushes a plain
          # single-arch OCI image manifest, not a multi-arch index: it
          # builds and cosign-signs one architecture per invocation, with
          # no fan-out composition step. This is NOT the module-forge
          # "native" path (ingest_native!, UNSIGNED by design, no cosign
          # verification at all) — push.sh's "Cosign sign" step really
          # does sign these, so they must still go through the normal
          # verify_signature call below. Synthesize the same
          # per_arch_descriptors shape from the manifest's `layers` array
          # instead of silently erroring or dropping verification.
          return fetch_manifest_single_arch(parsed) if parsed["layers"].present?
          return { error: "manifest had no per-arch descriptors" }
        end

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

      def verify_signature(oci_ref, expected_signers: nil, issuer_regexp: nil, registry_env: {})
        ensure_binary!("cosign")

        keys = trusted_public_keys
        if keys.any?
          verify_with_trusted_keys(oci_ref, keys, registry_env: registry_env)
        else
          # Keyless fallback path — only works for modules signed by
          # an issuer Sigstore Fulcio trusts (GitHub, GitLab.com, etc).
          # Unchanged by the multi-key trusted-key path above: no
          # trusted key configured at all (neither the Vault key nor
          # the legacy static key) is exactly the pre-existing
          # "nothing configured" case.
          verify_keyless(oci_ref, expected_signers: expected_signers, issuer_regexp: issuer_regexp, registry_env: registry_env)
        end
      end

      # R6 (task #48): whether a trusted KEY-verification path is configured
      # (the SiteSetting list or the legacy env key). When true, ingest_native!
      # MUST key-verify the just-signed artifact before recording it
      # (fail-closed). When false (no trusted keys — dev / legacy-unsigned),
      # native ingest skips verification, preserving today's behavior.
      def key_verification_available?
        trusted_public_keys.any?
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

      def verify_with_trusted_keys(oci_ref, keys, registry_env: {})
        last_error = nil
        keys.each do |pubkey_pem|
          result = verify_with_key(oci_ref, pubkey_pem, registry_env: registry_env)
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
      def verify_with_key(oci_ref, pubkey_pem, registry_env: {})
        Tempfile.create([ "cosign_pub", ".pem" ]) do |f|
          f.write(pubkey_pem)
          f.flush
          # --insecure-ignore-tlog=true: ModuleSigningService#cosign_sign! signs
          # via `cosign sign --key hashivault://...` with tlog upload left at
          # its default (on) — the resulting bundle carries a real Rekor entry
          # when the signer reached the public tlog. Verifying that entry's
          # inclusion proof requires fetching Sigstore's TUF trusted root
          # (tuf-repo-cdn.sigstore.dev), which egress-restricted fleet nodes —
          # and ops-hub's own self-hosted platform — can't reach. The keyed
          # signature itself is still fully checked; only the optional tlog
          # inclusion proof is skipped. Mirrors the identical fix already
          # applied to DiskImageOciIngestService's verify_signed_blob_with_keys.
          cmd = [ "cosign", "verify", "--output", "json", "--insecure-ignore-tlog=true", "--key", f.path, oci_ref ]
          # registry_env carries the DOCKER_CONFIG cosign needs to PULL the
          # manifest + .sig from the private registry (Fable #1); {} inherits the
          # ambient env (dev / public registry), matching prior behavior.
          out, err, status = Open3.capture3(registry_env, *cmd)
          unless status.success?
            return { error: ::System::ShellOutputSanitizer.redact(err.presence) || "cosign exit #{status.exitstatus}" }
          end

          { ok: true, bundle: out, signers: [], issuer: nil }
        end
      end

      def verify_keyless(oci_ref, expected_signers:, issuer_regexp:, registry_env: {})
        cmd = [ "cosign", "verify", "--output", "json" ]
        if expected_signers&.any?
          cmd += [ "--certificate-identity-regexp", expected_signers.join("|") ]
        end
        if issuer_regexp.present?
          cmd += [ "--certificate-oidc-issuer-regexp", issuer_regexp ]
        end
        cmd << oci_ref

        out, err, status = Open3.capture3(registry_env, *cmd)
        # cosign's verify failures often quote the certificate body,
        # which is fine to surface; sanitizer strips anything
        # secret-shaped regardless. nil-safe for the empty-err exit path.
        return { error: ::System::ShellOutputSanitizer.redact(err.presence) || "cosign exit #{status.exitstatus}" } unless status.success?

        { ok: true, bundle: out, signers: expected_signers || [], issuer: issuer_regexp }
      end

      # push.sh doesn't set a platform/architecture annotation on its
      # single-arch pushes (confirmed: only org.opencontainers.image.created,
      # org.powernode.built_from_sha, org.powernode.packages-sha256 are set),
      # so there's no signal to read it from. The bootstrap CI runners that
      # invoke push.sh build for amd64 — same fallback default already used
      # by ModuleOciIngestService#native_arch for the sibling native-ingest
      # path when no architecture is supplied.
      def fetch_manifest_single_arch(parsed)
        erofs_layer = Array(parsed["layers"]).find { |l| l["mediaType"] == EROFS_LAYER_MEDIA_TYPE }
        return { error: "single-arch manifest has no #{EROFS_LAYER_MEDIA_TYPE} layer" } unless erofs_layer

        {
          per_arch_descriptors: [ {
            architecture:       "amd64",
            oci_digest:         erofs_layer["digest"],
            media_type:         erofs_layer["mediaType"],
            size_bytes:         erofs_layer["size"].to_i,
            fsverity_root_hash: parsed.dig("annotations", "io.powernode.fsverity_root_hash"),
            sbom_uri:           parsed.dig("annotations", "io.powernode.sbom_uri"),
            provenance_uri:     parsed.dig("annotations", "io.powernode.provenance_uri"),
            vex_uri:            parsed.dig("annotations", "io.powernode.vex_uri"),
            built_at:           parse_built_at(parsed.dig("annotations", "org.opencontainers.image.created"))
          } ]
        }
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
