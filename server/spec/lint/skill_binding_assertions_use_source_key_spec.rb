# frozen_string_literal: true

require "rails_helper"

# CENSUS GUARD: a spec or seed that reads a skill-binding projection asserts
# the SOURCE KEY, never a display name.
#
# THE CLASS THIS PINS. 295742ba made SkillBindings resolve agents by
# `source_key` and stopped projecting a display name from a registration:
# `reg[:agents]` and `discover`'s `agent_key` carry "disk-image-manager", not
# "Disk Image Manager", and `agent_name` is no longer a projection key at all.
# Ten binding specs and the governance-reconcile spec still compared against
# the display name, and none of them said so until CI could run again weeks
# later — eleven sites, one cause, found by the failures rather than by a
# guard. Fixing eleven call sites does not stop the twelfth, so the shape is
# asserted here.
#
# TWO SHAPES are offences:
#   1. a projection read (`[:agents]`, `[:agent_key]`, `agent_key:`) on the
#      same line as a display-name literal — the assertion can only be
#      comparing the key to a label, which never matches;
#   2. a `[:agent_name]` read anywhere a SkillBindings projection is in play —
#      the key does not exist, so the read is nil and a `select` on it is
#      silently empty.
#
# The display-name set is DERIVED, not hand-listed: every name in
# PolicyDeclarations::AGENT_IDENTITIES plus every legacy label SkillBindings
# still accepts as an alias. A new canonical is covered the day it is declared.
#
# WHAT THIS DOES NOT CATCH, stated so the next reader does not over-trust it:
# a label held in a variable, or an assertion split across lines so the
# literal and the projection read are not on one line. It is a ratchet
# against the shape being RE-INTRODUCED by hand in the forms it actually took.
# Seeds that write `binds_to "Display Name"` are not offences: the alias table
# accepts a legacy label on purpose, and only the LOOKUP moved.
RSpec.describe "skill-binding assertions key on the source key, never a display name", type: :lint do
  SKB_SERVER_ROOT = File.expand_path("../..", __dir__)
  SKB_SCAN_GLOBS = [
    File.join(SKB_SERVER_ROOT, "spec", "**", "*.rb"),
    File.join(SKB_SERVER_ROOT, "db", "seeds", "**", "*.rb")
  ].freeze

  SKB_PROJECTION_READ = /\[:agents\]|\[:agent_key\]|\bagent_key:/
  SKB_AGENT_NAME_READ = /\[:agent_name\]/
  SKB_BINDINGS_REF = /SkillBindings/

  def self.display_names
    declared = System::Governance::PolicyDeclarations::AGENT_IDENTITIES.values.map { |v| v[:name] }
    legacy = System::Ai::Skills::SkillBindings::AGENT_ALIASES.keys.select { |k| k.include?(" ") }
    (declared + legacy).uniq.sort
  end

  def self.display_name_literal
    /"(?:#{display_names.map { |n| Regexp.escape(n) }.join('|')})"/
  end

  def self.scanned_sources
    SKB_SCAN_GLOBS.flat_map { |g| Dir.glob(g) }.sort.reject { |p| p == __FILE__ }
  end

  it "derives a non-empty display-name set from the declarations" do
    names = self.class.display_names
    expect(names.size).to be >= System::Governance::PolicyDeclarations::AGENT_IDENTITIES.size
    expect(names).to include("Disk Image Manager", "System Topology Designer")
  end

  it "scans a tree that actually contains projection reads (the scan itself is alive)" do
    sources = self.class.scanned_sources
    reads = sources.count { |p| File.read(p).match?(SKB_PROJECTION_READ) }
    expect(sources.size).to be > 100, "glob found #{sources.size} files — SKB_SCAN_GLOBS is wrong"
    expect(reads).to be >= 10, "found #{reads} files reading a binding projection — the token scan is dead"
  end

  it "never compares a binding projection to a display name" do
    literal = self.class.display_name_literal

    offences = self.class.scanned_sources.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        next if line.strip.start_with?("#")
        next unless line.match?(SKB_PROJECTION_READ) && line.match?(literal)

        "#{path.delete_prefix("#{SKB_SERVER_ROOT}/")}:#{i + 1}: #{line.strip}"
      end
    end

    expect(offences).to be_empty, <<~MSG
      A skill-binding projection carries the canonical SOURCE KEY
      ("disk-image-manager"), never the display name ("Disk Image Manager").
      A display name is a label; the lookup is keyed on source_key so that a
      rename cannot orphan an agent's skills. Assert the key.

      #{offences.join("\n")}
    MSG
  end

  it "never reads agent_name off a SkillBindings projection — that key does not exist" do
    offences = self.class.scanned_sources.flat_map do |path|
      src = File.read(path)
      next [] unless src.match?(SKB_BINDINGS_REF)

      src.lines.each_with_index.filter_map do |line, i|
        next if line.strip.start_with?("#")
        next unless line.match?(SKB_AGENT_NAME_READ)

        "#{path.delete_prefix("#{SKB_SERVER_ROOT}/")}:#{i + 1}: #{line.strip}"
      end
    end

    expect(offences).to be_empty, <<~MSG
      SkillBindings.discover projects `agent_key`, and `all`/`by_skill` carry
      `agents` (source keys). `[:agent_name]` is nil on every entry, so a
      select on it is silently empty and the example that reads it proves
      nothing. Read `agent_key` and compare to the source key.

      #{offences.join("\n")}
    MSG
  end
end
