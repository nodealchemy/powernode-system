# frozen_string_literal: true

require "rails_helper"
require File.expand_path("../../../../db/seeds/concerns/agent_setup_helpers.rb", __dir__)

# IMP-0a3ff97f6fbb — WHO OWNS AN OPERATOR-AUTHORED POLICY ROW?
#
# Until this change the answer was "nobody", because collectability was keyed
# on a row's SHAPE and every sweep enumerated a different shape:
#
#   clean_stale_policies!            (ai_agent_id: agent.id, scope "agent")
#   clean_stale_operator_policies!   (ai_agent_id: nil,      scope "action_type")
#   system_manual_operation_policies.rb, inline
#                                    (scope "global", nils, LIKE 'system.task.%')
#
# `System::AutonomyActions#update` mints a FOURTH shape — scope "global" with a
# nil ai_agent_id outside `system.task.` — whenever the panel saves a control
# whose row identity it could not recover (useAutonomyConfig.ts `save()` falls
# back to category + verb, which the controller resolves as scope "global").
# `system_instance_pool_policies.rb` seeds that same shape for
# `system.instance_pool_*` with no sweep at all. Neither is reachable by any of
# the three, so a row for a category that is later DEREGISTERED becomes a
# ghost: rendered by the by_domain pivot, refused by every save, collected by
# nothing.
#
# The rule this spec pins replaces the shape axis with the CATEGORY's
# registration state, which is the same predicate the write path already
# enforces: a row is collectable exactly when `#update` would refuse to create
# it. That is why a fifth shape cannot open a fifth orphan class — the rule
# never names a shape.
RSpec.describe "Autonomy policy row ownership", type: :request do
  let(:account)     { create(:account) }
  let(:read_user)   { user_with_permissions("system.infra_tasks.read",    account: account) }
  let(:manage_user) { user_with_permissions("system.infra_tasks.control", account: account) }

  # A REAL deregistered category, not an invented one: `system.runtime_docker_tls_rotate`
  # was seeded as `auto_approve` until the 2026-05-19 doc-accuracy audit removed
  # the seed, IMP-6e52d6aa53da removed its registration, and IMP-75f851ce0bf0
  # (e8ac5e8c) deleted the last executor stub. It still resolves to the
  # `container_runtime` domain through DOMAIN_PREFIXES' `system.runtime_`, so it
  # renders in a section the modal actually draws rather than the "other"
  # bucket the panel skips.
  let(:ghost_category) { "system.runtime_docker_tls_rotate" }

  # The exact shape `#update` mints, and the shape `system_instance_pool_policies.rb`
  # seeds: scope "global", no agent, no user.
  def operator_authored_row!(category)
    Ai::InterventionPolicy.create!(
      account: account, action_category: category,
      scope: "global", ai_agent_id: nil, user_id: nil,
      policy: "auto_approve", priority: 5, is_active: true
    )
  end

  describe "the ghost, before any rule owns it" do
    let!(:ghost) { operator_authored_row!(ghost_category) }

    it "is not a registered category" do
      expect(Ai::InterventionPolicy.category_registered?(ghost_category)).to be false
    end

    it "RENDERS to the operator in a drawn by_domain section" do
      get "/api/v1/system/autonomy", headers: auth_headers_for(read_user)

      expect(response).to have_http_status(:ok)
      runtime = json_response_data.dig("policies", "by_domain", "container_runtime")
      expect(runtime.map { |r| r["action_category"] }).to include(ghost_category)
    end

    it "CANNOT be saved — every edit 422s on the unknown category" do
      patch "/api/v1/system/autonomy",
            params: { updates: [ { action_category: ghost_category, policy: "require_approval" } ] },
            headers: auth_headers_for(manage_user), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response.dig("details", "errors").join).to include("unknown category")
      expect(ghost.reload.policy).to eq("auto_approve")
    end

    it "SURVIVES the agent-scoped sweep" do
      agent = create(:ai_agent, account: account, agent_type: "monitor", name: "Runtime Manager")

      System::Seeds::AgentSetupHelpers.clean_stale_policies!(
        account: account, agent: agent, keep_keys: [], owned_prefixes: [ "system.runtime_" ]
      )

      expect(Ai::InterventionPolicy.exists?(ghost.id)).to be true
    end

    it "SURVIVES the operator-path sweep" do
      System::Seeds::AgentSetupHelpers.clean_stale_operator_policies!(
        account: account, keep_keys: [], owned_prefixes: [ "system.runtime_" ]
      )

      expect(Ai::InterventionPolicy.exists?(ghost.id)).to be true
    end

    it "SURVIVES the manual-operations sweep, which is pinned to system.task." do
      # The REAL seed, loaded and run, rather than a copy of its relation — a
      # copy stays green if that sweep ever widens, which is exactly the
      # question this example asks.
      allow(Account).to receive(:first).and_return(account)

      expect {
        load File.expand_path("../../../../db/seeds/system_manual_operation_policies.rb", __dir__)
      }.to output(/Manual operation policies/).to_stdout

      expect(Ai::InterventionPolicy.exists?(ghost.id)).to be true
    end
  end

  describe ".clean_unregistered_policies! — collectability derived from registration" do
    it "collects the ghost regardless of its scope shape" do
      ghost = operator_authored_row!(ghost_category)

      destroyed = System::Seeds::AgentSetupHelpers.clean_unregistered_policies!(
        account: account, owned_prefixes: [ "system." ]
      )

      expect(destroyed).to eq(1)
      expect(Ai::InterventionPolicy.exists?(ghost.id)).to be false
    end

    # THE NAMED WRONG FIX. Deleting scope-"global" agent-less rows wholesale
    # would destroy the operator's own tuning of registered categories AND the
    # 26 rows `system_manual_operation_policies.rb` / `system_instance_pool_policies.rb`
    # seed at exactly that shape.
    it "NEVER collects a row for a REGISTERED category, whatever its shape" do
      agent = create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy")

      tuned_global   = operator_authored_row!("system.instance_pool_create")
      tuned_task     = operator_authored_row!("system.task.terminate")
      tuned_operator = Ai::InterventionPolicy.create!(
        account: account, action_category: "system.runtime_docker_provision",
        scope: "action_type", ai_agent_id: nil, policy: "auto_approve", priority: 5, is_active: true
      )
      tuned_agent = Ai::InterventionPolicy.create!(
        account: account, action_category: "system.cert_rotate",
        scope: "agent", ai_agent_id: agent.id, policy: "auto_approve", priority: 10, is_active: true
      )

      destroyed = System::Seeds::AgentSetupHelpers.clean_unregistered_policies!(
        account: account, owned_prefixes: [ "system." ]
      )

      expect(destroyed).to eq(0)
      [ tuned_global, tuned_task, tuned_operator, tuned_agent ].each do |row|
        expect(Ai::InterventionPolicy.exists?(row.id)).to be true
      end
    end

    it "collects an unregistered row at EVERY shape, not just the operator one" do
      agent = create(:ai_agent, account: account, agent_type: "monitor", name: "Runtime Manager")
      user  = create(:user, account: account)

      shapes = [
        Ai::InterventionPolicy.create!(account: account, action_category: ghost_category,
                                       scope: "global", policy: "auto_approve", priority: 5),
        Ai::InterventionPolicy.create!(account: account, action_category: ghost_category,
                                       scope: "agent", ai_agent_id: agent.id,
                                       policy: "auto_approve", priority: 10),
        Ai::InterventionPolicy.create!(account: account, action_category: ghost_category,
                                       scope: "action_type", policy: "auto_approve", priority: 5),
        Ai::InterventionPolicy.create!(account: account, action_category: ghost_category,
                                       scope: "global", user_id: user.id,
                                       policy: "auto_approve", priority: 5)
      ]

      destroyed = System::Seeds::AgentSetupHelpers.clean_unregistered_policies!(
        account: account, owned_prefixes: [ "system." ]
      )

      expect(destroyed).to eq(4)
      shapes.each { |row| expect(Ai::InterventionPolicy.exists?(row.id)).to be false }
    end

    it "reaps only inside the owned namespace" do
      mine    = operator_authored_row!(ghost_category)
      foreign = operator_authored_row!("marketing.retired_action")

      System::Seeds::AgentSetupHelpers.clean_unregistered_policies!(
        account: account, owned_prefixes: [ "system." ]
      )

      expect(Ai::InterventionPolicy.exists?(mine.id)).to be false
      expect(Ai::InterventionPolicy.exists?(foreign.id)).to be true
    end

    it "honours excluded_prefixes carve-outs" do
      carved = operator_authored_row!("system.runtime_docker_tls_rotate")

      destroyed = System::Seeds::AgentSetupHelpers.clean_unregistered_policies!(
        account: account, owned_prefixes: [ "system." ],
        excluded_prefixes: [ "system.runtime_" ]
      )

      expect(destroyed).to eq(0)
      expect(Ai::InterventionPolicy.exists?(carved.id)).to be true
    end

    it "leaves other accounts alone" do
      other = create(:account)
      theirs = Ai::InterventionPolicy.create!(account: other, action_category: ghost_category,
                                             scope: "global", policy: "auto_approve", priority: 5)

      System::Seeds::AgentSetupHelpers.clean_unregistered_policies!(
        account: account, owned_prefixes: [ "system." ]
      )

      expect(Ai::InterventionPolicy.exists?(theirs.id)).to be true
    end

    # BLAST-RADIUS GUARDS. This sweep deletes on the ABSENCE of a boot-time
    # registration, so the two ways that absence can be a lie have to be
    # refusals rather than deletions: an unbounded namespace, and a registry
    # that never got populated for the namespace being swept (engine.rb's
    # `to_prepare` block records that a Zeitwerk reload wipes the registry back
    # to core's STATIC_CATEGORIES). Both fail LOUD — a silent zero here reads
    # exactly like a clean sweep.
    it "refuses to run without an owned namespace" do
      ghost = operator_authored_row!(ghost_category)

      expect {
        System::Seeds::AgentSetupHelpers.clean_unregistered_policies!(
          account: account, owned_prefixes: []
        )
      }.to raise_error(ArgumentError, /owned_prefixes/)
      expect(Ai::InterventionPolicy.exists?(ghost.id)).to be true
    end

    it "refuses to run when the registry holds nothing in the swept namespace" do
      ghost = operator_authored_row!(ghost_category)

      expect {
        System::Seeds::AgentSetupHelpers.clean_unregistered_policies!(
          account: account, owned_prefixes: [ "never.registered.anything." ]
        )
      }.to raise_error(ArgumentError, /registry/)
      expect(Ai::InterventionPolicy.exists?(ghost.id)).to be true
    end

    # THE GUARD THAT MATTERS, asked of the PREFIXES THE SEED ACTUALLY PASSES.
    # engine.rb registers all ~137 extension categories in one
    # `register_categories!` call and swallows any raise from that block into a
    # log warning, so "registry holds core's STATIC_CATEGORIES only" is a
    # reachable production state — and in it, every system.*/sdwan.* row in the
    # account looks like an orphan. A guard asking whether ANY owned prefix is
    # live cannot see it, because `project.*` are STATIC_CATEGORIES and answer
    # yes forever. This is the example that goes red on that weaker rule.
    it "refuses when the registry has fallen back to core's statics" do
      allow(Ai::InterventionPolicy).to receive(:registered_categories)
        .and_return(Ai::InterventionPolicy::STATIC_CATEGORIES)

      seeded = Ai::InterventionPolicy.create!(
        account: account, action_category: "system.cert_rotate", scope: "agent",
        ai_agent_id: create(:ai_agent, account: account).id,
        policy: "auto_approve", priority: 10, is_active: true
      )
      pool = operator_authored_row!("system.instance_pool_create")

      expect {
        System::Seeds::AgentSetupHelpers.clean_unregistered_policies!(
          account: account,
          owned_prefixes: System::Seeds::AgentSetupHelpers::OWNED_CATEGORY_NAMESPACES
        )
      }.to raise_error(ArgumentError, /system\./)

      expect(Ai::InterventionPolicy.exists?(seeded.id)).to be true
      expect(Ai::InterventionPolicy.exists?(pool.id)).to be true
    end
  end

  # The helper is only half the fix — a sweep nothing invokes collects nothing,
  # and a seed absent from SYSTEM_SEED_FILES never runs. Both halves are
  # verified by EXECUTION here rather than by grepping for the name.
  describe "system_autonomy_orphan_cleanup.rb" do
    let(:seed_path) do
      File.expand_path("../../../../db/seeds/system_autonomy_orphan_cleanup.rb", __dir__)
    end

    # Parses the LITERAL rather than grepping the file. A text match passes on a
    # commented-out entry — and `%w[]` does not honour `#`, so prose written
    # inside it becomes one bogus element per word rather than a comment. Both
    # mistakes are caught by reading the list as the loader reads it.
    it "is listed in the extension's seed orchestrator, in a well-formed list" do
      source  = File.read(File.expand_path("../../../../db/seeds.rb", __dir__))
      entries = source[/SYSTEM_SEED_FILES = %w\[(.*?)\]/m, 1].to_s.split
      seed_dir = File.expand_path("../../../../db/seeds", __dir__)

      expect(entries).to include("system_autonomy_orphan_cleanup.rb")
      expect(entries.reject { |e| e.end_with?(".rb") }).to be_empty
      expect(entries.reject { |e| File.exist?(File.join(seed_dir, e)) }).to be_empty
    end

    it "collects the ghost and spares registered rows when actually run" do
      allow(Account).to receive(:first).and_return(account)
      ghost = operator_authored_row!(ghost_category)
      tuned = operator_authored_row!("system.task.terminate")

      expect { load seed_path }.to output(/Collected 1 policy row/).to_stdout

      expect(Ai::InterventionPolicy.exists?(ghost.id)).to be false
      expect(Ai::InterventionPolicy.exists?(tuned.id)).to be true
    end
  end

  # THE DRIFT GUARD that keeps the rule derived rather than enumerated. If a
  # future seed writes policy rows in a namespace no owned prefix covers, those
  # rows are outside every sweep again — a new orphan class. This fails then,
  # forcing ownership to be extended rather than silently ceded.
  describe "namespace ownership covers everything this extension seeds" do
    let(:seed_dir) { File.expand_path("../../../../db/seeds", __dir__) }

    # TWO forms, because the extension's seeds are not the only style a future
    # one may copy. The `"cat" => "verb"` hash is what every system seed uses
    # today; the `action_category: "cat"` keyword is what core's own
    # autonomy_data_seed.rb uses, and a seed written in that style would
    # contribute nothing to a scan that only knew the first. Neither form sees
    # an interpolated name (`"system.task.#{cmd}"`) — a seed building categories
    # that way is outside this guard, which is why the helper's refusals, not
    # this scan, are the load-bearing safety.
    let(:seed_entry_patterns) do
      verbs = Ai::InterventionPolicy::POLICIES.join("|")
      [
        /"([a-z][a-z0-9_.]*)"\s*=>\s*"(?:#{verbs})"/,
        /action_category:\s*"([a-z][a-z0-9_.]*)"/
      ]
    end

    let(:seeded_categories) do
      Dir[File.join(seed_dir, "*.rb")].sort
        .flat_map { |f| src = File.read(f); seed_entry_patterns.flat_map { |re| src.scan(re).flatten } }
        .uniq.sort
    end

    it "claims a namespace for every category the extension's seeds create a row for" do
      owned = System::Seeds::AgentSetupHelpers::OWNED_CATEGORY_NAMESPACES
      unclaimed = seeded_categories.reject { |c| owned.any? { |p| c.start_with?(p) } }

      expect(unclaimed).to be_empty,
                           "#{unclaimed.size} seeded category namespace(s) are outside " \
                           "OWNED_CATEGORY_NAMESPACES, so rows for them are collected by no " \
                           "sweep once the category is deregistered: #{unclaimed.join(', ')}"
    end
  end
end
