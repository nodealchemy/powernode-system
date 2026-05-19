# frozen_string_literal: true

module System
  module CveOps
    # Pure-Ruby semver comparison. Handles:
    #   - Numeric segments (1.2.3)
    #   - Pre-release identifiers per semver spec (1.0.0-alpha < 1.0.0)
    #   - Numeric vs alphanumeric pre-release segments (1.0.0-alpha.10 > 1.0.0-alpha.2)
    #   - Leading "v" stripping (v1.2.3 == 1.2.3)
    #   - Build metadata is ignored per semver spec (1.0.0+build123 == 1.0.0)
    #
    # NOT FULL spec compliance (e.g., no `~>` or `^` operator support — those
    # are the caller's job to translate into [>= AND <] pairs before invoking).
    class SemverComparator
      def self.satisfies?(version, op, range_version)
        cmp = compare(version, range_version)
        case op
        when :lt then cmp < 0
        when :le then cmp <= 0
        when :gt then cmp > 0
        when :ge then cmp >= 0
        when :eq then cmp.zero?
        else
          raise ArgumentError, "unknown comparison op: #{op.inspect}"
        end
      end

      # Returns -1, 0, or 1 (a la Comparable#<=>).
      def self.compare(a, b)
        a_main, a_pre = split(a)
        b_main, b_pre = split(b)

        main_cmp = compare_main(a_main, b_main)
        return main_cmp unless main_cmp.zero?

        # Per semver: a version WITH pre-release is LESS THAN the same without.
        return 0  if a_pre.nil? && b_pre.nil?
        return -1 if a_pre && b_pre.nil?
        return 1  if a_pre.nil? && b_pre

        compare_pre_release(a_pre, b_pre)
      end

      def self.split(version)
        v = version.to_s.strip.sub(/\Av/, "")
        # Strip build metadata (everything after the first "+")
        v = v.split("+", 2).first
        main, pre = v.split("-", 2)
        [main, pre]
      end

      def self.compare_main(a, b)
        a_parts = a.split(".").map { |s| Integer(s, 10) rescue 0 }
        b_parts = b.split(".").map { |s| Integer(s, 10) rescue 0 }
        # Pad with zeros so 1.2 == 1.2.0
        len = [a_parts.size, b_parts.size].max
        a_parts.fill(0, a_parts.size...len)
        b_parts.fill(0, b_parts.size...len)
        a_parts <=> b_parts
      end

      def self.compare_pre_release(a, b)
        a_ids = a.split(".")
        b_ids = b.split(".")
        len = [a_ids.size, b_ids.size].min

        len.times do |i|
          cmp = compare_pre_identifier(a_ids[i], b_ids[i])
          return cmp unless cmp.zero?
        end

        # If all common identifiers equal, longer pre-release > shorter
        a_ids.size <=> b_ids.size
      end

      def self.compare_pre_identifier(a, b)
        a_num = a.match?(/\A\d+\z/) ? a.to_i : nil
        b_num = b.match?(/\A\d+\z/) ? b.to_i : nil

        # Both numeric: numeric compare
        return a_num <=> b_num if a_num && b_num
        # Numeric < alphanumeric (per semver spec)
        return -1 if a_num && !b_num
        return 1  if !a_num && b_num
        # Both alphanumeric: lexicographic ASCII compare
        a <=> b
      end
    end
  end
end
