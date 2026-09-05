# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Assemble a Template *draft* from a natural-language workload description.
      #
      # v1 (campaign 019f6084 inc3) ranks modules SEMANTICALLY: it embeds the
      # description and each candidate module's `name + description`, then ranks
      # by cosine similarity (reusing the same Ai::Memory::EmbeddingService the
      # package-intent discovery skill uses). Keyword overlap on the module name
      # is kept as a graceful FALLBACK for when the embedding provider is
      # unavailable — discovery still degrades to *something* rather than an
      # error, unlike discover_packages_by_intent whose whole premise is the
      # vector match.
      #
      # v1 also BRIDGES module gaps: when no existing module clears the semantic
      # floor for the requested capability, it consults
      # discover_packages_by_intent and surfaces a `gap: materialize <pkg>`
      # entry (rather than silently returning an empty composition), so a
      # caller — notably fulfill_capability_request — can author the missing
      # capability from a package instead of giving up.
      #
      # Output is a *draft* — never a persisted Template. The Concierge or an
      # operator confirms via system_create_template +
      # system_assign_module_to_template against the returned module list; the
      # gaps are materialized via the package_module_create path.
      #
      # Reference: Golden Eclipse plan M6 — Skills catalog (module_compose row);
      # campaign 019f6084 inc3 (on-demand template + instance slice).
      class ModuleComposeExecutor < BaseSkillExecutor
        DEFAULT_MAX_MODULES = 10

        # Minimum keyword overlap to include a module in the FALLBACK ranker.
        # Ratio is matched tokens / total description tokens. 0.05 = 1 match per
        # 20 description tokens, generous on purpose so the fallback catches
        # anything plausible for the operator to review.
        INCLUDE_THRESHOLD = 0.05

        # Cosine-similarity floor a module must clear to count as "covering" the
        # request in the SEMANTIC ranker. Below the floor the capability is
        # treated as uncovered → a package gap is surfaced. Configurable via
        # SiteSetting `system.module_compose.min_similarity` (never a bare
        # constant — this is the fallback default only).
        DEFAULT_MIN_SIMILARITY = 0.5

        # Common English stopwords stripped before token matching. Not language-
        # aware — fine here since module catalogs are predominantly English.
        STOPWORDS = %w[
          a an the and or but if then in on for to of with at from by as is are
          be been being do does did done have has had this that these those it
          its we us our you your i me my they them their which who whose what
          want need spin run setup install deploy host server use using
        ].freeze

        skill_descriptor(
          name: "module_compose",
          description: "Compose a Template draft from a workload description — SEMANTICALLY ranks modules (embedding cosine, keyword fallback), runs conflict checks, and surfaces package gaps to materialize when no module covers a capability",
          category: "devops",
          inputs: {
            description: { type: "string", required: true,
                           description: "Free-form workload description, e.g. 'nginx web server with SSL and metrics'" },
            platform_id: { type: "string", required: false,
                           description: "Restrict the search to modules for a specific NodePlatform" },
            max_modules: { type: "integer", required: false, default: DEFAULT_MAX_MODULES }
          },
          outputs: {
            draft_template: :object,
            conflicts: [ :object ],
            gaps: [ :object ],
            candidate_count: :integer,
            ranking_mode: :string,
            reasoning: :string
          }
        )

        # System Concierge is the NL surface for on-demand composition; Fleet
        # Autonomy drives it policy-gated.
        binds_to "Fleet Autonomy", "concierge"

        protected

        def perform(description:, platform_id: nil, max_modules: DEFAULT_MAX_MODULES)
          tokens = tokenize(description)
          return failure("description must contain at least one non-stopword token") if tokens.empty?

          modules_resp = tool(::Ai::Tools::SystemFleetTool).execute(params: { action: "system_list_modules" })
          return failure("module listing failed: #{modules_resp[:error]}") unless modules_resp[:success]

          candidates = filter_for_platform(modules_resp[:data][:modules], platform_id)
          ranked, mode = rank(candidates, description, tokens)
          chosen = ranked.first(max_modules.to_i)

          conflicts = detect_conflicts(chosen)
          gaps = detect_gaps(description, chosen, platform_id)

          success(
            draft_template: build_draft_template(description, chosen),
            conflicts: conflicts,
            gaps: gaps,
            candidate_count: candidates.size,
            ranking_mode: mode,
            reasoning: build_reasoning(tokens, ranked, chosen, mode, gaps),
            requires_approval: false,
            note: "draft only — operator/concierge confirms via system_create_template + system_assign_module_to_template; gaps materialize via package_module_create"
          )
        end

        private

        def tokenize(text)
          text.to_s.downcase.scan(/[a-z0-9]+/).reject { |t| t.length < 2 || STOPWORDS.include?(t) }
        end

        def filter_for_platform(modules, platform_id)
          return modules if platform_id.blank?

          ids = ::System::NodeModule
                .where(account: @account, node_platform_id: platform_id)
                .pluck(:id)
          modules.select { |m| ids.include?(m[:id]) }
        end

        # === Ranking ======================================================
        # Returns [ranked, mode]. Prefers semantic (embedding cosine); falls
        # back to keyword overlap when the embedding provider can't embed the
        # description (returns nil) — that's the only signal the provider is
        # down, since a live provider always yields a vector.
        def rank(candidates, description, tokens)
          query_vec = embed(description)
          if query_vec
            [ semantic_rank(candidates, description, tokens, query_vec), "semantic" ]
          else
            [ keyword_rank(candidates, tokens), "keyword" ]
          end
        end

        # Semantic ranker: embeds each candidate's `name + description` on the
        # fly and scores it against the pre-computed description embedding.
        # Modules below the similarity floor are dropped — the capabilities
        # they'd cover surface as gaps.
        #
        # NodeModule DOES carry a persisted `embedding` column as of
        # IMP-67aea0728774, and this ranker deliberately does NOT use it yet.
        # Three reasons, strongest first:
        #
        #   1. Catalogs are partially embedded BY CONSTRUCTION — nothing
        #      enqueues an embed on save, so only what the backfill has reached
        #      carries a vector. A persisted-only ranker would make every
        #      unembedded module INVISIBLE here, and this executor converts
        #      "no module covers it" into a package gap — so an unindexed
        #      module would be silently re-materialized from a package. That is
        #      the exact false negative the discovery feature exists to
        #      prevent, inverted.
        #   2. The persisted vector covers a RICHER text than this one
        #      (embedding_text = name + variety + description + category +
        #      capabilities, vs `name + description` here), so similarity
        #      magnitudes differ — and the floor below is a configured value
        #      (`system.module_compose.min_similarity`, default 0.5) calibrated
        #      against the thin text. Swapping without re-tuning silently
        #      changes which modules count as "covering".
        #   3. Mixing both sources in one ranking compares two incompatible
        #      scales within a single sorted list.
        #
        # Safe sequencing when this is picked up: land an on-save embed (or get
        # coverage to 100% and keep it there), re-tune the floor against the
        # persisted text, then switch — not before.
        def semantic_rank(candidates, description, tokens, query_vec)
          floor = min_similarity
          descriptions = load_descriptions(candidates)
          svc = embedding_service

          Array(candidates).filter_map do |m|
            text = [ m[:name], descriptions[m[:id]] ].compact.join(" ").strip
            vec = embed(text)
            next unless vec

            sim = svc.similarity(query_vec, vec).to_f
            next if sim < floor

            {
              module: m,
              score: sim.round(4),
              similarity: sim.round(4),
              matched_tokens: overlap_tokens(text, tokens)
            }
          end.sort_by { |r| -r[:score] }
        end

        # Keyword-overlap fallback (v0 behavior, preserved verbatim in shape so
        # build_draft_template / detect_conflicts consume it unchanged).
        def keyword_rank(candidates, tokens)
          token_count = tokens.size.to_f
          Array(candidates).filter_map do |m|
            haystack = "#{m[:name]} #{m[:gitea_repo_full_name]}".downcase
            matched = tokens.uniq.select { |t| haystack.include?(t) }
            next if matched.empty?

            score = matched.size / [ token_count, 1 ].max
            next if score < INCLUDE_THRESHOLD

            { module: m, matched_tokens: matched, score: score.round(3) }
          end.sort_by { |r| -r[:score] }
        end

        def overlap_tokens(text, tokens)
          haystack = text.downcase
          tokens.uniq.select { |t| haystack.include?(t) }
        end

        # Bulk-load descriptions for the candidate module ids in one query
        # (the serialized tool payload omits description). Keyed by id.
        def load_descriptions(candidates)
          ids = Array(candidates).map { |m| m[:id] }.compact
          return {} if ids.empty?

          ::System::NodeModule.where(account: @account, id: ids).pluck(:id, :description).to_h
        end

        # Splits a workload description into candidate capability phrases on
        # conjunctions / separators, so gap detection is PER-CAPABILITY rather
        # than all-or-nothing. "nginx + redis" / "nginx and redis" / "nginx with
        # redis" all decompose to ["nginx", "redis"]; a description with no
        # separator stays a single phrase (legacy single-capability behavior).
        CAPABILITY_SPLIT = /\s*(?:,|\+|&|\/|\band\b|\bwith\b|\bplus\b|\balong\s+with\b)\s*/i

        # === Gap bridging =================================================
        # Surface a materialize-this-package gap for every requested capability
        # that NO chosen module covers — even under PARTIAL coverage. The prior
        # implementation short-circuited (`return [] if chosen.any?`), so a
        # request like "nginx + redis" where only nginx has a module silently
        # dropped redis. Now the request is decomposed into capability phrases
        # and each uncovered phrase surfaces its own gap.
        #
        # Coverage is token-level: a phrase is "covered" when any of its tokens
        # appears in the union of the chosen modules' matched_tokens. Residual
        # limitation (documented, deferred): decomposition is lexical (split on
        # conjunctions), not a true semantic capability parse — a compound phrase
        # naming several capabilities in prose ("a cache and a database", no
        # separator between "cache"/"database" beyond the conjunction we do split
        # on) is handled, but capabilities fused into one noun phrase are not
        # individually resolved. The all-or-nothing drop is gone regardless.
        def detect_gaps(description, chosen, _platform_id)
          phrases = split_capabilities(description)
          phrases = [ description.to_s.strip ] if phrases.empty?

          covered = chosen.flat_map { |c| Array(c[:matched_tokens]) }.map(&:downcase).to_set

          uncovered = phrases.reject do |phrase|
            ptoks = tokenize(phrase)
            ptoks.empty? || ptoks.any? { |t| covered.include?(t) }
          end
          return [] if uncovered.empty?

          uncovered.filter_map { |phrase| gap_for_capability(phrase) }
        end

        def split_capabilities(description)
          description.to_s.split(CAPABILITY_SPLIT).map(&:strip).reject(&:empty?)
        end

        # Resolve a single uncovered capability phrase to a materialize gap via
        # discover_packages_by_intent. Falls back to an author_module gap when
        # discovery FOUND NOTHING (a human must author a module), or to a
        # discovery_unavailable gap when discovery itself FAILED (transient
        # infra — retryable, NOT evidence that authoring is needed).
        def gap_for_capability(capability)
          disc = executor(DiscoverPackagesByIntentExecutor)
                   .execute(intent: capability)

          unless disc[:success]
            return {
              capability: capability,
              action: "discovery_unavailable",
              reason: "package discovery unavailable (#{disc[:error]}) — retry before concluding a module must be authored"
            }
          end

          top = Array(disc.dig(:data, :results)).first
          unless top
            return {
              capability: capability,
              action: "author_module",
              reason: "no covering module and no matching package"
            }
          end

          {
            capability: capability,
            action: "materialize",
            package: top[:name],
            package_id: top[:package_id],
            repository_id: top[:repository_id],
            confidence: disc.dig(:data, :confidence),
            reason: "no existing module clears the similarity floor — materialize #{top[:name]}"
          }
        end

        # === Embedding ====================================================
        def embedding_service
          @embedding_service ||= ::Ai::Memory::EmbeddingService.new(account: @account)
        end

        def embed(text)
          return nil if text.to_s.strip.empty?

          embedding_service.generate(text.to_s)
        rescue StandardError => e
          Rails.logger.warn("[ModuleCompose] embedding failed: #{e.class}: #{e.message}")
          nil
        end

        def min_similarity
          raw = ::SiteSetting.get("system.module_compose.min_similarity")
          raw.nil? ? DEFAULT_MIN_SIMILARITY : raw.to_f
        end

        # === Conflict detection (unchanged) ===============================
        def detect_conflicts(chosen)
          conflicts = []

          # Multiple `instance`-variety modules in the same category typically
          # indicate a collision (only one instance variety can win priority
          # within a category).
          group_by_category = chosen.group_by { |c| c[:module][:category_id] }
          group_by_category.each do |cat_id, items|
            instance_modules = items.select { |i| i[:module][:variety] == "instance" }
            if instance_modules.size > 1
              conflicts << {
                kind: "instance_variety_collision",
                category_id: cat_id,
                module_ids: instance_modules.map { |i| i[:module][:id] }
              }
            end
          end

          conflicts
        end

        # === Draft assembly ===============================================
        def build_draft_template(description, chosen)
          {
            name_suggestion: suggest_template_name(description),
            description: "Draft generated from: #{description}".truncate(280),
            modules: chosen.map { |c|
              { id: c[:module][:id], name: c[:module][:name],
                variety: c[:module][:variety], score: c[:score],
                matched_tokens: c[:matched_tokens] }
            }
          }
        end

        def suggest_template_name(description)
          base = description.to_s.downcase.scan(/[a-z0-9]+/).reject { |t| STOPWORDS.include?(t) }.first(3)
          return "draft-template" if base.empty?
          "#{base.join('-')}-template"
        end

        def build_reasoning(tokens, ranked, chosen, mode, gaps)
          if chosen.empty?
            gap_note = gaps.any? ? " Suggested gap: #{gaps.first[:action]} #{gaps.first[:package]}.".rstrip : ""
            "No modules matched the description tokens (#{tokens.first(8).join(', ')}) via #{mode} ranking." \
            "#{gap_note} Consider authoring a new module or broadening the description."
          else
            "Matched #{ranked.size} candidate modules via #{mode} ranking; selected top #{chosen.size}. " \
            "Top match: #{chosen.first[:module][:name]} (score=#{chosen.first[:score]})."
          end
        end
      end
    end
  end
end
