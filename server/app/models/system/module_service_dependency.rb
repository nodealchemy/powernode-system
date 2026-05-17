# frozen_string_literal: true

module System
  # Directed edge between two ModuleServices in the SAME NodeModule.
  # Declares ordering or readiness constraints for service startup on-node.
  #
  # kind semantics:
  #   - start_before:    target must be running (PID alive) before source starts
  #   - requires_health: target must pass its health check before source starts
  #   - softdep:         target preferred-running but not required (best-effort)
  class ModuleServiceDependency < BaseRecord
    KINDS = %w[start_before requires_health softdep].freeze

    belongs_to :module_service,
               class_name: "System::ModuleService",
               inverse_of: :outgoing_dependencies
    belongs_to :depends_on_module_service,
               class_name: "System::ModuleService",
               inverse_of: :incoming_dependencies

    # ModuleService already carries account_id; this edge doesn't duplicate it.
    delegate :account, :account_id, to: :module_service

    validates :kind, inclusion: { in: KINDS }
    validates :module_service_id, uniqueness: { scope: :depends_on_module_service_id,
                                                message: "already depends on this service" }
    validate :not_self_referential
    validate :same_node_module
    validate :no_circular_dependency

    scope :start_ordering, -> { where(kind: %w[start_before requires_health]) }

    private

    def not_self_referential
      return unless module_service_id == depends_on_module_service_id
      errors.add(:depends_on_module_service_id, "can't depend on itself")
    end

    def same_node_module
      return unless module_service && depends_on_module_service
      return if module_service.node_module_id == depends_on_module_service.node_module_id
      errors.add(:depends_on_module_service_id,
                 "must belong to the same node_module as the dependent service")
    end

    # O(N) walk through outgoing_dependencies. ModuleService graphs are small
    # (typically <10 services per module), so we don't need a more clever
    # cycle detector here.
    def no_circular_dependency
      return unless depends_on_module_service && module_service
      return unless reachable_from?(depends_on_module_service, target: module_service)
      errors.add(:depends_on_module_service_id, "would create a circular dependency")
    end

    def reachable_from?(start_service, target:, visited: Set.new)
      return false if visited.include?(start_service.id)
      visited << start_service.id
      return true if start_service.id == target.id

      start_service.dependencies.any? do |dep|
        reachable_from?(dep, target: target, visited: visited)
      end
    end
  end
end
