# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Governance::PolicyReconciler do
  let(:account) { create(:account) }
  let(:declared) { System::Governance::PolicyDeclarations::MANUAL_OPERATION_POLICIES }
  let(:scope) { System::Governance::PolicyDeclarations::MANUAL_OPERATION_SCOPE }

  subject(:reconciler) { described_class.new(account: account, logger: Logger.new(IO::NULL)) }

  def row_for(category)
    Ai::InterventionPolicy.find_by(scope.merge(account: account, action_category: category))
  end

  # Declared rows are keyed by SET as well as category — the same category is
  # declared by more than one set — so scope the manual-set assertions to it.
  def missing_in(report, set_key)
    report.missing.select { |m| m.set_key == set_key }.map(&:action_category)
  end

  def created_in(result, set_key)
    result.created_categories.select { |c| c.start_with?("#{set_key}/") }
  end

  describe "#drift" do
    it "reports every declared manual category as missing on an install that never seeded them" do
      report = reconciler.drift
      expect(report).to be_drifted
      expect(missing_in(report, "manual-operations")).to match_array(declared.keys)
    end

    it "mutates nothing" do
      expect { reconciler.drift }.not_to change(Ai::InterventionPolicy, :count)
    end

    it "SKIPS an agent set whose agent row is absent, naming the set" do
      report = reconciler.drift

      expect(report.skipped_sets).to include(a_string_matching(/fleet-autonomy\(agent absent\)/))
      expect(missing_in(report, "fleet-autonomy")).to be_empty
    end

    # Deactivate, don't delete, is the durable off switch: a row an operator
    # turned OFF must not be silently recreated on the next boot. Pinned
    # because the query's lack of an is_active filter is easy to "tidy up".
    # A skipped set contributes no MISSING rows precisely because it was never
    # examined, so counting only `missing` reported the extension-enabled-after-
    # first-boot install — 117 of the 189 declared rows absent, every one of
    # them in a skipped agent set — as perfectly clean.
    it "reports DRIFT when a set is skipped, even with nothing missing" do
      # Reconcile FIRST so every agent-less set is satisfied. What remains is
      # only the skipped agent sets — the state this example exists to catch.
      # Without this the fixture still has missing rows and the assertion
      # passes on `missing.any?` alone, i.e. it could not fail.
      reconciler.reconcile!
      report = reconciler.drift

      expect(report.missing).to be_empty
      expect(report.skipped_sets).not_to be_empty
      expect(report).to be_drifted
    end

    it "counts a DEACTIVATED row as present, not missing" do
      reconciler.reconcile!
      row = row_for("system.task.terminate")
      row.update!(is_active: false)

      expect(missing_in(reconciler.drift, "manual-operations")).not_to include("system.task.terminate")
    end
  end

  describe "#reconcile!" do
    it "creates the declared rows that are absent, with the declared verbs" do
      result = reconciler.reconcile!

      expect(created_in(result, "manual-operations").size).to eq(declared.size)
      expect(row_for("system.task.terminate").policy).to eq("require_approval")
      expect(row_for("system.task.start").policy).to eq("auto_approve")
    end

    it "creates rows at the operator-resolvable shape, not agent-scoped" do
      reconciler.reconcile!
      row = row_for("system.task.terminate")

      # An agent-scoped row can never match an agent-less operator caller, so a
      # row of the wrong shape would leave the gate falling through to default.
      expect(row.scope).to eq("global")
      expect(row.ai_agent_id).to be_nil
      expect(row.user_id).to be_nil
    end

    it "is idempotent — a second run creates nothing" do
      reconciler.reconcile!
      expect { reconciler.reconcile! }.not_to change(Ai::InterventionPolicy, :count)
    end

    # THE LOAD-BEARING GUARANTEE. The seed path overwrites a tuned verb and
    # destroy_all's unlisted rows; that is safe only because it never re-runs.
    # This reconciler runs on every deploy, so it must never do either.
    it "NEVER overwrites an operator's tuned verb" do
      reconciler.reconcile!
      row = row_for("system.task.terminate")
      row.update!(policy: "block")

      reconciler.reconcile!

      expect(row.reload.policy).to eq("block")
    end

    it "NEVER deletes a row it does not declare" do
      foreign = Ai::InterventionPolicy.create!(
        scope.merge(
          account: account,
          action_category: "system.task.operator_invented_category",
          policy: "block", priority: 5, is_active: true,
          conditions: {}, preferred_channels: %w[notification]
        )
      )

      reconciler.reconcile!

      expect(foreign.reload).to be_persisted
      expect(foreign.policy).to eq("block")
    end

    it "fills only the gap when some rows already exist" do
      Ai::InterventionPolicy.create!(
        scope.merge(
          account: account, action_category: "system.task.start", policy: "block",
          priority: 5, is_active: true, conditions: {}, preferred_channels: %w[notification]
        )
      )

      result = reconciler.reconcile!

      expect(created_in(result, "manual-operations").size).to eq(declared.size - 1)
      expect(result.created_categories).not_to include("manual-operations/system.task.start")
      expect(row_for("system.task.start").policy).to eq("block")
    end

    it "scopes to its own account" do
      other = create(:account)
      reconciler.reconcile!

      expect(
        Ai::InterventionPolicy.where(scope.merge(account: other)).count
      ).to eq(0)
    end

    context "with the declared agents present" do
      let!(:fleet) do
        create(:ai_agent, account: account, name: "Fleet Autonomy",
                          agent_type: "monitor", source_key: "fleet-autonomy")
      end

      def agent_row(category)
        Ai::InterventionPolicy.find_by(account: account, scope: "agent",
                                       ai_agent_id: fleet.id, action_category: category)
      end

      it "creates the agent-scoped set at its declared shape" do
        reconciler.reconcile!
        row = agent_row("system.cert_rotate")

        expect(row.policy).to eq("require_approval")
        expect(row.priority).to eq(10)
        expect(row.conditions).to eq("trust_tier_minimum" => "monitored")
      end

      # source_key is a FALLBACK, and it rescues less than it looks like it
      # does: the RUNTIME resolves agents by name (FleetAutonomyService.tick!),
      # so a renamed agent has already killed its own tick and these rows are
      # merely staged for whenever the name is restored. Pinned so the fallback
      # keeps working, NOT as evidence that a rename is survivable.
      it "still resolves a renamed agent through the source_key fallback" do
        fleet.update!(name: "Renamed By Operator")

        result = reconciler.reconcile!

        # Only the fleet agent exists here, so the other five sets skip by
        # design; what matters is that THIS set did not skip on the rename.
        expect(result.skipped_sets).not_to include(a_string_matching(/fleet-autonomy/))
        expect(agent_row("system.cert_rotate")).to be_present
      end

      # A set-level condition cannot express this one; without a per-category
      # override slot it flattens to the default and the window disappears.
      it "applies the per-category conditions override" do
        reconciler.reconcile!
        row = agent_row("project.scale_horizontal")

        expect(row.conditions).to eq(
          "trust_tier_minimum" => "monitored",
          "auto_apply_window" => "watch_policies.auto_scale_max_replicas"
        )
      end

      # Creating an agent row where a global one exists changes what an agent
      # caller resolves (agent out-ranks global at any priority) without this
      # run touching the global row. Report it; do not silently do it.
      it "reports an agent row that now shadows an existing global row" do
        Ai::InterventionPolicy.create!(
          account: account, scope: "global", ai_agent_id: nil, user_id: nil,
          action_category: "system.cert_rotate", policy: "block", priority: 5,
          is_active: true, conditions: {}, preferred_channels: %w[notification]
        )

        result = reconciler.reconcile!

        expect(result.shadowed).to include("fleet-autonomy/system.cert_rotate")
      end

      # THE ROWS MUST LAND WHERE THE GATE LOOKS. Ai::Agent.resolve_for is
      # override-aware — an account's own clone of a seeded agent beats the
      # global row — and every gate site resolves that way. Resolving by bare
      # source_key wrote against the GLOBAL id while the gate asked the
      # OVERRIDE id: rows nothing reads, reported present forever.
      it "prefers the account's OVERRIDE agent over the global one" do
        # `fleet` (the enclosing let!) is the ACCOUNT's agent — the override.
        # Build the global twin via update_columns: the factory cannot make an
        # account-less agent (its creator needs one), and the name collides.
        global = create(:ai_agent, account: account, name: "Global Fleet Autonomy",
                                   agent_type: "monitor", source_key: "fleet-autonomy")
        global.update_columns(account_id: nil, name: "Fleet Autonomy")
        override = fleet

        reconciler.reconcile!

        row = Ai::InterventionPolicy.find_by(account: account, scope: "agent",
                                             action_category: "system.cert_rotate")
        expect(row.ai_agent_id).to eq(override.id)
        expect(row.ai_agent_id).not_to eq(global.id)
      end

      it "still never overwrites a tuned agent verb" do
        reconciler.reconcile!
        row = agent_row("system.cert_rotate")
        row.update!(policy: "block")

        reconciler.reconcile!

        expect(row.reload.policy).to eq("block")
      end
    end
  end

  # Pins the figures PolicyReconciler's header quotes. This exists as an
  # assertion rather than prose because the claim it replaced — "it cannot
  # widen autonomy that was previously closed" — was itself a comment, and a
  # comment cannot fail when the declarations move out from under it.
  #
  # If one of these fails, the declared verb mix changed: update the header's
  # numbers in the same commit.
  # sdwan.port_mapping_delete was the ONE destructive verb of 14 declared at
  # notify_and_proceed, so it proceeded unattended while every sibling delete
  # parked for approval. That is the kind of single-entry drift a hand-kept
  # table loses, so state the RULE rather than the one value.
  describe "destructive SDWAN verbs" do
    let(:sdwan) { System::Governance::PolicyDeclarations::SDWAN_MANAGER_POLICIES }

    # Tearing something down is never a proceed-unattended action, whatever the
    # resource. `revoke` counts: it withdraws access someone is relying on.
    it "require approval for every delete and revoke" do
      destructive = sdwan.select { |cat, _| cat.match?(/_(delete|revoke)\z/) }
      proceeding = destructive.reject { |_, verb| verb == "require_approval" }

      expect(proceeding).to be_empty,
                            "#{proceeding.size} destructive SDWAN verb(s) proceed without approval: " \
                            "#{proceeding.map { |c, v| "#{c}=#{v}" }.join(', ')}"
    end

    # Guards the above from passing vacuously on a renamed/emptied set.
    it "has destructive verbs to check" do
      expect(sdwan.keys.count { |c| c.match?(/_(delete|revoke)\z/) }).to be >= 14
    end
  end

  describe "the declared verb mix (pins the reconciler's header)" do
    # A `let`, not a constant: a constant assigned inside a describe block
    # lands on Object, where a same-named one in another spec file silently
    # clobbers it.
    let(:proceeds_unattended) { %w[auto_approve notify_and_proceed silent] }

    # The load-bearing premise. Everything below is only a widening BECAUSE
    # absence resolves to require_approval — asserted against the service
    # rather than restated, so a change to the default breaks this first.
    it "resolves an undeclared category to require_approval" do
      resolved = Ai::InterventionPolicyService
                 .new(account: account)
                 .resolve(action_category: "system.task.never_declared_anywhere")

      expect(resolved[:policy]).to eq("require_approval")
      expect(resolved[:record]).to be_nil
    end

    # The set is DERIVED from System::Task::COMMANDS (IMP-944567d41689), so
    # this split moves whenever a command lands or leaves — which is the point
    # of pinning it: the reconciler's header states these numbers as its
    # justification for widening, and a command added without a verb decision
    # would silently change how much it widens.
    it "declares 20 rows in a 6/5/9 split" do
      expect(declared.size).to eq(20)
      expect(declared.size).to eq(System::Task::COMMANDS.size)
      expect(declared.values.tally).to eq(
        "auto_approve" => 6,
        "notify_and_proceed" => 5,
        "require_approval" => 9
      )
    end

    it "widens 11 of them relative to the absence they replace" do
      widening, no_op = declared.partition { |_, verb| proceeds_unattended.include?(verb) }

      expect(widening.size).to eq(11)
      expect(no_op.size).to eq(9)
      expect(no_op.map(&:last).uniq).to eq(%w[require_approval])
    end

    # The named ones, pinned individually. The set-level counts above would
    # stay green if a root-equivalent handler traded places with a harmless
    # one, and these six are where that trade would be silent: five storage
    # verbs whose agent handlers take an UNVALIDATED payload (an unsanitised
    # systemd unit name written under /etc/systemd/system and started, an
    # unbounded /etc/exports.d entry, a chown rooted at any path but "/"), plus
    # the boot-image rewrite. See MANUAL_OPERATION_DEFAULT_VERBS for the
    # per-command derivation.
    it "parks every command whose node-side handler takes an unvalidated payload" do
      %w[
        storage.mount storage.unmount storage.exports.apply
        storage.gateway.provision storage.gateway.deprovision storage.chown
        upgrade_boot_image ssh_command
      ].each do |command|
        expect(declared.fetch("system.task.#{command}")).to eq("require_approval"),
                                                            "system.task.#{command} is declared " \
                                                            "#{declared['system.task.' + command].inspect}. These rows " \
                                                            "resolve for AGENT callers too (scope global, nil agent), and " \
                                                            "TasksController permits an arbitrary options JSONB, so anything " \
                                                            "looser hands an unattended root primitive to a prompt-injected agent."
      end
    end
  end
end
