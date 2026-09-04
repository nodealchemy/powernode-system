# frozen_string_literal: true

module System
  # The PRODUCER of the module blob signature — the artefact the on-node
  # agent's Verifier can actually check.
  #
  # The platform has always signed modules as OCI IMAGE signatures (`cosign
  # sign <ref@digest>`, pushed to the registry as a .sig tag), which the
  # agent's `cosign verify-blob` cannot consume and which no node can reach
  # (the agent has no registry client, by design). This attaches the missing
  # subject: a `cosign sign-blob --bundle` over the erofs BYTES, made
  # server-side by ModuleSigningService#sign_blob! with the same key, and
  # persisted at NodeModuleVersion.artifacts.erofs.cosign_blob_bundle_b64 —
  # the store the node-facing serializer reads and the hop the fs-verity root
  # already takes. Nodes verify it against ModuleSigningTrust.public_keys.
  #
  # ONE seam for every publish path — ModulePublicationProcessor (Gitea
  # webhook ingest! and native ingest_native!) and ModulePublicationsController
  # (platform-CI notify) both call .attach! after writing the artifacts JSONB —
  # plus .backfill! for already-published versions.
  #
  # NON-BLOCKING by policy: a failed signing is logged and emitted as
  # system.module_blob_signing_failed, and the publish proceeds without a
  # bundle. Refusing the publish would make blob signing mandatory fleet-wide,
  # a policy change beyond producing the artefact — the same stance the
  # fs-verity root took. Enforcement is the NODE's opt-in
  # (agent module-signing mode), and the promote gate's opt-in
  # (Fleet::PromotionCriteria.signature_gate).
  class ModuleBlobSigner
    BUNDLE_KEY       = "cosign_blob_bundle_b64"
    EROFS_MEDIA_TYPE = "application/vnd.powernode.erofs"
    # Whether publishes sign blobs at all. Default ON everywhere except the
    # test environment, where a publish must not reach for a blob proxy or a
    # signer; specs that exercise signing set it explicitly.
    ENABLED_SETTING  = "system.module_signing.sign_blobs"

    Result = Struct.new(:ok?, :error, :bundle_b64, :skipped, keyword_init: true)

    class << self
      def enabled?
        configured = ::SiteSetting.get(ENABLED_SETTING)
        return configured if [ true, false ].include?(configured)

        !::Rails.env.test?
      rescue StandardError
        !::Rails.env.test?
      end

      # Does this version's erofs artifact carry a platform blob signature?
      def signed?(version)
        version&.artifact&.dig(BUNDLE_KEY).present?
      end

      # Signs the erofs blob recorded on `version` and merges the bundle into
      # artifacts.erofs. Never raises; never blocks the caller's publish.
      def attach!(version, node_module:)
        return Result.new(ok?: false, skipped: true, error: "blob signing disabled (#{ENABLED_SETTING})") unless enabled?

        erofs = version.artifact
        digest = erofs&.dig("oci_digest").presence || erofs&.dig(:oci_digest).presence
        oci_ref = erofs&.dig("oci_ref").presence || erofs&.dig(:oci_ref).presence
        if erofs.blank? || digest.blank? || oci_ref.blank?
          return Result.new(ok?: false, skipped: true,
                            error: "version #{version.id} has no erofs oci_digest/oci_ref to sign yet")
        end

        signed = ::System::ModuleSigningService.sign_blob!(
          oci_ref:                oci_ref,
          digest:                 digest,
          size:                   erofs["size"] || erofs[:size],
          account:                node_module.account,
          node_module:            node_module,
          node_module_version_id: version.id
        )
        unless signed.ok?
          report_failure(version, node_module, signed.error)
          return Result.new(ok?: false, error: signed.error)
        end

        merged = version.artifacts.deep_dup
        key = merged.key?("erofs") ? "erofs" : ::System::NodeModuleVersion::PRIMARY_ARTIFACT_FORMAT
        merged[key] = (merged[key] || {}).merge(BUNDLE_KEY => signed.bundle_b64)
        version.update_columns(artifacts: merged)
        Result.new(ok?: true, bundle_b64: signed.bundle_b64)
      rescue StandardError => e
        ::Rails.logger.error("[ModuleBlobSigner] #{e.class}: #{e.message}")
        report_failure(version, node_module, "#{e.class}: #{e.message}")
        Result.new(ok?: false, error: "#{e.class}: #{e.message}")
      end

      # Signs the CURRENT version of every module (optionally one account's)
      # that carries an erofs digest but no bundle. dry_run (the default)
      # only lists candidates. Returns
      # { candidates: [versions], signed:, failed:, errors: [strings] }.
      #
      # Current versions only: those are what the fleet mounts, and what an
      # enforcing node would refuse. Older rows stay unsigned until rolled
      # back to — rollback then re-publishes through the same seam.
      def backfill!(account: nil, dry_run: true)
        scope = ::System::NodeModuleVersion
                  .joins("INNER JOIN system_node_modules ON system_node_module_versions.id = system_node_modules.current_version_id")
                  .where("system_node_module_versions.artifacts -> 'erofs' ->> 'oci_digest' IS NOT NULL")
                  .where("system_node_module_versions.artifacts -> 'erofs' ->> ? IS NULL", BUNDLE_KEY)
                  .includes(node_module: :account)
        scope = scope.where(system_node_modules: { account_id: account.id }) if account
        candidates = scope.order(:id).to_a
        report = { candidates: candidates, signed: 0, failed: 0, errors: [] }
        return report if dry_run

        candidates.each do |version|
          result = attach!(version, node_module: version.node_module)
          if result.ok?
            report[:signed] += 1
          else
            report[:failed] += 1
            report[:errors] << "#{version.node_module.name}@#{version.version_number}: #{result.error}"
          end
        end
        report
      end

      private

      def report_failure(version, node_module, error)
        ::Rails.logger.error(
          "[ModuleBlobSigner] #{node_module.name} version #{version.id}: blob signing failed: #{error}. " \
          "Published WITHOUT a blob signature; a node enforcing module signing will refuse this version."
        )
        return unless node_module.account && defined?(::System::Fleet::EventBroadcaster)

        ::System::Fleet::EventBroadcaster.emit!(
          account:                node_module.account,
          kind:                   "system.module_blob_signing_failed",
          severity:               :medium,
          source:                 "module_blob_signer",
          node_module_id:         node_module.id,
          node_module_version_id: version.id,
          payload: { module_name: node_module.name, version_number: version.version_number, error: error }
        )
      rescue StandardError => e
        ::Rails.logger.warn("[ModuleBlobSigner] failure event emit failed: #{e.class}: #{e.message}")
      end
    end
  end
end
