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
    def self.parse_requirement_string(raw)
      raw_str = raw.to_s
      return nil unless raw_str.start_with?("capability:")

      tag, constraint = raw_str.sub(/\Acapability:/, "").split("@", 2)
      return nil if tag.blank?

      [ tag, constraint.presence ]
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
      ::Gem::Requirement.new(constraint)
    rescue ::ArgumentError
      ::Rails.logger.warn("[CapabilityResolver] invalid version constraint #{constraint.inspect} for capability #{tag.inspect}")
      nil
    end
    private_class_method :parse_requirement

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
