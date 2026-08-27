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
    # Safe because the defaults are conservative: Ai::InterventionPolicyService
    # returns require_approval when it finds nothing, so a row this class
    # creates can only ever be equal to or stricter than the absence it
    # replaces — it cannot widen autonomy that was previously closed.
    class PolicyReconciler
      Result = Struct.new(:created, :already_present, :created_categories, keyword_init: true) do
        def changed? = created.positive?
      end

      DriftReport = Struct.new(:missing, :present, keyword_init: true) do
        def drifted? = missing.any?
      end

      def initialize(account:, logger: Rails.logger)
        @account = account
        @logger = logger
      end

      # Creates every declared row the account is missing. Returns a Result.
      # Idempotent: a second call on an unchanged database creates nothing.
      def reconcile!
        missing = drift.missing
        return Result.new(created: 0, already_present: declared.size, created_categories: []) if missing.empty?

        created = []
        missing.each do |action_category|
          ::Ai::InterventionPolicy.create!(
            PolicyDeclarations::MANUAL_OPERATION_SCOPE.merge(
              PolicyDeclarations::MANUAL_OPERATION_ATTRIBUTES
            ).merge(
              account: @account,
              action_category: action_category,
              policy: declared.fetch(action_category)
            )
          )
          created << action_category
        end

        @logger.info(
          "[GovernanceReconciler] created #{created.size} missing policy row(s) " \
          "for account #{@account.id}: #{created.join(', ')}"
        )
        Result.new(
          created: created.size,
          already_present: declared.size - created.size,
          created_categories: created
        )
      end

      # Read-only: what the code declares that the database lacks. Safe to call
      # from a health check or a CI assertion — mutates nothing.
      def drift
        existing = ::Ai::InterventionPolicy
                   .where(PolicyDeclarations::MANUAL_OPERATION_SCOPE.merge(account: @account))
                   .where(action_category: declared.keys)
                   .pluck(:action_category)
                   .to_set

        missing = declared.keys.reject { |c| existing.include?(c) }
        DriftReport.new(missing: missing, present: existing.to_a.sort)
      end

      private

      def declared = PolicyDeclarations::MANUAL_OPERATION_POLICIES
    end
  end
end
