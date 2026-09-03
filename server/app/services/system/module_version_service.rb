# frozen_string_literal: true

module System
  # Service for managing module versioning operations
  # Handles version creation, rollback, and comparison
  class ModuleVersionService
    class VersionError < StandardError; end
    class LockError < VersionError; end
    class RollbackError < VersionError; end

    attr_reader :node_module, :current_user

    def initialize(node_module, current_user: nil)
      @node_module = node_module
      @current_user = current_user
    end

    # Create a new version of the module, capturing current state.
    #
    # MINTS A VERSION ROW ONLY — it does NOT move current_version_id.
    # (IMP-b7abf6c777da.) That column is the ARTIFACT actuator: it decides what
    # every instance carrying the module MOUNTS — has_data_file, the reported
    # current_version and the download artifact all resolve through
    # mod.current_version (NodeModuleNodeApiSerializer#serialize_module, and
    # node_api/modules_controller's download). It is not the whole manifest:
    # mask/file_spec/package_spec/dependency_spec/protected_spec/config are
    # served straight off the module ROW and always have been, so a spec edit
    # reaches attached instances either way. This method used to repoint the
    # column at every version it minted, and its widest caller is NodeModule's
    # `after_update :auto_create_version` callback, which fires on ANY save
    # touching NodeModule::VERSIONED_ATTRIBUTES — so an ordinary spec edit also
    # moved what the fleet MOUNTS, as a side effect, onto a version with no
    # build behind it, past every promotion guard (auto_promote opt-out,
    # non-empty artifact floor, core-provenance verdict, batch-atomic hold) and
    # with nothing armed to restart. Operator
    # direction: auto-versioning records a built version; promotion stays
    # behind the promote seam — NodeModule#promote_to_version! — and is the
    # CALLER's explicit decision (see #rollback_to, which makes it).
    #
    # @param changelog [String] optional description of changes
    # @param user [User] optional user who created this version
    # @param source_version [System::NodeModuleVersion] optional version to
    #   copy the build artifact bundle (erofs/OCI metadata) from. The bundle
    #   lives only on NodeModuleVersion, never on node_module, so it can't be
    #   recovered from node_module's own columns the way mask/file_spec/etc.
    #   can — callers that need it carried forward (rollback_to) must pass
    #   the version to copy it from explicitly.
    # @return [System::NodeModuleVersion] the created version
    def create_version(changelog: nil, user: nil, source_version: nil)
      raise LockError, "Module is locked and cannot be versioned" if node_module.locked?

      user ||= current_user

      ActiveRecord::Base.transaction do
        attrs = {
          changelog: changelog,
          created_by: user,
          mask: node_module.mask || {},
          file_spec: node_module.file_spec || {},
          package_spec: node_module.package_spec || {},
          config: node_module.config || {},
          data_file_name: node_module.data_file_name,
          data_checksum: node_module.data_checksum,
          data_file_size: node_module.data_file_size
        }
        attrs.merge!(artifact_bundle_of(source_version)) if source_version

        node_module.versions.create!(attrs)
      end
    end

    # Create initial version when module is first created. Like
    # #create_version it records the row without promoting it; a caller that
    # wants the fleet to serve it promotes through
    # NodeModule#promote_to_version!.
    # @return [System::NodeModuleVersion] the initial version
    def create_initial_version
      return if node_module.versions.exists?

      create_version(changelog: "Initial version")
    end

    # Rollback to a specific version.
    #
    # Rollback IS a promotion — the operator is saying "serve this instead" —
    # so, unlike #create_version, it moves current_version_id: onto the new
    # rollback version, through NodeModule#promote_to_version!, the sanctioned
    # writer. That is an X -> Y transition and so it ARMS
    # System::RestartAfterUpdate (NodeModule::ARM_ON_TRANSITIONS) — subject to
    # arm!'s own guard: a module that declares no restart_after_update unit
    # arms nothing, by design. Before IMP-b7abf6c777da this route reached the
    # column through #create_version's own `update!` and armed nothing at all:
    # the rolled-back artifact was served, but no unit was restarted onto it,
    # so instances kept RUNNING the build the operator had just rolled back
    # FROM until something else restarted them.
    #
    # @param version [System::NodeModuleVersion] the version to rollback to
    # @param changelog [String] optional description for the rollback
    # @param allow_confinement_removal [Boolean] a snapshot cannot be edited
    #   to state removal intent the way a config write can (key presence), so
    #   restoring one that lacks the module's current `security` / `verify`
    #   block requires this explicit acknowledgement instead — see the
    #   REMOVAL CONTRACT in System::ModuleConfigValidator. Notably the
    #   CI-publication paths mint versions whose config is just
    #   { "git_tag" => ... }; rolling back to one of those would otherwise
    #   silently strip the module's on-node confinement fleet-wide.
    # @return [System::NodeModuleVersion] new version created from rollback
    def rollback_to(version, changelog: nil, allow_confinement_removal: false)
      raise LockError, "Module is locked and cannot be modified" if node_module.locked?
      raise RollbackError, "Version does not belong to this module" unless version.node_module_id == node_module.id

      validate_restored_config!(version, allow_confinement_removal: allow_confinement_removal)

      changelog ||= "Rollback to version #{version.version_number}"

      ActiveRecord::Base.transaction do
        # Skip auto-versioning during rollback
        node_module.instance_variable_set(:@skip_auto_version, true)

        # Restore module state from version
        node_module.update!(
          mask: version.mask,
          file_spec: version.file_spec,
          package_spec: version.package_spec,
          config: version.config,
          data_file_name: version.data_file_name,
          data_checksum: version.data_checksum,
          data_file_size: version.data_file_size
        )

        node_module.instance_variable_set(:@skip_auto_version, false)

        # Create new version recording the rollback, carrying forward the
        # rolled-back-to version's build artifact bundle (erofs/OCI digest,
        # fsverity root, SBOM/provenance/VEX). Without this the rollback
        # version is spec-only: current_version&.artifact comes back nil and
        # the agent has nothing to deploy — rollback strands the module
        # instead of restoring the prior build.
        rollback_version = create_version(changelog: changelog, source_version: version)

        # The promotion decision, made explicitly and through the seam.
        node_module.promote_to_version!(rollback_version)

        rollback_version
      end
    end

    # Rollback to the previous version — the one before whatever is CURRENTLY
    # SERVED, not the one before the newest row minted.
    #
    # Raises RollbackError when current_version is nil, and since
    # IMP-b7abf6c777da that state is reachable: #create_version no longer
    # repoints the pointer, so a module whose promotion was withheld
    # (auto_promote opt-out, artifact floor, provenance verdict, batch hold)
    # can hold version rows with nothing promoted. The refusal is the intended
    # answer — nothing was ever served, so there is nothing to roll back FROM —
    # and the operator's route in that state is #rollback_to with an explicit
    # target. Pinned in spec/requests/api/v1/system/node_modules_rollback_spec.rb
    # ("no previous version" context).
    #
    # @return [System::NodeModuleVersion] new version created from rollback
    def rollback_to_previous(allow_confinement_removal: false)
      current = node_module.current_version
      raise RollbackError, "No current version to rollback from" unless current

      previous = current.previous_version
      raise RollbackError, "No previous version available" unless previous

      rollback_to(previous, changelog: "Rollback to version #{previous.version_number}",
                            allow_confinement_removal: allow_confinement_removal)
    end

    # Lock the module to prevent further changes
    # @return [Boolean] true if locked successfully
    def lock!
      raise LockError, "Module is already locked" if node_module.locked?

      node_module.update!(lock_spec: true)
    end

    # Unlock the module to allow changes (admin only typically)
    # @return [Boolean] true if unlocked successfully
    def unlock!
      raise LockError, "Module is not locked" unless node_module.locked?

      node_module.update!(lock_spec: false)
    end

    # Compare two versions and return differences
    # @param version_a [System::NodeModuleVersion] first version
    # @param version_b [System::NodeModuleVersion] second version
    # @return [Hash] differences between versions
    def compare_versions(version_a, version_b)
      {
        version_numbers: [ version_a.version_number, version_b.version_number ],
        mask_diff: diff_json(version_a.mask, version_b.mask),
        file_spec_diff: diff_json(version_a.file_spec, version_b.file_spec),
        package_spec_diff: diff_json(version_a.package_spec, version_b.package_spec),
        config_diff: diff_json(version_a.config, version_b.config),
        data_file_changed: version_a.data_checksum != version_b.data_checksum
      }
    end

    # Get version history with summary information
    # @param limit [Integer] maximum number of versions to return
    # @return [Array<Hash>] version history with summaries
    def version_history(limit: 20)
      node_module.versions.ordered.limit(limit).map do |version|
        {
          id: version.id,
          version_number: version.version_number,
          changelog: version.changelog,
          created_by: version.created_by&.email,
          created_at: version.created_at,
          is_current: version.current?,
          has_data_file: version.has_data_file?
        }
      end
    end

    private

    # IMP-01a02f50ce34 — rollback is a config WRITER: it restores
    # version.config verbatim onto the module, which is then serialized to
    # every node carrying it. A snapshot minted before the config gate landed
    # can carry a shape the gate now refuses (a verify probe with a
    # shell-metacharacter command, a hostile security block), and restoring
    # it would re-ship exactly what the write gate exists to keep off nodes —
    # so the restored config passes through the SAME shared validator, and a
    # snapshot that would silently drop the module's current confinement
    # (`security` / `verify`) needs the caller's explicit acknowledgement.
    #
    # A snapshot whose config fails errors_for outright is unrestorable even
    # WITH the acknowledgement — deliberately: the ack states "drop my
    # confinement", not "ship a config the gate refuses". The supported
    # escape hatch during an incident is promote-only recovery
    # (NodeModule#promote_to_version! / system_rollback_module_version moves
    # the artifact pointer without touching config), or fixing the config via
    # a gated write first.
    def validate_restored_config!(version, allow_confinement_removal:)
      restored = version.config || {}
      errors = ::System::ModuleConfigValidator.errors_for(restored)
      if errors.any?
        raise RollbackError,
              "version #{version.version_number}'s snapshotted config is no longer acceptable " \
              "(it predates the config write gate); refusing to re-ship it to nodes: #{errors.join('; ')}"
      end

      return if allow_confinement_removal

      removal = ::System::ModuleConfigValidator.removal_errors_for(restored, node_module.config || {})
      return if removal.none?

      dropped = ::System::ModuleConfigValidator::PROTECTED_CONFINEMENT_KEYS.select do |key|
        (node_module.config || {})[key].present? && !restored.key?(key)
      end
      raise RollbackError,
            "rolling back to version #{version.version_number} would drop config block(s) the module " \
            "currently carries (#{dropped.join(', ')}) — every node running the module would lose that " \
            "confinement. Pass acknowledge_confinement_removal to state that intent explicitly."
    end

    # The build artifact bundle a version carries: the erofs/OCI artifacts
    # JSONB plus the denormalized supply-chain metadata columns populated by
    # ModuleOciIngestService. See System::NodeModuleVersion#artifact.
    def artifact_bundle_of(source_version)
      {
        artifacts: source_version.artifacts || {},
        oci_digest: source_version.oci_digest,
        fsverity_root_hash: source_version.fsverity_root_hash,
        sbom_uri: source_version.sbom_uri,
        provenance_uri: source_version.provenance_uri,
        vex_uri: source_version.vex_uri
      }
    end

    def diff_json(hash_a, hash_b)
      hash_a ||= {}
      hash_b ||= {}

      all_keys = (hash_a.keys + hash_b.keys).uniq

      changes = {}
      all_keys.each do |key|
        val_a = hash_a[key]
        val_b = hash_b[key]
        next if val_a == val_b

        changes[key] = {
          from: val_a,
          to: val_b
        }
      end

      changes
    end
  end
end
