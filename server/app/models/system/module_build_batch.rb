# frozen_string_literal: true

module System
  # The operator-visible unit of a native module-build run (campaign 019f5885
  # inc9 Part A) — replaces "the Gitea run" as the thing an operator inspects
  # to answer "did this push's module rebuild succeed." One row per build run,
  # created from a System::ModuleBuildPlannerService.plan result.
  #
  # SEMANTICS: a batch is bookkeeping + status aggregation over its member
  # `ci.module_build` System::Task rows — it does NOT dispatch or execute
  # anything itself (that's Part B's orchestrator). Members are correlated
  # by option, not FK: each member Task's `options["batch_id"]` carries this
  # batch's id (see #member_tasks). This mirrors System::CiRunnerLease's
  # "bookkeeping wrapper, not job isolation" posture from inc3 — the batch
  # tracks what the orchestrator already dispatched, it doesn't gate it.
  #
  # AASM mirrors System::CiRunnerLease / System::Task: each event stamps its
  # own timestamp column via a `before` block so the single AASM transition
  # save persists everything atomically.
  class ModuleBuildBatch < BaseRecord
    include System::Base
    include AASM

    self.table_name = "system_module_build_batches"

    # === Constants ===
    STATUSES = %w[planning dispatched awaiting_signature publishing complete partial failed].freeze
    # "package" (campaign 019f6084 inc2 §4.3.2): an on-demand package-closure
    # build materialized by System::PackageModuleMaterializer and routed through
    # the native pipeline via System::PackageClosureBuildBridge. Unlike push/
    # manual/cve (git-sha-driven platform-module builds), a package batch's
    # base_sha/head_sha carry the repository sync-snapshot token (no git ref
    # exists) and its per-module build context lives in metadata["package_context"].
    TRIGGERS = %w[push manual cve package].freeze

    # === Associations ===
    belongs_to :account

    # === Validations ===
    validates :status,   presence: true, inclusion: { in: STATUSES }
    validates :trigger,  presence: true, inclusion: { in: TRIGGERS }
    validates :base_sha, presence: true
    validates :head_sha, presence: true

    # === State machine (AASM — platform standard, mirrors System::CiRunnerLease) ===
    aasm column: :status, whiny_transitions: true do
      state :planning, initial: true
      state :dispatched
      state :awaiting_signature
      state :publishing
      state :complete
      state :partial
      state :failed

      # All planned ci.module_build Tasks have been created/enqueued.
      event :dispatch do
        transitions from: :planning, to: :dispatched
        before { self.dispatched_at = Time.current }
      end

      # Builds finished; waiting on Vault/cosign signing (inc8) before publish.
      event :await_signature do
        transitions from: :dispatched, to: :awaiting_signature
        before { self.awaiting_signature_at = Time.current }
      end

      # Signed artifacts are being pushed to the OCI registry.
      event :begin_publishing do
        transitions from: :awaiting_signature, to: :publishing
        before { self.publishing_at = Time.current }
      end

      # Every member task succeeded.
      event :complete do
        transitions from: :publishing, to: :complete
        before { self.completed_at = Time.current }
      end

      # Some, but not all, member tasks succeeded.
      event :complete_partially do
        transitions from: :publishing, to: :partial
        before { self.completed_at = Time.current }
      end

      # Terminal failure from any in-flight state (mirrors CiRunnerLease#fail's
      # allow-from-anywhere-active shape — a batch can fail before it ever
      # reaches publishing, e.g. every build fails outright).
      event :fail do
        transitions from: [ :planning, :dispatched, :awaiting_signature, :publishing ], to: :failed

        before do |message = nil|
          self.failed_at = Time.current
          self.error_message = message if message
        end
      end
    end

    # === Scopes ===
    scope :by_status,  ->(status)  { where(status: status) }
    scope :by_trigger, ->(trigger) { where(trigger: trigger) }
    scope :recent,      -> { order(created_at: :desc) }

    # === Class methods ===

    # Builds a batch in `planning` from a System::ModuleBuildPlannerService.plan
    # result (an array of { module:, oci_ref: } hashes — see that service for
    # the exact shape). The full plan (module + assigned oci_ref/tag per
    # module) is preserved in metadata["plan"] for audit/debugging; the
    # queryable module_slugs column is just the slug list.
    #
    # shadow: (campaign 019f5885 inc10 — dual-run) marks this batch as a
    # shadow native build dispatched alongside a Gitea-authoritative build
    # (mode == "dual"). Callers building a shadow plan are responsible for
    # already having tagged each plan entry's oci_ref with the `native-`
    # prefix (see System::ModuleBuildTriggerService) — this method just
    # persists the flag so System::NativeModuleBuildOrchestrator#advance!
    # knows to publish with promote: false (System::ModulePublicationProcessor)
    # instead of the normal promote-on-publish default.
    def self.create_for(account:, plan:, trigger:, base_sha:, head_sha:, shadow: false)
      plan_array = Array(plan)
      create!(
        account: account,
        trigger: trigger,
        base_sha: base_sha,
        head_sha: head_sha,
        shadow: shadow,
        module_slugs: plan_array.map { |p| p[:module].to_s },
        planned_count: plan_array.size,
        metadata: {
          "plan" => plan_array.map { |p| { "module" => p[:module].to_s, "oci_ref" => p[:oci_ref].to_s } }
        }
      )
    end

    # === Instance methods ===

    # The System::Task command for this batch's member build tasks. Package
    # batches (campaign 019f6084 inc2 §4.3.2) dispatch `ci.package_build`
    # (mmdebstrap-a-closure) tasks; every other trigger dispatches the platform
    # `ci.module_build` (checkout-and-build-modules/<slug>) task. Keeping the
    # correlation command trigger-derived lets one orchestrator + one batch
    # model serve both build kinds.
    PACKAGE_TASK_COMMAND  = "ci.package_build"
    PLATFORM_TASK_COMMAND = "ci.module_build"

    def member_task_command
      trigger == "package" ? PACKAGE_TASK_COMMAND : PLATFORM_TASK_COMMAND
    end

    # The build Tasks dispatched for this batch. Correlated by option
    # (options["batch_id"] == id), not FK — see class comment. options is JSONB
    # with a GIN index (system_tasks baseline migration), so the containment
    # query below is index-backed.
    def member_tasks
      ::System::Task.where(account_id: account_id, command: member_task_command)
                     .where("options @> ?", { batch_id: id }.to_json)
    end

    # Recomputes succeeded_count/failed_count from the current member_tasks
    # state. Does NOT touch planned_count (fixed at creation from the plan
    # size) and does NOT drive AASM transitions — the orchestrator decides
    # when a batch is done and calls complete!/complete_partially!/fail!
    # itself, using these counts to choose which.
    def recompute_counts!
      statuses = member_tasks.pluck(:status)
      update!(
        succeeded_count: statuses.count { |s| s == "complete" },
        failed_count: statuses.count { |s| %w[failed aborted cancelled].include?(s) }
      )
    end

    # === Lifecycle category checks ===
    def active?
      %w[planning dispatched awaiting_signature publishing].include?(status)
    end

    def finished?
      %w[complete partial failed].include?(status)
    end
  end
end
