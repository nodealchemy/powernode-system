# frozen_string_literal: true

module System
  # Lifecycle/accounting/recycle wrapper around a pooled builder NodeInstance
  # leased to CI work (campaign 019f5885 inc3).
  #
  # SEMANTICS (operator decision, inc3): a lease is bookkeeping + recycle, NOT
  # job isolation. Registration is pull-based — a warm builder carrying the
  # gitea-act-runner module self-registers with Gitea on boot regardless of any
  # lease, and Gitea schedules jobs by *label*, not by lease. So the `registered`
  # state means "this leased instance has been CORRELATED to a live GitRunner
  # row", not "registration was gated on this lease." Real isolation
  # (lease-gated registration + per-lease labels) arrives in inc4/inc5; until
  # then hygiene is the recycle-on-release path plus the sweep's orphan reaping.
  #
  # git_runner_id is a plain uuid (no FK): RunnerLifecycleService#delete_runner
  # destroys the git_runners row on release. runner_name/runner_external_id are
  # snapshotted here so the audit trail survives that destroy.
  class CiRunnerLease < BaseRecord
    include System::Base
    include AASM

    # === Constants ===
    STATUSES = %w[leased registered busy releasing released errored].freeze
    PURPOSES = %w[generic module_build disk_image_build].freeze
    SCOPES   = %w[repo org admin].freeze

    # === Associations ===
    belongs_to :account
    belongs_to :node_instance, class_name: "System::NodeInstance"
    belongs_to :instance_pool, class_name: "System::InstancePool", optional: true
    # Read-convenience only; not FK-backed (git_runner_id is a plain uuid that
    # dangles once delete_runner destroys the row — the snapshot columns are the
    # durable record).
    belongs_to :git_runner, class_name: "Devops::GitRunner", optional: true

    # === Validations ===
    validates :status,  presence: true, inclusion: { in: STATUSES }
    validates :purpose, presence: true, inclusion: { in: PURPOSES }
    # Matches the migration's NOT NULL + default("org") — allow_nil here would
    # let `.valid?` pass on a record that can never actually be saved (the DB
    # rejects a null runner_scope), so this validates the same way status/purpose
    # do. No caller ever constructs a lease with a nil scope (CiRunnerLeaseService
    # always computes one via API_SCOPE_TO_RUNNER_SCOPE); this only closes the gap
    # for future callers.
    validates :runner_scope, presence: true, inclusion: { in: SCOPES }

    # === State machine (AASM — platform standard, mirrors System::Task) ===
    # Each event stamps its timestamp inline via `before` so AASM's single
    # transition save persists everything atomically.
    aasm column: :status, whiny_transitions: true do
      state :leased, initial: true
      state :registered
      state :busy
      state :releasing
      state :released
      state :errored

      # Correlated to a live GitRunner row (see class semantics note).
      event :register do
        transitions from: :leased, to: :registered

        before do |runner = nil|
          self.registered_at = Time.current
          if runner
            self.git_runner_id       = runner.id
            self.runner_external_id  = runner.external_id
            self.runner_name       ||= runner.name
          end
        end
      end

      event :mark_busy do
        transitions from: :registered, to: :busy
        before { self.busy_at = Time.current }
      end

      # Allow-from-leased so a lease whose runner never correlated can still be
      # torn down cleanly.
      event :begin_release do
        transitions from: [ :leased, :registered, :busy ], to: :releasing
        before { self.releasing_at = Time.current }
      end

      event :complete_release do
        transitions from: :releasing, to: :released
        before { self.released_at = Time.current }
      end

      event :fail do
        transitions from: [ :leased, :registered, :busy, :releasing ], to: :errored

        before do |message = nil|
          self.errored_at = Time.current
          self.error_message = message if message
        end
      end
    end

    # === Scopes ===
    scope :by_status, ->(status) { where(status: status) }
    scope :leased,     -> { by_status("leased") }
    scope :registered, -> { by_status("registered") }
    scope :busy,       -> { by_status("busy") }
    scope :releasing,  -> { by_status("releasing") }
    scope :released,   -> { by_status("released") }
    scope :errored,    -> { by_status("errored") }

    scope :active,   -> { where(status: %w[leased registered busy releasing]) }
    scope :finished, -> { where(status: %w[released errored]) }

    scope :for_node_instance, ->(instance) { where(node_instance: instance) }
    scope :for_workflow_run,  ->(run_id) { where(workflow_run_id: run_id) }
    scope :with_run_ref,      -> { where.not(workflow_run_id: nil) }
    scope :expired, -> { where.not(expires_at: nil).where(expires_at: ..Time.current) }
    scope :recent,  -> { order(created_at: :desc) }

    # === Lifecycle category checks ===
    def active?
      %w[leased registered busy releasing].include?(status)
    end

    def finished?
      %w[released errored].include?(status)
    end

    def expired?
      expires_at.present? && expires_at < Time.current
    end
  end
end
