# frozen_string_literal: true

module System
  # Redacts and bounds STORED node output before it is served to an operator
  # or agent over the MCP tool surface: a task's error_message, and the events
  # (System::Task#events) a handler's result rides on. Built over
  # System::ShellOutputSanitizer.redact_text, whose patterns are the redactor;
  # this class owns the two things that redactor does not, the per-surface size
  # policy and the structure of a jsonb value.
  #
  # REDACT FIRST, THEN BOUND. Truncating first can leave a fragment of a secret
  # inside the returned window, so every cut happens on already-redacted text.
  #
  # The sanitizer's patterns are keyed on what PRECEDES a secret (password=,
  # --password, an api_key: label, a `login` on the same line), so a value that
  # has been separated from that context by the jsonb structure is invisible to
  # them. Three rules restore it, each failing closed:
  #
  #   * A string under a hash key is redacted together with the key as its lead.
  #     If redaction rewrote the lead itself the value is withheld whole.
  #   * A run of consecutive strings in an array is redacted as ONE string (its
  #     elements joined by a space, and again by a newline). If that changed
  #     anything the whole run is withheld: mapping a redaction back onto
  #     elements is not reliable (a PEM split across lines, an argv whose -p is
  #     two elements after `login`), and over-redacting a log-line array is
  #     cheaper than leaking.
  #   * A secret-NAMED key (password, pwd, token, api_key, cookie, ...) withholds
  #     its whole subtree whatever the value's type or shape, because a short
  #     value, a passphrase with spaces, a number or a nested object carries no
  #     pattern for the redactor to see.
  #
  # Best-effort, like the sanitizer: a secret shape with no pattern, under a key
  # with no secret name, is not caught.
  class StoredOutputRedactor
    REDACTED = ::System::ShellOutputSanitizer::REDACTED
    HEAD_MARKER = "...[truncated]"
    TAIL_MARKER = "[truncated]..."
    OMITTED = "[omitted: event payload budget exhausted]"
    TOO_DEEP = "[max depth exceeded]"

    MAX_DEPTH = 6
    MAX_WIDTH = 50
    MAX_KEY_LENGTH = 200

    # Keys whose value is a log: an operator wants its END (the failing last
    # lines), so these are bounded from the end rather than the start.
    LOG_SEGMENTS = %w[log logs tail stdout stderr output trace].freeze

    # A key matches by SUBSTRING of its snake_cased form for the long, specific
    # names, and by WHOLE SEGMENT for the short ones that would otherwise
    # match "bypass", "passed", "compass" or "author". The substring list is
    # Ai::SensitiveParams' own (the platform's one definition of a secret key
    # name, deployment-extensible), widened with the shapes it does not carry.
    EXTRA_SECRET_SUBSTRINGS = %w[
      passwd authorization apikey access_key accesskey privatekey secretkey
    ].freeze
    SECRET_SEGMENTS = %w[pass pwd auth cookie cookies session signature].freeze

    # A number under one of these is a measurement, not a credential:
    # token_count, token_ttl, secret_length.
    METADATA_SEGMENTS = %w[count total ttl seconds ms bytes size length].freeze

    # Bounded PEM-shaped lines at the START of a cut window: the BEGIN header
    # fell outside it, so no block or clipped-block pattern can see them.
    PEM_BODY_LEAD = %r{\A(?:\r?\n|[A-Za-z0-9+/=]{16,}\r?\n|(?:Proc-Type|DEK-Info):[^\n]*\n)+}

    Budget = Struct.new(:chars, :nodes, :string_limit, :patterns) do
      def exhausted?
        chars <= 0 || nodes <= 0
      end
    end

    class << self
      # One string, redacted then bounded. `from: :head` keeps the start (the
      # error_message policy), `:tail` keeps the end and marks the cut at the
      # front. `inclusive` counts the marker inside `limit` (events do;
      # error_message keeps its historical limit-plus-marker shape).
      #
      # `lead` is the text that sat immediately before the value in its source.
      # The value is redacted WITH it and the lead stripped again; if redaction
      # altered the lead, the value is withheld whole rather than guessed at.
      def bounded(raw, limit, from: :head, lead: nil, inclusive: false)
        # .scrub — the redaction regexes raise ArgumentError on invalid UTF-8,
        # and this is captured node output, not text the platform authored.
        text = raw.to_s.scrub("")
        redacted = ::System::ShellOutputSanitizer.redact_text("#{lead}#{bound_input(text, limit, from)}")
        if lead
          return REDACTED unless redacted.start_with?(lead)

          redacted = redacted[lead.length..]
        end
        cut(redacted, limit, from, inclusive)
      end

      # The newest `limit` events, oldest first, redacted and bounded on every
      # axis: `string_limit` per string, `max_chars` over every string, key and
      # scalar in the reply, `max_nodes` values in all, MAX_DEPTH levels and
      # MAX_WIDTH entries per container. The budget is spent newest-first, so a
      # long history returns its latest events whole and the older ones
      # collapse into ONE leading marker.
      def events(list, limit:, string_limit:, max_chars:, max_nodes:)
        all = list.is_a?(::Array) ? list : []
        budget = Budget.new(max_chars, max_nodes, string_limit, secret_substrings)
        kept = all.last(limit)
        out = []
        kept.reverse_each.with_index do |event, index|
          if budget.exhausted?
            out << "[omitted: #{kept.size - index} older events, event payload budget exhausted]"
            break
          end
          out << walk(event, budget, key: nil, secret: false, depth: 0)
        end
        { events: out.reverse, total: all.size, truncated: all.size > limit }
      end

      private

      def walk(value, budget, key:, secret:, depth:)
        budget.nodes -= 1
        return nil if value.nil?
        return spend(budget, OMITTED) if budget.exhausted?
        return spend(budget, REDACTED) if secret

        case value
        when ::Hash then walk_hash(value, budget, secret: secret, depth: depth)
        when ::Array then walk_array(value, budget, key: key, secret: secret, depth: depth)
        when ::String then walk_string(value, budget, key: key)
        else
          budget.chars -= value.to_s.length
          value
        end
      end

      def walk_hash(hash, budget, secret:, depth:)
        return spend(budget, TOO_DEEP) if depth >= MAX_DEPTH

        out = {}
        hash.first(MAX_WIDTH).each_with_index do |(raw_key, value), index|
          if budget.exhausted?
            put(out, "...[omitted]", "#{hash.size - index} more keys, event payload budget exhausted")
            return out
          end

          name = raw_key.to_s.scrub("")
          # Keys are redacted like any other stored string, and charged.
          shown = bounded(name, MAX_KEY_LENGTH, inclusive: true)
          budget.chars -= shown.length
          child_secret = secret || secret_key?(name, value, budget)
          put(out, shown, walk(value, budget, key: name, secret: child_secret, depth: depth + 1))
        end
        put(out, "...[truncated]", "#{hash.size - MAX_WIDTH} more keys") if hash.size > MAX_WIDTH
        out
      end

      def walk_array(array, budget, key:, secret:, depth:)
        return spend(budget, TOO_DEEP) if depth >= MAX_DEPTH

        from = log_key?(key) ? :tail : :head
        items = from == :tail ? array.last(MAX_WIDTH) : array.first(MAX_WIDTH)
        out = []
        out << spend(budget, "[#{array.size - items.size} earlier items truncated]") if from == :tail && array.size > items.size
        items.chunk_while { |a, b| a.is_a?(::String) && b.is_a?(::String) }.each do |run|
          if budget.exhausted?
            out << spend(budget, "[omitted: event payload budget exhausted]")
            return out
          end

          if run.first.is_a?(::String)
            out.concat(string_run(run, budget, key: key, from: from))
          else
            out << walk(run.first, budget, key: key, secret: secret, depth: depth + 1)
          end
        end
        out << spend(budget, "[#{array.size - items.size} more items truncated]") if from == :head && array.size > items.size
        out
      end

      def walk_string(string, budget, key:)
        limit = [ budget.string_limit, budget.chars ].min
        return spend(budget, OMITTED) if limit <= 0

        lead = "#{key.last(MAX_KEY_LENGTH)}: " if key
        result = bounded(string, limit, from: log_key?(key) ? :tail : :head, lead: lead, inclusive: true)
        budget.chars -= result.length
        result
      end

      # A run of consecutive strings redacted as one. See the class comment.
      def string_run(run, budget, key:, from:)
        budget.nodes -= run.size
        limit = budget.string_limit
        texts = run.map { |string| bound_input(string.to_s.scrub(""), limit, from) }
        lead = "#{key.last(MAX_KEY_LENGTH)}: " if key
        changed = [ " ", "\n" ].any? do |separator|
          joined = "#{lead}#{texts.join(separator)}"
          ::System::ShellOutputSanitizer.redact_text(joined) != joined
        end
        return run.map { spend(budget, REDACTED) } if changed

        texts.map do |text|
          room = [ limit, budget.chars ].min
          room <= 0 ? spend(budget, OMITTED) : spend(budget, cut(text, room, from, true))
        end
      end

      def spend(budget, text)
        budget.chars -= text.length
        text
      end

      # Hash#[]= that never merges two keys that redacted or were cut to the
      # same text: the second becomes "<key>#2", the third "#3".
      def put(hash, key, value)
        candidate = key
        suffix = 1
        candidate = "#{key}##{suffix += 1}" while hash.key?(candidate)
        hash[candidate] = value
      end

      # Bounds the redaction INPUT (rather than only its output) so a list call
      # cannot run every pattern over an unbounded blob. It is NOT safe on its
      # own: a secret the cut splits leaves a fragment, and redaction that
      # SHRINKS the window (a run of long token= values collapses to short
      # markers) can pull that fragment inside the returned text (measured: a
      # 9-char credential fragment served over MCP, IMP-675ed7763230 review). So
      # the run the cut split is dropped — but only while enough text survives
      # to fill the bound, since a whitespace-free body would otherwise be
      # stripped to nothing (BaseSkillExecutor#audit_text, the same rule). A
      # tail window also drops any PEM-shaped lines at its start, whose BEGIN
      # header the cut left outside.
      def bound_input(text, limit, from)
        span = limit * 4
        return text if text.length <= span

        if from == :tail
          sliced = text[-span..]
          stripped = sliced.sub(/\A\S+/, "").sub(PEM_BODY_LEAD, "")
        else
          sliced = text[0, span]
          stripped = sliced.sub(/\S+\z/, "")
        end
        stripped.length >= limit ? stripped : sliced
      end

      def cut(text, limit, from, inclusive)
        return text if text.length <= limit

        marker = from == :tail ? TAIL_MARKER : HEAD_MARKER
        keep = inclusive ? [ limit - marker.length, 0 ].max : limit
        return marker if keep.zero?

        from == :tail ? "#{marker}#{text[-keep..]}" : "#{text[0, keep]}#{marker}"
      end

      def log_key?(key)
        key.present? && segments(key).intersect?(LOG_SEGMENTS)
      end

      def secret_key?(name, value, budget)
        snake = snake_case(name)
        parts = snake.split("_")
        return false unless budget.patterns.any? { |pattern| snake.include?(pattern) } ||
                            parts.intersect?(SECRET_SEGMENTS)

        !(value.is_a?(::Numeric) && METADATA_SEGMENTS.include?(parts.last))
      end

      def segments(key)
        snake_case(key).split("_")
      end

      def snake_case(key)
        key.to_s.scrub("").gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase.gsub(/[^a-z0-9]+/, "_")
      end

      def secret_substrings
        (::Ai::SensitiveParams.key_patterns + EXTRA_SECRET_SUBSTRINGS).map(&:downcase).uniq
      end
    end
  end
end
