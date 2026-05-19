# frozen_string_literal: true

module System
  module CveOps
    # RPM version comparison — pure-Ruby port of the rpmvercmp algorithm
    # from rpm/lib/rpmvercmp.c. Handles:
    #   - Epoch:upstream-release format
    #   - Numeric vs alphabetic segment comparison
    #   - Tilde-suffix pre-release semantics (1.0~rc1 < 1.0)
    #   - Plus-suffix (handled per upstream as alphanumeric)
    #
    # Not a shell-out because rpm isn't always installed on Debian/Ubuntu
    # build hosts.
    class RpmVersionComparator
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

      def self.compare(a, b)
        a_epoch, a_main = split_epoch(a)
        b_epoch, b_main = split_epoch(b)

        epoch_cmp = a_epoch <=> b_epoch
        return epoch_cmp unless epoch_cmp.zero?

        rpmvercmp(a_main, b_main)
      end

      def self.split_epoch(version)
        if version.include?(":")
          epoch, rest = version.split(":", 2)
          [(Integer(epoch, 10) rescue 0), rest]
        else
          [0, version]
        end
      end

      # Port of upstream rpmvercmp. Walks both strings segment-by-segment,
      # alternating between numeric and alphabetic runs; numeric > alpha.
      def self.rpmvercmp(a, b)
        return 0 if a == b

        i = 0
        j = 0
        while i < a.length || j < b.length
          # Tilde suffixes mark pre-release: 1.0~rc1 < 1.0
          if a[i] == "~" && b[j] == "~"
            i += 1
            j += 1
            next
          elsif a[i] == "~"
            return -1
          elsif b[j] == "~"
            return 1
          end

          # Skip non-alphanumeric separators
          i += 1 while i < a.length && !alphanumeric?(a[i])
          j += 1 while j < b.length && !alphanumeric?(b[j])

          break if i >= a.length || j >= b.length

          # Determine segment kind
          a_is_num = a[i].match?(/\d/)
          b_is_num = b[j].match?(/\d/)

          # Numeric segments always win over alphabetic
          return 1  if a_is_num && !b_is_num
          return -1 if !a_is_num && b_is_num

          # Extract the run
          a_end = i
          b_end = j
          if a_is_num
            a_end += 1 while a_end < a.length && a[a_end].match?(/\d/)
            b_end += 1 while b_end < b.length && b[b_end].match?(/\d/)
            a_seg = a[i...a_end].sub(/\A0+/, "")
            b_seg = b[j...b_end].sub(/\A0+/, "")
            # Longer numeric > shorter (after leading-zero strip)
            return 1  if a_seg.length > b_seg.length
            return -1 if a_seg.length < b_seg.length
            seg_cmp = a_seg <=> b_seg
            return seg_cmp unless seg_cmp.zero?
          else
            a_end += 1 while a_end < a.length && a[a_end].match?(/[A-Za-z]/)
            b_end += 1 while b_end < b.length && b[b_end].match?(/[A-Za-z]/)
            seg_cmp = a[i...a_end] <=> b[j...b_end]
            return seg_cmp unless seg_cmp.zero?
          end

          i = a_end
          j = b_end
        end

        # Whoever has bytes remaining is the larger version
        return 0  if i >= a.length && j >= b.length
        return 1  if j >= b.length
        -1
      end

      def self.alphanumeric?(ch)
        return false if ch.nil?
        ch.match?(/[A-Za-z0-9~]/)
      end
    end
  end
end
