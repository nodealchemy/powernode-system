# frozen_string_literal: true

module System
  # Semantic reuse-first discovery over the NodeModule + NodeTemplate catalogs.
  #
  # The module-authoring runbook opens with a reuse-first gate — "does a module
  # for this purpose already exist?" — that had no machine surface:
  # `system_list_modules` filtered by variety only and `system_list_templates`
  # took no parameters at all, so an agent could only answer the question by
  # pulling the whole catalog and eyeballing names. This is the answer surface.
  #
  # Shape and policy intentionally mirror
  # System::Ai::Skills::DiscoverPackagesByIntentExecutor:
  #
  #   * Pure pgvector cosine ranking over persisted embeddings.
  #   * Confidence bucketed off the TOP match's distance.
  #   * NO lexical degradation. The package-side rationale applies verbatim:
  #     discovery's whole premise IS the semantic match, so a missing embedding
  #     provider raises rather than quietly returning keyword noise that an
  #     agent would read as "nothing exists" — the exact false negative that
  #     causes a duplicate module to be authored.
  #
  # One addition over the package version: every Result carries `coverage`.
  # The recorded platform lesson is that a "completed" index can be 0% embedded
  # and status lies — so an empty result set with 40 unembedded rows must be
  # distinguishable from a genuinely empty catalog. Callers surface it.
  class CatalogDiscoveryService
    DEFAULT_TOP_K = 10
    MAX_TOP_K     = 50

    # Pull this many neighbors before truncating to top_k.
    #
    # This is NOT filter headroom — every structured filter (variety,
    # platform, enabled) is applied to the scope BEFORE nearest_neighbors
    # runs, so nothing whittles the result set afterward and an over-fetch
    # could not rescue an empty page. (The comment here claimed otherwise
    # until IMP-a9adf9ea4399.)
    #
    # What it actually buys is `seed_count`: how many ranked candidates
    # existed beyond the page returned, capped at top_k * this factor. That
    # is the signal a caller uses to decide whether to re-ask with a larger
    # top_k — "10 results, seed_count 30" means the catalog had more to say.
    # Keep the two in sync: changing this factor changes what seed_count can
    # report, which is documented on the system_discover_* MCP actions.
    SEMANTIC_OVERSCORE_FACTOR = 3

    # Confidence buckets keyed off the TOP match's cosine distance — same
    # thresholds as discover_packages_by_intent so operators read one scale.
    CONFIDENCE_HIGH_BELOW   = 0.30
    CONFIDENCE_MEDIUM_BELOW = 0.50

    # Raised when the embedding provider yields no vector for the intent.
    # Deliberately NOT rescued into a lexical fallback — see the class comment.
    class EmbeddingUnavailable < StandardError; end

    Result = Struct.new(:records, :seed_count, :confidence, :coverage, keyword_init: true)

    class << self
      def discover_modules(account:, intent:, top_k: DEFAULT_TOP_K, variety: nil,
                           platform_id: nil, include_disabled: false)
        scope = ::System::NodeModule.where(account: account).includes(:category)
        scope = scope.enabled unless include_disabled
        scope = scope.where(variety: variety) if variety.present?
        scope = scope.where(node_platform_id: platform_id) if platform_id.present?

        rank(scope: scope, account: account, intent: intent, top_k: top_k)
      end

      def discover_templates(account:, intent:, top_k: DEFAULT_TOP_K,
                             platform_id: nil, include_disabled: false)
        scope = ::System::NodeTemplate.where(account: account)
        scope = scope.where(enabled: true) unless include_disabled
        scope = scope.where(node_platform_id: platform_id) if platform_id.present?

        rank(scope: scope, account: account, intent: intent, top_k: top_k)
      end

      # Cosine distance → similarity, rounded for display. Shared with the
      # callers that build per-result payloads.
      def similarity_for(record)
        (1.0 - record.neighbor_distance.to_f).round(4)
      end

      private

      def rank(scope:, account:, intent:, top_k:)
        cleaned = intent.to_s.strip
        raise ArgumentError, "intent is required" if cleaned.empty?
        raise ArgumentError, "account is required" if account.blank?

        top_k = top_k.to_i.clamp(1, MAX_TOP_K)
        vector = generate_embedding(cleaned, account: account)
        raise EmbeddingUnavailable, "could not generate an embedding for the intent (provider unavailable)" if vector.blank?

        candidates = scope.with_embedding
                          .nearest_neighbors(:embedding, vector, distance: "cosine")
                          .first(top_k * SEMANTIC_OVERSCORE_FACTOR)
        ranked = candidates.first(top_k)

        Result.new(
          records:    ranked,
          seed_count: candidates.size,
          confidence: confidence_for(ranked),
          coverage:   coverage_for(scope)
        )
      end

      def generate_embedding(text, account:)
        ::Ai::Memory::EmbeddingService.new(account: account).generate(text)
      rescue StandardError => e
        Rails.logger.warn("[CatalogDiscovery] embedding failed: #{e.class}: #{e.message}")
        nil
      end

      def confidence_for(ranked)
        return "low" if ranked.empty?

        distance = ranked.first.neighbor_distance.to_f
        return "high"   if distance < CONFIDENCE_HIGH_BELOW
        return "medium" if distance < CONFIDENCE_MEDIUM_BELOW

        "low"
      end

      # Counted over the SAME filtered scope the search ran against, so the
      # numbers answer "how much of what I just searched is actually indexed?"
      # rather than a catalog-wide figure that wouldn't explain this result.
      def coverage_for(scope)
        counted  = scope.unscope(:includes)
        total    = counted.count
        embedded = counted.with_embedding.count
        { total: total, embedded: embedded, unembedded: total - embedded }
      end
    end
  end
end
