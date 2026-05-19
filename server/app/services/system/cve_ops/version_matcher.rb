# frozen_string_literal: true

module System
  module CveOps
    # Ecosystem-aware version-range matcher used by ExposureCalculator's
    # SBOM-matching path (see exposure_calculator.rb:99–122). Returns true
    # iff `version` satisfies `constraint` under the rules of `ecosystem`.
    #
    # Audit plan P2.9a: this class previously didn't exist — ExposureCalculator
    # was calling .vulnerable? on a missing class, raising NameError on every
    # SBOM-match attempt. Smoke surfaced by `exposure_calculator_sbom_spec.rb`.
    #
    # Supported ecosystems: deb, rpm, gem, npm, pypi, go, generic.
    # Comparators:
    #   - SemverComparator         — gem, npm, go, generic, and the catch-all
    #   - DebVersionComparator     — deb (shells out to dpkg for correctness)
    #   - RpmVersionComparator     — rpm (pure-Ruby rpmvercmp port)
    #   - Pep440Comparator         — pypi (numeric tuple compare; common 80%)
    #
    # Constraint grammar (subset of NPM / Composer / Cargo):
    #   "<2.0.0"          — strict less-than
    #   "<=2.0.0"         — less-than-or-equal
    #   ">1.0.0"          — strict greater-than
    #   ">=1.0.0"         — greater-than-or-equal
    #   "=1.2.3", "1.2.3" — exact match
    #   ">=1.0.0,<2.0.0"  — AND (all ranges must hold)
    #   "*", ""           — match everything
    class VersionMatcher
      ECOSYSTEM_DISPATCH = {
        "deb"     => :DebVersionComparator,
        "rpm"     => :RpmVersionComparator,
        "gem"     => :SemverComparator,
        "npm"     => :SemverComparator,
        "pypi"    => :Pep440Comparator,
        "go"      => :SemverComparator,
        "generic" => :SemverComparator
      }.freeze

      def self.vulnerable?(version:, constraint:, ecosystem:)
        return false if version.to_s.strip.empty?

        comparator_name = ECOSYSTEM_DISPATCH.fetch(ecosystem.to_s.downcase, :SemverComparator)
        # const_get on the parent module (System::CveOps) — calling on `self`
        # (VersionMatcher) would search WITHIN this class, missing siblings.
        comparator = ::System::CveOps.const_get(comparator_name)

        ranges = parse_constraint(constraint.to_s)
        return true if ranges.empty? # "*" or empty constraint matches everything

        ranges.all? { |op, range_version| comparator.satisfies?(version.to_s, op, range_version) }
      rescue StandardError => e
        # Per ExposureCalculator's design, matcher errors fall back to the
        # keyword stub. Log but don't raise — a malformed constraint shouldn't
        # crash the per-tick CVE responder reconcile.
        Rails.logger.warn "[VersionMatcher] error matching #{version} against #{constraint.inspect} " \
                          "(ecosystem=#{ecosystem}): #{e.class}: #{e.message}"
        false
      end

      RANGE_REGEX = /\A\s*(<=|>=|<|>|=)?\s*(.+?)\s*\z/

      # Map string operators to semantic symbol names (avoiding `:<` etc.
      # which are syntactically awkward in Ruby case-when statements).
      OP_SYMBOLS = { "<" => :lt, "<=" => :le, ">" => :gt, ">=" => :ge, "=" => :eq }.freeze

      def self.parse_constraint(raw)
        return [] if raw.empty? || raw.strip == "*"

        raw.split(",").filter_map do |segment|
          segment = segment.strip
          next nil if segment.empty? || segment == "*"

          match = segment.match(RANGE_REGEX)
          op = OP_SYMBOLS.fetch(match[1] || "=")
          ver = match[2].strip
          [op, ver] unless ver.empty?
        end
      end
    end
  end
end
