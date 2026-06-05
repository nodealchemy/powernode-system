# frozen_string_literal: true

module System
  # Projects a set of resolved NodeModules into the compose-preview payload the
  # Visual Template Composer renders (M-FE-1): per-module serialization,
  # conflict detection, footprint estimate, and the dependency graph — all
  # without persisting anything. Extracted verbatim from
  # NodeTemplatesController#compose_preview's private helpers to keep that
  # controller under the 300-line guideline.
  #
  # Takes the FULL resolved closure (operator's explicit picks + transitively
  # required/recommended modules from DependencyResolutionService). The
  # `explicit_ids` set distinguishes the operator's direct selections from
  # auto-resolved dependencies in the serialized output and graph nodes.
  #
  # Reuses the same conflict-detection logic the build pipeline's
  # ModuleComposeExecutor applies, so the preview matches build-time behavior.
  class TemplateComposerService
    # modules — Array<System::NodeModule> already eager-loaded with
    #   :current_version, :category, :node_platform, :module_dependencies,
    #   :dependencies, :package_module_link.
    def initialize(modules)
      @modules = Array(modules)
    end

    # Serializes every module in the closure. `explicit_ids` is the set of
    # module ids the operator picked directly; everything else is flagged
    # auto_resolved.
    def serialize_modules(explicit_ids:)
      explicit = explicit_ids.to_set
      @modules.map { |m| serialize_module(m, auto_resolved: !explicit.include?(m.id)) }
    end

    def detect_conflicts
      conflicts = []
      module_ids = @modules.map(&:id).to_set

      # Hard conflict: explicit ModuleDependency rows of type "conflicts"
      # where both modules ended up in the closure. This catches the
      # apt/rpm `Conflicts:` semantics for package-driven modules.
      @modules.each do |m|
        next unless m.respond_to?(:module_dependencies)

        m.module_dependencies.conflicts.each do |conflict_dep|
          other_id = conflict_dep.dependency_id
          next unless module_ids.include?(other_id)

          conflicts << {
            kind: "module_dependency_conflict",
            severity: "error",
            source_id: m.id,
            source_name: m.name,
            target_id: other_id,
            target_name: conflict_dep.dependency&.name,
            detail: "#{m.name} declares a Conflicts: relation against #{conflict_dep.dependency&.name}"
          }
        end
      end

      # Hard conflict: two instance-variety modules in the same category.
      # Only one instance can ship per category; the second would silently
      # collide at build time.
      @modules.group_by(&:category_id).each do |cat_id, ms|
        instance_variety = ms.select { |m| m.variety == "instance" }
        if instance_variety.size > 1
          conflicts << {
            kind: "instance_variety_collision",
            category_id: cat_id,
            module_ids: instance_variety.map(&:id),
            detail: "Only one instance-variety module per category is allowed"
          }
        end
      end

      # Soft conflict: another module's file_spec covers paths this
      # module has claimed via protected_spec. Build pipeline will
      # auto-resolve (the other module's blob excludes the path), but
      # the operator probably wants to know — that's the whole point
      # of protected_spec being visible at composition time.
      decoded = @modules.each_with_object({}) do |m, acc|
        acc[m.id] = {
          module:         m,
          file_spec:      decode_b64_array(Array(m.file_spec)),
          protected_spec: decode_b64_array(Array(m.protected_spec))
        }
      end

      decoded.each do |claimer_id, claimer|
        next if claimer[:protected_spec].empty?
        decoded.each do |other_id, other|
          next if other_id == claimer_id
          next if other[:file_spec].empty?

          overlapping = claimer[:protected_spec].each_with_object([]) do |claim, acc|
            if other[:file_spec].any? { |fs| paths_overlap?(claim, fs) }
              acc << claim
            end
          end
          next if overlapping.empty?

          conflicts << {
            kind: "protected_spec_overlap",
            severity: "warning",
            claimer_id:   claimer[:module].id,
            claimer_name: claimer[:module].name,
            other_id:     other[:module].id,
            other_name:   other[:module].name,
            paths: overlapping,
            detail: "#{other[:module].name}'s file_spec covers paths claimed by " \
                    "#{claimer[:module].name}'s protected_spec. Build pipeline will " \
                    "exclude them from #{other[:module].name}'s blob; only " \
                    "#{claimer[:module].name} will ship them."
          }
        end
      end

      conflicts
    end

    def footprint
      {
        module_count: @modules.size,
        estimated_package_count: @modules.sum { |m| Array(m.respond_to?(:package_spec) ? m.package_spec : []).size },
        architectures: @modules.map { |m| m.node_platform&.node_architecture&.name }.compact.uniq
      }
    end

    def dependency_graph(explicit_ids:)
      explicit = explicit_ids.to_set
      ids = @modules.map(&:id).to_set

      # Layer 1: parent_module hierarchy (config/instance dependant children)
      parent_edges = @modules.filter_map do |m|
        next unless m.respond_to?(:parent_module_id) && m.parent_module_id && ids.include?(m.parent_module_id)

        { source: m.parent_module_id, target: m.id, type: "depends_on" }
      end

      # Layer 2: ModuleDependency edges (requires/recommends from the new
      # package-driven materializer + any operator-authored dependencies).
      # Only include edges where BOTH endpoints are in the resolved closure.
      dep_edges = []
      @modules.each do |m|
        next unless m.respond_to?(:module_dependencies)

        m.module_dependencies.each do |md|
          next unless ids.include?(md.dependency_id)

          dep_edges << {
            source: m.id,
            target: md.dependency_id,
            type:   md.dependency_type,        # "requires" | "recommends" | "conflicts" | "provides"
            required: md.required?,
            version_constraint: md.version_constraint
          }
        end
      end

      {
        nodes: @modules.map do |m|
          {
            id: m.id,
            name: m.name,
            variety: m.variety,
            explicit: explicit.include?(m.id),
            auto_resolved: !explicit.include?(m.id)
          }
        end,
        edges: parent_edges + dep_edges
      }
    end

    private

    def serialize_module(m, auto_resolved: false)
      link = m.respond_to?(:package_module_link) ? m.package_module_link : nil
      {
        id: m.id,
        name: m.name,
        variety: m.variety,
        priority: m.priority,
        effective_priority: m.respond_to?(:effective_priority) ? m.effective_priority : m.priority,
        category_id: m.category_id,
        auto_resolved: auto_resolved,
        auto_generated: m.respond_to?(:auto_generated) ? m.auto_generated : false,
        package_source: link.present? ? { repository_id: link.package_repository_id,
                                          package_name: link.package_name,
                                          package_version: link.package_version,
                                          architecture: link.architecture } : nil,
        current_version: m.current_version&.then do |v|
          { id: v.id, version_number: v.version_number, oci_digest: v.try(:oci_digest) }
        end
      }
    end

    # Decodes a NodeModule jsonb-array spec column to plain glob lines.
    def decode_b64_array(arr)
      arr.map { |entry| ::Base64.decode64(entry.to_s) }
    end

    # Cheap path-prefix overlap check. Strips trailing `/*` or `/**`
    # segments and tests prefix containment in either direction. Not
    # a full rsync-glob matcher — that's what the build pipeline runs;
    # we just need a usefully-loud preview signal.
    def paths_overlap?(a, b)
      ax = a.to_s.sub(%r{/\*\*\z}, "").sub(%r{/\*\z}, "")
      bx = b.to_s.sub(%r{/\*\*\z}, "").sub(%r{/\*\z}, "")
      return true if ax == bx
      return true if a.to_s == b.to_s
      ax.start_with?("#{bx}/") || bx.start_with?("#{ax}/")
    end
  end
end
