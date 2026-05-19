# frozen_string_literal: true

module System
  module CveOps
    # PEP 440 version comparison — handles the common 80% of Python package
    # versions: numeric tuples, alpha/beta/rc pre-release markers, post-release
    # suffixes, dev releases.
    #
    # Not a full PEP 440 implementation (no local version `+foo`, no epoch
    # `1!2.0`, no compatible-release `~=` operator) — those are rare in real
    # CVE constraints. Falls back to semver-style numeric tuple compare
    # when the input doesn't match PEP 440's quirkier shapes.
    class Pep440Comparator
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

      # Pre-release markers per PEP 440. Lower index = earlier release.
      PRE_RANKS = { "a" => 0, "alpha" => 0, "b" => 1, "beta" => 1,
                    "rc" => 2, "c" => 2, "pre" => 2, "preview" => 2 }.freeze

      def self.compare(a, b)
        a_main, a_pre, a_post, a_dev = parse(a)
        b_main, b_pre, b_post, b_dev = parse(b)

        main_cmp = compare_main(a_main, b_main)
        return main_cmp unless main_cmp.zero?

        # Pre-release < release < post-release (per PEP 440)
        pre_cmp = compare_pre(a_pre, b_pre)
        return pre_cmp unless pre_cmp.zero?

        post_cmp = (a_post || -1) <=> (b_post || -1)
        return post_cmp unless post_cmp.zero?

        dev_cmp = (a_dev || Float::INFINITY) <=> (b_dev || Float::INFINITY)
        dev_cmp.zero? ? 0 : dev_cmp
      end

      # Returns [main_array, pre_tuple_or_nil, post_int_or_nil, dev_int_or_nil].
      def self.parse(version)
        v = version.to_s.strip.downcase.sub(/\Av/, "")

        # Extract dev/post/pre parts via regex; whatever's left is the main.
        dev  = v.slice!(/\.?dev(\d*)\z/) ? (Regexp.last_match(1).to_i) : nil
        post = v.slice!(/\.?(post|rev|r)(\d*)\z/) ? (Regexp.last_match(2).to_i) : nil

        pre = nil
        if (m = v.match(/(a|alpha|b|beta|rc|c|pre|preview)(\d*)\z/))
          pre_label = m[1]
          pre_num   = m[2].to_i
          v = v[0...m.begin(0)].sub(/[._-]\z/, "")
          pre = [PRE_RANKS[pre_label], pre_num]
        end

        main = v.split(".").map { |s| Integer(s, 10) rescue 0 }
        [main, pre, post, dev]
      end

      def self.compare_main(a, b)
        len = [a.size, b.size].max
        a_padded = a + Array.new(len - a.size, 0)
        b_padded = b + Array.new(len - b.size, 0)
        a_padded <=> b_padded
      end

      def self.compare_pre(a_pre, b_pre)
        # No pre-release > with pre-release (release > pre-release)
        return 0  if a_pre.nil? && b_pre.nil?
        return 1  if a_pre.nil? && b_pre
        return -1 if a_pre && b_pre.nil?
        a_pre <=> b_pre
      end
    end
  end
end
