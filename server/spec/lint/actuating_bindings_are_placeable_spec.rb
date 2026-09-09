# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 6 — the RATCHET behind
# environment_resolver_sensor_subjects_spec.rb.
#
# A side-effectful signal binding actuates the fleet without a person in the
# loop unless policy parks it, and policy varies by plane ONLY if
# System::EnvironmentResolver can place the executor inputs the binding's
# input_mapper produces. An unplaceable action is not refused and not escalated
# — Ai::EnvironmentResolution.resolve answers nil and the gate applies no
# overlay at all, which reads exactly like a passed gate.
#
# So this guard reads every actuating binding's mapper and asserts the KEYS it
# writes include at least one the resolver knows. It is a source census on
# purpose: calling each mapper would need a live fixture per signal kind, and
# what rots here is the KEY SPELLING a new binding chooses, which is visible
# statically. The behavioural half — that each subject kind resolves to the
# right plane — is the sibling spec above.
module ActuatingBindingLint
  R = ::System::EnvironmentResolver

  # Every params spelling the resolver can place a subject by.
  PLACEABLE_KEYS = (
    R::INSTANCE_KEYS + R::NODE_KEYS + R::TEMPLATE_KEYS + R::POOL_KEYS +
    R::PEER_KEYS + R::NETWORK_KEYS + R::VIRTUAL_IP_KEYS + R::CERTIFICATE_KEYS +
    R::FEDERATION_PEER_KEYS + R::ENVIRONMENT_KEYS +
    R::PLURAL_KEYS.keys.flatten + %w[task_attributes]
  ).uniq.freeze

  # Keyed on the signal kind so a rename forces re-acknowledgement rather than
  # silently widening the exemption.
  UNPLACEABLE_BY_DESIGN = {
    "system.governance_gap" =>
      "Proposes a campaign (dev.campaign_propose) out of a governance gap. It " \
      "touches no fleet row, so there is no plane to place it in and no " \
      "instance to count — the thing it writes is a proposal a person reads."
  }.freeze

  def self.mapper_keys(mapper)
    node = RubyVM::AbstractSyntaxTree.of(mapper)
    return [] if node.nil?

    file = mapper.source_location.first
    lines = File.readlines(file)[(node.first_lineno - 1)..(node.last_lineno - 1)] || []
    lines.join.scan(/([a-z_][a-z0-9_]*):\s/).flatten.uniq
  end
end

RSpec.describe "every actuating fleet binding is placeable in a plane" do
  let(:bindings) do
    ::System::Fleet::DecisionEngine::SIGNAL_BINDINGS.select { |_kind, b| b[:side_effectful] }
  end

  # Vacuity floor: the walk must find the surface. A refactor that renames
  # SIGNAL_BINDINGS or drops :side_effectful would otherwise pass over an empty
  # set and report nothing.
  it "finds the actuating bindings at all" do
    expect(bindings.size).to be >= 8
  end

  it "maps each one onto inputs the environment resolver can place" do
    unplaceable = bindings.filter_map do |kind, binding|
      next if ActuatingBindingLint::UNPLACEABLE_BY_DESIGN.key?(kind)

      mapper = binding[:input_mapper]
      next "#{kind}: no input_mapper" if mapper.nil?

      keys = ActuatingBindingLint.mapper_keys(mapper)
      next if keys.intersect?(ActuatingBindingLint::PLACEABLE_KEYS)

      "#{kind}: writes #{keys.inspect}, none of which the resolver can place"
    end

    expect(unplaceable).to be_empty, <<~MSG
      These bindings actuate the fleet in a plane the gate cannot see, so their
      per-environment escalation is silently off:

        #{unplaceable.join("\n        ")}

      Fix the resolver (System::EnvironmentResolver — add the subject kind) or
      the mapper (name the subject by a spelling it already knows). Add to
      ActuatingBindingLint::UNPLACEABLE_BY_DESIGN only for a binding that
      touches no fleet row at all, with the reason.
    MSG
  end

  it "keeps every exemption pointed at a binding that still exists and still actuates" do
    ActuatingBindingLint::UNPLACEABLE_BY_DESIGN.each_key do |kind|
      expect(bindings).to have_key(kind),
                          "#{kind} is exempted but is no longer a side-effectful binding — drop the exemption"
    end
  end
end
