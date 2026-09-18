# frozen_string_literal: true

require "rails_helper"

# IMP-7fbfb5a25e44 — regression guard for the ProxmoxProvider#sync_status
# incident (fixed in 76ae3fde/IMP-43f071c918e6): the method sat below
# `private`, so its explicit-receiver callers (instance_state_drift_sensor,
# node_instance_reconciliation, promote_replica_executor,
# instance_unrecoverable_sensor) raised NoMethodError into broad rescues —
# DR promote refused every Proxmox primary, the drift sensor went blind, index
# reconciliation never ran, and the provider_terminal arm of the unrecoverable
# sensor was unreachable.
#
# The root cause the visibility fix alone does not close: every caller spec
# stubs `instance_double("System::Providers::BaseProvider")`, and an
# instance_double is only as strict as the CLASS it doubles — it allows
# anything public on BaseProvider regardless of what a concrete subclass
# actually exposes. A subclass that re-privatizes (or removes) a public
# BaseProvider method stays invisible to every one of those specs. This spec
# is the one place that checks the real subclasses instead of the double.
#
# Scope: VISIBILITY only, not signatures. A subclass that redefines a public
# BaseProvider method with a different arity/keyword shape is not caught here.
RSpec.describe "System::Providers::BaseProvider public interface contract" do
  before(:all) { Rails.application.eager_load! }

  # Adapters Registry actually dispatches through (registry.rb:24-33), resolved
  # by constantize rather than relying on eager_load! to have reached every
  # adapter file.
  def registry_classes
    @registry_classes ||= System::Providers::Registry::PROVIDER_CLASSES.values.map(&:constantize)
  end

  # Named (non-anonymous) descendants only — excludes ad hoc
  # `Class.new(BaseProvider)` test fixtures (e.g. base_provider_spec.rb's
  # test_provider_class), which are real descendants for the run but are not
  # adapters this contract governs.
  def named_descendants
    @named_descendants ||= System::Providers::BaseProvider.descendants.select(&:name)
  end

  # Union of both sources: catches an adapter that exists but was never wired
  # into the registry, and doesn't depend on eager_load! alone reaching every
  # adapter file (the registry side is resolved explicitly via constantize).
  def concrete_subclasses
    @concrete_subclasses ||= registry_classes | named_descendants
  end

  def offenders_for(base_methods, singleton:)
    concrete_subclasses.flat_map do |klass|
      target = singleton ? klass.singleton_class : klass
      base_methods.filter_map do |method_name|
        next if target.public_method_defined?(method_name)

        visibility =
          if target.private_method_defined?(method_name)
            "private"
          elsif target.protected_method_defined?(method_name)
            "protected"
          else
            "undefined"
          end

        label = singleton ? "#{klass}.#{method_name}" : "#{klass}##{method_name}"
        "#{label} is #{visibility} (BaseProvider declares it public)"
      end
    end
  end

  it "keeps every BaseProvider public instance method public on every concrete subclass" do
    base_public_methods = System::Providers::BaseProvider.public_instance_methods(false)

    # Non-vacuity: kept inside this example (not a separate `it`) so running
    # it alone by line number, or via --only-failures, can't pass silently
    # over an empty method or subclass list.
    expect(base_public_methods).to include(:sync_status),
      "BaseProvider's public instance methods didn't include :sync_status — " \
      "the method list this spec derives from is wrong, not the code clean"
    expect(concrete_subclasses).to include(System::Providers::ProxmoxProvider),
      "the enumerated subclass set didn't include ProxmoxProvider — fix the enumeration, not this spec"
    expect(named_descendants).to include(*registry_classes),
      "BaseProvider.descendants is missing a class Registry::PROVIDER_CLASSES dispatches " \
      "through — an adapter exists without inheriting BaseProvider, or eager loading never reached it"

    offenders = offenders_for(base_public_methods, singleton: false)

    expect(offenders).to be_empty, <<~MSG
      A concrete provider subclass narrowed the visibility of an instance method
      BaseProvider declares public. Every caller that stubs
      `instance_double("System::Providers::BaseProvider")` stays green through
      this — the double is as permissive as the base class, not the real
      subclass — so this is the only check that catches it:

      #{offenders.join("\n")}
    MSG
  end

  it "keeps every BaseProvider public class method public on every concrete subclass" do
    base_public_class_methods = System::Providers::BaseProvider.singleton_class.public_instance_methods(false)

    # Same class of defect on the class-method side: Registry calls
    # provider_class.sdk_available? (registry.rb:52) with an explicit
    # receiver, so a subclass that re-privatizes a public BaseProvider class
    # method breaks the same way sync_status did.
    expect(base_public_class_methods).to include(:sdk_available?),
      "BaseProvider's public class methods didn't include :sdk_available? — " \
      "the method list this spec derives from is wrong, not the code clean"
    expect(concrete_subclasses).to include(System::Providers::ProxmoxProvider),
      "the enumerated subclass set didn't include ProxmoxProvider — fix the enumeration, not this spec"
    expect(named_descendants).to include(*registry_classes),
      "BaseProvider.descendants is missing a class Registry::PROVIDER_CLASSES dispatches " \
      "through — an adapter exists without inheriting BaseProvider, or eager loading never reached it"

    offenders = offenders_for(base_public_class_methods, singleton: true)

    expect(offenders).to be_empty, <<~MSG
      A concrete provider subclass narrowed the visibility of a class method
      BaseProvider declares public (Registry calls it with an explicit
      receiver — registry.rb:52 — so a private override raises NoMethodError):

      #{offenders.join("\n")}
    MSG
  end
end
