# frozen_string_literal: true

require "rails_helper"

# IMP-e037c96e807e — `System::AutonomyActions::DOMAIN_PREFIXES` and the
# `by_domain` pivot it drives (GET /api/v1/system/autonomy).
#
# The pivot buckets policy ROWS by their own `action_category` string, so the
# set it must cover is "every category the extension's agent seeds create a row
# for" — NOT the sensor bindings, and not the fourteen categories that happened
# to be unregistered in IMP-097a267b50b7. Deriving the input set from the seed
# files is what shows the real size of the defect: 23 of 119 seeded categories
# fell through to "other", and 7 were mis-filed, against the 11 + 1 the finding
# quantified from the smaller set.
#
# Resolution is `DOMAIN_PREFIXES.find { ... }&.first`, i.e. FIRST match wins, so
# the map is order-sensitive in a way nothing else in the file signals. Two
# declared prefixes are extensions of another entry's prefix:
#
#   system.instance_pool_            ⊂ system.instance_  (node_lifecycle)
#   system.module_critical_upgrade_  ⊂ system.module_    (node_lifecycle)
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

  # Same derivation as spec/lib/powernode_system/autonomy_categories_registration_spec.rb:
  # a seed entry is a `"category" => "policy"` pair, anchored on the real
  # POLICIES constant so it cannot match unrelated string-to-string hashes.
  let(:seed_entry_pattern) do
    /"([a-z][a-z0-9_.]*)"\s*=>\s*"(?:#{Ai::InterventionPolicy::POLICIES.join('|')})"/
  end

  let(:seed_dir) { File.expand_path("../../../../../db/seeds", __dir__) }

  let(:seeded_categories) do
    Dir[File.join(seed_dir, "*.rb")].sort
      .flat_map { |f| File.read(f).scan(seed_entry_pattern).flatten }
      .uniq
      .sort
  end

  # One row per seeded category, so the pivot sees exactly the population an
  # operator's account carries after the agent seeds have run.
  def seed_policy_rows!
    seeded_categories.each do |cat|
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

  it "files every seeded action_category into a named domain (none fall through to \"other\")" do
    seed_policy_rows!

    stranded = categories_in(by_domain, "other").sort

    expect(stranded).to be_empty,
                        "#{stranded.size} seeded category(ies) have no DOMAIN_PREFIXES entry, so the " \
                        "Autonomy payload's by_domain view dumps them into the catch-all bucket: " \
                        "#{stranded.join(', ')}"
  end

  # The ordering guard. A map that adds every missing prefix but leaves a
  # specific prefix declared AFTER the broader one it extends still passes the
  # example above (nothing reaches "other") while the shadowed domain stays
  # permanently empty. `instance_pool` was in exactly that state.
  it "leaves no declared domain unreachable — every DOMAIN_PREFIXES key receives a seeded category" do
    seed_policy_rows!
    pivot = by_domain

    unreachable = System::AutonomyActions::DOMAIN_PREFIXES.keys
                                                          .reject { |d| categories_in(pivot, d).any? }

    expect(unreachable).to be_empty,
                           "#{unreachable.size} declared domain(s) received no seeded category. A domain " \
                           "whose prefixes are all shadowed by an earlier, broader entry can never be " \
                           "reached (first match wins): #{unreachable.join(', ')}"
  end

  # Pins the two shadowed families to their intended bucket by name, so a
  # reorder that fixes reachability but sends them somewhere new still reds.
  it "files each shadowed category under the specific domain, not the broader one" do
    seed_policy_rows!
    pivot = by_domain

    pool = %w[
      system.instance_pool_acquire system.instance_pool_create system.instance_pool_delete
      system.instance_pool_drain system.instance_pool_replenish system.instance_pool_update
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

  # Non-regression guard — no mutant of the fix reds this one. It fails only if
  # the examples above lose their input and start passing vacuously: a moved or
  # reformatted seed directory (scan matches nothing), or a payload that stopped
  # carrying the rows at all, would make "nothing reached other" trivially true.
  it "has real inputs and a populated pivot (guards the examples above from passing vacuously)" do
    expect(seeded_categories.size).to be > 50
    expect(seeded_categories).to include("system.instance_pool_create", "system.module_critical_upgrade_ready")

    seed_policy_rows!
    pivot = by_domain

    expect(pivot).to be_a(Hash)
    expect(pivot.values.sum { |v| Array(v).size }).to eq(seeded_categories.size)
  end
end
