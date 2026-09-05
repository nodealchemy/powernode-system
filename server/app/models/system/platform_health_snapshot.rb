# frozen_string_literal: true

module System
  # One composite platform-health observation.
  #
  # Written by System::Platform::CompositeHealthProbe on every run. The row is
  # a RECORD OF WHAT WAS OBSERVED, not a verdict to be trusted on its own: a
  # subsystem the probe could not reach is stored as `not_measured`, and
  # `overall` never reports "ok" while any subsystem carries that status. See
  # the probe for the ranking.
  class PlatformHealthSnapshot < BaseRecord
    # `unknown` is what a run reports when nothing was observed to be wrong and
    # something could not be observed at all. It is separate from `degraded`
    # because blindness and observed degradation are different facts and an
    # operator acts differently on each.
    OVERALLS = %w[ok degraded down unknown].freeze

    belongs_to :account

    validates :overall, presence: true, inclusion: { in: OVERALLS }
    validates :captured_at, presence: true

    attribute :subsystems, :json, default: -> { {} }

    scope :for_account, ->(account) { where(account: account) }
    scope :since,       ->(time) { where("captured_at >= ?", time) }
    scope :recent,      -> { order(captured_at: :desc) }
    scope :not_ok,      -> { where.not(overall: "ok") }

    # The subsystem names at a given status, as symbols — the same shape the
    # probe returns, so a caller reading a stored row and a caller reading a
    # live run can share code.
    def subsystems_at(status)
      subsystems.select { |_name, entry| entry.is_a?(Hash) && entry["status"].to_s == status.to_s }
                .keys.map(&:to_sym)
    end

    def healthy?
      overall == "ok"
    end
  end
end
