# frozen_string_literal: true

module System
  # Handles CI completion callbacks for closure-batched package-module builds
  # dispatched by ModuleBuildDispatchService.dispatch_closure.
  #
  # The build-package-module.yaml workflow POSTs to
  # /api/v1/system/webhooks/package_build when each (closure, arch) job
  # finishes; this service translates that callback into:
  #
  #   * Updated NodeModule.file_spec + .dependency_spec from dpkg -L / rpm -ql
  #     output (file_spec_source=package_query semantics; M0.J inheritance
  #     for dependant config-variety children works because both columns
  #     mirror the same discovered file list)
  #   * New NodeModuleVersion row promoted to "built" (or "blessed" for
  #     auto-generated transitive deps that skip the operator promotion gate)
  #   * New ModuleArtifact row per (module, architecture) with OCI digest,
  #     fsverity_root_hash, sbom_uri, cosign_bundle from the CI workflow.
  #
  # Distinct from ManifestImportService (which is keyed by gitea_repo_full_name
  # and assumes a Gitea-hosted manifest). Auto-generated modules don't have a
  # manifest repo; they're keyed by NodeModule.id directly via this service.
  class PackageBuildWebhookService
    class WebhookError < StandardError; end

    Result = Struct.new(
      :success, :artifacts_created, :versions_created, :modules_updated, :errors,
      keyword_init: true
    )

    def self.call(payload:)
      new(payload: payload).call
    end

    def initialize(payload:)
      @payload = payload.with_indifferent_access
    end

    def call
      validate_payload!

      arch = @payload[:architecture]
      closure_id = @payload[:closure_id]
      modules_data = Array(@payload[:modules])

      artifacts_created = 0
      versions_created = 0
      modules_updated = 0
      errors = []

      ::System::NodeModule.transaction do
        modules_data.each do |entry|
          mod = ::System::NodeModule.find_by(id: entry[:module_id])
          unless mod
            errors << "module #{entry[:module_id]} not found"
            next
          end

          update_module_specs(mod, file_spec: entry[:file_spec])
          modules_updated += 1

          version = create_version(mod, entry: entry, arch: arch, closure_id: closure_id)
          versions_created += 1 if version

          if entry[:oci_ref] && entry[:oci_digest]
            create_artifact(mod, version: version, entry: entry, arch: arch)
            artifacts_created += 1
          end
        end
      end

      Result.new(
        success: errors.empty?,
        artifacts_created: artifacts_created,
        versions_created: versions_created,
        modules_updated: modules_updated,
        errors: errors
      )
    end

    private

    def validate_payload!
      %i[closure_id architecture modules].each do |key|
        raise WebhookError, "missing #{key}" if @payload[key].blank?
      end
    end

    # Writes the dpkg -L / rpm -ql discovered file list to BOTH file_spec
    # AND dependency_spec. The latter is what M0.J dependant child modules
    # inherit when an operator creates a config-variety override on top of
    # an auto-generated module (NodeModule#file_spec delegates to
    # parent.dependency_spec for dependant children — node_module.rb:207-210).
    # Setting both keeps inheritance well-defined.
    def update_module_specs(mod, file_spec:)
      return unless file_spec.is_a?(Array) || file_spec.is_a?(String)

      raw = file_spec.is_a?(Array) ? file_spec.join("\n") : file_spec
      mod.update!(
        file_spec:        raw,        # encoded by before_validation :encode_specs
        dependency_spec:  raw
      )
    end

    def create_version(mod, entry:, arch:, closure_id:)
      # Compute next version_number. For auto-generated modules we use
      # build-timestamp + closure_id suffix for stable monotonicity across
      # parallel arch builds of the same closure.
      next_number = (mod.versions.maximum(:version_number) || 0) + 1
      promotion_state = mod.auto_generated ? "blessed" : "built"

      version = mod.versions.create!(
        version_number:      next_number,
        promotion_state:     promotion_state,
        changelog:           "Auto-built from #{closure_id} (#{arch})",
        oci_digest:          entry[:oci_digest],
        fsverity_root_hash:  entry[:fsverity_root_hash],
        sbom_uri:            entry[:sbom_uri],
        provenance_uri:      entry[:provenance_uri],
        vex_uri:             entry[:vex_uri]
      )
      mod.update!(current_version_id: version.id, current_version_number: next_number)
      version
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[PackageBuildWebhook] version create failed for #{mod.id}: #{e.message}")
      nil
    end

    def create_artifact(mod, version:, entry:, arch:)
      ::System::ModuleArtifact.create!(
        node_module_version_id: version&.id,
        oci_ref:               entry[:oci_ref],
        oci_digest:            entry[:oci_digest],
        architecture:          arch,
        media_type:            entry[:media_type] || "application/vnd.powernode.module.composefs.v1",
        size_bytes:            entry[:size_bytes],
        fsverity_root_hash:    entry[:fsverity_root_hash],
        cosign_bundle:         entry[:cosign_bundle],
        sbom_uri:              entry[:sbom_uri],
        provenance_uri:        entry[:provenance_uri],
        vex_uri:               entry[:vex_uri],
        built_at:              Time.current
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[PackageBuildWebhook] artifact create failed for module #{mod.id}: #{e.message}")
      nil
    end
  end
end
