# frozen_string_literal: true

module System
  # Shared search backbone for the package catalog. Both surfaces — the MCP
  # tool action `system_search_packages` and the REST endpoint
  # `GET /api/v1/system/packages` — call into this service so hybrid ranking
  # logic lives in exactly one place.
  #
  # Modes:
  #   lexical  — trigram + ILIKE; deterministic; no embedding required.
  #   semantic — pgvector nearest_neighbors over the query embedding; requires q.
  #   hybrid   — (default) merge lexical + semantic candidate sets and re-rank
  #              by a weighted combined score. Degrades to lexical-only when
  #              q is blank (no semantic anchor) and to lexical-only when the
  #              embedding service fails to produce a vector.
  #
  # Back-compat: singular params (repository_id, architecture, section) remain
  # accepted alongside the new array forms (repository_ids, architectures,
  # sections).
  #
  # Result shape:
  #   Result.new(
  #     packages:         [Package, ...],   # already ordered + paginated
  #     total:            Integer | nil,    # nil under semantic/hybrid with q (exact COUNT prohibitive)
  #     mode:             "lexical" | "semantic" | "hybrid",
  #     applied_filters:  Hash               # echo of normalized filters
  #   )
  class PackageSearchService
    DEFAULT_MODE     = "hybrid"
    DEFAULT_SORT     = "relevance"
    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE     = 200
    SEMANTIC_OVERSCORE_FACTOR = 3       # pull N*3 candidates so structured filters have headroom
    HYBRID_WEIGHTS = { trigram: 0.45, cosine: 0.45, prefix: 0.10 }.freeze

    Result = Struct.new(:packages, :total, :mode, :applied_filters, keyword_init: true)

    def self.call(account:, params:)
      new(account: account, params: params).call
    end

    def initialize(account:, params:)
      @account = account
      @raw_params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params
      @raw_params = @raw_params.deep_symbolize_keys
      @page       = [(@raw_params[:page] || 1).to_i, 1].max
      @per_page   = clamp_per_page(@raw_params[:per_page])
      @q          = @raw_params[:q].to_s.strip
      @mode       = normalize_mode(@raw_params[:mode], q: @q)
      @sort       = (@raw_params[:sort] || DEFAULT_SORT).to_s
    end

    def call
      repos = accessible_repos_scope
      base  = ::System::Package.live.where(package_repository_id: repos.pluck(:id))
      base  = apply_structured_filters(base)

      packages, total = case @mode
                        when "lexical"  then run_lexical(base)
                        when "semantic" then run_semantic(base)
                        when "hybrid"   then run_hybrid(base)
                        end

      Result.new(
        packages:        packages,
        total:           total,
        mode:            @mode,
        applied_filters: applied_filters_echo
      )
    end

    private

    # === Param normalization ===========================================

    def clamp_per_page(raw)
      n = raw.to_i
      return DEFAULT_PER_PAGE if n <= 0

      [n, MAX_PER_PAGE].min
    end

    def normalize_mode(value, q:)
      mode = value.to_s
      mode = DEFAULT_MODE if mode.blank?
      return "lexical" if mode == "semantic" && q.blank?
      return "lexical" if mode == "hybrid"   && q.blank?

      %w[lexical semantic hybrid].include?(mode) ? mode : DEFAULT_MODE
    end

    def repository_ids
      ids = Array(@raw_params[:repository_ids]).compact_blank
      ids << @raw_params[:repository_id] if @raw_params[:repository_id].present?
      ids.uniq
    end

    def kind_filter
      @raw_params[:kind].to_s.presence
    end

    def architectures_input
      arr = Array(@raw_params[:architectures]).compact_blank.map(&:to_s)
      arr << @raw_params[:architecture].to_s if @raw_params[:architecture].present?
      arr.uniq
    end

    def sections_input
      arr = Array(@raw_params[:sections]).compact_blank.map(&:to_s)
      arr << @raw_params[:section].to_s if @raw_params[:section].present?
      arr.uniq
    end

    def license_input
      @raw_params[:license].to_s.presence
    end

    def provides_input
      @raw_params[:provides].to_s.presence
    end

    # === Scope construction ============================================

    def accessible_repos_scope
      scope = ::System::PackageRepository.accessible_to(@account).enabled
      scope = scope.where(id: repository_ids) if repository_ids.any?
      scope = scope.where(kind: kind_filter)  if kind_filter
      scope
    end

    def apply_structured_filters(scope)
      scope = scope.where(architecture: expanded_architectures) if architectures_input.any?
      scope = scope.where(section_or_group: sections_input)     if sections_input.any?
      scope = scope.where(license: license_input)               if license_input
      if provides_input
        # JSONB GIN-backed lookup — name match OR provides @> [[{name: cap}]]
        scope = scope.where(
          "system_packages.name = ? OR system_packages.provides @> ?::jsonb",
          provides_input,
          [[{ name: provides_input }]].to_json
        )
      end
      scope
    end

    # Each canonical name expands to its known kind-specific aliases so
    # the filter works cross-kind (one search spanning apt + rpm repos).
    def expanded_architectures
      names = []
      architectures_input.each do |canonical|
        arch = ::System::NodeArchitecture.find_normalized(canonical)
        if arch
          names.concat([arch.name, arch.apt_name, arch.rpm_name])
        else
          # Unknown alias — pass through literally so the user still gets a
          # filter (just no cross-kind expansion). Better than swallowing.
          names << canonical
        end
      end
      names.compact.uniq
    end

    # === Modes =========================================================

    def run_lexical(scope)
      ordered = if @q.present?
                  apply_lexical_ranking(scope, @q)
                else
                  scope.order(name: :asc, architecture: :asc)
                end
      paginate_with_count(ordered)
    end

    def run_semantic(scope)
      embedding = generate_embedding(@q)
      # Embedding generation failed — degrade gracefully to lexical so the
      # caller still sees results instead of an empty set.
      return run_lexical(scope) if embedding.blank?

      candidates = scope.with_embedding
                        .nearest_neighbors(:embedding, embedding, distance: "cosine")
                        .first(@per_page * SEMANTIC_OVERSCORE_FACTOR)

      paginated = candidates.drop((@page - 1) * @per_page).first(@per_page)
      [paginated, nil] # total: nil — exact count prohibitive on vector-filtered sets
    end

    def run_hybrid(scope)
      embedding = generate_embedding(@q)
      lex_candidates = apply_lexical_ranking(scope, @q).limit(@per_page * SEMANTIC_OVERSCORE_FACTOR).to_a
      sem_candidates =
        if embedding.present?
          scope.with_embedding
               .nearest_neighbors(:embedding, embedding, distance: "cosine")
               .first(@per_page * SEMANTIC_OVERSCORE_FACTOR)
        else
          []
        end

      merged = merge_and_rerank(lex_candidates, sem_candidates, @q)
      paginated = merged.drop((@page - 1) * @per_page).first(@per_page)
      [paginated, nil] # total: nil — see run_semantic
    end

    # === Lexical ranking ===============================================

    def apply_lexical_ranking(scope, query)
      sanitized = ActiveRecord::Base.sanitize_sql_like(query.to_s)
      ilike = "%#{sanitized}%"
      prefix = "#{sanitized}%"
      # Trigram similarity (pg_trgm) yields a stable 0..1 rank; ILIKE fallback
      # keeps non-trigram matches in the result set. exact > prefix > sim.
      scope
        .where("system_packages.name ILIKE :ilike OR system_packages.description ILIKE :ilike", ilike: ilike)
        .reorder(
          Arel.sql(ActiveRecord::Base.sanitize_sql_array([
            "(CASE WHEN LOWER(system_packages.name) = LOWER(?) THEN 0 " \
            "      WHEN system_packages.name ILIKE ? THEN 1 " \
            "      ELSE 2 END) ASC, " \
            "similarity(system_packages.name, ?) DESC, " \
            "system_packages.name ASC",
            query, prefix, query
          ]))
        )
    end

    # === Hybrid scoring ================================================

    def merge_and_rerank(lex_rows, sem_rows, query)
      seen = {}
      lex_rows.each_with_index do |pkg, idx|
        seen[pkg.id] ||= { pkg: pkg, trigram: trigram_score(pkg.name, query), cosine: nil, lex_rank: idx }
      end
      sem_rows.each_with_index do |pkg, idx|
        entry = seen[pkg.id] ||= { pkg: pkg, trigram: trigram_score(pkg.name, query), cosine: nil, lex_rank: nil }
        # neighbor_distance is set on the AR record by the nearest_neighbors scope
        entry[:cosine] = 1.0 - pkg.neighbor_distance.to_f
        entry[:sem_rank] = idx
      end

      scored = seen.values.map do |e|
        trigram_part = HYBRID_WEIGHTS[:trigram] * e[:trigram]
        cosine_part  = HYBRID_WEIGHTS[:cosine]  * (e[:cosine] || 0.0)
        prefix_part  = HYBRID_WEIGHTS[:prefix]  * prefix_bonus(e[:pkg].name, query)
        score = trigram_part + cosine_part + prefix_part
        # Stash on the AR record so serializers can echo it
        e[:pkg].define_singleton_method(:hybrid_similarity) { score }
        { pkg: e[:pkg], score: score }
      end

      scored.sort_by { |row| -row[:score] }.map { |row| row[:pkg] }
    end

    def trigram_score(name, query)
      # Cheap Ruby-side approximation of pg_trgm similarity for the merge
      # step. The DB does the precise similarity() ordering in the lexical
      # leg; this fallback handles rows that surfaced only via the semantic
      # leg and never went through the SQL trigram ordering.
      return 0.0 if name.blank? || query.blank?

      n = name.downcase
      q = query.downcase
      return 1.0 if n == q
      return 0.85 if n.start_with?(q)
      return 0.65 if n.include?(q)

      0.3
    end

    def prefix_bonus(name, query)
      return 0.0 if name.blank? || query.blank?
      return 1.0 if name.downcase.start_with?(query.downcase)
      return 0.5 if name.downcase.include?(query.downcase)

      0.0
    end

    # === Helpers =======================================================

    def generate_embedding(query)
      return nil if query.blank?
      # Account is required by Ai::Memory::EmbeddingService for cache + provider
      # resolution. When @account is nil (system call), skip semantic — the
      # mode falls back to lexical in run_hybrid.
      return nil unless @account.present?

      begin
        ::Ai::Memory::EmbeddingService.new(account: @account).generate(query)
      rescue StandardError => e
        Rails.logger.warn("[PackageSearch] embedding generation failed: #{e.class}: #{e.message}")
        nil
      end
    end

    def paginate_with_count(scope)
      total   = scope.count
      results = scope.limit(@per_page).offset((@page - 1) * @per_page).to_a
      [results, total]
    end

    def applied_filters_echo
      {
        q:              @q.presence,
        mode:           @mode,
        sort:           @sort,
        page:           @page,
        per_page:       @per_page,
        repository_ids: repository_ids.presence,
        kind:           kind_filter,
        architectures:  architectures_input.presence,
        sections:       sections_input.presence,
        license:        license_input,
        provides:       provides_input
      }
    end
  end
end
