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

  # NO EXEMPTIONS. IMP-51e5c6184ae4 shipped one — system.package_module.create /
  # system.package_module_create, the same defect in another action family —
  # recorded by name and pinned present so it could not outlive its subject.
  # IMP-2effedffc990 settled that pair the same way (the executor declares the
  # dotted category, the underscored row is gone), so the assertion below is
  # now the whole claim over every registered system./sdwan. category. Do not
  # add a `reject` here: a second spelling is settled, not recorded.

  it "registers no two spellings of the same autonomy action" do
    expect(owned_categories).not_to be_empty,
                                    "the engine's autonomy category registration did not run — this example " \
                                    "would pass vacuously"

    collisions = owned_categories
                 .group_by { |c| normalise(c) }
                 .select { |_key, spellings| spellings.size > 1 }

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

  # Every executor whose action already had a SEEDED dotted row when APO-1c
  # started deriving "<domain>.<skill name>" for it. The architecture trio came
  # first (IMP-51e5c6184ae4); PackageModuleCreateExecutor was the recorded
  # second instance (IMP-2effedffc990) — FLEET_AUTONOMY_POLICIES seeds
  # system.package_module.create while the derivation minted
  # system.package_module_create.
  describe "the executors whose action has a seeded dotted row" do
    let(:executors) do
      {
        System::Ai::Skills::ArchitectureCreateExecutor => "system.architecture.create",
        System::Ai::Skills::ArchitectureUpdateExecutor => "system.architecture.update",
        System::Ai::Skills::ArchitectureDeleteExecutor => "system.architecture.delete",
        System::Ai::Skills::PackageModuleCreateExecutor => "system.package_module.create"
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
      # On the Supply Chain Manager since HIER-P2DECL (packages + architecture).
      declared = System::Governance::PolicyDeclarations::SUPPLY_CHAIN_MANAGER_POLICIES.keys

      expect(declared).to include(*executors.values)
    end

    # The retired spellings must stay retired everywhere a name can be
    # registered from — the declaration tables AND the engine's explicit
    # concat lists — or the normalised-set example above reds again the next
    # time someone re-adds the "obvious" underscored name beside the executor.
    it "registers none of the retired underscored spellings" do
      retired = executors.values.map { |dotted| dotted.sub(/\.(\w+)\z/, '_\\1') }

      still_registered = retired.select { |c| Ai::InterventionPolicy.category_registered?(c) }

      expect(still_registered).to be_empty,
                                  "retired duplicate spelling(s) registered again: #{still_registered.join(', ')}"
    end

    # The Autonomy modal's domain pivot carried a prefix per retired spelling
    # (`system.architecture_`, `system.package_module_`) so the two controls at
    # least filed under one domain. Those prefixes came out with the spellings,
    # and nothing else pins their removal: the pivot spec asserts reachability
    # per DOMAIN, and both domains stay reachable through their dotted prefix,
    # so a re-added underscored prefix would survive that suite untouched.
    it "keeps no domain prefix that would match a retired spelling" do
      retired = executors.values.map { |dotted| dotted.sub(/\.(\w+)\z/, '_\\1') }
      prefixes = System::AutonomyActions::DOMAIN_PREFIXES.values.flatten

      matching = prefixes.select { |prefix| retired.any? { |c| c.start_with?(prefix) } }

      expect(matching).to be_empty,
                          "domain prefix(es) still pivot a retired spelling: #{matching.join(', ')}"
    end
  end
end
