# frozen_string_literal: true

# Knowledge-graph sync for the system extension's catalog skills (HIER-P2G).
#
# The three catalog seeds (system_skills_seed, system_provisioning_skills_seed,
# system_dr_skills_seed — all loaded before this one by db/seeds.rb) write GLOBAL
# Ai::Skill rows, and a global row never
# fires the per-account KG sync hook — Ai::Skill#sync_to_knowledge_graph returns
# early on `account_id.nil?` because a knowledge-graph node requires an account,
# so every account carries its own copy instead (IMP-059e6c5af2bf). Core
# compensates for its own global skills at the tail of db/seeds/ai_skills_seed.rb,
# but that runs BEFORE the extension seeds (server/db/seeds.rb loads the extension
# orchestrators last), so it cannot cover these rows.
#
# Without this pass every system skill is invisible to `platform.discover_skills`
# and Ai::ConciergeRouter#discover_relevant_skills — both read skill NODES
# (Ai::SkillGraph::TraversalService over account.ai_knowledge_graph_nodes), not
# the ai_skills table. The bridge is idempotent (update-or-create per account)
# and degrades gracefully without an embedding service.
begin
  synced_accounts = 0
  Account.find_each do |acct|
    results = Ai::SkillGraph::BridgeService.new(acct).sync_all_skills
    synced_accounts += 1
    Rails.logger.info("[system extension seeds] KG skill sync for account #{acct.id}: #{results.inspect}")
  rescue StandardError => e
    Rails.logger.warn("[system extension seeds] KG skill sync failed for account #{acct.id}: #{e.class}: #{e.message}")
    puts "  ⚠️  KG skill sync failed for account #{acct.id}: #{e.message}"
  end
  puts "  ✅ Knowledge-graph skill sync: #{synced_accounts} account(s)"
rescue StandardError => e
  Rails.logger.error("[system extension seeds] KG skill sync pass failed: #{e.class}: #{e.message}")
  puts "  ❌ KG skill sync pass failed: #{e.message}"
end
