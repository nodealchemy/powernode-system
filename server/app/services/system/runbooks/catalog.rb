# frozen_string_literal: true

module System
  module Runbooks
    # Loads and validates extensions/system/config/runbooks.yml — the
    # signal-kind → operator-runbook map (campaign 01a08c9b, increment B4a;
    # design §5.2).
    #
    # WHY A CLASS AND NOT A SPEC HELPER: core's Platform::Runbook::Registry
    # (increment A5) resolves a component's active signal to a runbook when it
    # renders the remediation front door. The extension owns the mapping
    # because it owns the signal kinds (DecisionEngine::SIGNAL_BINDINGS), so
    # the LOADING and the VALIDATION have to live somewhere both the registry
    # and the coverage spec can call. This is that seam: #for is what A5 calls,
    # #validate is what the spec asserts on, and neither re-implements the
    # other's rules.
    #
    # PATHS ARE EXTENSION-RELATIVE ("docs/runbooks/<file>.md#<anchor>"), not
    # repo-relative. The extension is a submodule with its own checkout; a path
    # anchored at the parent repo root resolves to nothing when the extension
    # is cloned on its own, and the parent root is not knowable from inside the
    # engine. #resolved_path turns an entry into an absolute path against
    # EXTENSION_ROOT, and that is the only place the two are joined.
    class Catalog
      EXTENSION_ROOT = Pathname.new(File.expand_path("../../../../..", __dir__)).freeze
      DEFAULT_PATH   = EXTENSION_ROOT.join("config", "runbooks.yml").freeze

      # Every entry key the schema allows. An unknown key is an error, not a
      # comment: a typo'd `not_documeted: true` would otherwise read as a
      # doc-less entry and be reported as a schema violation naming the wrong
      # thing.
      ENTRY_KEYS = %w[doc not_documented reason].freeze

      class LoadError < StandardError; end

      attr_reader :path, :entries

      def self.load(path: DEFAULT_PATH)
        new(path: path)
      end

      # The anchor rule GitHub applies to a markdown heading, reproduced so a
      # `doc:` anchor written here is the anchor a browser will actually jump
      # to: downcase, trim, drop every character that is not a letter, digit,
      # space, hyphen or underscore, then map each remaining space to a hyphen.
      #
      # Spaces are mapped ONE FOR ONE and the result is not re-trimmed —
      # that is why "Phase 4 — Run ✅" is "phase-4--run-" and not
      # "phase-4-run". Collapsing them would produce anchors that look tidier
      # and resolve to nothing.
      def self.slug(heading)
        heading.to_s.downcase.strip.gsub(/[^\p{L}\p{N} \-_]/u, "").tr(" ", "-")
      end

      # Heading slugs for one markdown file, in document order.
      #
      # FENCE-AWARE, and it has to be: these runbooks are mostly shell and
      # javascript blocks, and a `# Set the priority-ordered endpoints` shell
      # comment inside a fence is not a heading. Counting it would let a
      # `doc:` anchor validate against a code comment.
      def self.heading_slugs(file)
        in_fence = false
        File.readlines(file).filter_map do |line|
          if line =~ /^\s*(?:```|~~~)/
            in_fence = !in_fence
            next
          end
          next if in_fence
          next unless (match = line.match(/^\#{1,6}\s+(.*?)\s*$/))

          slug(match[1])
        end
      end

      def initialize(path: DEFAULT_PATH)
        @path = Pathname.new(path)
        @entries = read_entries
      end

      # What Platform::Runbook::Registry (A5) calls. Returns the entry hash for
      # a signal kind, or nil when the kind is not in the catalog at all —
      # which is DIFFERENT from a `not_documented` entry, and the caller has to
      # be able to tell them apart: "nobody has decided" is a coverage gap,
      # "decided, and there is nothing to point at" is an answer.
      def for(signal_kind)
        entries[signal_kind.to_s]
      end

      def documented?(signal_kind)
        self.for(signal_kind)&.key?("doc") || false
      end

      # Absolute path of an entry's doc, anchor stripped. nil for a
      # not_documented entry or an unknown kind.
      def resolved_path(signal_kind)
        doc = self.for(signal_kind)&.dig("doc")
        return nil if doc.blank?

        EXTENSION_ROOT.join(doc.split("#", 2).first)
      end

      # Both arms of the coverage question, as a list of human-readable
      # problems. Empty means the catalog is sound.
      #
      # Arm 1 (under-coverage): every bound kind has an entry.
      # Arm 2 (over-coverage):  every entry names a bound kind.
      #
      # A checker that only ran arm 1 would pass a catalog full of entries for
      # kinds that no longer exist, and a stale entry is worse than a missing
      # one: it renders a runbook for a signal the platform cannot emit.
      def validate(bound_kinds:)
        bound = bound_kinds.map(&:to_s)
        problems = []

        (bound - entries.keys).sort.each do |kind|
          problems << "#{kind}: bound in SIGNAL_BINDINGS but absent from #{path.basename}"
        end

        (entries.keys - bound).sort.each do |kind|
          problems << "#{kind}: present in #{path.basename} but bound by no SIGNAL_BINDINGS entry"
        end

        entries.sort.each do |kind, entry|
          problems.concat(entry_problems(kind, entry))
        end

        problems
      end

      private

      def read_entries
        raise LoadError, "runbook catalog not found at #{path}" unless path.exist?

        raw = YAML.safe_load(path.read) || {}
        raise LoadError, "#{path} must be a mapping of signal kind => entry" unless raw.is_a?(Hash)

        raw
      end

      def entry_problems(kind, entry)
        return [ "#{kind}: entry must be a mapping" ] unless entry.is_a?(Hash)

        unknown = entry.keys.map(&:to_s) - ENTRY_KEYS
        return [ "#{kind}: unknown key(s) #{unknown.sort.inspect}; allowed: #{ENTRY_KEYS.inspect}" ] if unknown.any?

        doc = entry["doc"]
        not_documented = entry["not_documented"]

        if doc.present? && not_documented
          return [ "#{kind}: entry declares both doc: and not_documented:" ]
        end

        return not_documented_problems(kind, entry) if not_documented
        return [ "#{kind}: entry declares neither doc: nor not_documented: true" ] if doc.blank?

        doc_problems(kind, doc)
      end

      def not_documented_problems(kind, entry)
        return [] if entry["reason"].to_s.strip.present?

        [ "#{kind}: not_documented entries require a non-empty reason" ]
      end

      def doc_problems(kind, doc)
        file_part, anchor = doc.to_s.split("#", 2)

        if anchor.to_s.strip.empty?
          return [ "#{kind}: doc #{doc.inspect} carries no #anchor" ]
        end

        file = EXTENSION_ROOT.join(file_part)
        return [ "#{kind}: doc file #{file_part} does not exist" ] unless file.file?

        slugs = self.class.heading_slugs(file)
        return [] if slugs.include?(anchor)

        [ "#{kind}: #{file_part} has no heading whose anchor is ##{anchor} " \
          "(#{slugs.size} headings; nearest: #{nearest(anchor, slugs).inspect})" ]
      end

      def nearest(anchor, slugs)
        slugs.min_by { |slug| levenshtein_ish(anchor, slug) }
      end

      # Cheap ordering for the error message only — never a correctness input.
      def levenshtein_ish(a, b)
        (a.chars - b.chars).size + (b.chars - a.chars).size + (a.length - b.length).abs
      end
    end
  end
end
