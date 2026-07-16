# frozen_string_literal: true

module System
  # Runs the post-version-creation chain for a module publication:
  # manifest re-import → OCI ingest → skill registration → fleet event
  # emission. Extracted from GiteaModuleController so the same chain
  # can run from two callers:
  #
  #   - The synchronous webhook receiver (when worker dispatch is
  #     unavailable / disabled / in dev — same behavior as before)
  #   - The internal processing endpoint hit by the async worker job
  #     (production path — webhook returns 200 immediately)
  #
  # Each side effect is independently non-fatal: manifest fetch
  # failure, OCI ingest failure, skill registrar raise, broadcaster
  # raise — none of these abort the chain. Failure surfaces via
  # log + a system.module_publish_failed FleetEvent so the operator
  # sees the issue in the dashboard rather than silent loss.
  #
  # Reference: Golden Eclipse plan M1 (module supply chain) — async
  # variant from the audit notes 2026-05-02.
  class ModulePublicationProcessor
    Result = Struct.new(:ok?, :error, :node_module_version, :artifacts,
                        :resolved_dependencies, keyword_init: true)

    class << self
      def process!(node_module:, tag:, promote: true, native_build: nil)
        new.process!(node_module: node_module, tag: tag, promote: promote, native_build: native_build)
      end
    end

    # @param promote [Boolean] whether a successful ingest advances
    #   node_module.current_version_id (campaign 019f5885 inc10 — dual-run
    #   shadow mode). Default true preserves every existing caller's
    #   behavior (Gitea webhook, CI-direct publish, the native authoritative
    #   path). Callers publishing a SHADOW native build (mode == "dual")
    #   pass promote: false so the ingest still creates a NodeModuleVersion +
    #   ModuleArtifact rows (parity comparison needs those) without ever
    #   moving current_version_id off whatever the Gitea build published —
    #   the fleet keeps consuming exactly what it consumed before.
    # @param native_build [Hash, nil] present ONLY for native (module-forge)
    #   builds — carries the agent build result's {fsverity_root:,
    #   architecture:}. When present, the artifact is recorded from the
    #   registry-resolved erofs LAYER (blob) digest via
    #   ModuleOciIngestService.ingest_native! instead of the multi-arch
    #   index + cosign ingest! path. nil (every Gitea webhook / CI-direct
    #   caller) preserves the exact prior behavior — ingest! is called
    #   byte-for-byte as before. See NativeModuleBuildOrchestrator#finalize_success!.
    def process!(node_module:, tag:, promote: true, native_build: nil)
      return failure("node_module required") unless node_module
      return failure("tag required") if tag.blank?

      # Order matters: refresh manifest FIRST so the version snapshot
      # captures the imported declaration, not stale module state.
      resolved_deps = refresh_manifest!(node_module, tag)
      node_module_version = find_or_create_version(node_module, tag)

      # Single-format ingest — every CI publish produces one erofs OCI
      # ref. Cosign verification + per-arch ModuleArtifact rows happen
      # inside ModuleOciIngestService; this processor records the
      # canonical metadata into NodeModuleVersion.artifacts JSONB.
      oci_ref = build_oci_ref(node_module, tag)
      result = ingest_artifact(node_module, node_module_version, oci_ref, native_build)

      if result.ok?
        canonical = result.module_artifacts.find { |a| a.architecture == "amd64" } ||
                    result.module_artifacts.first
        if canonical
          node_module_version.update_columns(
            artifacts: {
              ::System::NodeModuleVersion::PRIMARY_ARTIFACT_FORMAT => {
                "oci_ref"       => oci_ref,
                "oci_digest"    => canonical.oci_digest,
                "fsverity_root" => canonical.fsverity_root_hash,
                "size"          => canonical.size_bytes,
                "media_type"    => canonical.media_type
              }
            }
          )
        end
        promote_current_version(node_module, node_module_version) if promote
        register_skills_for(node_module)
        emit_published_event(node_module, node_module_version, oci_ref, result.module_artifacts, tag, promote)
        Result.new(
          ok?: true,
          node_module_version: node_module_version,
          artifacts: result.module_artifacts,
          resolved_dependencies: resolved_deps
        )
      else
        Rails.logger.warn "[ModulePublicationProcessor] ingest failed: #{result.error}"
        emit_publish_failed_event(node_module, tag, result.error)
        Result.new(
          ok?: false,
          error: result.error,
          node_module_version: node_module_version,
          resolved_dependencies: resolved_deps
        )
      end
    end

    private

    def failure(message)
      Result.new(ok?: false, error: message, resolved_dependencies: [])
    end

    # Routes to the correct OCI ingest path. native_build present (module-forge
    # single-arch push) → resolve the real erofs blob digest from the registry;
    # nil (Gitea webhook / CI-direct publish) → the unchanged multi-arch index +
    # cosign ingest! path.
    def ingest_artifact(node_module, node_module_version, oci_ref, native_build)
      return ingest_default(node_module_version, oci_ref) unless native_build

      ::System::ModuleOciIngestService.ingest_native!(
        node_module_version: node_module_version,
        oci_ref: oci_ref,
        account: node_module.account,
        fsverity_root: native_build[:fsverity_root] || native_build["fsverity_root"],
        architecture: native_build[:architecture] || native_build["architecture"]
      )
    end

    def ingest_default(node_module_version, oci_ref)
      ::System::ModuleOciIngestService.ingest!(
        node_module_version: node_module_version,
        oci_ref: oci_ref
      )
    end

    # Registry host resolves through the same platform config DK1/DK4 built
    # for disk images (AdminSetting -> SecretStore/ENV -> Gitea provider
    # credential) — it's the same Gitea-hosted OCI registry, just a
    # different repo path. ENV.fetch stays as a final, dev-only fallback for
    # a box with neither AdminSetting nor a Gitea credential configured.
    def build_oci_ref(node_module, tag)
      registry = ::System::DiskImageRegistryConfig.registry_host(account: node_module.account).presence ||
                 ENV.fetch("POWERNODE_OCI_REGISTRY", ::System::DiskImageRegistryConfig::PLACEHOLDER_HOST)
      # gitea_repo_full_name is blank for every platform module (only the 5
      # custom per-repo modules set it). Mirror push.sh's hardcoded
      # `powernode/<module>` namespace as the fallback so the ingested/signed
      # ref matches where the artifact was actually pushed — otherwise this
      # builds `<registry>/:<tag>` (empty repo) and oras/cosign reject it.
      repo = node_module.gitea_repo_full_name.presence || "powernode/#{node_module.name}"
      "#{registry}/#{repo}:#{tag}"
    end

    # Idempotent: if a NodeModuleVersion already exists for this tag,
    # return it (Gitea retries are routine and re-running the processor
    # against the same version snapshot is fine — OCI ingest re-runs are
    # cheap and re-verify the cosign signature). Otherwise create a fresh
    # snapshot of the now-imported module state.
    def find_or_create_version(node_module, tag)
      existing = ::System::NodeModuleVersion
                   .where(node_module: node_module)
                   .where("config->>'git_tag' = ?", tag)
                   .order(version_number: :desc)
                   .first
      return existing if existing

      ::System::NodeModuleVersion.create!(
        node_module: node_module,
        changelog: "Auto-ingested from Gitea tag #{tag}",
        mask:           Array(node_module.mask),
        file_spec:      Array(node_module.file_spec),
        package_spec:   Array(node_module.package_spec),
        protected_spec: Array(node_module.protected_spec),
        config: { "git_tag" => tag }
      )
    end

    def refresh_manifest!(node_module, tag)
      yaml = ::System::ManifestFetchService.fetch(node_module: node_module, ref: tag)
      return [] unless yaml.present?

      result = ::System::ManifestImportService.import!(node_module: node_module, yaml: yaml)
      # ManifestImportService::Result = Struct.new(:ok?, ...) — accessor is `ok?`.
      # The `.success?` typo bubbled a NoMethodError up to process! and aborted
      # the whole publication path (no NodeModuleVersion created), defeating
      # the explicit "non-fatal when manifest yaml fails validation" guard.
      unless result.ok?
        Rails.logger.warn "[ModulePublicationProcessor] manifest re-import failed at tag #{tag}: #{result.error}"
        return []
      end
      node_module.reload
      Rails.logger.info "[ModulePublicationProcessor] manifest refreshed at tag #{tag}: " \
                        "#{result.resolved_dependencies.size} dependency reference(s)"
      result.resolved_dependencies
    end

    # Mirrors module_publications_controller's auto-promote: a publish
    # that survives cosign verification + OCI ingest has already cleared
    # every gate the platform enforces, so withholding current_version_id
    # buys nothing but drift between what's published and what the fleet
    # resolves (agents read node_module.current_version&.artifact; the
    # drift sensor + system_fleet_tool key off current_version&.oci_digest).
    def promote_current_version(node_module, version)
      return if node_module.current_version_id == version.id

      node_module.update_columns(current_version_id: version.id, updated_at: Time.current)
    end

    def register_skills_for(node_module)
      return unless defined?(::System::ModuleSkillRegistrar)
      result = ::System::ModuleSkillRegistrar.register_for_module!(node_module: node_module)
      # ModuleSkillRegistrar::Result = Struct.new(:ok?, ...) — the accessor
      # is `ok?`, not `success?`. The mismatch was getting swallowed by the
      # rescue below, masking failures (and tripping the gitea_module_spec
      # registrar mock which exposes the matching `ok?` shape).
      unless result.ok?
        Rails.logger.warn "[ModulePublicationProcessor] skill registration failed: #{result.error}"
      end
    rescue StandardError => e
      Rails.logger.warn "[ModulePublicationProcessor] skill registrar raised: #{e.class}: #{e.message}"
    end

    def emit_published_event(node_module, version, oci_ref, artifacts, tag, promoted)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account: node_module.account,
        kind: "system.module_published",
        severity: :low,
        source: "gitea_webhook",
        node_module_id: node_module.id,
        node_module_version_id: version.id,
        payload: {
          module_name:    node_module.name,
          version_number: version.version_number,
          git_tag:        tag,
          oci_ref:        oci_ref,
          arches:         artifacts.map(&:architecture),
          promoted:       promoted
        }
      )
    rescue StandardError => e
      Rails.logger.warn "[ModulePublicationProcessor] fleet event emit failed: #{e.class}: #{e.message}"
    end

    def emit_publish_failed_event(node_module, tag, error_message)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account: node_module.account,
        kind: "system.module_publish_failed",
        severity: :high,
        source: "gitea_webhook",
        node_module_id: node_module.id,
        payload: {
          module_name: node_module.name,
          git_tag:     tag,
          error:       error_message
        }
      )
    rescue StandardError => e
      Rails.logger.warn "[ModulePublicationProcessor] fleet event (failure) emit failed: #{e.class}: #{e.message}"
    end
  end
end
