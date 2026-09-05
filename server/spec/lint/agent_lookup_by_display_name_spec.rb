# frozen_string_literal: true

require "rails_helper"

# CENSUS GUARD: no agent lookup may key on a DISPLAY NAME.
#
# The defect this pins is not a stale string. It is that `Ai::Agent#name` was
# being used as a binding key in three places, while `source_key` — the only
# field on a seeded canonical that is set explicitly and derived from nothing —
# sat unused for resolution. Two consequences made that worse than it sounds:
#
#   * `Ai::Agent` has `before_validation :generate_slug, if: name_changed?`,
#     which re-derives the slug from the name. One rename therefore moved TWO
#     identifiers other code addressed the agent by.
#   * a name-keyed lookup does not raise when it misses. SkillBindings-
#     Reconciler simply stopped matching and the agent lost its entire skill
#     set; the controller returned its "not seeded" refusal with the row
#     sitting right there.
#
# So the invariant is asserted here rather than in prose: resolve an agent by
# `source_key` (or by `slug` where the addressable handle is genuinely what is
# wanted), never by `name`.
#
# WHAT THIS DOES NOT CATCH, stated so the next reader does not over-trust it:
# a lookup built from a variable (`where(name: some_name)`) is invisible to a
# textual scan, as is one composed at runtime. This is a ratchet against the
# shape being RE-INTRODUCED by hand, not proof that none exists. It is scoped
# to the system extension's own app tree; core is out of its reach.
RSpec.describe "agent lookups never key on a display name", type: :lint do
  APP_ROOT = File.expand_path("../../app", __dir__)

  # `Ai::Agent` / `agents` receiver, then a name: lookup. Matches the shapes
  # that actually appeared on this tree: `Ai::Agent.global.find_by(name: "X")`,
  # `Ai::Agent.where(name: "X")`, `resolve_for(account, name: "X")`.
  OFFENDING = [
    /Ai::Agent[\w.:]*\.(?:find_by|where)\(\s*name:/,
    /resolve_for\([^)]*\bname:/
  ].freeze

  # Every exemption names WHY it is safe. An entry here is a claim that the
  # site is a deliberate fallback or a non-binding read, not a licence.
  #
  # GRANDFATHERED, on the same principle as .claude/hooks/core-purity-baseline
  # .txt: the sites below predate this guard. They are listed so no committer
  # is wedged on a backlog they did not create, and so the guard can still
  # ratchet against a NEW one. Each entry says which of the two it is —
  # a deliberate fallback, or debt.
  #
  # None of them resolves the agent this increment renamed: the Autonomy
  # roster (SYSTEM_AGENT_NAMES) covers only declared policy-set owners, and
  # the Infrastructure Generalist carries no policy set.
  ALLOWED = {
    # SAFE — source_key is tried FIRST in #resolve_agent; the name is only the
    # fallback for an install whose canonical predates source_key being set.
    "services/system/governance/hierarchy_reconciler.rb" =>
      "documented source_key-first fallback",

    # DEBT — precedence is INVERTED relative to HierarchyReconciler: name
    # first, source_key second. It works today only because the source_key
    # fallback catches a renamed agent, so a rename degrades this from a
    # primary lookup to a fallback rather than breaking it. Flipping the two
    # is the correct fix and is out of this increment's scope.
    "services/system/governance/agent_resolver.rb" =>
      "pre-existing: name-first with a source_key fallback; precedence should be flipped",

    # DEBT — lane B owns this tree (fleet services); read-only for this
    # increment. Same shape as agent_resolver: resolves a declared identity by
    # name, with AGENT_IDENTITIES supplying the name.
    "services/system/fleet/sensors/governance_gap_sensor.rb" =>
      "pre-existing, lane-owned tree: resolves declared identities by name",

    # DEBT — the Autonomy panel roster is a list of display names and resolves
    # each one by name. Moving it to source keys means re-keying
    # SYSTEM_AGENT_NAMES itself.
    "controllers/concerns/system/autonomy_actions.rb" =>
      "pre-existing: roster is keyed by display name end to end",

    # DEBT — resolves a monitor agent by a name passed in from the caller.
    "services/ai/tools/system_architecture_catalog_tool.rb" =>
      "pre-existing: name arrives from the caller",

    # DEBT — a hardcoded "GitOps Reconciler" literal with no source_key
    # fallback. The most exposed of the five, since that agent has a declared
    # source_key already.
    "services/system/gitops/reconciler.rb" =>
      "pre-existing: hardcoded display name, no fallback"
  }.freeze

  def ruby_sources
    Dir.glob(File.join(APP_ROOT, "**", "*.rb")).sort
  end

  it "finds at least one Ai::Agent lookup to scan (the scan itself is alive)" do
    # Without this, a glob that silently matched nothing would report a
    # spotless tree and this guard would pass forever while checking zero
    # bytes.
    hits = ruby_sources.count { |f| File.read(f).include?("Ai::Agent") }
    expect(hits).to be_positive, "scanned #{ruby_sources.size} files and found no Ai::Agent reference — the glob is wrong"
  end

  it "keys every agent lookup on source_key or slug, never on name" do
    violations = ruby_sources.flat_map do |path|
      rel = path.sub("#{APP_ROOT}/", "")
      next [] if ALLOWED.key?(rel)

      File.readlines(path).each_with_index.filter_map do |line, i|
        next if line.strip.start_with?("#")
        next unless OFFENDING.any? { |re| line.match?(re) }

        "#{rel}:#{i + 1}: #{line.strip}"
      end
    end

    expect(violations).to be_empty, <<~MSG
      #{violations.size} agent lookup(s) key on a display name:

        #{violations.join("\n  ")}

      A display name is not an identity. Resolve by `source_key` (the seeded
      canonical's stable key, copied onto account clones by
      GloballyScopable#clone_to_account) or by `slug` where the addressable
      handle is what you actually want. If the site is a deliberate fallback,
      add it to ALLOWED in this spec with the reason.
    MSG
  end

  it "resolves every skill binding through a source key" do
    values = System::Ai::Skills::SkillBindings::AGENT_ALIASES.values.uniq
    declared = System::Governance::PolicyDeclarations::AGENT_IDENTITIES.keys

    # Every alias target is a source_key. The concierge is the one agent with
    # no policy set, so it is not in AGENT_IDENTITIES and is named explicitly.
    expect(values - declared).to eq([ "system-concierge" ])
  end

  it "binds the entry skill through a source key too" do
    expect(System::Ai::Skills::SkillBindingsReconciler::ENTRY_SKILL_BINDINGS.values)
      .to all(eq("system-concierge"))
  end
end
