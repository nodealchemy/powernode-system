# frozen_string_literal: true

require "rails_helper"

# IMP-51e5c6184ae4 — ONE SPELLING per autonomy action.
#
# THE DEFECT THIS EXISTS FOR
#
# An operator tunes an action through exactly one row: PATCH
# /api/v1/system/autonomy writes `Ai::InterventionPolicy` keyed on
# action_category, and every gate resolves that same string. So two spellings of
# one action are two INDEPENDENT controls over the same behaviour, and the
# operator has no way to see that. Tuning `system.architecture.delete` down to
# notify_and_proceed left the gated ArchitectureDeleteExecutor — which resolved
# `system.architecture_delete` — still parking an approval, and nothing anywhere
# reported the disagreement.
#
# Both spellings shipped registered: the dotted family came from the seeded
# FLEET_AUTONOMY_POLICIES rows, the underscored one from APO-1c, which derived a
# gated executor's category as "<domain>.<skill name>" and then had to register
# what it derived. System::AutonomyActions::DOMAIN_PREFIXES pivoted both into a
# single "architecture" domain, which made the modal render them side by side —
# visible, but as two controls, not as one control spelled twice.
#
# WHY A NORMALISED SET AND NOT A LIST OF KNOWN PAIRS
#
# `.` and `_` are the only two separators this vocabulary uses, and neither
# carries meaning the other does not: `system.architecture.delete` and
# `system.architecture_delete` are the same words in the same order. Collapsing
# both to one separator therefore maps every spelling of an action onto one key,
# so the assertion catches the NEXT pair without anyone having to notice it —
# which is the whole failure mode here, since a derived category is minted by a
# descriptor default rather than written down beside the row it collides with.
RSpec.describe "PowernodeSystem autonomy category spelling uniqueness", type: :lib do
  # Deliberately `let`, not constants: a bare constant assigned inside a
  # describe block lands on Object, and a generic name there is the
  # duplicate-constant clobber that makes suites order-dependent.

  # `system.` and `sdwan.` only. `project.` is in the extension's owned-prefix
  # list for the orphan sweep but its categories are core-owned
  # (Ai::InterventionPolicy::STATIC_CATEGORIES), and this extension cannot
  # rename them — asserting over them would file core's spelling as this
  # extension's defect.
  let(:owned_prefixes) { %w[system. sdwan.] }

  let(:owned_categories) do
    Ai::InterventionPolicy.registered_categories
                          .select { |c| owned_prefixes.any? { |p| c.start_with?(p) } }
                          .uniq
                          .sort
  end

  # One key per ACTION, whatever separator its spelling happens to use.
  def normalise(category) = category.downcase.gsub(/[._]+/, ".")

  # The one pair this task did not settle, recorded rather than hidden.
  #
  # system.package_module.create (seeded, FLEET_AUTONOMY_POLICIES) and
  # system.package_module_create (PackageModuleCreateExecutor's derived
  # category, APO-1c) are the SAME defect with the same fix — declare
  # action_category on the executor, retire the underscored row — but they are a
  # different action family and a different executor, so settling them here
  # would be a second change riding on this one. Filed separately.
  #
  # This exemption is PINNED PRESENT below, not merely subtracted: when that
  # pair is fixed the pin reds and the exemption has to be deleted, so it cannot
  # outlive the defect it describes and quietly excuse a future collision.
  let(:recorded_duplicate_pair) do
    %w[system.package_module.create system.package_module_create].freeze
  end

  it "registers no two spellings of the same autonomy action" do
    expect(owned_categories).not_to be_empty,
                                    "the engine's autonomy category registration did not run — this example " \
                                    "would pass vacuously"

    collisions = owned_categories
                 .group_by { |c| normalise(c) }
                 .select { |_key, spellings| spellings.size > 1 }
                 .reject { |_key, spellings| spellings.sort == recorded_duplicate_pair.sort }

    expect(collisions).to be_empty, <<~MSG
      #{collisions.size} autonomy action(s) are registered under more than one spelling:

        #{collisions.map { |key, spellings| "#{key}: #{spellings.join(' / ')}" }.join("\n  ")}

      Each spelling is a SEPARATE Ai::InterventionPolicy row and a separate control in
      the Autonomy modal, so an operator who tunes one does not tune the other and the
      gate that resolves the other spelling keeps its old verdict. Pick ONE spelling
      (the seeded row's), declare it on the executor as
      `skill_descriptor(action_category: "...")`, drop the other from
      System::Governance::PolicyDeclarations and from the engine's registration list,
      and retire any row already written for it — the governance reconciler is
      absence-only and will never delete it.
    MSG
  end

  # Guards the exemption above against rotting into a blanket excuse.
  it "still carries the recorded package_module duplicate the exemption names" do
    still_registered = recorded_duplicate_pair.select { |c| Ai::InterventionPolicy.category_registered?(c) }

    expect(still_registered).to match_array(recorded_duplicate_pair), <<~MSG
      The recorded duplicate pair (#{recorded_duplicate_pair.join(' / ')}) is no longer
      registered in full — registered now: #{still_registered.join(', ').presence || '(none)'}.

      That pair is exempted from the uniqueness example above. If it has been settled,
      DELETE the exemption rather than leaving it: an exemption whose subject is gone
      silently excuses whatever collision lands on those names next.
    MSG
  end

  describe "the architecture executors" do
    let(:executors) do
      {
        System::Ai::Skills::ArchitectureCreateExecutor => "system.architecture.create",
        System::Ai::Skills::ArchitectureUpdateExecutor => "system.architecture.update",
        System::Ai::Skills::ArchitectureDeleteExecutor => "system.architecture.delete"
      }
    end

    # The gate resolves BaseSkillExecutor.action_category, and the row an
    # operator tunes is the seeded dotted one. Asserting the class rather than
    # the registry is what pins the two to each other: dropping the declaration
    # sends the derivation back to "<domain>.<skill name>" — the underscored
    # spelling — and the gate silently resolves an unseeded category at the
    # require_approval default again.
    it "resolves the SEEDED dotted category, not the derived underscored one" do
      actual = executors.keys.index_with(&:action_category)

      expect(actual).to eq(executors)
    end

    it "resolves a category the seeded policy declarations actually declare" do
      declared = System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES.keys

      expect(declared).to include(*executors.values)
    end
  end
end
