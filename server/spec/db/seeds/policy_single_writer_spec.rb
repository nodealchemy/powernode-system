# frozen_string_literal: true

require "rails_helper"

# IMP-10e4f6c3bcd2 — proposal §5 ruling 7 (single-writer seeds), offer 01a0696f.
#
# System::Governance::PolicyReconciler is the ONLY writer of declared
# intervention-policy rows. An agent seed writes identity, prompt, approval
# chain, trust score, tool access and skills — and NO policy row. The four
# policy-only seeds (instance-pool, provisioning, volume-snapshot, cordon)
# whose whole body was an upsert are gone, from disk and from
# SYSTEM_SEED_FILES; the reconciler writes their sets on boot (rails-start.sh
# runs governance-reconcile.rb after db:seed on a first boot and after
# db:migrate on every later one) and via `rails system:governance:reconcile`.
#
# WHY IT MATTERS. Two writers of one row set disagreed in shape by
# construction: the seeds wrote against the CANONICAL's id on first boot while
# the reconciler and the gate (HIER-P2I) key on the account's acting
# principal, the seeds RESET a tuned verb on a targeted re-run while the
# reconciler is absence-only, and a policy seed that ran after its owner's
# seed could leave a duplicate the reconciler can never re-home. One writer,
# one shape, one rule.
#
# THE PROOF is the operator's own acceptance test: run the rewritten seeds
# against an empty database and assert the seeds themselves create ZERO rows,
# then that the reconciler creates the declared set. The seed list is read
# from the orchestrator, never restated here, so a seed added later is
# covered the moment it is listed.
RSpec.describe "declared intervention policies have ONE writer (ruling 7)" do
  let(:seeds_dir)    { Rails.root.join("..", "extensions", "system", "server", "db", "seeds") }
  let(:orchestrator) { File.read(Rails.root.join("..", "extensions", "system", "server", "db", "seeds.rb")) }

  # SYSTEM_SEED_FILES, parsed out of the orchestrator exactly as
  # seed_manifest_coverage_spec does. Raises rather than returning [] so a
  # reshaped literal cannot make every example below pass vacuously.
  let(:listed_seeds) do
    body = orchestrator[/SYSTEM_SEED_FILES\s*=\s*%w\[(.*?)\]/m, 1]
    raise "could not parse SYSTEM_SEED_FILES out of the orchestrator" if body.nil?

    body.split
  end

  # Every agent seed the orchestrator runs — the ten rewritten under this
  # task plus the System Concierge (never wrote a row) and the Supply Chain
  # Manager (the reference shape). Derived, so the count below is a ratchet.
  let(:agent_seeds) { listed_seeds.select { |file| file.end_with?("_agent.rb") } }

  # The four first-boot policy seeds this task retired. Named, not derived:
  # the assertion is that each is ABSENT, and an absent file cannot be found
  # by a scan.
  let(:retired_policy_seeds) do
    %w[
      system_instance_pool_policies.rb
      system_provisioning_intervention_policies.rb
      system_volume_snapshot_policies.rb
      system_instance_cordon_policies.rb
    ]
  end

  let(:declarations) { System::Governance::PolicyDeclarations }

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  def load_seed!(file)
    silence_warnings { load seeds_dir.join(file) }
  end

  def reconciler
    System::Governance::PolicyReconciler.new(account: account, logger: Logger.new(IO::NULL))
  end

  # The row the gate reads for an agent set sits on the account's ACTING
  # principal for that agent (HIER-P2I: the canonical is a template), resolved
  # through the same seam the reconciler writes against.
  def principal_for(agent_key)
    System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: agent_key)
  end

  def agent_rows(agent_key)
    Ai::InterventionPolicy
      .where(account: account, scope: "agent", user_id: nil, ai_agent_id: principal_for(agent_key).id)
      .pluck(:action_category, :policy).to_h
  end

  def operator_rows(set)
    Ai::InterventionPolicy
      .where(account: account, scope: set[:scope], ai_agent_id: nil, user_id: nil,
             action_category: set[:policies].keys)
      .pluck(:action_category, :policy).to_h
  end

  it "runs twelve agent seeds from the orchestrator (the ten rewritten, the Concierge and the reference shape)" do
    expect(agent_seeds.size).to eq(12), agent_seeds.inspect
    expect(agent_seeds).to include("fleet_autonomy_agent.rb", "system_supply_chain_manager_agent.rb",
                                   "system_concierge_agent.rb")
  end

  # HIER-P3: the boot this models is CORE seeds then EXTENSION seeds, because
  # one declared owner — the Platform Architect (CORE_CANONICAL_KEYS) — is a
  # core canonical produced by db/seeds/ai_engineering_agents_seed.rb. That
  # seed is core's own single writer of the ENGINEERING rows (core has no
  # PolicyReconciler, so a core-mode install needs them written), and it
  # writes them for the admin account THIS spec creates. Exactly one of those
  # rows is ALSO an extension-declared key — dev.campaign_propose on the
  # Platform Architect, declared so the routed governance-gap lane has an owner
  # and so non-admin accounts converge — at the SAME verb, which is what keeps
  # ruling 7 whole: the reconciler finds it present and writes nothing.
  # `core_written_rows` accounts for that seed's rows so every count below is
  # exact rather than loosened.
  let(:core_seeds) { %w[ai_engineering_agents_seed.rb] }

  def load_core_seed!(file)
    silence_warnings { load Rails.root.join("db", "seeds", file) }
  end

  def core_written_rows
    Ai::InterventionPolicy.where(account: account)
  end

  # (category, agent name, verb) of every core-written row the extension ALSO
  # declares ON THAT AGENT — the row the reconciler will find present. Core
  # writes dev.campaign_propose on the Platform Developer too, but no
  # extension set declares it there, so that row is core's alone.
  def shared_rows
    owners = declarations::AGENT_SET_OWNERS
    core_written_rows.where(scope: "agent", action_category: owners.keys).includes(:agent)
                     .select { |row| row.agent&.name == declarations::AGENT_IDENTITIES.fetch(owners[row.action_category])[:name] }
                     .map { |row| [ row.action_category, row.agent&.name, row.policy ] }.sort
  end

  describe "the agent seeds, against an empty database" do
    # HIER-P3 review — the WRITER is the oracle, not the category. Snapshot the
    # rows core's engineering seed wrote BEFORE the extension seeds run, so the
    # example below can assert the extension seeds added none at all. Keying the
    # exemption on ENGINEERING_CATEGORIES instead would have exempted all ten of
    # them for every writer, and an extension seed that started writing one of
    # the other nine would no longer have redded.
    before do
      core_seeds.each { |file| load_core_seed!(file) }
      @core_row_ids = Ai::InterventionPolicy.where(account: account).pluck(:id).to_set
      agent_seeds.each { |file| load_seed!(file) }
    end

    it "seed a GLOBAL canonical for every declared owner" do
      missing = declarations::AGENT_IDENTITIES.reject do |_key, identity|
        Ai::Agent.global.exists?(name: identity[:name], agent_type: identity[:agent_type])
      end
      expect(missing.keys).to be_empty
    end

    it "create ZERO intervention-policy rows — the reconciler is the only writer (the extension seeds)" do
      extension_written = core_written_rows.where.not(id: @core_row_ids.to_a)
      expect(extension_written.count).to eq(0),
        "the extension seeds wrote #{extension_written.count} row(s) core's seed had not: " \
        "#{extension_written.pluck(:scope, :action_category).first(5).inspect}…"
    end

    it "share exactly one row with core's engineering seed, at the verb the extension declares" do
      expect(shared_rows).to eq([ [ "dev.campaign_propose", "Platform Architect", "auto_approve" ] ])
      expect(declarations::PLATFORM_ARCHITECT_POLICIES["dev.campaign_propose"]).to eq("auto_approve")
    end

    # The reconciler writes policies and nothing else, so the CHAINS the
    # require_approval verbs route to stay with the seeds (checked first:
    # PolicyReconciler touches Ai::InterventionPolicy only).
    it "still write the approval chain and the trust score the reconciler does not" do
      chains = Ai::ApprovalChain.where(account: account, trigger_type: "autonomy_action").pluck(:name)
      expect(chains).to include(
        "Fleet Autonomy Actions", "Runtime Manager Actions", "CVE Responder Actions",
        "Disk Image Manager Actions", "SDWAN Manager Actions", "GitOps Reconciler Actions",
        "Topology Designer Actions", "Capacity Manager Actions", "Storage Manager Actions",
        "Ingress Manager Actions", "Supply Chain Manager Actions"
      )

      unscored = declarations::AGENT_IDENTITIES.reject do |_key, identity|
        canonical = Ai::Agent.global.find_by(name: identity[:name], agent_type: identity[:agent_type])
        canonical && Ai::AgentTrustScore.exists?(agent_id: canonical.id)
      end
      expect(unscored.keys).to be_empty
    end

    describe "and then the reconciler" do
      it "creates every declared set on a fresh install — nothing skipped, nothing missing afterwards" do
        declared_total = declarations::MANUAL_OPERATION_POLICIES.size +
                         declarations::POLICY_SETS.sum { |set| set[:policies].size }

        core_rows = core_written_rows.count
        shared = shared_rows.size

        result = reconciler.reconcile!

        expect(result.skipped_sets).to be_empty
        expect(result.rehomed).to be_empty
        # Every declared row is created here except the ones core's seed
        # already wrote at the declared verb (found present, never re-written).
        expect(result.already_present).to eq(shared)
        expect(result.created).to eq(declared_total - shared)
        expect(Ai::InterventionPolicy.where(account: account).count).to eq(core_rows + declared_total - shared)

        report = reconciler.drift
        expect(report.skipped_sets).to be_empty
        expect(report.missing).to be_empty
      end

      it "lands each agent set on the account's acting principal for that agent, verbs as declared" do
        reconciler.reconcile!

        declarations::POLICY_SETS.select { |set| set[:agent_key] }.each do |set|
          rows = agent_rows(set[:agent_key])
          if declarations::CORE_CANONICAL_KEYS.include?(set[:agent_key])
            # A core canonical also carries core's own engineering rows (the
            # refine pair, ...), so the declared keys are a SUBSET of its rows.
            expect(rows.slice(*set[:policies].keys)).to eq(set[:policies]), "set #{set[:key]}"
          else
            expect(rows).to eq(set[:policies]), "set #{set[:key]}"
          end
        end
      end

      it "lands each operator set at its declared shape" do
        reconciler.reconcile!

        declarations::POLICY_SETS.reject { |set| set[:agent_key] }.each do |set|
          expect(operator_rows(set)).to eq(set[:policies]), "set #{set[:key]}"
        end
      end

      it "is idempotent — a second pass, and a re-run of every seed, create nothing" do
        reconciler.reconcile!

        expect {
          agent_seeds.each { |file| load_seed!(file) }
          reconciler.reconcile!
        }.not_to change { Ai::InterventionPolicy.order(:id).pluck(:id, :ai_agent_id, :policy) }
      end

      # WHAT THE RETIRED SEED USED TO WRITE, asked of the ROWS the reconciler
      # leaves behind (IMP-28cccf7cee28). system_manual_operation_policies.rb
      # upserted MANUAL_OPERATION_POLICIES at (scope "global", no agent, no
      # user) with priority 5 / conditions {} / notification channels; before
      # deleting that writer the surviving one has to be shown covering the
      # same categories at the same shape, or a row the seed alone wrote would
      # simply vanish. It reads the SAME frozen constant the seed read
      # (PolicyReconciler#manual_set), so the two sets cannot diverge — this
      # pins the SHAPE, which was restated by hand in the seed and is the half
      # that could have.
      it "lands the manual-operations set at the shape the retired seed wrote it" do
        reconciler.reconcile!

        rows = Ai::InterventionPolicy.where(
          account: account, **declarations::MANUAL_OPERATION_SCOPE
        ).where("action_category LIKE 'system.task.%'")

        expect(rows.pluck(:action_category, :policy).to_h).to eq(declarations::MANUAL_OPERATION_POLICIES)
        attributes = declarations::MANUAL_OPERATION_ATTRIBUTES
        expect(rows.pluck(:priority).uniq).to eq([ attributes[:priority] ])
        expect(rows.pluck(:conditions).uniq).to eq([ attributes[:conditions] ])
        expect(rows.pluck(:is_active).uniq).to eq([ attributes[:is_active] ])
        expect(rows.pluck(:preferred_channels).uniq).to eq([ attributes[:preferred_channels] ])
      end
    end

    # THE ROW IS THE ORACLE — which writer produced it, not which file exists.
    #
    # A "the second writer's file is gone" assertion is defeated by the same
    # body under another name, and the runtime example above only executes
    # `*_agent.rb`, so a policy-writing seed of ANY other name met neither half
    # of this spec — which is exactly how system_manual_operation_policies.rb
    # stayed a second writer through IMP-10e4f6c3bcd2 (IMP-28cccf7cee28). So
    # the load set here is DERIVED from the same containment pattern the lint
    # uses, and the question asked of every seed in it is what it does to an
    # already-reconciled database.
    describe "every other policy-touching seed, against an ALREADY-RECONCILED database" do
      # An operator's deliberate tuning of a declared verb, and a
      # `system.task.` row whose command no longer exists — the two rows the
      # retired upsert reset and the retired destroy_all collected on every
      # re-run.
      let(:tuned_category)   { "system.task.terminate" }
      let(:retired_category) { "system.task.decommissioned_command" }

      before do
        reconciler.reconcile!
        Ai::InterventionPolicy.find_by!(
          account: account, action_category: tuned_category, **declarations::MANUAL_OPERATION_SCOPE
        ).update!(policy: "block")
        Ai::InterventionPolicy.create!(
          account: account, action_category: retired_category,
          **declarations::MANUAL_OPERATION_SCOPE,
          policy: "auto_approve", priority: 5, is_active: true
        )
      end

      # Every listed seed whose (comment-stripped) body could touch a policy
      # row at all, minus the single writer's own call site. Delete-only seeds
      # run LAST so the deregistered row is still there for a would-be
      # destroy_all to find.
      let(:second_writer_candidates) do
        candidates = policy_touching_seeds - [ single_writer_seed ]
        candidates.partition { |file| !delete_only_seeds.include?(file) }.flatten
      end

      def row_state
        Ai::InterventionPolicy.where(account: account).order(:id)
          .pluck(:id, :action_category, :scope, :ai_agent_id, :policy, :is_active, :priority)
          .to_h { |id, *rest| [ id, rest ] }
      end

      it "has a non-empty load set — an empty one would pass vacuously" do
        expect(second_writer_candidates).not_to be_empty
      end

      it "leaves every reconciled row exactly as the reconciler wrote it" do
        second_writer_candidates.each do |file|
          before_state = row_state
          load_seed!(file)
          after_state = row_state

          # AGGREGATED on purpose: a seed that both resets a verb and sweeps
          # rows is two defects, and the first expectation to fail would
          # otherwise hide the second — which is the more dangerous half, since
          # a deleting second writer silently reverts a reconciled row.
          aggregate_failures(file) do
            expect(after_state.keys - before_state.keys).to be_empty,
              "#{file} CREATED policy row(s) — the reconciler is the single writer"

            changed = after_state.select { |id, values| before_state.key?(id) && before_state[id] != values }
            expect(changed).to be_empty,
              "#{file} MODIFIED reconciled policy row(s): " \
              "#{changed.values.map { |values| values.first(1) + values.last(3) }.first(5).inspect}"

            deleted = before_state.keys - after_state.keys
            deleted_categories = before_state.values_at(*deleted).map(&:first)
            if delete_only_seeds.include?(file)
              # Pinned as delete-only: it may collect a row for a DEREGISTERED
              # category and nothing else.
              registered = deleted_categories.select { |category| Ai::InterventionPolicy.category_registered?(category) }
              expect(registered).to be_empty,
                "#{file} deleted row(s) for REGISTERED category(ies): #{registered.inspect}"
            else
              expect(deleted_categories).to be_empty,
                "#{file} DELETED policy row(s) — only the pinned delete-only collector may: " \
                "#{deleted_categories.inspect}"
            end
          end
        end

        # The two rows the retired writer acted on, asked directly: the tuned
        # verb survived every seed, and the deregistered row was collected by
        # the delete-only pass rather than by a second writer's sweep.
        expect(Ai::InterventionPolicy.find_by(
          account: account, action_category: tuned_category, **declarations::MANUAL_OPERATION_SCOPE
        ).policy).to eq("block")
      end
    end
  end

  # The orchestrator's own reconcile pass. Retiring the fourteen seed upserts
  # left `rails db:seed` — the documented install path for every non-hub
  # deployment (quickstart, production-deployment, single-node-bootstrap,
  # development-setup) — writing NO declared row at all: only the hub image's
  # rails-start.sh ran `governance-reconcile.rb`. The orchestrator now ends
  # with a reconcile pass of its own, so the single writer still runs on the
  # ordinary install path.
  describe "the orchestrator's reconcile pass" do
    let(:reconcile_seed) { "system_governance_policy_reconcile.rb" }

    it "is listed LAST in SYSTEM_SEED_FILES — every agent it reconciles is seeded above it" do
      expect(listed_seeds).to include(reconcile_seed)
      expect(listed_seeds.last).to eq(reconcile_seed)
    end

    it "installs every declared row on a fresh `db:seed` — the seeds alone install none" do
      core_seeds.each { |file| load_core_seed!(file) }
      agent_seeds.each { |file| load_seed!(file) }
      # Only core's engineering rows exist before the reconcile pass (HIER-P3,
      # see the boot model above); the extension seeds wrote none.
      core_rows = core_written_rows.count
      expect(core_written_rows.where.not(action_category: Ai::InterventionPolicy::ENGINEERING_CATEGORIES).count).to eq(0)

      declared_total = declarations::MANUAL_OPERATION_POLICIES.size +
                       declarations::POLICY_SETS.sum { |set| set[:policies].size }

      expect { load_seed!(reconcile_seed) }
        .to change { Ai::InterventionPolicy.where(account: account).count }
        .from(core_rows).to(core_rows + declared_total - shared_rows.size)
    end

    it "is idempotent — a second orchestrator run creates nothing" do
      core_seeds.each { |file| load_core_seed!(file) }
      agent_seeds.each { |file| load_seed!(file) }
      load_seed!(reconcile_seed)

      expect { load_seed!(reconcile_seed) }
        .not_to change { Ai::InterventionPolicy.order(:id).pluck(:id, :ai_agent_id, :policy) }
    end
  end

  describe "the retired policy-only seeds" do
    it "are gone from disk" do
      present = retired_policy_seeds.select { |file| File.exist?(seeds_dir.join(file)) }
      expect(present).to be_empty
    end

    it "are gone from SYSTEM_SEED_FILES" do
      expect(listed_seeds & retired_policy_seeds).to be_empty
    end
  end

  # The lint half: no seed the orchestrator runs may TOUCH Ai::InterventionPolicy.
  #
  # CONTAINMENT, not a write-shape list. An earlier version matched the five
  # literal write verbs, which any of `.new(...).save!`, `insert_all`, an
  # `update!` on a fetched row or a freshly named helper would have walked
  # past — and the runtime example above only executes `*_agent.rb`, so a
  # policy-writing NON-agent seed met neither half. So the rule is now
  # "mentions the model at all", with the two seeds that legitimately do named
  # here and each PINNED as still matching: an exception that stops matching
  # must be deleted from this list rather than quietly protecting a new file.
  # (Comment lines are dropped, so a seed may still SAY the reconciler writes
  # the rows — every rewritten seed does.)
  # A SEAM that writes policy rows without naming the model counts too:
  # `Ai::Engineering::ReleaseDispatchFloorSeeder` creates
  # Ai::InterventionPolicy rows and mentions neither the model nor a write
  # verb, so the containment rule above would have walked past it
  # (IMP-99988ef54942). `System::Governance::PolicyReconciler` is deliberately
  # NOT in the pattern: a dozen agent seeds name it in a `puts` line saying who
  # writes their rows, so it would flag files that write nothing — its one call
  # site is the pinned exception below.
  let(:policy_touch) do
    /Ai::InterventionPolicy|Ai::Engineering::ReleaseDispatchFloorSeeder|upsert_(operator_)?policies!|clean_stale_(operator_)?policies!/
  end

  # file => why it is allowed to touch the model.
  let(:lint_exceptions) do
    {
      # Delete-only: collects rows whose action_category is no longer
      # registered (IMP-0a3ff97f6fbb). Ruling 7 forbids a second WRITER.
      "system_autonomy_orphan_cleanup.rb" => :deletes_deregistered_rows,
      # Writes nothing itself: it CALLS two absence-only seams — the
      # PolicyReconciler for the extension's declared rows (ruling 7's single
      # writer) and core's ReleaseDispatchFloorSeeder for core's own
      # account-wide engineering floors, CORE rows with one core seam
      # (IMP-99988ef54942). Pinned here so the lint keeps the file in view
      # rather than leaving it silently uncovered.
      "system_governance_policy_reconcile.rb" => :calls_the_two_absence_only_seams
    }
  end

  # The seeds the orchestrator runs that could touch a policy row at all,
  # derived from the containment pattern above rather than from a filename —
  # the load set the row-oracle examples execute (IMP-28cccf7cee28).
  let(:policy_touching_seeds) do
    listed_seeds.select do |file|
      code = policy_touching_code(file)
      code && code.match?(policy_touch)
    end
  end

  # The single writer's own call site: the ONE listed seed that may land a
  # declared row.
  let(:single_writer_seed) { "system_governance_policy_reconcile.rb" }

  # The exceptions pinned as delete-only. They may collect a row whose category
  # is no longer registered; they may still never write one. Read off the same
  # labels, so a new exception has to declare which of the two it is.
  let(:delete_only_seeds) do
    lint_exceptions.select { |_file, why| why == :deletes_deregistered_rows }.keys
  end

  def policy_touching_code(file)
    path = seeds_dir.join(file)
    return nil unless File.exist?(path)

    File.read(path).lines.reject { |line| line.strip.start_with?("#") }.join
  end

  it "leaves no seed in SYSTEM_SEED_FILES touching Ai::InterventionPolicy (two named exceptions)" do
    writers = (listed_seeds - lint_exceptions.keys).select do |file|
      code = policy_touching_code(file)
      code && code.match?(policy_touch)
    end

    expect(writers).to be_empty, "seed(s) still touching intervention policies: #{writers.join(', ')}"
  end

  it "pins each lint exception as listed, present, and still matching" do
    lint_exceptions.each_key do |file|
      expect(listed_seeds).to include(file)
      code = policy_touching_code(file)
      expect(code).not_to be_nil, "#{file} is gone — drop it from lint_exceptions"
      expect(code).to match(policy_touch),
        "#{file} no longer touches intervention policies — drop it from lint_exceptions so the lint covers it"
    end
  end
end
