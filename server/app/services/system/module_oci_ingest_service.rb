# frozen_string_literal: true

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

    private

    def failure(msg)
      Result.new(ok?: false, error: msg, module_artifacts: [])
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
        return { error: err.presence || "oras exit #{status.exitstatus}" } unless status.success?

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

      def verify_signature(oci_ref, expected_signers: nil, issuer_regexp: nil)
        ensure_binary!("cosign")
        cmd = [ "cosign", "verify", "--output", "json", oci_ref ]
        if expected_signers&.any?
          cmd += [ "--certificate-identity-regexp", expected_signers.join("|") ]
        end
        if issuer_regexp.present?
          cmd += [ "--certificate-oidc-issuer-regexp", issuer_regexp ]
        end
        out, err, status = Open3.capture3(*cmd)
        return { error: err.presence || "cosign exit #{status.exitstatus}" } unless status.success?

        { ok: true, bundle: out, signers: expected_signers || [], issuer: issuer_regexp }
      end

      private

      def ensure_binary!(name)
        return if system("which #{name} > /dev/null 2>&1")

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
