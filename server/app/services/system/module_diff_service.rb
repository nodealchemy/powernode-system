# frozen_string_literal: true

module System
  # Compares two NodeModuleVersions and returns a structured diff:
  # added/removed files (rsync_spec deltas), package_spec changes,
  # mount-point differences, and a single summary fingerprint that's
  # stable across rebuilds.
  #
  # Used by:
  #   - the operator UI's "preview before apply" hover (M-FE-1)
  #   - the Concierge "what changes if I switch X to v2?" answer (M-FE-4)
  #   - the rolling_module_upgrade skill's plan disclosure (M6)
  #
  # Reference: Golden Eclipse plan F-11 Live Module Diff Preview.
  class ModuleDiffService
    # Diff result struct. file_changes carries up to MAX_FILE_DELTA entries
    # — beyond that we count + summarize rather than dump.
    Result = Struct.new(
      :ok?,
      :unchanged,
      :file_changes,
      :package_changes,
      :mount_changes,
      :fingerprint_a,
      :fingerprint_b,
      :error,
      keyword_init: true
    )

    MAX_FILE_DELTA = 200

    def self.compare(version_a:, version_b:, target: nil)
      new.compare(version_a: version_a, version_b: version_b, target: target)
    end

    def compare(version_a:, version_b:, target: nil)
      raise ArgumentError, "version_a required" unless version_a.is_a?(::System::NodeModuleVersion)
      raise ArgumentError, "version_b required" unless version_b.is_a?(::System::NodeModuleVersion)

      mod_a = version_a.node_module
      mod_b = version_b.node_module

      compiler = ::System::RsyncSpecCompiler
      a = compiler.compile(node_module: snapshot_module(mod_a, version_a), target: target)
      b = compiler.compile(node_module: snapshot_module(mod_b, version_b), target: target)

      if a.fingerprint == b.fingerprint
        return Result.new(
          ok?: true, unchanged: true,
          fingerprint_a: a.fingerprint, fingerprint_b: b.fingerprint,
          file_changes: { added: [], removed: [], total: 0, truncated: false },
          package_changes: { added: [], removed: [], unchanged: 0 },
          mount_changes: []
        )
      end

      Result.new(
        ok?: true,
        unchanged: false,
        file_changes: diff_rsync_specs(a.rsync_spec, b.rsync_spec),
        package_changes: diff_package_specs(a.package_spec, b.package_spec),
        mount_changes: diff_mount_points(version_a, version_b),
        fingerprint_a: a.fingerprint,
        fingerprint_b: b.fingerprint
      )
    rescue ArgumentError => e
      Result.new(ok?: false, error: e.message)
    rescue StandardError => e
      Rails.logger.error("[ModuleDiffService] #{e.class}: #{e.message}")
      Result.new(ok?: false, error: e.message)
    end

    private

    # Snapshot a NodeModule with the spec arrays from a specific version
    # so RsyncSpecCompiler produces the rsync_spec for that version, not
    # the module's current spec.
    #
    # Important: clear parent_module_id on the shadow so NodeModule#file_spec
    # returns the explicitly-assigned column value rather than delegating
    # to parent.dependency_spec at runtime. The diff service's purpose is
    # to compare what each version SHIPPED, not what the parent currently
    # delegates — for dependants those are different (the version's
    # snapshot was captured at create time, the parent has since drifted).
    def snapshot_module(node_module, version)
      shadow = node_module.dup
      shadow.id = node_module.id           # preserve associations
      shadow.parent_module_id = nil        # disable dependant inheritance for the diff
      shadow.mask = version.mask
      shadow.file_spec = version.file_spec
      shadow.package_spec = version.package_spec
      shadow.dependency_spec = version.dependency_spec if version.respond_to?(:dependency_spec)
      shadow
    end

    # Two rsync specs are line-arrays of "+ path" or "- path"; we extract
    # the include set per side and diff those. The spec format guarantees
    # absolute paths so set-membership is meaningful.
    def diff_rsync_specs(spec_a, spec_b)
      includes_a = extract_includes(spec_a)
      includes_b = extract_includes(spec_b)

      added = (includes_b - includes_a)
      removed = (includes_a - includes_b)
      total = added.size + removed.size
      truncated = total > MAX_FILE_DELTA

      {
        added: added.first(MAX_FILE_DELTA / 2),
        removed: removed.first(MAX_FILE_DELTA / 2),
        total: total,
        truncated: truncated
      }
    end

    def extract_includes(spec)
      Array(spec.to_s.lines).filter_map do |line|
        line.strip!
        next if line.empty?
        next unless line.start_with?("+ ", "+")
        line.sub(/\A\+\s+/, "").chomp
      end
    end

    def diff_package_specs(packages_a, packages_b)
      # RsyncSpecCompiler returns package_spec as a newline-joined string;
      # tokenize before set-comparison so order doesn't matter.
      a = tokenize_package_spec(packages_a)
      b = tokenize_package_spec(packages_b)
      {
        added: (b - a).sort,
        removed: (a - b).sort,
        unchanged: (a & b).size
      }
    end

    def tokenize_package_spec(spec)
      return [] if spec.blank?
      case spec
      when Array  then spec.map(&:to_s).reject(&:blank?)
      when String then spec.split(/\r?\n/).reject(&:blank?)
      else []
      end
    end

    # Mount-point comparison joins each version to its module's mount points
    # at the time of release. v0 returns nothing if the version doesn't
    # carry mount metadata; M-D2-1 audit snapshot will populate.
    def diff_mount_points(_version_a, _version_b)
      []
    end
  end
end
