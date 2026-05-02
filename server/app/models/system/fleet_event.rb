# frozen_string_literal: true

module System
  class FleetEvent < BaseRecord
    self.table_name = "system_fleet_events"

    SEVERITIES = %w[low medium high critical].freeze

    belongs_to :account

    validates :kind, presence: true
    validates :severity, presence: true, inclusion: { in: SEVERITIES }

    attribute :payload, :json, default: -> { {} }

    scope :recent,           -> { order(emitted_at: :desc) }
    scope :by_kind,          ->(kind) { where(kind: kind) }
    scope :by_correlation,   ->(corr) { where(correlation_id: corr) }
    scope :high_or_critical, -> { where(severity: %w[high critical]) }
    scope :for_instance,     ->(id) { where(node_instance_id: id) }
    scope :for_module,       ->(id) { where(node_module_id: id) }
    scope :since,            ->(t) { where("emitted_at >= ?", t) }

    # Severity weight for cross-event ranking (matches Signal::SEVERITY_WEIGHTS
    # so dashboards rank consistently with autonomy decisions).
    def severity_weight
      ::System::Fleet::Signal::SEVERITY_WEIGHTS[severity.to_sym]
    end

    # Convenience for ActionCable broadcasts — produces a stable shape that
    # frontends can subscribe to without re-deriving fields.
    def as_broadcast
      {
        id: id,
        kind: kind,
        severity: severity,
        node_id: node_id,
        node_instance_id: node_instance_id,
        node_module_id: node_module_id,
        node_module_version_id: node_module_version_id,
        certificate_id: certificate_id,
        cve_id: cve_id,
        payload: payload,
        correlation_id: correlation_id,
        source: source,
        emitted_at: emitted_at.iso8601(3),
        account_id: account_id
      }
    end
  end
end
