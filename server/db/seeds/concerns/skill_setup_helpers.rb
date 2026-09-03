# frozen_string_literal: true

# Shared helpers for the system extension's Ai::Skill catalog seeds
# (system_skills_seed.rb, system_provisioning_skills_seed.rb,
# system_dr_skills_seed.rb).
#
# CANONICAL RULE (HIER-P2G, operator ruling 2026-09-03): "all official agents
# are canonical and seeded" extends to the skills they bind. The system agents
# are GLOBAL seeded canonicals (AgentSetupHelpers.find_or_initialize_global_agent),
# and a global agent cannot be made whole by ACCOUNT-scoped skill rows — the
# canonical Claude Code export (Ai::ClaudeExport::AgentSkeletonSync, canonical
# scope) and the router read GLOBAL skills only. So every catalog skill is a
# GLOBAL row: account_id nil, source_key = slug, is_system, upserted by slug —
# exactly how core seeds its baseline skills (db/seeds/ai_skills_seed.rb via
# GloballyScopable.find_or_initialize_global).
#
# Usage from a seed file:
#
#   require_relative "concerns/skill_setup_helpers"
#   skill = System::Seeds::SkillSetupHelpers.find_or_initialize_global_skill(slug: data[:slug])
#   skill.assign_attributes(...)   # never `account:`
#   skill.save!
module System
  module Seeds
    module SkillSetupHelpers
      module_function

      # Find-or-initialize the GLOBAL canonical Ai::Skill for a catalog slug.
      #
      # Same contract as core's GloballyScopable.find_or_initialize_global
      # (which db/seeds/ai_skills_seed.rb uses): the global row by slug if one
      # exists; else a pre-P2G ACCOUNT-scoped row of the same slug, CONVERTED
      # IN PLACE (account_id -> nil, id stable, so every Ai::AgentSkill and
      # knowledge-graph edge keeps pointing at it — the pattern HIER-P1 used for
      # the agents); else a new row. With one refinement the core helper lacks:
      # an account's own OVERRIDE (cloned_from_id set — GloballyScopable
      # documents that an override may reuse the global slug) is never the
      # conversion candidate. A clone is the account's customisation, not the
      # platform default, so when only clones carry the slug a fresh global is
      # minted beside them and the clones are left exactly as they are.
      #
      # The caller assigns the content attributes and saves.
      #
      # @param slug [String] the catalog slug (doubles as the source_key)
      # @return [Ai::Skill] global (possibly unsaved) row
      def find_or_initialize_global_skill(slug:)
        skill = ::Ai::Skill.global.find_by(slug: slug) ||
                ::Ai::Skill.account_scoped.where(slug: slug, cloned_from_id: nil).order(:created_at, :id).first ||
                ::Ai::Skill.new(slug: slug)
        skill.account_id = nil
        skill.source_key = slug
        skill.is_system  = true
        skill
      end

      # The Ai::InterventionPolicy action category the skill's executor gates
      # on (BaseSkillExecutor.action_category — declared, else derived), stashed
      # in the skill's metadata so the canonical Claude Code export can derive
      # the agent's policy DOMAINS (Ai::ClaudeExport::PolicyDomains, registered
      # by this extension at boot) from GLOBAL rows alone: policy rows are
      # account data and never reach a committed skeleton.
      #
      # @return [String, nil] nil when the class is not loaded or has no category
      def executor_action_category(executor_class_name)
        klass = executor_class_name.to_s.safe_constantize
        return nil unless klass.respond_to?(:action_category)

        klass.action_category.presence
      end
    end
  end
end
