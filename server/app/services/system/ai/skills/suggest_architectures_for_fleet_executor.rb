# frozen_string_literal: true

module System
  module Ai
    module Skills
      # T2.B — Suggest a set of architectures for materializing a package
      # from a given PackageRepository, based on the fleet's existing
      # NodePlatform coverage.
      #
      # The CreateModuleFromPackageModal calls this on open to pre-
      # populate the architectures multi-select with sensible defaults.
      # AI agents can also invoke it directly to ground their
      # materialization decisions in the operator's actual fleet shape.
      #
      # Heuristic (v0):
      #   1. Take the intersection of (repo.architectures, catalog rows
      #      with node_platform_count > 0) — these are arches the repo
      #      can build for AND the fleet is already configured for.
      #   2. Rank by NodeArchitecture.node_platform_count descending.
      #   3. Top N (default 4); if none qualify, fall back to repo's
      #      first 2 arches with a `fallback: true` flag + low confidence.
      #
      # The output's `rationale` array gives the agent / UI a per-arch
      # justification ("Top fleet arch with 12 platforms") so the
      # suggestion is auditable.
      class SuggestArchitecturesForFleetExecutor < BaseSkillExecutor
        DEFAULT_MAX_SUGGESTIONS = 4

        skill_descriptor(
          name: "suggest_architectures_for_fleet",
          description: "Suggest which canonical architectures to materialize a package for, based on the current fleet's NodePlatform coverage and the repository's served architectures.",
          category: "devops",
          inputs: {
            repository_id:    { type: "string",  required: true,
                                description: "PackageRepository.id whose architectures bound the suggestion set" },
            max_suggestions:  { type: "integer", required: false,
                                default: DEFAULT_MAX_SUGGESTIONS,
                                description: "Cap on the number of suggested arches (1-7)" }
          },
          outputs: {
            repository_id: :string,
            suggested:     :array,    # Array<String> of canonical names
            rationale:     :array,    # Array<Hash> per-arch reasoning
            fallback:      :boolean,  # true ⇔ no fleet overlap; suggesting repo defaults
            confidence:    :string    # "high" | "medium" | "low"
          }
        )

        binds_to "Fleet Autonomy", "System Concierge"

        protected

        def perform(repository_id:, max_suggestions: DEFAULT_MAX_SUGGESTIONS)
          max_n = max_suggestions.to_i.clamp(1, 7)

          repo = scoped_repos.find_by(id: repository_id)
          return failure("repository not found or not accessible") unless repo

          repo_arches = Array(repo.architectures).uniq
          return success(empty_result(repo, fallback: true, confidence: "low")) if repo_arches.empty?

          # Resolve each repo-arch name to a NodeArchitecture row + score.
          scored = repo_arches.filter_map do |name|
            arch = ::System::NodeArchitecture.find_normalized(name)
            next nil unless arch

            {
              arch:           arch,
              canonical_name: arch.name,
              node_platforms: arch.node_platform_count,
              packages:       arch.package_count,
              # Score: weight node_platforms heavily (fleet shape is the
              # primary signal), packages as a tiebreaker.
              score:          arch.node_platform_count * 10 + Math.log10(arch.package_count.to_i + 1)
            }
          end

          # Partition: covered (>0 platforms) vs uncovered (=0).
          covered, uncovered = scored.partition { |s| s[:node_platforms].positive? }

          if covered.any?
            ranked = covered.sort_by { |s| -s[:score] }.first(max_n)
            success(build_result(repo, ranked, fallback: false))
          else
            # No fleet overlap — suggest the repo's first 2 canonical
            # arches as a fallback so the operator has something to
            # uncheck rather than facing an empty selection.
            ranked = scored.first(2)
            success(build_result(repo, ranked, fallback: true))
          end
        end

        private

        def scoped_repos
          ::System::PackageRepository.accessible_to(@account)
        end

        def build_result(repo, ranked, fallback:)
          rationale = ranked.each_with_index.map do |s, i|
            reason =
              if fallback
                "No fleet platforms yet for this arch — defaulting to repo-supported arches"
              elsif i.zero?
                "Top fleet arch with #{s[:node_platforms]} NodePlatform#{'s' unless s[:node_platforms] == 1}"
              elsif ranked.first[:score] - s[:score] < 1
                "Co-leading fleet arch with #{s[:node_platforms]} NodePlatform#{'s' unless s[:node_platforms] == 1}"
              else
                "Secondary fleet arch with #{s[:node_platforms]} NodePlatform#{'s' unless s[:node_platforms] == 1}"
              end
            {
              arch:           s[:canonical_name],
              node_platforms: s[:node_platforms],
              packages:       s[:packages],
              reason:         reason
            }
          end

          {
            repository_id: repo.id,
            suggested:     ranked.map { |s| s[:canonical_name] },
            rationale:     rationale,
            fallback:      fallback,
            confidence:    confidence_for(ranked, fallback: fallback)
          }
        end

        def confidence_for(ranked, fallback:)
          return "low" if fallback || ranked.empty?
          return "low" if ranked.first[:node_platforms].zero?

          top = ranked.first[:score]
          second = ranked[1]&.fetch(:score) || 0
          # ≥ 2x ratio between top and runner-up → clear winner.
          # Multiple ties at the top → medium (operator should review).
          if second.zero? || top >= second * 2
            "high"
          else
            "medium"
          end
        end

        def empty_result(repo, fallback:, confidence:)
          {
            repository_id: repo.id,
            suggested:     [],
            rationale:     [{ reason: "Repository has no architectures configured" }],
            fallback:      fallback,
            confidence:    confidence
          }
        end
      end
    end
  end
end
