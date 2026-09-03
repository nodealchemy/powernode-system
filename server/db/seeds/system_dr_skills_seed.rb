# frozen_string_literal: true

# Disaster-recovery skill rows — the third `Ai::Skill` seed in this extension,
# after `system_skills_seed.rb` (the general catalog) and
# `system_provisioning_skills_seed.rb` (the six provisioning-owned slugs).
#
# WHY A THIRD FILE. Every executor that declares `binds_to` must have a matching
# `Ai::Skill` row or `System::Ai::Skills::SkillBindings.validate!` raises —
# UNRESCUED, in `system_skill_bindings_seed.rb` — which leaves the whole fleet
# with ZERO `Ai::AgentSkill` rows, not just the one skill missing. This file
# exists so a DR skill can be added without a same-line edit to the general
# catalog, which several concurrent lanes touch at once.
#
# It upserts by slug exactly the way the other two do, and it MUST run before
# `system_skill_bindings_seed.rb` — see SYSTEM_SEED_FILES in
# `extensions/system/server/db/seeds.rb`, which is the only place seed ORDER is
# declared (an unlisted extension seed never runs at all).
#
# Consolidation note: folding these rows back into `system_skills_seed.rb` is a
# clean follow-up once the concurrent edits to that file have landed. Both files
# upsert by slug, so the ROW is safe either way — the only rule is that a slug
# must live in exactly ONE of them, or the later file silently clobbers the
# earlier one and the losing copy rots.
#
# Run standalone with:
#   cd server && rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/system_dr_skills_seed.rb')"

# GLOBAL CANONICALS (HIER-P2G): every row is account_id nil, source_key =
# slug, is_system — see concerns/skill_setup_helpers.rb; no account is needed.
require_relative "concerns/skill_setup_helpers"

begin
  DR_SKILLS_DATA = [
    {
      name: "Promote Replica",
      slug: "system-promote-replica",
      description: "Promote a postgres streaming replica to primary after the primary is provider-confirmed down — cut the DB VIP over to the replica's SDWAN peer and fence the old primary",
      category: "sre_observability",
      subdomain: "fleet",
      executor: "System::Ai::Skills::PromoteReplicaExecutor",
      tags: %w[fleet disaster-recovery postgres replication failover],
      system_prompt: <<~PROMPT.strip
        Promote the postgres streaming replica of a cluster_member spawn (the one
        ClusterMemberPgReplicaSetupJob prepared) after its parent primary is lost.
        Inputs: peer_id (required — the System::FederationPeer carrying the cluster_pg
        replication record), primary_instance_id (required — the LOST primary),
        replica_instance_id (required — the replica to promote), operation_id
        (required — the idempotency key; a re-drive replays instead of promoting
        twice), virtual_ip_id (default: every VIP the old primary's peers hold),
        reason, accept_data_loss (default false), dry_run.
        The DB VIP is the cutover point: the promote re-points its holder set at the
        replica's SDWAN peer and takes the old primary off both the holder and the
        failover lists, then dispatches the promote command postgres-replica's
        manifest declares (services[].metadata.promote_command).
        TWO SAFETY CONDITIONS. The primary must be PROVIDER-CONFIRMED DOWN — not
        waivable by anything, because promoting around a live primary is a split
        brain. The replication lag at the LAST SAMPLE must be under the configured
        bound (SiteSetting system.promote_replica.max_lag_bytes); a missing or stale
        sample is a refusal, waivable only by passing accept_data_loss: true.
        APPROVAL-GATED on system.replica_promote. The old primary is FENCED and is
        never restarted as primary — re-basing it as a replica of the promoted node
        is a separate, operator-initiated act.
      PROMPT
    }
  ].freeze

  created_count = 0
  updated_count = 0

  DR_SKILLS_DATA.each do |data|
    skill = System::Seeds::SkillSetupHelpers.find_or_initialize_global_skill(slug: data[:slug])
    was_new = skill.new_record?
    skill.assign_attributes(
      name: data[:name],
      description: data[:description],
      category: data[:category],
      status: "active",
      system_prompt: data[:system_prompt],
      commands: [],
      activation_rules: {},
      metadata: {
        "author" => "system_extension",
        "icon" => data[:subdomain],
        "system_subdomain" => data[:subdomain],
        "executor_class" => data[:executor],
        # The executor's gate category — what the canonical Claude Code export
        # turns into the agent's policy DOMAIN triggers (HIER-P2G).
        "action_category" => System::Seeds::SkillSetupHelpers.executor_action_category(data[:executor]),
        "domain" => "system",
        "invocation_mode" => data[:invocation_mode] || "one_shot"
      }.compact,
      tags: data[:tags] + %w[system workspace],
      is_system: true,
      is_enabled: true,
      version: "1.0.0"
    )
    skill.save!
    was_new ? created_count += 1 : updated_count += 1
  end

  puts "    ✓ DR skills: #{created_count} created, #{updated_count} updated (#{DR_SKILLS_DATA.size} total)"
end
