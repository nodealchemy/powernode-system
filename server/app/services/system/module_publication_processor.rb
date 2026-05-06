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
      def process!(node_module:, tag:)
        new.process!(node_module: node_module, tag: tag)
      end
    end

    def process!(node_module:, tag:)
      return failure("node_module required") unless node_module
      return failure("tag required") if tag.blank?

      # Order matters: refresh manifest FIRST so the version snapshot
      # captures the imported declaration, not stale module state.
      resolved_deps = refresh_manifest!(node_module, tag)
      node_module_version = find_or_create_version(node_module, tag)

      oci_ref = build_oci_ref(node_module, tag)
      ingest = ::System::ModuleOciIngestService.ingest!(
        node_module_version: node_module_version,
        oci_ref: oci_ref
      )

      if ingest.ok?
        register_skills_for(node_module)
        emit_published_event(node_module, node_module_version, oci_ref, ingest.module_artifacts, tag)
        Result.new(
          ok?: true,
          node_module_version: node_module_version,
          artifacts: ingest.module_artifacts,
          resolved_dependencies: resolved_deps
        )
      else
        Rails.logger.warn "[ModulePublicationProcessor] ingest failed: #{ingest.error}"
        emit_publish_failed_event(node_module, tag, ingest.error)
        Result.new(
          ok?: false,
          error: ingest.error,
          node_module_version: node_module_version,
          resolved_dependencies: resolved_deps
        )
      end
    end

    private

    def failure(message)
      Result.new(ok?: false, error: message, resolved_dependencies: [])
    end

    def build_oci_ref(node_module, tag)
      registry = ENV.fetch("POWERNODE_OCI_REGISTRY", "registry.example.com")
      "#{registry}/#{node_module.gitea_repo_full_name}:#{tag}"
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
      unless result.ok?
        Rails.logger.warn "[ModulePublicationProcessor] manifest re-import failed at tag #{tag}: #{result.error}"
        return []
      end
      node_module.reload
      Rails.logger.info "[ModulePublicationProcessor] manifest refreshed at tag #{tag}: " \
                        "#{result.resolved_dependencies.size} dependency reference(s)"
      result.resolved_dependencies
    end

    def register_skills_for(node_module)
      return unless defined?(::System::ModuleSkillRegistrar)
      result = ::System::ModuleSkillRegistrar.register_for_module!(node_module: node_module)
      unless result.ok?
        Rails.logger.warn "[ModulePublicationProcessor] skill registration failed: #{result.error}"
      end
    rescue StandardError => e
      Rails.logger.warn "[ModulePublicationProcessor] skill registrar raised: #{e.class}: #{e.message}"
    end

    def emit_published_event(node_module, version, oci_ref, artifacts, tag)
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
          arches:         artifacts.map(&:architecture)
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
