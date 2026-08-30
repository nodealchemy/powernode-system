# frozen_string_literal: true

module System
  module Fleet
    # Ground-truth effectiveness record for an autonomous remediation (substrate
    # self-improvement, Phase 0 — the validate step).
    #
    # When the fleet autonomy loop PROCEEDs an action for a signal, it records a
    # pending outcome keyed by the signal's fingerprint. A later tick re-senses:
    # if the fingerprint is gone the remediation was EFFECTIVE; if it still fires
    # it was INEFFECTIVE. This is the ground truth the LEARN/ADAPT steps (later
    # phases) consume — you can't improve on actions you never measured.
    class RemediationOutcome < BaseRecord
      self.table_name = "system_fleet_remediation_outcomes"

      STATUSES = %w[pending effective ineffective inconclusive].freeze

      belongs_to :account

      validates :signal_kind, :fingerprint, :acted_at, :settle_until, presence: true
      validates :status, inclusion: { in: STATUSES }

      attribute :metadata, :jsonb, default: -> { {} }

      scope :pending,   -> { where(status: "pending") }
      scope :effective, -> { where(status: "effective") }
      scope :due,       -> { pending.where(settle_until: ..Time.current) }

      def effective?   = status == "effective"
      def ineffective? = status == "ineffective"

      # Score for the LEARN step: effective -> 1.0, ineffective -> 0.0, else nil
      # (pending/inconclusive carry no signal yet).
      def effectiveness_score
        case status
        when "effective" then 1.0
        when "ineffective" then 0.0
        end
      end

      # IMP-848c7e953e2d — how long a settled deferral keeps blocking.
      #
      # THIS WINDOW IS LOAD-BEARING, NOT A TUNABLE. Without it the block is
      # permanent, and permanent is worse than the noise it replaces: the
      # branch that reads this returns BEFORE the gate, so a blocked
      # fingerprint can never PROCEED, and only a PROCEEDED decision mints an
      # outcome (RemediationValidator#record_proceeded!) — so no newer settled
      # row can ever exist to lift the block. The streak lane has a real escape
      # (it keeps proceeding below the threshold, so a reboot between windows
      # produces an `effective` row and take_while resets); this lane has none,
      # because one deferral is enough to stop it. And the fingerprint is
      # per-instance, not per-drift (`module_drift:<instance_id>`), so an
      # unbounded block would silently disable autonomous remediation on that
      # instance for every FUTURE, live-fixable drift as well.
      #
      # The value is a statement about EVIDENCE, not about reboot schedules:
      # how long we are willing to keep asserting "this node still needs the
      # reboot we asked for" on the strength of one old row before dropping
      # back to measuring. Much longer than DecisionEngine::DEDUP_TTL_SECONDS
      # so the escalation is not re-raised every cycle; much shorter than the
      # outcome retention sweep so a row cannot block for the life of a node.
      DEFERRED_BLOCK_WINDOW = (ENV["FLEET_DEFERRED_BLOCK_SECONDS"] || 24 * 60 * 60).to_i

      # IMP-848c7e953e2d — the deferred lane's brake, and the counterpart to
      # #ineffective_streak below. A remediation that DECLARED it could not
      # converge settles `inconclusive`, which is deliberately held out of the
      # streak — so without this the lane would have no operator surface at
      # all, and re-proceeding would be futile forever in silence. True when
      # the most recently SETTLED outcome for this fingerprint is a deferred
      # one AND that row is younger than DEFERRED_BLOCK_WINDOW;
      # DecisionEngine#decide reads it pre-gate and routes into the SAME
      # escalate_stuck_remediation! lane the streak uses.
      #
      # "Most recently settled" means a later row that DID score — one written
      # after the window lapses and the lane resumes proceeding — takes over,
      # the way take_while does for the streak. It cannot do so while the block
      # stands, which is exactly why the window exists.
      #
      # Ordered by id as well as validated_at: the two rows either side of a
      # resumption can settle in the same tick, and UUIDv7 ids sort by
      # creation time, so this is a deterministic tie-break rather than
      # whichever row Postgres returns first.
      def self.deferred_convergence?(account:, fingerprint:)
        last = where(account: account, fingerprint: fingerprint)
               .where.not(validated_at: nil)
               .order(validated_at: :desc, id: :desc)
               .first
        return false unless last&.status == "inconclusive"
        return false if last.validated_at < DEFERRED_BLOCK_WINDOW.seconds.ago

        last.metadata.is_a?(Hash) && last.metadata["convergence_deferred"].present?
      end

      # F3-11 — consecutive ineffective count for a fingerprint, newest first,
      # stopping at the first effective outcome. This is the feedback signal
      # the DecisionEngine's stuck-escalation consumer reads: N validated
      # remediations in a row that did NOT clear the signal mean re-proceeding
      # is futile and the action needs an operator.
      def self.ineffective_streak(account:, fingerprint:, limit: 10)
        where(account: account, fingerprint: fingerprint)
          .where(status: %w[effective ineffective])
          .order(validated_at: :desc)
          .limit(limit)
          .pluck(:status)
          .take_while { |s| s == "ineffective" }
          .size
      end
    end
  end
end
