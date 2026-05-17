# frozen_string_literal: true

module System
  # First-class service definition attached to a NodeModule. Modules ship
  # `manifest_yaml` in their OCI artifact as authoring source;
  # Module::OciIngestService parses `manifest_yaml#services` into rows
  # on ingest. The Go agent on-node reads manifest_yaml directly; the
  # platform queries the structured rows for the Platform Infrastructure
  # dashboard, scaling composer, and SDWAN VIP service discovery.
  #
  # Plan reference: §A in
  # ~/.claude/plans/the-powrnode-platform-consists-peppy-salamander.md
  class ModuleService < BaseRecord
    include System::Base

    RESTART_POLICIES = %w[always on-failure never].freeze
    HEALTH_METHODS   = %w[GET POST PUT].freeze

    belongs_to :node_module, class_name: "System::NodeModule"

    has_many :outgoing_dependencies,
             class_name: "System::ModuleServiceDependency",
             foreign_key: :module_service_id,
             inverse_of: :module_service,
             dependent: :destroy
    has_many :incoming_dependencies,
             class_name: "System::ModuleServiceDependency",
             foreign_key: :depends_on_module_service_id,
             inverse_of: :depends_on_module_service,
             dependent: :destroy
    has_many :dependencies,
             through: :outgoing_dependencies,
             source: :depends_on_module_service
    has_many :dependents,
             through: :incoming_dependencies,
             source: :module_service

    attribute :env,           :jsonb, default: -> { {} }
    attribute :exposed_ports, :jsonb, default: -> { [] }
    attribute :capabilities,  :jsonb, default: -> { [] }
    attribute :metadata,      :jsonb, default: -> { {} }

    validates :name, presence: true, length: { maximum: 100 },
                     uniqueness: { scope: :node_module_id }
    validates :start_command, presence: true
    validates :restart_policy, inclusion: { in: RESTART_POLICIES }
    validates :health_method, inclusion: { in: HEALTH_METHODS }
    validates :health_interval_seconds,      numericality: { greater_than: 0 }
    validates :health_timeout_seconds,       numericality: { greater_than: 0 }
    validates :health_initial_delay_seconds, numericality: { greater_than_or_equal_to: 0 }
    validate :account_matches_node_module

    scope :with_health_check, -> { where.not(health_endpoint: nil) }
    scope :exposes_port,      ->(port) { where("exposed_ports @> ?", [{ port: port }].to_json) }

    def http_health_url
      return nil if health_endpoint.blank?
      "#{health_method} #{health_endpoint}"
    end

    private

    # The denormalized account_id MUST match the parent NodeModule's account.
    # Service modules are tenant-scoped through their module; this guard
    # prevents drift if account_id is set incorrectly.
    def account_matches_node_module
      return unless node_module && account_id
      return if account_id == node_module.account_id
      errors.add(:account_id, "must match the parent node_module's account")
    end
  end
end
