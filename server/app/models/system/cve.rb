# frozen_string_literal: true

module System
  class Cve < BaseRecord
    self.table_name = "system_cves"

    SEVERITIES = %w[critical high medium low unknown].freeze

    has_many :cve_exposures, class_name: "System::CveExposure", foreign_key: :cve_id, dependent: :destroy
    has_many :exposed_module_versions, through: :cve_exposures, source: :node_module_version

    validates :cve_id, presence: true, uniqueness: true,
              format: { with: /\ACVE-\d{4}-\d{4,}\z/, message: "must match CVE-YYYY-NNNN format" }
    validates :severity, presence: true, inclusion: { in: SEVERITIES }

    attribute :affected_packages, :json, default: -> { [] }
    attribute :metadata, :json, default: -> { {} }

    scope :critical, -> { where(severity: "critical") }
    scope :high,     -> { where(severity: "high") }
    scope :recent,   -> { order(published_at: :desc) }
    scope :open_exposure, -> { joins(:cve_exposures).where(system_cve_exposures: { state: "open" }).distinct }

    # Severity-weighted score for risk prioritization. Mirrors
    # CveResponseExecutor::SEVERITY_WEIGHT for consistency.
    def severity_weight
      case severity
      when "critical" then 100
      when "high"     then 60
      when "medium"   then 30
      when "low"      then 10
      else 0
      end
    end

    # Returns the list of affected_packages with stringified keys for
    # consistent matching with module SBOMs.
    def normalized_affected_packages
      Array(affected_packages).map { |p| p.is_a?(Hash) ? p.with_indifferent_access : { "name" => p.to_s } }
    end
  end
end
