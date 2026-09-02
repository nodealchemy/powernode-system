# frozen_string_literal: true

require "rails_helper"

# IMP-e037c96e807e / IMP-fa63f411633b — `System::AutonomyActions::DOMAIN_PREFIXES`
# and the `by_domain` pivot it drives (GET /api/v1/system/autonomy).
#
# INPUT SET: the registry, not the seeds. The pivot buckets whatever policy
# rows the account carries, and the PATCH half of the same concern
# (System::AutonomyActions#update) admits any category passing
# `Ai::InterventionPolicy.category_registered?` — so the population an
# operator can put in front of the pivot is exactly
# `Ai::InterventionPolicy.registered_categories`, not the subset the agent
# seeds happen to create rows for today. Pinning a narrower set is how the
# same scope error shipped twice: first "sensor bindings" was widened to
# "seeded" (IMP-e037c96e807e), and then two registered-but-deliberately-
# unseeded composer categories (`system.multi_tenant_isolation`,
# `system.service_discovery_compose`) still stranded in "other" the moment an
# operator saved a policy row for them through the endpoint — a path no seed
# file exercises (IMP-fa63f411633b).
#
# ORACLE SUBSET: only the EXTENSION-OWNED namespaces (`system.`, `sdwan.`)
# must resolve to a named domain. Core's own registrations
# (`Ai::InterventionPolicy::STATIC_CATEGORIES`: approval, dev.*, "*", ...)
# land in "other" DELIBERATELY — the concern's header says so and the System
# modal skips that bucket — and `project.*` is core-owned but claimed by the
# "project" domain on purpose (ruling recorded at DOMAIN_PREFIXES). Same
# namespace-selection assumption as
# spec/lib/powernode_system/autonomy_categories_registration_spec.rb: the
# registry is process-global, so the selection sees every engine's
# system./sdwan. names, which today is exactly this extension.
#
# Resolution is `DOMAIN_PREFIXES.find { ... }&.first`, i.e. FIRST match wins, so
# the map is order-sensitive in a way nothing else in the file signals. Three
# declared prefixes are extensions of another entry's prefix:
#
#   system.instance_pool_            ⊂ system.instance_  (node_lifecycle)
#   system.module_critical_upgrade_  ⊂ system.module_    (node_lifecycle)
#   system.sdwan_federation_compose  ⊂ system.sdwan_     (topology)
#
# Before the fix, `system.instance_` shadowed the whole `instance_pool` domain —
# a declared bucket that could never receive a row — and the CVE Responder's
# `system.module_critical_upgrade_ready` was filed under node_lifecycle.
#
# These examples deliberately exercise the REAL endpoint rather than replaying
# the resolution expression against the constant: a spec that re-implements the
# `find` is green against any map, including one whose ordering the production
# pivot reads differently.
RSpec.describe "Api::V1::System::Autonomy by_domain pivot", type: :request do
  let(:account) { create(:account) }
  let(:read_user) { user_with_permissions("system.infra_tasks.read", account: account) }

  # The full set the PATCH endpoint admits — every row an operator can create.
  let(:registered_categories) { Ai::InterventionPolicy.registered_categories }

  # The subset that must resolve to a named domain: the namespaces this
  # extension owns. Everything else registered (core statics, any sibling
  # extension's namespaces) is "other"-or-"project" by design.
  let(:extension_categories) do
    registered_categories.select { |c| c.start_with?("system.", "sdwan.") }
  end

  # One row per registered category, so the pivot sees the worst-case
  # population #update can produce, not just the one the agent seeds ship.
  def seed_policy_rows!
    registered_categories.each do |cat|
      Ai::InterventionPolicy.create!(
        account: account, action_category: cat, scope: "global",
        policy: "require_approval", priority: 5, is_active: true
      )
    end
  end

  def by_domain
    get "/api/v1/system/autonomy", headers: auth_headers_for(read_user)
    expect(response).to have_http_status(:ok)
    json_response_data.dig("policies", "by_domain")
  end

  def categories_in(pivot, domain)
    Array(pivot[domain]).map { |p| p["action_category"] }
  end

  it "files every extension-registered action_category into a named domain (none fall through to \"other\")" do
    seed_policy_rows!

    stranded = categories_in(by_domain, "other")
               .select { |c| c.start_with?("system.", "sdwan.") }
               .sort

    expect(stranded).to be_empty,
                        "#{stranded.size} registered category(ies) have no DOMAIN_PREFIXES entry, so the " \
                        "Autonomy payload's by_domain view dumps them into the catch-all bucket the moment " \
                        "an operator saves a policy row for them via PATCH: #{stranded.join(', ')}"
  end

  # The ordering guard. A map that adds every missing prefix but leaves a
  # specific prefix declared AFTER the broader one it extends still passes the
  # example above (nothing reaches "other") while the shadowed domain stays
  # permanently empty. `instance_pool` was in exactly that state.
  it "leaves no declared domain unreachable — every DOMAIN_PREFIXES key receives a registered category" do
    seed_policy_rows!
    pivot = by_domain

    unreachable = System::AutonomyActions::DOMAIN_PREFIXES.keys
                                                          .reject { |d| categories_in(pivot, d).any? }

    expect(unreachable).to be_empty,
                           "#{unreachable.size} declared domain(s) received no registered category. A domain " \
                           "whose prefixes are all shadowed by an earlier, broader entry can never be " \
                           "reached (first match wins): #{unreachable.join(', ')}"
  end

  # Pins the two shadowed families to their intended bucket by name, so a
  # reorder that fixes reachability but sends them somewhere new still reds.
  it "files each shadowed category under the specific domain, not the broader one" do
    seed_policy_rows!
    pivot = by_domain

    pool = %w[
      system.instance_pool_acquire system.instance_pool_archive
      system.instance_pool_ceiling_raise system.instance_pool_create
      system.instance_pool_delete system.instance_pool_drain
      system.instance_pool_replenish system.instance_pool_update
    ]

    expect(categories_in(pivot, "instance_pool")).to match_array(pool)
    expect(categories_in(pivot, "node_lifecycle")).not_to include(*pool)

    # Seeded on the CVE Responder (db/seeds/system_cve_responder_agent.rb), and
    # NOT prefixed `system.cve_` — so ordering "cve" ahead of "node_lifecycle"
    # is not sufficient on its own; the specific prefix has to be declared.
    expect(categories_in(pivot, "cve")).to include("system.module_critical_upgrade_ready")
    expect(categories_in(pivot, "node_lifecycle")).not_to include("system.module_critical_upgrade_ready")

    # Positive twin: the broader prefixes still claim their own members, so the
    # fix narrows the shadowing entry rather than removing it.
    expect(categories_in(pivot, "node_lifecycle"))
      .to include("system.instance_reboot", "system.module_assign")
  end

  # The System Topology Designer's composer trio. All three are registered but
  # deliberately unseeded (engine.rb: operator/Concierge-driven composer
  # skills), so their rows only ever arrive through #update — and by name they
  # split: one happens to start with `system.sdwan_`, two match nothing. Kept
  # together in one domain so no member is ever covered by string accident
  # again; the by-name pin is the reorder guard for the third shadowed pair
  # (`system.sdwan_federation_compose` ⊂ `system.sdwan_` — "topology" must be
  # declared before "sdwan").
  it "files the Topology Designer composer trio together under topology, ahead of sdwan's broader prefix" do
    seed_policy_rows!
    pivot = by_domain

    trio = %w[
      system.multi_tenant_isolation
      system.sdwan_federation_compose
      system.service_discovery_compose
    ]

    expect(categories_in(pivot, "topology")).to match_array(trio)
    expect(categories_in(pivot, "sdwan")).not_to include("system.sdwan_federation_compose")
    expect(categories_in(pivot, "other")).not_to include(*trio)
  end

  # The account-wide-view ruling (recorded at DOMAIN_PREFIXES): core-owned rows
  # stay VISIBLE — statics in the "other" catch-all, `project.*` under the
  # deliberately-claimed "project" domain. Guards against "fixing" the oracle
  # above by filtering core categories out of the pivot, which would hide real
  # policy rows from an operator — the same defect class as the by_agent pivot
  # silently dropping agents' rows.
  it "keeps core-owned rows visible: statics land in \"other\" and project.* under \"project\"" do
    seed_policy_rows!
    pivot = by_domain

    expect(categories_in(pivot, "other")).to include("approval", "dev.pull_task")
    expect(categories_in(pivot, "project")).to include("project.adapt", "project.cost_control")
  end

  # Non-regression guard — no mutant of the fix reds this one. It fails only if
  # the examples above lose their input and start passing vacuously: an
  # extension engine that never registered (leaving a core-only registry), or a
  # payload that stopped carrying the rows at all, would make "nothing reached
  # other" trivially true.
  it "has real inputs and a populated pivot (guards the examples above from passing vacuously)" do
    expect(extension_categories.size).to be > 50
    expect(extension_categories).to include(
      "system.instance_pool_create", "system.module_critical_upgrade_ready",
      "system.multi_tenant_isolation", "system.service_discovery_compose"
    )

    seed_policy_rows!
    pivot = by_domain

    expect(pivot).to be_a(Hash)
    expect(pivot.values.sum { |v| Array(v).size }).to eq(registered_categories.size)
  end
end
