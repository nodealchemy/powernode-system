# frozen_string_literal: true

module System
  # IMP-24d473c6f448 — which modules does a scripts/module-build/* change belong to?
  #
  # System::ModuleBuildPlannerService used to answer "module-forge" for every such
  # path, because module-forge bakes the scripts. That left a change confined to
  # ONE module's stage15 build arm (or to a helper that arm calls) with no way to
  # target the module it actually changes. This derives the attribution from the
  # scripts' own structure instead of a slug list kept beside them:
  #
  #   * stage15.sh dispatches on the module slug with top-level
  #     `case "$MODULE" in <slug>) ... ;; esac` blocks. An arm whose text differs
  #     between the range's base and head copies is attributed to the slug(s) on
  #     its pattern line (`a|b)` attributes to both).
  #   * A changed helper under scripts/module-build/ is attributed to every arm
  #     that names it.
  #   * Anything else — code outside every arm, a wildcard arm, a helper no arm
  #     calls — is shared and attributes to no module; the planner keeps mapping
  #     it to module-forge.
  #
  # This is a line-oriented reader for the shape stage15.sh has, not a shell
  # parser. It tracks case/esac nesting and heredoc bodies and refuses (ParseError)
  # anything it cannot account for, so the caller falls back to module-forge only
  # rather than attributing off a misread script. The spec that parses the real
  # stage15.sh is what keeps a rewrite of the script from silently degrading it.
  class ModuleBuildScriptAttribution
    class ParseError < StandardError; end

    STAGE15_PATH = "scripts/module-build/stage15.sh"

    # One module-dispatch arm: its literal slugs, whether any pattern was a glob
    # (`*)`, `runtime-*)` — shared, never a slug), and its verbatim text.
    Arm = Struct.new(:slugs, :wildcard, :text, keyword_init: true) do
      def wildcard?
        wildcard
      end
    end

    Parsed = Struct.new(:arms, keyword_init: true) do
      def slugs
        arms.flat_map(&:slugs).to_set
      end

      # Every arm that names the slug, in file order, so a slug reached through
      # both the needs_parent dispatch and the build dispatch compares as one unit.
      def text_for(slug)
        arms.select { |a| a.slugs.include?(slug) }.map(&:text).join
      end
    end

    MODULE_SCRUTINEE_RX = /\A"?\$\{?MODULE\}?"?\z/
    CASE_OPEN_RX        = /\A\s*case\s+(.+?)\s+in\b(.*)\z/
    ESAC_RX             = /\A\s*esac\b/
    ARM_START_RX        = /\A\s*\(?\s*((?:"[^"]*"|'[^']*'|[^\s)|"'])+(?:\s*\|\s*(?:"[^"]*"|'[^']*'|[^\s)|"'])+)*)\s*\)(.*)\z/
    ARM_END_RX          = /;;&?\s*(?:#.*)?\z|;&\s*(?:#.*)?\z/
    # `<<WORD` / `<<-WORD` / `<<'WORD'`, with no space before the delimiter.
    HEREDOC_RX          = /(?<!<)<<-?(["']?)([A-Za-z_]\w*)\1/
    # A SPACED opener is accepted only when it cannot be a Ruby append or an
    # arithmetic shift, which a script this size holds far more of than spaced
    # heredocs (`missing << spec.full_name` in stage15.sh): a quoted delimiter
    # (`<< 'EOF'`) or an all-caps word ending the token (`<< EOF`). A caps
    # append (`list << CONST`) misread as a heredoc swallows the rest of the
    # script and ends in a ParseError, i.e. the safe fallback.
    HEREDOC_SPACED_RX   = /(?<!<)<<-?\s+(?:(["'])([A-Za-z_]\w*)\1|([A-Z][A-Z0-9_]*)(?=\s|;|\)|\z))/
    COMMENT_RX          = /\A\s*#/
    LITERAL_SLUG_RX     = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    class << self
      # @param changed_paths [Array<String>] paths changed under scripts/module-build/
      # @param base_stage15 [String, nil] stage15.sh at the range's base; required
      #   only when stage15.sh itself changed
      # @param head_stage15 [String] stage15.sh at the range's head
      # @return [Set<String>] module slugs the change is attributable to
      # @raise [ParseError] a script could not be read faithfully — the caller
      #   must fall back to its module-forge-only behaviour
      def modules_for(changed_paths:, base_stage15:, head_stage15:)
        head = parse(head_stage15)
        base = nil
        slugs = Set.new

        if changed_paths.include?(STAGE15_PATH)
          raise ParseError, "stage15.sh changed but no base copy is available to compare arms against" if base_stage15.nil?

          base = parse(base_stage15)
          (head.slugs | base.slugs).each do |slug|
            slugs << slug unless head.text_for(slug) == base.text_for(slug)
          end
        end

        helpers = changed_paths.reject { |p| p == STAGE15_PATH }.map { |p| File.basename(p) }
        unless helpers.empty?
          (head.arms + (base ? base.arms : [])).each do |arm|
            slugs.merge(arm.slugs) if helpers.any? { |h| calls?(arm, h) }
          end
        end

        slugs
      end

      # @param script [String] the text of a script with a `case "$MODULE" in` dispatch
      # @return [Parsed]
      # @raise [ParseError] no module dispatch, or case/esac that does not balance
      def parse(script)
        raise ParseError, "script text is not a String" unless script.is_a?(String)

        arms = []
        stack = []          # one entry per open case; true = the top-level MODULE dispatch
        current = nil       # the arm being read
        heredoc = nil

        script.each_line do |raw|
          line = raw.chomp

          if heredoc
            current[:text] << raw if current
            heredoc = nil if line.strip == heredoc
            next
          end

          if line.match?(COMMENT_RX)
            current[:text] << raw if current
            next
          end

          if (m = line.match(CASE_OPEN_RX))
            unless m[2].match?(/\besac\b/) # a one-line `case ... esac` never opens a block
              module_dispatch = stack.empty? && m[1].match?(MODULE_SCRUTINEE_RX)
              stack.push(module_dispatch)
            end
            current[:text] << raw if current
          elsif line.match?(ESAC_RX)
            raise ParseError, "esac with no open case" if stack.empty?

            if stack.pop && current # the MODULE dispatch itself closes
              arms << finish(current)
              current = nil
            elsif current
              current[:text] << raw
              # `esac ;;` ends the nested case AND the arm around it.
              if stack.size == 1 && stack.first && line.match?(ARM_END_RX)
                arms << finish(current)
                current = nil
              end
            end
          elsif stack.size == 1 && stack.first
            # Directly inside the MODULE dispatch: an arm boundary is possible here.
            if current.nil?
              if (am = line.match(ARM_START_RX))
                current = { patterns: am[1].split("|").map { |p| p.strip.delete("\"'") }, text: +raw }
                if am[2].match?(ARM_END_RX)
                  arms << finish(current)
                  current = nil
                end
              end
            else
              current[:text] << raw
              if line.match?(ARM_END_RX)
                arms << finish(current)
                current = nil
              end
            end
          elsif current
            current[:text] << raw
          end

          hm = line.match(HEREDOC_RX)
          if hm
            heredoc = hm[2]
          elsif (sm = line.match(HEREDOC_SPACED_RX))
            heredoc = sm[2] || sm[3]
          end
        end

        raise ParseError, "unterminated case (#{stack.size} open at end of script)" unless stack.empty?
        raise ParseError, "no `case \"$MODULE\" in` dispatch found" if arms.empty?

        Parsed.new(arms: arms)
      end

      private

      def finish(current)
        literal, glob = current[:patterns].partition { |p| p.match?(LITERAL_SLUG_RX) }
        Arm.new(slugs: literal, wildcard: !glob.empty?, text: current[:text])
      end

      # Does the arm invoke the helper? A whole-name match on non-comment lines: a
      # comment is not a call, and `lock.sh` must not match `assert-lock.sh`.
      def calls?(arm, helper)
        rx = /(?<![\w.-])#{Regexp.escape(helper)}(?![\w.-])/
        arm.text.each_line.any? { |l| !l.match?(COMMENT_RX) && l.match?(rx) }
      end
    end
  end
end
