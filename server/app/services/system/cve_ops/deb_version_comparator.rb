# frozen_string_literal: true

require "open3"

module System
  module CveOps
    # Debian version comparison. Shells out to `dpkg --compare-versions`
    # because (a) the algorithm has edge cases that pure-Ruby ports get
    # wrong (epochs, tilde-suffixes for pre-releases, mixed alphanumerics),
    # and (b) dpkg is the authoritative implementation and present on every
    # Debian/Ubuntu build host.
    #
    # Local cache: comparisons are deterministic; memoize within a process
    # to keep the per-CVE matching tight (a typical CVE check runs O(modules
    # × packages) comparisons against the same constraint).
    class DebVersionComparator
      @cache = {}
      @cache_mutex = Mutex.new

      DPKG_OPS = {
        lt: "lt",
        le: "le",
        gt: "gt",
        ge: "ge",
        eq: "eq"
      }.freeze

      def self.satisfies?(version, op, range_version)
        dpkg_op = DPKG_OPS.fetch(op) do
          raise ArgumentError, "unknown comparison op: #{op.inspect}"
        end
        cache_key = [version, dpkg_op, range_version]

        cached = @cache_mutex.synchronize { @cache[cache_key] }
        return cached unless cached.nil?

        result = run_dpkg(version, dpkg_op, range_version)
        @cache_mutex.synchronize { @cache[cache_key] = result }
        result
      end

      def self.reset_cache!
        @cache_mutex.synchronize { @cache.clear }
      end

      def self.run_dpkg(version, dpkg_op, range_version)
        # dpkg --compare-versions <ver1> <op> <ver2>  → exit 0 if true, 1 if false
        # We deliberately don't capture stdout/stderr — dpkg is silent on success.
        Open3.capture2e("dpkg", "--compare-versions", version, dpkg_op, range_version)[1].success?
      rescue StandardError => e
        Rails.logger.warn "[DebVersionComparator] dpkg --compare-versions failed: #{e.class}: #{e.message}"
        # Fall back to lexicographic compare — better than dropping the match silently.
        case op_from(dpkg_op)
        when :lt then version <  range_version
        when :le then version <= range_version
        when :gt then version >  range_version
        when :ge then version >= range_version
        when :eq then version == range_version
        else          false
        end
      end

      def self.op_from(dpkg_op)
        DPKG_OPS.invert[dpkg_op]
      end
    end
  end
end
