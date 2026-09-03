# frozen_string_literal: true

module System
  module Governance
    # Reconciles DECLARED governance rows into the running database, creating
    # only what is ABSENT.
    #
    # WHY THIS EXISTS -----------------------------------------------------
    # `db:seed` runs on FIRST BOOT ONLY (rails-start.sh gates it behind a
    # durable `.db-initialized` marker; later boots run `db:migrate` alone), so
    # a policy row added to a seed after an install's first boot never reaches
    # that install. The gate then resolves the missing row through
    # Ai::InterventionPolicyService's require_approval default, or — for a
    # DecisionEngine-routed lane — blocks every signal with only a WARN. Both
    # look exactly like a deliberate operator decision.
    #
    # WHY IT IS NOT "JUST RUN THE SEED ON EVERY BOOT" ---------------------
    # The seed path is DESTRUCTIVE by design, and safe today only because it
    # never re-runs:
    #
    #   * `upsert_manual_policies!` and AgentSetupHelpers#upsert_policies! both
    #     `assign_attributes(policy: <declared verb>, ...)` and save when
    #     `changed?` — so re-running RESETS an operator's deliberately tuned
    #     verb back to the seeded default.
    #   * system_manual_operation_policies.rb then `destroy_all`s every
    #     `system.task.*` global row whose category is not in the seed's key
    #     list.
    #
    # On first boot there is no operator intent to destroy. On every boot
    # thereafter both behaviours are live regressions — an operator who set
    # `system.task.terminate` to "block" would find it silently back at
    # "require_approval" after a deploy. That is a WORSE governance failure
    # than the gap this class closes.
    #
    # THE RULE: reconcile ABSENCE ONLY. Create a declared row that does not
    # exist. Never update an existing row's verb, never delete. An existing row
    # is operator intent until an operator says otherwise, and this class has no
    # way to distinguish "operator tuned it" from "an older seed wrote it".
    #
    # WHAT RECONCILING COSTS: IT CAN WIDEN AUTONOMY -----------------------
    # Ai::InterventionPolicyService#default_policy returns require_approval
    # when it finds no row, so absence is the STRICTEST resolution short of
    # "block". Creating a declared row therefore does not merely fill a hole —
    # for any declared verb looser than require_approval it REPLACES a parked
    # write with one that proceeds.
    #
    # As declared today that is a MINORITY of the set: of the 20 rows in
    # PolicyDeclarations::MANUAL_OPERATION_POLICIES, 5 are auto_approve and 5
    # notify_and_proceed — 10 that proceed without an approval where absence
    # would have parked. The other 10 are require_approval and so are no-ops on
    # resolution. Note that notify_and_proceed counts as a widening here: it
    # proceeds.
    #
    # (That set is now DERIVED from System::Task::COMMANDS — IMP-944567d41689 —
    # so the split moves whenever a command lands or leaves. The counts are
    # pinned in spec/services/system/governance/policy_reconciler_spec.rb.)
    #
    # This is defensible, and is the intended behaviour: it converges an
    # established install onto what its own first boot would have written, and
    # the declared verbs are the operator defaults. But it is a WIDENING, so
    # reconciling an install for the first time is an operator-visible change
    # in what proceeds unattended, not a silent repair. Capture the before
    # state and state the count.
    #
    # What it still cannot do is override intent: absence-only means an
    # operator's tuned row is never touched, and nothing here deletes.
    class PolicyReconciler
      Result = Struct.new(:created, :already_present, :created_categories,
                          :skipped_sets, :shadowed, keyword_init: true) do
        def changed? = created.positive?
      end

      DriftReport = Struct.new(:missing, :present, :skipped_sets, keyword_init: true) do
        # A SKIPPED set is drift, not a neutral outcome. An install that enables
        # this extension AFTER its first boot never seeds the agents (db:seed is
        # first-boot only — the whole argument this class exists for), so every
        # agent set skips — the eight agent-keyed sets, which hold roughly
        # two-thirds of every row PolicyDeclarations declares. Counting only
        # `missing` reported that install as CLEAN: the skipped set contributes
        # no missing rows precisely because it was never examined. (No literal
        # counts here on purpose: they are sums over PolicyDeclarations and
        # moved four times in a week — "~168 of 195", "119 of 191", "136 of
        # 207", "133 of 206" — each revision leaving the previous one wrong;
        # sum `POLICY_SETS` when a figure is needed; nothing asserts it.)
        #
        # That is the flagship scenario the reconciler was built for, and it was
        # the one it stayed silent about.
        def drifted? = missing.any? || skipped_sets.any?
      end

      # One declared row that the database lacks. `to_s` is what the rake task
      # and the boot summary print, so it names the SET as well as the category
      # — the same category is declared by more than one set (instance-pool
      # declares eight at the agent shape and its gated four at the operator
      # shape) and "which one is missing" is the whole question.
      MissingRow = Struct.new(:set_key, :action_category, :policy, keyword_init: true) do
        def to_s = "#{set_key}/#{action_category}"
      end

      def initialize(account:, logger: Rails.logger)
        @account = account
        @logger = logger
      end

      # Creates every declared row the account is missing. Returns a Result.
      # Idempotent: a second call on an unchanged database creates nothing.
      def reconcile!
        created = []
        shadowed = []
        present = 0
        skipped = []

        each_set do |set, agent, skip_reason|
          if skip_reason
            skipped << "#{set[:key]}(#{skip_reason})"
            next
          end

          existing = existing_categories(set, agent)
          set[:policies].each do |action_category, verb|
            if existing.include?(action_category)
              present += 1
              next
            end

            ::Ai::InterventionPolicy.create!(
              account: @account,
              action_category: action_category,
              scope: set[:scope],
              ai_agent_id: agent&.id,
              user_id: nil,
              policy: verb,
              priority: set[:priority],
              is_active: true,
              conditions: conditions_for(set, action_category),
              preferred_channels: %w[notification]
            )
            created << "#{set[:key]}/#{action_category}"

            # An agent-scoped row OUT-RANKS a global one at any priority
            # (Ai::InterventionPolicy#specificity_key is lexicographic), so
            # creating this row can change what an agent caller resolves even
            # though we touched no existing row. Absence-only cannot tell
            # "never seeded" from "operator deleted the agent row to fall back
            # to their tuned global floor", and deleting a policy IS an
            # expressible operator action — so surface it rather than let the
            # change happen unremarked.
            shadowed << "#{set[:key]}/#{action_category}" if set[:scope] == "agent" && global_row?(action_category)
          end
        end

        unless created.empty?
          @logger.info(
            "[GovernanceReconciler] created #{created.size} missing policy row(s) " \
            "for account #{@account.id}: #{created.join(', ')}"
          )
        end

        Result.new(
          created: created.size,
          already_present: present,
          created_categories: created,
          skipped_sets: skipped,
          shadowed: shadowed
        )
      end

      # Read-only: what the code declares that the database lacks. Safe to call
      # from a health check or a CI assertion — mutates nothing.
      #
      # NOTE it does NOT filter on is_active. A deactivated row is PRESENT: an
      # operator turning a control off must not have it silently recreated on
      # the next boot, so deactivate — not delete — is the durable off switch.
      # (On the FleetAutonomyService pre-gate, whose permitted_actions DOES
      # filter is_active, "off" means the lane hard-blocks. Off is off there,
      # not a fall-through to some looser row.)
      def drift
        missing = []
        present = []
        skipped = []

        each_set do |set, agent, skip_reason|
          if skip_reason
            skipped << "#{set[:key]}(#{skip_reason})"
            next
          end

          existing = existing_categories(set, agent)
          set[:policies].each do |action_category, verb|
            if existing.include?(action_category)
              present << "#{set[:key]}/#{action_category}"
            else
              missing << MissingRow.new(set_key: set[:key], action_category: action_category, policy: verb)
            end
          end
        end

        DriftReport.new(missing: missing, present: present.sort, skipped_sets: skipped)
      end

      private

      # The manual operator set, expressed in the same record shape as the
      # declared agent sets so there is ONE iteration and no special case.
      def manual_set
        {
          key: "manual-operations",
          agent_key: nil,
          scope: PolicyDeclarations::MANUAL_OPERATION_SCOPE[:scope],
          priority: PolicyDeclarations::MANUAL_OPERATION_ATTRIBUTES[:priority],
          conditions: PolicyDeclarations::MANUAL_OPERATION_ATTRIBUTES[:conditions],
          policies: PolicyDeclarations::MANUAL_OPERATION_POLICIES
        }
      end

      def declared_sets = [ manual_set ] + PolicyDeclarations::POLICY_SETS

      # Yields (set, agent, skip_reason). skip_reason is non-nil when the set
      # cannot be reconciled — today only "agent absent". A set is SKIPPED, never
      # written at a different shape: declaring "whatever shape the database
      # happens to have" would make drift unfalsifiable.
      def each_set
        declared_sets.each do |set|
          if set[:agent_key].nil?
            yield set, nil, nil
            next
          end

          agent = resolve_agent(set[:agent_key])
          yield set, agent, (agent ? nil : "agent absent")
        end
      end

      # Resolve EXACTLY as the runtime does, or the rows land on an agent the
      # gate never reads.
      #
      # `Ai::Agent.resolve_for` is override-aware: an account's own clone of a
      # seeded agent WINS over the global row (`account_override_first`). Every
      # gate site resolves that way — FleetAutonomyService.tick!, the CVE
      # responder, and the tools. A bare `find_by(source_key:)` here has no
      # account filter and no override precedence, so on any account holding an
      # override it wrote rows against the GLOBAL agent id while the gate asked
      # the OVERRIDE id: rows nothing reads, and a drift report that says
      # "present" forever. That is the same defect class as reimplementing a
      # resolution rule in ad-hoc SQL — the copy drifts from the original.
      #
      # source_key stays as a FALLBACK only, for an agent an operator renamed.
      # It rescues less than it appears to: the runtime resolves by NAME, so a
      # renamed agent has already killed its own tick ("agent not seeded") and
      # these rows are staged for whenever the name is restored. Resolving the
      # RUNTIME by source_key is the real fix and is not this class's to make.
      #
      # Memoized per (account, key) — the same agent backs several sets.
      def resolve_agent(agent_key)
        @agents ||= {}
        return @agents[agent_key] if @agents.key?(agent_key)

        identity = PolicyDeclarations::AGENT_IDENTITIES[agent_key]
        @agents[agent_key] =
          (identity && ::Ai::Agent.resolve_for(@account.id, name: identity[:name],
                                                            agent_type: identity[:agent_type])) ||
          ::Ai::Agent.find_by(source_key: agent_key)
      end

      def existing_categories(set, agent)
        ::Ai::InterventionPolicy
          .where(account: @account, scope: set[:scope], ai_agent_id: agent&.id, user_id: nil)
          .where(action_category: set[:policies].keys)
          .pluck(:action_category)
          .to_set
      end

      def global_row?(action_category)
        ::Ai::InterventionPolicy
          .exists?(account: @account, scope: "global", ai_agent_id: nil, action_category: action_category)
      end

      def conditions_for(set, action_category)
        (set[:condition_overrides] || {}).fetch(action_category, set[:conditions])
      end
    end
  end
end
