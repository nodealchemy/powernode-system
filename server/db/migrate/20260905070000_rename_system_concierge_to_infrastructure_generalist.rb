# frozen_string_literal: true

# Renames the seeded canonical "System Concierge" to "Infrastructure
# Generalist" on an install that is already up.
#
# WHY A MIGRATION AND NOT THE SEED. db/seeds runs on FIRST BOOT ONLY
# (rails-start.sh marker), so editing system_concierge_agent.rb renames the
# agent on a fresh install and NOTHING on an established one. Worse, if the
# seed ever did re-run, AgentSetupHelpers.find_or_initialize_global_agent
# looks the row up by (name, agent_type) — not by source_key — so the new
# name would MISS the existing row and CREATE A SECOND global agent, leaving
# the original and its skill bindings in place. The seed cannot perform this
# rename; only a keyed update can.
#
# WHY THE PREDICATE IS SHAPED THIS WAY. Three conditions, each load-bearing:
#
#   account_id IS NULL — GloballyScopable#clone_to_account copies source_key
#     onto an account's clone, so matching on source_key ALONE would rename
#     every operator's customised clone too. An operator who cloned this agent
#     and named it themselves must keep their name. The guard this migration
#     needs is not "the canonical was renamed", it is "nothing else was".
#
#   source_key — the stable identity. It is set explicitly by the seed and
#     derived from nothing, which is exactly why the rename keys on it and
#     why it is NOT itself changed here. HierarchyReconciler resolves the
#     agent-forest root through this value, so leaving it alone is what keeps
#     the rename from moving the root.
#
#   name — makes the migration idempotent. A row already carrying the new
#     name matches nothing, so a second run is a no-op rather than a
#     redundant write.
#
# WHY update_all. Ai::Agent#generate_slug is a before_validation that
# re-derives the slug from the name, so a normal save would INFER the slug.
# The slug is the addressable handle — Ai::Routing::RoutableAgents.key returns
# it and that value is the Claude Code subagent_type — so it is written
# explicitly here and the callback is bypassed deliberately. Both identifiers
# move together in one statement, and the value is stated rather than left to
# a derivation whose trigger is `name_changed?`.
class RenameSystemConciergeToInfrastructureGeneralist < ActiveRecord::Migration[8.1]
  SOURCE_KEY = "system-concierge"
  OLD_NAME   = "System Concierge"
  NEW_NAME   = "Infrastructure Generalist"
  OLD_SLUG   = "system-concierge"
  NEW_SLUG   = "infrastructure-generalist"

  # Local model: a migration must not depend on an app model whose validations
  # and callbacks can drift out from under it — and here the callback is
  # precisely what must not run.
  class AgentRow < ActiveRecord::Base
    self.table_name = "ai_agents"
  end

  def up
    return unless table_exists?(:ai_agents)

    renamed = AgentRow.where(account_id: nil, source_key: SOURCE_KEY, name: OLD_NAME)
                      .update_all(name: NEW_NAME, slug: NEW_SLUG, updated_at: Time.current)

    if renamed.zero?
      say "No global canonical at source_key=#{SOURCE_KEY.inspect} named #{OLD_NAME.inspect} — nothing to rename"
    else
      say "Renamed #{renamed} global canonical to #{NEW_NAME.inspect} (slug #{NEW_SLUG.inspect})"
    end

    # Say the count out loud rather than touching them: account clones carry
    # the same source_key and are deliberately OUT of scope.
    clones = AgentRow.where(source_key: SOURCE_KEY).where.not(account_id: nil).count
    say "Left #{clones} account clone(s) at source_key=#{SOURCE_KEY.inspect} untouched" if clones.positive?
  end

  def down
    return unless table_exists?(:ai_agents)

    reverted = AgentRow.where(account_id: nil, source_key: SOURCE_KEY, name: NEW_NAME)
                       .update_all(name: OLD_NAME, slug: OLD_SLUG, updated_at: Time.current)
    say "Reverted #{reverted} global canonical to #{OLD_NAME.inspect}"
  end
end
