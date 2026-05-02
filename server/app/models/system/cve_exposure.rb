# frozen_string_literal: true

module System
  class CveExposure < BaseRecord
    self.table_name = "system_cve_exposures"

    STATES = %w[open remediating resolved wont_fix].freeze

    belongs_to :cve, class_name: "System::Cve", foreign_key: :cve_id
    belongs_to :node_module_version, class_name: "System::NodeModuleVersion",
               foreign_key: :node_module_version_id

    validates :package_name, presence: true
    validates :state, inclusion: { in: STATES }

    attribute :metadata, :json, default: -> { {} }

    scope :open,         -> { where(state: "open") }
    scope :remediating,  -> { where(state: "remediating") }
    scope :resolved,     -> { where(state: "resolved") }
    scope :unresolved,   -> { where(state: %w[open remediating]) }

    def resolve!(note: nil)
      update!(state: "resolved", resolved_at: Time.current, resolution_note: note)
    end

    def remediating!
      update!(state: "remediating")
    end
  end
end
