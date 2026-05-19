# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Assemble a Template *draft* from a natural-language workload description.
      # v0 uses keyword overlap between the description and module name;
      # M-FE-1 (Visual Template Composer) layers a richer ranking over this
      # same skill.
      #
      # Output is a *draft* — never a persisted Template. The Concierge or
      # an operator confirms via system_create_template + system_assign_module_to_template
      # against the returned module list.
      #
      # Reference: Golden Eclipse plan M6 — Skills catalog (module_compose row).
      class ModuleComposeExecutor < BaseSkillExecutor
        DEFAULT_MAX_MODULES = 10
        # Minimum keyword overlap to include a module. Ratio is matched
        # tokens / total description tokens. 0.05 = 1 match per 20 description
        # tokens, which is generous on purpose so v0 catches anything plausible
        # for the operator to review.
        INCLUDE_THRESHOLD = 0.05

        # Common English stopwords stripped before token matching. Not language-
        # aware — fine for v0 since module catalogs are predominantly English.
        STOPWORDS = %w[
          a an the and or but if then in on for to of with at from by as is are
          be been being do does did done have has had this that these those it
          its we us our you your i me my they them their which who whose what
          want need spin run setup install deploy host server use using
        ].freeze

        skill_descriptor(
          name: "module_compose",
          description: "Compose a Template draft from a workload description — keyword-matches modules and proposes a composition with conflict checks",
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
            candidate_count: :integer,
            reasoning: :string
          }
        )

        binds_to "Fleet Autonomy"

        protected

        def perform(description:, platform_id: nil, max_modules: DEFAULT_MAX_MODULES)
          tokens = tokenize(description)
          return failure("description must contain at least one non-stopword token") if tokens.empty?

          modules_resp = tool(::Ai::Tools::SystemFleetTool).execute(params: { action: "system_list_modules" })
          return failure("module listing failed: #{modules_resp[:error]}") unless modules_resp[:success]

          candidates = filter_for_platform(modules_resp[:data][:modules], platform_id)
          ranked = rank_candidates(candidates, tokens)
          chosen = ranked.first(max_modules.to_i)

          conflicts = detect_conflicts(chosen)

          success(
            draft_template: build_draft_template(description, chosen),
            conflicts: conflicts,
            candidate_count: candidates.size,
            reasoning: build_reasoning(tokens, ranked, chosen),
            requires_approval: false,
            note: "draft only — operator/concierge must confirm via system_create_template + system_assign_module_to_template"
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

        def rank_candidates(modules, tokens)
          token_count = tokens.size.to_f
          Array(modules).filter_map do |m|
            haystack = "#{m[:name]} #{m[:gitea_repo_full_name]}".downcase
            matched = tokens.uniq.select { |t| haystack.include?(t) }
            next if matched.empty?

            score = matched.size / [ token_count, 1 ].max
            next if score < INCLUDE_THRESHOLD

            { module: m, matched_tokens: matched, score: score.round(3) }
          end.sort_by { |r| -r[:score] }
        end

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

        def build_reasoning(tokens, ranked, chosen)
          if chosen.empty?
            "No modules matched the description tokens (#{tokens.first(8).join(', ')}). " \
            "Consider authoring a new module or broadening the description."
          else
            "Matched #{ranked.size} candidate modules; selected top #{chosen.size}. " \
            "Top match: #{chosen.first[:module][:name]} (score=#{chosen.first[:score]})."
          end
        end
      end
    end
  end
end
