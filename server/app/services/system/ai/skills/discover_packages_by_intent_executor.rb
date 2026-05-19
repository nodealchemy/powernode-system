# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Intent-based package discovery — given a free-text capability need
      # ("I need a reverse proxy", "distributed cache"), returns ranked
      # packages from accessible repositories by semantic similarity.
      #
      # Wraps the same filter dimensions PackageSearchService exposes
      # (kind, repository_ids, architectures, license) so callers can
      # narrow the candidate pool before the semantic ranking — useful
      # when the operator already knows e.g. "find me an apt amd64
      # reverse proxy" but doesn't remember the exact package name.
      #
      # Pure pgvector cosine-distance ranking. Falls back to a clear error
      # if the embedding service is unavailable (no graceful lexical
      # degradation — discovery's premise IS the semantic match).
      class DiscoverPackagesByIntentExecutor < BaseSkillExecutor
        DEFAULT_TOP_K = 10
        MAX_TOP_K     = 50

        # Pull this many vector neighbors before applying the top_k cap.
        # Higher factors give the structured filters more headroom — if
        # the user adds an arch filter that excludes most candidates, we
        # still have alternates to surface.
        SEMANTIC_OVERSCORE_FACTOR = 3

        # Confidence buckets keyed off the TOP match's cosine distance.
        # Below 0.30 cosine distance = high (top match is a near twin),
        # below 0.50 = medium (relevant but not certain), else = low
        # (best guess — operator should sanity-check).
        CONFIDENCE_HIGH_BELOW   = 0.30
        CONFIDENCE_MEDIUM_BELOW = 0.50

        skill_descriptor(
          name: "discover_packages_by_intent",
          description: "Intent-based package discovery — describe a capability need ('reverse proxy', 'distributed cache') and get ranked packages from accessible repositories. Use system_search_packages instead when you already know the package name and just want filter/browse.",
          category: "devops",
          inputs: {
            intent:         { type: "string",  required: true,
                              description: "Free-text capability description — what the package should do" },
            repository_ids: { type: "array",   required: false,
                              description: "PackageRepository UUIDs to restrict the search to" },
            kind:           { type: "string",  required: false,
                              description: "Repository kind filter — apt|rpm|dnf" },
            architectures:  { type: "array",   required: false,
                              description: "Canonical arch names (amd64, arm64) to filter against — cross-kind expanded" },
            license:        { type: "string",  required: false,
                              description: "Exact license string to require (e.g. 'MIT', 'Apache-2.0')" },
            top_k:          { type: "integer", required: false,
                              default: DEFAULT_TOP_K,
                              description: "Max results to return (1-#{MAX_TOP_K})" }
          },
          outputs: {
            intent:     :string,
            results:    :array,    # Array<Hash> {package_id, name, version, architecture, summary, similarity, repository_id, reason}
            seed_count: :integer,  # Raw candidate count before top_k
            confidence: :string    # high|medium|low
          }
        )

        binds_to "Fleet Autonomy", "System Concierge"

        protected

        def perform(intent:, repository_ids: nil, kind: nil, architectures: nil, license: nil, top_k: DEFAULT_TOP_K)
          return failure("intent is required") if intent.to_s.strip.empty?
          return failure("account is required for embedding generation") if @account.blank?

          top_k = top_k.to_i.clamp(1, MAX_TOP_K)

          embedding = generate_embedding(intent.to_s.strip)
          return failure("could not generate embedding for intent (provider unavailable)") unless embedding

          scope = build_scope(
            repository_ids: repository_ids,
            kind:           kind,
            architectures:  architectures,
            license:        license
          )

          # Pull a wider neighbor window then top_k after — gives the user's
          # filters room to whittle without empty-result blackouts.
          candidates = scope.with_embedding
                            .nearest_neighbors(:embedding, embedding, distance: "cosine")
                            .first(top_k * SEMANTIC_OVERSCORE_FACTOR)
          ranked = candidates.first(top_k)

          success(
            intent:     intent,
            results:    ranked.map { |pkg| build_match(pkg, intent) },
            seed_count: candidates.size,
            confidence: confidence_for(ranked)
          )
        end

        private

        # === Scope assembly (intentionally mirrors PackageSearchService) ==

        def build_scope(repository_ids:, kind:, architectures:, license:)
          repos = ::System::PackageRepository.accessible_to(@account).enabled
          repos = repos.where(id: Array(repository_ids).compact_blank) if Array(repository_ids).compact_blank.any?
          repos = repos.where(kind: kind) if kind.present?

          scope = ::System::Package.live.where(package_repository_id: repos.pluck(:id))
          scope = scope.where(architecture: expanded_architectures(architectures)) if Array(architectures).compact_blank.any?
          scope = scope.where(license: license) if license.present?
          scope
        end

        def expanded_architectures(canonical_inputs)
          names = []
          Array(canonical_inputs).compact_blank.each do |canonical|
            arch = ::System::NodeArchitecture.find_normalized(canonical)
            if arch
              names.concat([arch.name, arch.apt_name, arch.rpm_name])
            else
              names << canonical
            end
          end
          names.compact.uniq
        end

        # === Embedding ====================================================

        def generate_embedding(text)
          ::Ai::Memory::EmbeddingService.new(account: @account).generate(text)
        rescue StandardError => e
          Rails.logger.warn("[DiscoverPackagesByIntent] embedding failed: #{e.class}: #{e.message}")
          nil
        end

        # === Result assembly ==============================================

        def build_match(pkg, intent)
          distance   = pkg.neighbor_distance.to_f
          similarity = (1.0 - distance).round(4)
          {
            package_id:    pkg.id,
            name:          pkg.name,
            version:       pkg.version,
            architecture:  pkg.architecture,
            summary:       pkg.summary,
            similarity:    similarity,
            repository_id: pkg.package_repository_id,
            reason:        build_reason(pkg, intent, similarity)
          }
        end

        def build_reason(pkg, intent, similarity)
          caps = Array(pkg.provides_capabilities).first(3).join(", ")
          base = "Semantic match for '#{intent}' (similarity #{similarity})"
          caps.empty? ? base : "#{base} — provides #{caps}"
        end

        def confidence_for(ranked)
          return "low" if ranked.empty?

          top = ranked.first
          distance = top.neighbor_distance.to_f
          return "high"   if distance < CONFIDENCE_HIGH_BELOW
          return "medium" if distance < CONFIDENCE_MEDIUM_BELOW

          "low"
        end
      end
    end
  end
end
