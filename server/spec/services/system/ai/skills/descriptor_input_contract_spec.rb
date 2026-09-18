# frozen_string_literal: true

require "rails_helper"

# IMP-702d27f2d384 — the anti-drift guard for the skill descriptor contract.
#
# `Ai::Skill#executor_descriptor` (core) now derives a skill's declared
# inputs LIVE from its executor's `skill_descriptor(inputs: {...})` at read
# time, so the descriptor itself cannot drift from what `#perform` actually
# accepts... unless the descriptor is wrong to begin with. This spec is what
# catches THAT: it enumerates every concrete executor and asserts, by
# reflection on `#perform`'s own keyword parameters, that the descriptor
# tells the truth about what the executor accepts. `CveResponseExecutor`
# accepted `persist:` for a full seed cycle with no descriptor entry and no
# mention in the seeded system_prompt — this spec would have failed on that
# code the day it landed.
#
# A `#perform` keyword an executor's own author decided NOT to expose (a
# destructive flag re-gated at runtime, an orchestrator-injected value, a
# legacy alias that would create ambiguity if declared twice) is not a bug —
# but a keyword silently missing from BOTH the descriptor AND any
# explanation is indistinguishable from one. `intentionally_hidden_inputs:`
# (a `skill_descriptor` extra, forwarded verbatim via `**extras`) is the
# named escape hatch: every entry needs a reason, and EXPECTED_HIDDEN_INPUTS
# below is the second, central place that hatch has to be exercised through.
#
# EXACT MATCH is the load-bearing property on both checks below:
#   1. actual "perform accepts it, descriptor doesn't declare it" keywords
#      == the executor's own `intentionally_hidden_inputs` keys (mechanical:
#      a keyword can't fall through uncovered, and a hidden entry can't
#      point at a keyword `#perform` no longer accepts).
#   2. the executor's own `intentionally_hidden_inputs` keys ==
#      EXPECTED_HIDDEN_INPUTS[class] (central inventory: adding OR removing
#      a hidden input inside an executor file reddens this spec until
#      someone edits the reviewable list below — a subset check would let
#      the list grow silently and defeat the point).
RSpec.describe "System skill executor descriptor input contract" do
  # Central, reviewable inventory of every (executor, perform-keyword) pair
  # that is deliberately NOT a descriptor input. This is the one place a
  # reviewer can read in one sitting to ask "is five hidden inputs still the
  # right number" — it does not duplicate the reason prose (that lives once,
  # on the executor, checked for non-blankness below) so there is exactly
  # one place per hidden input where the reason can go stale.
  EXPECTED_HIDDEN_INPUTS = {
    "System::Ai::Skills::PackageRepositorySyncExecutor" => %w[force],
    "System::Ai::Skills::ProvisionFullStackExecutor" => %w[storage_gb name_prefix mission_id],
    "System::Ai::Skills::RelocateWorkloadExecutor" => %w[storage_gb],
    "System::Ai::Skills::ScaleProjectExecutor" => %w[storage_gb]
  }.freeze

  described_classes = System::Ai::Skills::BaseSkillExecutor.all_concrete_executors

  it "enumerates at least one executor (a zero-length list would make every example below vacuously pass)" do
    expect(described_classes).not_to be_empty
  end

  described_classes.each do |klass|
    describe klass.name do
      # Class-body `next` (not inside the `it`) so a class with no `perform`
      # of its own — none exist today, but a future abstract intermediate
      # under the same directory glob should skip cleanly rather than raise
      # `NameError` reflecting on a method it doesn't define — doesn't break
      # the suite.
      next unless klass.instance_methods(false).include?(:perform) ||
                  klass.protected_instance_methods(false).include?(:perform) ||
                  klass.private_instance_methods(false).include?(:perform)

      perform_params = klass.instance_method(:perform).parameters
      required_kw = perform_params.select { |type, _| type == :keyreq }.map { |_, n| n.to_s }
      optional_kw = perform_params.select { |type, _| type == :key }.map { |_, n| n.to_s }
      has_kwrest  = perform_params.any? { |type, _| type == :keyrest }
      all_perform_kw = required_kw + optional_kw

      declared = (klass.descriptor[:inputs] || {}).transform_keys(&:to_s)
      own_hidden = (klass.descriptor[:intentionally_hidden_inputs] || {}).transform_keys(&:to_s)
      expected_hidden = (EXPECTED_HIDDEN_INPUTS[klass.name] || []).sort

      it "declares every required perform keyword as a required descriptor input" do
        wrongly_optional = required_kw.select { |k| declared[k] && declared[k][:required] != true }
        expect(wrongly_optional).to be_empty,
          "#{klass.name}: perform requires #{wrongly_optional.inspect} but the descriptor " \
          "does not mark #{wrongly_optional.size == 1 ? 'it' : 'them'} required:true"
      end

      it "has no descriptor input perform cannot accept" do
        next if has_kwrest # a catch-all perform(**extra) accepts any key — nothing to flag

        extra = declared.keys - all_perform_kw
        expect(extra).to be_empty,
          "#{klass.name}: descriptor declares #{extra.inspect} but perform does not accept " \
          "#{extra.size == 1 ? 'it' : 'them'} as a keyword argument"
      end

      it "accounts for every perform keyword as either a declared input or a reasoned intentionally_hidden_inputs entry" do
        actual_undeclared = (all_perform_kw - declared.keys).sort
        expect(actual_undeclared).to eq(own_hidden.keys.sort),
          "#{klass.name}: perform accepts #{actual_undeclared.inspect} that the descriptor " \
          "neither declares as an input nor lists in intentionally_hidden_inputs — this is " \
          "the exact drift class IMP-702d27f2d384 exists to catch (see CveResponseExecutor's " \
          "prior `persist:` gap)"
      end

      it "gives every intentionally_hidden_inputs entry a non-empty reason" do
        blank = own_hidden.select { |_k, reason| reason.to_s.strip.empty? }.keys
        expect(blank).to be_empty,
          "#{klass.name}: intentionally_hidden_inputs #{blank.inspect} has no reason — a bare " \
          "name tells a future reader nothing about whether the omission is still justified"
      end

      it "matches the central EXPECTED_HIDDEN_INPUTS inventory exactly" do
        expect(own_hidden.keys.sort).to eq(expected_hidden),
          "#{klass.name}: declares intentionally_hidden_inputs #{own_hidden.keys.sort.inspect} " \
          "but the central inventory (descriptor_input_contract_spec.rb) expects " \
          "#{expected_hidden.inspect} — a hidden input must be added to (or removed from) " \
          "BOTH places together, never just the executor file"
      end
    end
  end

  it "has no stray EXPECTED_HIDDEN_INPUTS entry for an executor that no longer exists or no longer hides that input" do
    described_names = described_classes.map(&:name)
    EXPECTED_HIDDEN_INPUTS.each do |class_name, names|
      klass = class_name.safe_constantize
      expect(described_names).to include(class_name),
        "EXPECTED_HIDDEN_INPUTS names #{class_name}, which no longer resolves to a concrete executor"
      next unless klass

      own_hidden_keys = (klass.descriptor[:intentionally_hidden_inputs] || {}).transform_keys(&:to_s).keys.sort
      expect(own_hidden_keys).to eq(names.sort),
        "EXPECTED_HIDDEN_INPUTS[#{class_name.inspect}] = #{names.inspect} but the executor's own " \
        "intentionally_hidden_inputs is #{own_hidden_keys.inspect}"
    end
  end
end
