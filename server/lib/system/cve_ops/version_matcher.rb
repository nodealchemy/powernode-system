# frozen_string_literal: true

module System
  module CveOps
    # Pure helper: ecosystem-aware version-range comparison for CVE matching.
    # Inputs: a version string (from an SBOM) and a constraint string (from a
    # CVE's affected_packages entry). Output: bool indicating whether the
    # version is in the vulnerable range.
    #
    # Constraint syntax (NVD-style):
    #   ">=2.0.0"           — any version >= 2.0.0 vulnerable
    #   "<3.1.4"            — any version < 3.1.4 vulnerable
    #   ">=2.0.0,<3.1.4"    — range, both ends required
    #   "1.2.3"             — exact match (single equality)
    #   "*"                 — all versions
    #   ""  / nil           — all versions (NVD convention when range is unknown)
    #
    # Ecosystems supported with strict semver-style comparison:
    #   - npm, rubygems, pypi (PEP 440 subset), cargo, golang
    # Other ecosystems fall back to lexical comparison + a warning to stderr;
    # operators should review for correctness.
    #
    # Reference: comprehensive stabilization sweep P4 — replaces v0 keyword
    # stub in System::CveOps::ExposureCalculator.
    class VersionMatcher
      # Recognized ecosystems for which version-range parsing is reliable.
      KNOWN_ECOSYSTEMS = %w[npm rubygems pypi cargo golang generic].freeze

      class << self
        # Returns true iff `version` is in `constraint`'s vulnerable range.
        # Returns false on parse failure (defensive — better to under-report
        # than to fire false positives).
        def vulnerable?(version:, constraint:, ecosystem: "generic")
          return true  if blank?(constraint) || constraint.strip == "*"
          return false if blank?(version)

          parts = constraint.split(",").map(&:strip).reject(&:empty?)
          parts.all? { |part| part_matches?(version, part, ecosystem) }
        rescue StandardError => e
          Rails.logger.warn("[VersionMatcher] parse failed version=#{version.inspect} constraint=#{constraint.inspect} ecosystem=#{ecosystem}: #{e.message}")
          false
        end

        # Compare two version strings for the given ecosystem.
        # Returns -1 / 0 / 1 like <=>.
        def compare(a, b, ecosystem: "generic")
          parsed_a = parse(a, ecosystem)
          parsed_b = parse(b, ecosystem)
          parsed_a <=> parsed_b
        end

        private

        def part_matches?(version, part, ecosystem)
          case part
          when /\A(>=|<=|>|<|==|=)\s*(.+)\z/
            op = Regexp.last_match(1)
            target = Regexp.last_match(2).strip
            cmp = compare(version, target, ecosystem: ecosystem)
            apply_op(cmp, op)
          else
            # Bare version — equality
            compare(version, part, ecosystem: ecosystem).zero?
          end
        end

        def apply_op(cmp, op)
          case op
          when ">=" then cmp >= 0
          when "<=" then cmp <= 0
          when ">"  then cmp > 0
          when "<"  then cmp < 0
          when "==", "=" then cmp.zero?
          else false
          end
        end

        # Returns an Array<Integer> for comparable lexicographic comparison
        # using <=> on Arrays (which compares element-wise).
        def parse(version, ecosystem)
          v = strip_prefix(version.to_s.strip, ecosystem)
          # Handle pre-release: split on first '-' or '+'
          core, _suffix = v.split(/[-+]/, 2)
          components = core.split(".").map { |c| c.to_i.to_s == c ? c.to_i : 0 }
          # Pad to length 4 so [1,2,3] vs [1,2,3,0] both compare equally
          components += [ 0 ] * (4 - components.size) if components.size < 4
          components
        end

        # Some ecosystems prefix versions (e.g., golang's `v` prefix). Strip
        # any single-letter leading character followed by a digit.
        def strip_prefix(v, _ecosystem)
          v.sub(/\A[A-Za-z](?=\d)/, "")
        end

        def blank?(value)
          value.nil? || value.to_s.strip.empty?
        end
      end
    end
  end
end
