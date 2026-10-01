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
  #   * The shared parent-clone block (IMP-c19b10a942d7) — the text between
  #     stage15.sh's `# --- BEGIN needs-parent shared block ---` and
  #     `# --- END needs-parent shared block ---` markers — sits outside every arm
  #     but is an input of exactly the modules needs-parent-modules.sh lists. It
  #     is attributed to those slugs, read from that file's NEEDS_PARENT_MODULES
  #     list, never from a copy kept here.
  #   * A changed helper under scripts/module-build/ is attributed to every arm
  #     that names it, and to the needs-parent modules if the shared block does.
  #   * Anything else — code outside every arm and the block, a wildcard arm, a
  #     helper nothing calls — is shared and attributes to no module; the planner
  #     keeps mapping it to module-forge.
  #
  # This is a line-oriented reader for the shape stage15.sh has, not a shell
  # parser. It tracks case/esac nesting and heredoc bodies and refuses (ParseError)
  # anything it cannot account for, so the caller falls back to module-forge only
  # rather than attributing off a misread script. A block marker that matches
  # nothing is refused the same way: a non-empty list with no block, a block with
  # no list, BEGIN without END, END without BEGIN, a second block, or a marker
  # inside a case. The spec that parses the real stage15.sh is what keeps a
  # rewrite of the script from silently degrading it.
  class ModuleBuildScriptAttribution
    class ParseError < StandardError; end

    STAGE15_PATH      = "scripts/module-build/stage15.sh"
    NEEDS_PARENT_PATH = "scripts/module-build/needs-parent-modules.sh"

    # One module-dispatch arm: its literal slugs, whether any pattern was a glob
    # (`*)`, `runtime-*)` — shared, never a slug), and its verbatim text.
    Arm = Struct.new(:slugs, :wildcard, :text, keyword_init: true) do
      def wildcard?
        wildcard
      end
    end

    # arms: the dispatch arms in file order. shared_block: the needs-parent block's
    # verbatim text (markers included), or nil. needs_parent: the slugs that own it.
    Parsed = Struct.new(:arms, :shared_block, :needs_parent, keyword_init: true) do
      def slugs
        arms.flat_map(&:slugs).to_set | needs_parent.to_set
      end

      # Every arm that names the slug, in file order, so a slug reached through
      # both the needs_parent dispatch and the build dispatch compares as one unit;
      # then the shared block, for a slug that owns it.
      def text_for(slug)
        text = arms.select { |a| a.slugs.include?(slug) }.map(&:text).join
        text += shared_block if shared_block && needs_parent.include?(slug)
        text
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
    # The shared block's two markers, each on a line of its own.
    SHARED_BLOCK_RX     = /\A\s*#\s*---\s*(BEGIN|END) needs-parent shared block\s*---\s*\z/
    # needs-parent-modules.sh's list: the ONE definition of which modules own the block.
    NEEDS_PARENT_LIST_RX = /^NEEDS_PARENT_MODULES="([^"]*)"/

    class << self
      # @param changed_paths [Array<String>] paths changed under scripts/module-build/
      # @param base_stage15 [String, nil] stage15.sh at the range's base; required
      #   only when stage15.sh or needs-parent-modules.sh changed
      # @param head_stage15 [String] stage15.sh at the range's head
      # @param base_needs_parent [String, nil] needs-parent-modules.sh at the base
      #   (nil: absent at that ref)
      # @param head_needs_parent [String, nil] needs-parent-modules.sh at the head
      # @return [Set<String>] module slugs the change is attributable to
      # @raise [ParseError] a script could not be read faithfully — the caller
      #   must fall back to its module-forge-only behaviour
      def modules_for(changed_paths:, base_stage15:, head_stage15:, base_needs_parent: nil, head_needs_parent: nil)
        head = parse(head_stage15, needs_parent: needs_parent_modules(head_needs_parent))
        base = nil
        slugs = Set.new

        # A change to the list re-owns the block as much as a change to the block
        # does, so either file changing compares every slug's attributed text.
        if changed_paths.include?(STAGE15_PATH) || changed_paths.include?(NEEDS_PARENT_PATH)
          raise ParseError, "build scripts changed but no base copy of stage15.sh is available to compare arms against" if base_stage15.nil?

          base = parse(base_stage15, needs_parent: needs_parent_modules(base_needs_parent))
          (head.slugs | base.slugs).each do |slug|
            slugs << slug unless head.text_for(slug) == base.text_for(slug)
          end
        end

        helpers = changed_paths.reject { |p| p == STAGE15_PATH || p == NEEDS_PARENT_PATH }.map { |p| File.basename(p) }
        unless helpers.empty?
          [ head, base ].compact.each do |parsed|
            parsed.arms.each do |arm|
              slugs.merge(arm.slugs) if helpers.any? { |h| calls?(arm.text, h) }
            end
            if parsed.shared_block && helpers.any? { |h| calls?(parsed.shared_block, h) }
              slugs.merge(parsed.needs_parent)
            end
          end
        end

        slugs
      end

      # The slugs needs-parent-modules.sh lists, in file order.
      #
      # @param text [String, nil] the file's text; nil when it is absent at the ref
      # @return [Array<String>, nil]
      # @raise [ParseError] the text carries no list (renamed, reshaped) or a
      #   token in it is not a module slug
      def needs_parent_modules(text)
        return nil if text.nil?

        m = text.match(NEEDS_PARENT_LIST_RX)
        raise ParseError, "needs-parent-modules.sh has no NEEDS_PARENT_MODULES=\"...\" list" unless m

        slugs = m[1].split
        slugs.each do |slug|
          raise ParseError, "needs-parent list entry #{slug.inspect} is not a module slug" unless slug.match?(LITERAL_SLUG_RX)
        end
        slugs
      end

      # @param script [String] the text of a script with a `case "$MODULE" in` dispatch
      # @param needs_parent [Array<String>, nil] the slugs that own the shared block
      # @return [Parsed]
      # @raise [ParseError] no module dispatch, case/esac that does not balance, or
      #   a shared block / needs-parent list without its counterpart
      def parse(script, needs_parent: nil)
        raise ParseError, "script text is not a String" unless script.is_a?(String)

        needs_parent = Array(needs_parent)
        arms = []
        stack = []          # one entry per open case; true = the top-level MODULE dispatch
        current = nil       # the arm being read
        heredoc = nil
        block = nil         # the shared block's text while it is open
        shared = nil        # its text once closed

        script.each_line do |raw|
          line = raw.chomp

          if heredoc
            current[:text] << raw if current
            block << raw if block
            heredoc = nil if line.strip == heredoc
            next
          end

          if (bm = line.match(SHARED_BLOCK_RX))
            if bm[1] == "BEGIN"
              raise ParseError, "second needs-parent shared block BEGIN" if block || shared
              raise ParseError, "needs-parent shared block BEGIN inside a case" if !stack.empty? || current

              block = +raw
            else
              raise ParseError, "needs-parent shared block END with no BEGIN" if block.nil?
              raise ParseError, "needs-parent shared block END inside a case" unless stack.empty?

              block << raw
              shared = block
              block = nil
            end
            next
          end
          block << raw if block

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
        raise ParseError, "unterminated needs-parent shared block (BEGIN with no END)" if block
        raise ParseError, "no `case \"$MODULE\" in` dispatch found" if arms.empty?
        raise ParseError, "needs-parent modules are listed but the script has no needs-parent shared block" if !needs_parent.empty? && shared.nil?
        raise ParseError, "the script has a needs-parent shared block but no needs-parent module list owns it" if shared && needs_parent.empty?

        Parsed.new(arms: arms, shared_block: shared, needs_parent: needs_parent)
      end

      private

      def finish(current)
        literal, glob = current[:patterns].partition { |p| p.match?(LITERAL_SLUG_RX) }
        Arm.new(slugs: literal, wildcard: !glob.empty?, text: current[:text])
      end

      # Does the text invoke the helper? A whole-name match on non-comment lines: a
      # comment is not a call, and `lock.sh` must not match `assert-lock.sh`.
      def calls?(text, helper)
        rx = /(?<![\w.-])#{Regexp.escape(helper)}(?![\w.-])/
        text.each_line.any? { |l| !l.match?(COMMENT_RX) && l.match?(rx) }
      end
    end
  end
end
