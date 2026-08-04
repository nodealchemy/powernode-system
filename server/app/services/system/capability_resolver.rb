# frozen_string_literal: true

module System
  # Answers one question: does any module on this account PROVIDE a given
  # capability tag, at a version satisfying an optional constraint?
  #
  # Extracted from ManifestImportService#resolve_capability so the importer
  # and CapabilityGapSensor share one definition of "satisfied". They must
  # agree exactly: the sensor's entire job is to report the requirements the
  # importer could not resolve, so any divergence makes it either cry wolf
  # about capabilities that are in fact available, or stay silent about gaps
  # that are real. Two copies of the constraint semantics below would drift
  # the first time either side was touched.
  #
  # Providers are read from NodeModule#capabilities, which is denormalized
  # from manifest.dependencies.provides at import time.
  class CapabilityResolver
    # Returns the winning provider NodeModule, or nil when the capability is
    # unsatisfied. Highest priority wins, then most recently created.
    def self.resolve(account_id:, tag:, constraint: nil, exclude_module_id: nil)
      return nil if account_id.blank? || tag.blank?

      candidates = candidates_for(account_id: account_id, tag: tag, exclude_module_id: exclude_module_id)
      return candidates.first if constraint.blank?

      requirement = parse_requirement(constraint, tag)
      return nil if requirement.nil?

      candidates.detect { |cand| satisfies?(cand, tag, requirement) }
    end

    # Splits a raw "capability:<tag>[@<constraint>]" requirement into its
    # parts. Returns nil for anything that is not a capability requirement
    # (name-based deps resolve by gitea repo elsewhere) so callers can
    # filter_map over a mixed requires list.
    #
    # A requirement whose constraint is malformed is also nil — it is not a
    # usable capability requirement. That matters most for CapabilityGapSensor,
    # which filter_maps over this method: a manifest typo must not be reported
    # to the operator as a MISSING PROVIDER. The typo is surfaced instead by
    # ManifestImportService, which rejects the manifest at import time.
    def self.parse_requirement_string(raw)
      raw_str = raw.to_s
      return nil unless raw_str.start_with?("capability:")

      tag, constraint = raw_str.sub(/\Acapability:/, "").split("@", 2)
      return nil if tag.blank?
      return nil unless constraint_valid?(constraint)

      [ tag, constraint.presence ]
    end

    # The single runtime authority on whether a capability version constraint
    # is well-formed. `requires` entries are also pattern-checked at PR time by
    # .gitea/workflows/module-validate.yaml against
    # modules/.schema/module-manifest.schema.json — that pattern is a coarser
    # mirror of this rule and must stay consistent with it.
    #
    # Note this accepts only Gem::Requirement syntax. npm caret (`^1.0`) is NOT
    # valid here, even though every module-to-module pin in this repo uses it:
    # those are name-based pins, which are never parsed as requirements.
    def self.constraint_valid?(constraint)
      return true if constraint.blank?

      !requirement_for(constraint).nil?
    end

    # Does this module advertise `tag` at a version satisfying `constraint`?
    # Public so DependencyResolutionService can re-check a stored constraint
    # after import without owning a second copy of the semantics below.
    def self.satisfied_by?(node_module, tag, constraint)
      return false if node_module.nil? || tag.blank?

      if constraint.blank?
        return Array(node_module.capabilities).any? { |cap| cap.to_s.split("@", 2).first == tag }
      end

      requirement = requirement_for(constraint)
      return false if requirement.nil?

      satisfies?(node_module, tag, requirement)
    end

    # PostgreSQL JSONB array containment: `capabilities ?| array[tag]`
    # matches modules whose capabilities array contains the bare tag; the
    # LIKE prefix additionally catches versioned `tag@x.y.z` entries.
    def self.candidates_for(account_id:, tag:, exclude_module_id: nil)
      scope = ::System::NodeModule
              .where(account_id: account_id)
              .where("capabilities ?| array[:t] OR capabilities::text LIKE :p",
                     t: tag, p: "%\"#{tag}@%")
              .order(priority: :desc, created_at: :desc)
      scope = scope.where.not(id: exclude_module_id) if exclude_module_id.present?
      scope
    end
    private_class_method :candidates_for

    def self.parse_requirement(constraint, tag)
      requirement = requirement_for(constraint)
      if requirement.nil?
        ::Rails.logger.warn("[CapabilityResolver] invalid version constraint #{constraint.inspect} for capability #{tag.inspect}")
      end
      requirement
    end
    private_class_method :parse_requirement

    # Silent variant — used by the predicates, which are asking whether a
    # constraint parses rather than reporting that it did not.
    def self.requirement_for(constraint)
      ::Gem::Requirement.new(constraint)
    rescue ::ArgumentError
      nil
    end
    private_class_method :requirement_for

    def self.satisfies?(candidate, tag, requirement)
      Array(candidate.capabilities).any? do |cap|
        cap_tag, cap_ver = cap.to_s.split("@", 2)
        next false unless cap_tag == tag
        # A bare tag deliberately does NOT satisfy a versioned constraint.
        # That is a manifest-quality signal: a provider that wants to answer
        # version-constrained requirements must declare its version.
        next false if cap_ver.blank?

        begin
          requirement.satisfied_by?(::Gem::Version.new(cap_ver))
        rescue ::ArgumentError
          false
        end
      end
    end
    private_class_method :satisfies?
  end
end
