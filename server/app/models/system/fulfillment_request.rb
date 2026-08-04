# frozen_string_literal: true

module System
  # Campaign 019f6084 inc-M — the durable state machine behind on-demand
  # capability fulfillment. One row per "give me a running <X> instance" request.
  #
  # WHY THIS EXISTS (the TOCTOU fix): the previous synchronous skill computed a
  # plan, returned it for approval, and on the *approved* re-invocation
  # RE-COMPOSED the plan from scratch — so what an operator approved and what
  # actually executed could differ (a new module could have appeared, a package
  # could have moved). Here the composed plan is FROZEN in `plan["execution"]` at
  # creation; approval is the out-of-band `approve!` transition on THIS persisted
  # row, and System::FulfillmentAdvanceOrchestrator only ever replays the frozen
  # plan. Approved plan ≡ executed plan, always.
  #
  # SEMANTICS: like System::ModuleBuildBatch, this is bookkeeping + status
  # aggregation over a multi-step run — it does not execute anything itself
  # (the orchestrator does). Every artifact the run creates (build batch,
  # template, instances, materialized modules) is recorded here so a failure can
  # be rolled back cleanly and every run is resumable. "Auditable" here means
  # exactly two things and no more: the artifact/timestamp ladder on this row,
  # and the `system.fulfillment_approved` FleetEvent that `approve_by!` emits
  # (carrying the approver + a digest of the frozen plan). This subsystem writes
  # NO AuditLog rows — do not describe it as audit-logged.
  #
  # AASM mirrors System::ModuleBuildBatch / System::CiRunnerLease: each event
  # stamps its own timestamp column via a `before` block so the single AASM
  # transition save persists state + timestamp atomically.
  class FulfillmentRequest < BaseRecord
    include System::Base
    include AASM

    self.table_name = "system_fulfillment_requests"

    # === Constants ===
    STATES = %w[composed approved materializing building templated
                provisioning smoking ready failed expired].freeze
    # Non-terminal states the sweep may drive forward. `composed` is excluded:
    # it is waiting on an out-of-band approval, not on the orchestrator.
    ADVANCEABLE_STATES = %w[approved materializing building templated provisioning smoking].freeze
    TERMINAL_STATES = %w[ready failed expired].freeze

    # === Associations ===
    belongs_to :account
    belongs_to :requested_by_user, class_name: "User", optional: true
    belongs_to :approved_by_user, class_name: "User", optional: true

    # === Validations ===
    validates :state, presence: true, inclusion: { in: STATES }
    validates :request, presence: true

    # === State machine ===
    aasm column: :state, whiny_transitions: true do
      state :composed, initial: true
      state :approved
      state :materializing
      state :building
      state :templated
      state :provisioning
      state :smoking
      state :ready
      state :failed
      state :expired

      # Out-of-band approval of the FROZEN plan (kills the TOCTOU — this is the
      # single recorded decision — see approve_by!, which stamps the approver and
      # emits the approval event; the orchestrator replays plan["execution"]).
      event :approve do
        transitions from: :composed, to: :approved
        before { self.approved_at = Time.current }
      end

      # The approved→materializing gate is where the budget + rate-limit checks
      # live (see FulfillmentAdvanceOrchestrator#advance_approved).
      event :start_materializing do
        transitions from: :approved, to: :materializing
        before { self.materializing_at = Time.current }
      end

      event :start_building do
        transitions from: :materializing, to: :building
        before { self.building_at = Time.current }
      end

      # Reachable from :materializing too — an all-reused request (no gaps to
      # materialize, no build batch) skips the build barrier entirely.
      event :mark_templated do
        transitions from: [ :building, :materializing ], to: :templated
        before { self.templated_at = Time.current }
      end

      event :start_provisioning do
        transitions from: :templated, to: :provisioning
        before { self.provisioning_at = Time.current }
      end

      event :start_smoking do
        transitions from: :provisioning, to: :smoking
        before { self.smoking_at = Time.current }
      end

      event :mark_ready do
        transitions from: :smoking, to: :ready
        before { self.ready_at = Time.current }
      end

      # Terminal failure from any in-flight state (mirrors ModuleBuildBatch#fail).
      # The orchestrator performs the rollback BEFORE calling this.
      event :fail do
        transitions from: [ :composed, :approved, :materializing, :building,
                            :templated, :provisioning, :smoking ], to: :failed
        before do |message = nil|
          self.failed_at = Time.current
          self.error = message if message
        end
      end

      # Lease elapsed — the reaper terminated the run's instances. Reachable from
      # `ready` (the common case) and from any in-flight state (a stuck request
      # whose record-level lease elapsed before it ever finished).
      event :expire do
        transitions from: [ :composed, :approved, :materializing, :building,
                            :templated, :provisioning, :smoking, :ready ], to: :expired
        before { self.expired_at = Time.current }
      end
    end

    # === Scopes ===
    scope :by_state, ->(state) { where(state: state) }
    scope :advanceable, -> { where(state: ADVANCEABLE_STATES) }
    scope :open, -> { where.not(state: TERMINAL_STATES) }
    scope :recent, -> { order(created_at: :desc) }

    # === Class methods ===

    # Build a `composed` request with the plan FROZEN. `plan` MUST carry a
    # replayable `plan["execution"]` context (base-os id, reused module ids, gap
    # descriptors, resolved region/type ids, template name) — the orchestrator
    # replays exactly that and never re-composes.
    def self.create_composed!(account:, request:, plan:, cost_estimate:,
                              reused_modules:, lease_ttl_seconds:, requested_by_user: nil)
      reused = Array(reused_modules)
      create!(
        account: account,
        requested_by_user_id: requested_by_user&.id,
        request: request,
        state: "composed",
        plan: plan,
        cost_estimate: cost_estimate || {},
        reused_modules: reused,
        reused_count: reused.size,
        materialized_modules: [],
        materialized_module_ids: [],
        node_instance_ids: [],
        parked: [],
        lease_ttl_seconds: lease_ttl_seconds
      )
    end

    # === Instance methods ===

    def active?
      !TERMINAL_STATES.include?(state)
    end

    def terminal?
      TERMINAL_STATES.include?(state)
    end

    # The replayable execution context frozen at compose time (string-keyed —
    # it round-trips through jsonb).
    def execution
      (plan || {})["execution"] || {}
    end

    # The build batch this run dispatched (plain-uuid lookup — build_batch_id is
    # not FK-backed, mirroring CiRunnerLease#git_runner_id).
    def build_batch
      return nil if build_batch_id.blank?
      ::System::ModuleBuildBatch.find_by(id: build_batch_id)
    end

    def gate_blocked?
      approved? && Array(parked).any? { |p| %w[budget_gate rate_limit_gate].include?(p["step"]) }
    end

    # THE audited approval. Use this rather than the bare `approve!` event so the
    # decision leaves a trail: who released the frozen plan, when, and a digest of
    # the exact plan bytes released. `user` is nil for the autonomous executor path
    # (`approved: true`), which `source` then distinguishes from an operator.
    #
    # approved_by_user_id is assigned BEFORE the transition so AASM's single
    # transition save persists state + approved_at + approver atomically — the
    # same idiom the `before` blocks above rely on.
    def approve_by!(user: nil, source: "operator_ui")
      self.approved_by_user_id = user&.id
      approve!
      emit_approved_event!(user: user, source: source)
      self
    end

    # sha256 over the canonical frozen plan. Lets an auditor prove the plan that
    # executed is the plan that was approved without storing a second copy.
    def plan_digest
      ::Digest::SHA256.hexdigest((plan || {}).to_json)
    end

    # --- recording helpers (the orchestrator's persistence seam) ---

    def record_materialization!(module_ids:, module_names:, build_batch:)
      names = Array(module_names)
      update!(
        materialized_modules: names,
        materialized_module_ids: Array(module_ids),
        materialized_count: names.size,
        build_batch_id: build_batch&.id
      )
    end

    def record_template!(template)
      update!(template_id: template.id)
    end

    def record_instances!(ids)
      ids = Array(ids)
      update!(node_instance_ids: ids, instance_count: ids.size)
    end

    def record_smoke!(result)
      update!(smoke: result)
    end

    # Append a park note (honest "did not silently skip" trail). Deduped by
    # (step, reason) so a resumed/re-ticked run doesn't stack identical notes.
    def add_park!(step:, reason:)
      note = { "step" => step.to_s, "reason" => reason.to_s, "at" => Time.current.iso8601 }
      current = Array(parked)
      return if current.any? { |p| p["step"] == note["step"] && p["reason"] == note["reason"] }
      update!(parked: current + [ note ])
    end

    # Gate rejection: record the reason but DO NOT transition — the request stays
    # `approved` and is re-evaluated on the next tick (a rate limit clears next
    # hour; a budget cap clears if the operator raises it). Resumable by design.
    def park_gate!(step:, reason:)
      add_park!(step: step, reason: reason)
      update!(error: reason)
    end

    # Per-instance lease summaries reconstructed from the leased instances'
    # config blobs (the durable per-instance lease detail).
    def lease_summaries
      ::System::NodeInstance.where(account_id: account_id, id: Array(node_instance_ids)).map do |inst|
        lease = (inst.config || {})["fulfillment_lease"] || {}
        lease.merge(
          "instance_id" => inst.id,
          "pool_state" => inst.try(:pool_state),
          "lifecycle_class" => inst.try(:lifecycle_class),
          "lease_expires_at" => inst.try(:lease_expires_at)&.iso8601
        )
      end
    end

    # The fulfillment subsystem wrote NO audit trail of any kind before this —
    # no AuditLog, no FleetEvent — so a provisioning run that spent real money
    # had no record of who authorized it. FleetEvent is the extension's
    # operator-action trail (same seam as CiWorkersController's token-rotation
    # event), and emit! swallows its own failures, so a broken sink can never
    # block an approval that already committed.
    def emit_approved_event!(user:, source:)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account: account,
        kind: "system.fulfillment_approved",
        severity: :medium,
        source: source,
        payload: {
          fulfillment_request_id: id,
          request: request,
          approved_by_user_id: approved_by_user_id,
          autonomous: user.nil?,
          plan_digest: plan_digest,
          unresolved_gap_count: Array((plan || {})["unresolved_gaps"]).size,
          cost_estimate: cost_estimate
        }
      )
    rescue StandardError => e
      Rails.logger.warn("[FulfillmentRequest] approved event emit failed: #{e.class}: #{e.message}")
    end

    def summary
      {
        id: id, state: state, request: request,
        reused_count: reused_count, materialized_count: materialized_count,
        instance_count: instance_count,
        build_batch_id: build_batch_id, template_id: template_id,
        node_instance_ids: node_instance_ids,
        expires_at: expires_at, error: error, parked: parked, smoke: smoke,
        approved_at: approved_at, approved_by_user_id: approved_by_user_id,
        created_at: created_at
      }
    end
  end
end
