# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# "System Operations" canonical team (HIER-P4, operator rulings 2026-09-03):
# System Concierge manages the eleven domain agents that RUN the fleet — the
# same agents system_agent_hierarchy.rb hangs under it, each with its lineage
# edge and delegation row already written by System::Governance::HierarchyReconciler.
# ONE STRUCTURE, THREE VIEWS: the template (nodes + roles), the lineage forest
# and the delegation graph describe one organisation, and the core
# Ai::Teams::CanonicalTeamReconciler reports where they disagree (`drift`) and
# repairs membership (`reconcile!` — also on `rails system:governance:reconcile`
# and `system:governance:drift`, see lib/tasks/governance_reconcile.rake).
#
# ROLES. The Concierge is the manager. The agents that run a remediation loop
# or apply changes themselves — Fleet Autonomy (the tick), CVE Responder,
# GitOps Reconciler, Runtime Manager — are `executor`s; the SDWAN Manager, the
# Disk Image Manager, the System Topology Designer and the four operations
# managers (Capacity / Storage / Ingress / Supply Chain) are `specialist`s.
# Roles come from Ai::AgentTeamMember::ROLES.
#
# WHO SITS IN THE TEAM: the account's executing principals for the canonicals
# (the clones Ai::Agents::AccountPrincipalResolver mints), never the canonicals
# (§5 ruling 8). The template is the canonical; the team is the account's
# materialisation, read-only through the MCP verbs.
#
# WRITES the template (through the core seam Ai::Teams::CanonicalTeamSeeder,
# shared with db/seeds/ai_canonical_teams_seed.rb's "Platform Engineering")
# and the admin account's team, members and backing Ai::TeamRoles. CREATES no
# lineage edge, no delegation row and no policy row (ruling 7 — the reconcilers
# above keep those); the principal seam it mints seats through may RE-HOME an
# existing intervention-policy row onto the account's clone
# (Ai::Agents::AccountPrincipalResolver#rehome_intervention_policies!), which
# moves an already-declared row rather than declaring one.
# Runs AFTER system_agent_hierarchy.rb in SYSTEM_SEED_FILES
# so every edge it verifies against exists; idempotent.
#
# The member slugs are the canonicals' `slug`s (the Topology Designer's slug
# is "system-topology-designer" while its source_key is "topology-designer";
# the reconciler resolves slug first, then source_key).

puts "\n  Seeding the System Operations canonical team (System Concierge manages the domain agents)..."

SYSTEM_OPERATIONS_TEAM = {
  slug: "system-operations",
  name: "System Operations",
  category: "operations",
  tags: %w[canonical operations hierarchical fleet],
  description: "Runs the fleet: the domain agents that sense, remediate, design and manage capacity, storage, " \
               "ingress, supply chain, SDWAN, images, runtimes and GitOps — managed by System Concierge under " \
               "the delegation policies the hierarchy reconciler writes.",
  members: [
    { slug: "system-concierge",         name: "System Concierge",         role: "manager",    lead: true,
      description: "Routes and coordinates; decomposes the objective and synthesises the result" },
    { slug: "fleet-autonomy",           name: "Fleet Autonomy",           role: "executor",
      description: "Runs the sensor tick and applies the remediations its policy rows admit" },
    { slug: "sdwan-manager",            name: "SDWAN Manager",            role: "specialist",
      description: "Overlay networks, peers, routing, federation" },
    { slug: "cve-responder",            name: "CVE Responder",            role: "executor",
      description: "Triage and remediation of vulnerability exposure" },
    { slug: "disk-image-manager",       name: "Disk Image Manager",       role: "specialist",
      description: "Disk-image publication, retention and revert" },
    { slug: "runtime-manager",          name: "Runtime Manager",          role: "executor",
      description: "Container and inference runtimes on managed hosts" },
    { slug: "gitops-reconciler",        name: "GitOps Reconciler",        role: "executor",
      description: "Repository sync, drift reports and proposal application" },
    { slug: "system-topology-designer", name: "System Topology Designer", role: "specialist",
      description: "Architecture catalog, topology composition and multi-tenant isolation designs" },
    { slug: "capacity-manager",         name: "Capacity Manager",         role: "specialist",
      description: "Instance pools, provisioning, replacement and project adaptation" },
    { slug: "storage-manager",          name: "Storage Manager",          role: "specialist",
      description: "Volumes, snapshots and storage migrations" },
    { slug: "ingress-manager",          name: "Ingress Manager",          role: "specialist",
      description: "Service exposure, certificates and the reverse proxy" },
    { slug: "supply-chain-manager",     name: "Supply Chain Manager",     role: "specialist",
      description: "Packages, module builds, publication integrity and promotion" }
  ]
}.freeze

system_operations_template = Ai::Teams::CanonicalTeamSeeder.seed!(**SYSTEM_OPERATIONS_TEAM)
puts "  ✅ Template #{system_operations_template.slug} (global, #{system_operations_template.member_definitions.size} seats)"

system_operations_account = System::Seeds::AgentSetupHelpers.admin_account
if system_operations_account.nil?
  puts "  ⚠️  No account exists to materialise the team in — template seeded only (re-run after setup)"
else
  result = Ai::Teams::CanonicalTeamReconciler.new(account: system_operations_account,
                                                   template: system_operations_template).reconcile!
  if result.team
    puts "  ✅ #{result.team.name} #{result.created ? 'materialised' : 'present'} in #{system_operations_account.name}: " \
         "+#{result.members_added} -#{result.members_removed} ~#{result.members_updated} member(s), " \
         "#{result.team.members.count} seated"
  end
  puts "  ⚠️  Skipped (seat not filled — drift until seeded): #{result.skipped.join(', ')}" if result.skipped.any?
end
