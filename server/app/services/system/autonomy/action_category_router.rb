# frozen_string_literal: true

module System
  module Autonomy
    # WHICH ACTION CATEGORIES DOES THE PLATFORM ROUTE?
    #
    # System::Autonomy::RoutedLaneGuard needs that set to tell two failures
    # apart: a lane the code routes to but this database has no
    # Ai::InterventionPolicy row for (a DEPLOY DEFECT — db:seed is
    # first-boot-only, so a policy added to a seed afterwards never reaches an
    # already-running host) from an ordinary refusal of a category nothing
    # routes.
    #
    # IT ASKED ONE SOURCE, AND THERE WERE TWO ROUTERS (IMP-7a6c9a70e050).
    # DecisionEngine::SIGNAL_BINDINGS was treated as the whole routed set, but
    # System::AdaptationGate maps a change_type onto `project.<change_type>`
    # and hands it to the same FleetAutonomyService#gate_action!. Four of those
    # categories — project.relocate, project.schema_change,
    # project.security_change, project.scale_horizontal — are named by no
    # signal binding, so a missing policy row for them took the quiet arm and
    # the adaptation lane raised "blocked by policy" for a lane no policy had
    # ever answered. An operator was sent to tune a row that did not exist when
    # the fix was re-running a seed.
    #
    # WHY A DECLARATION SEAM RATHER THAN A LONGER LIST
    #
    # Appending AdaptationGate's categories to the routed set would close those
    # four and leave the NEXT routing surface equally invisible — the same
    # "fixed on one, missed on the other" drift RoutedLaneGuard itself exists
    # to end. So routing is DECLARED by the router:
    #
    #   class SomeRouter
    #     extend System::Autonomy::ActionCategoryRouter
    #
    #     def self.routed_action_categories = [...]
    #   end
    #
    # Extension is an OBSERVABLE PROPERTY (`Klass.singleton_class.include?`),
    # so adoption can be enumerated and enforced rather than remembered — the
    # same reason RoutedLaneGuard is a mixin and not a class method.
    # `action_category_router_spec.rb` DISCOVERS routers by scanning this
    # extension for classes that CALL gate_action!, and reds when one of them
    # is missing from ROUTERS. A third router therefore fails loudly the first
    # time its author runs the suite, instead of silently inheriting the gap.
    #
    # WHY ROUTERS IS AN EXPLICIT NAME LIST AND NOT AN `extended` HOOK REGISTRY
    #
    # Zeitwerk loads lazily. A registry populated as a side effect of class
    # loading is EMPTY until something happens to have referenced the class, so
    # `router_for` would answer differently depending on what else the
    # process had touched — non-deterministic in exactly the direction that
    # reintroduces the silent block. Naming the routers resolves them (and
    # therefore autoloads them) on demand, and the discovery spec is what keeps
    # the list honest.
    module ActionCategoryRouter
      ROUTERS = %w[
        System::AdaptationGate
        System::Fleet::DecisionEngine
      ].freeze

      def self.routers
        ROUTERS.map(&:constantize)
      end

      # The set RoutedLaneGuard reads. Union, so a category either router names
      # is routed.
      def self.routed_action_categories
        routers.flat_map(&:routed_action_categories).uniq.freeze
      end

      # WHICH router routes this? The misconfiguration alarm has to say, or it
      # sends the operator to the wrong constant — the same wrong-destination
      # failure this whole seam is about. The alarm named DecisionEngine
      # unconditionally, which is false for exactly the four categories
      # IMP-7a6c9a70e050 is about.
      #
      # @return [Class, nil] nil when nothing routes it, which the caller
      #   treats as "not a routed lane" rather than guessing.
      def self.router_for(action_category)
        routers.find { |r| r.routed_action_categories.include?(action_category) }
      end

      # The contract a router must satisfy. Extending without declaring is a
      # mistake that must NOT degrade to an empty set: an empty declaration is
      # silently permissive — it puts that router's lanes straight back in the
      # quiet arm this seam exists to drain.
      def routed_action_categories
        raise NotImplementedError,
              "#{name} extends System::Autonomy::ActionCategoryRouter but declares no " \
              "routed_action_categories — every category it hands to gate_action! must be named " \
              "here, or a missing policy row for it is reported as an operator's deliberate block"
      end
    end
  end
end
