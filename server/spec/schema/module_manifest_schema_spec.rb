# frozen_string_literal: true

require "rails_helper"
require "json"
require "yaml"

# Guards the `dependencies.requires` pattern in the module manifest JSON schema.
#
# The schema is enforced at PR time by .gitea/workflows/module-validate.yaml
# (ajv, draft 2020-12). This spec is the fast local mirror: it checks the same
# pattern against every manifest actually shipped in this repo, so tightening
# the pattern cannot silently invalidate the fleet, and it pins the malformed
# constraints the pattern exists to reject.
#
# The runtime authority on whether a capability constraint is well-formed is
# System::CapabilityResolver.constraint_valid? (Gem::Requirement). The schema
# pattern is an earlier, coarser mirror of that rule — it catches the realistic
# typos at review time, before a manifest ever reaches the importer.
RSpec.describe "module manifest schema: dependencies.requires" do
  extension_root = File.expand_path("../../..", __dir__)
  schema_path    = File.join(extension_root, "modules/.schema/module-manifest.schema.json")

  let(:schema) { JSON.parse(File.read(schema_path)) }

  let(:requires_schema) do
    schema.dig("properties", "dependencies", "properties", "requires", "items")
  end

  # JSON Schema patterns are ECMA-262, where ^/$ anchor the whole string.
  # Ruby's ^/$ are line anchors, so translate before matching or a trailing
  # newline would let a malformed value pass here but fail in CI.
  def matches?(patterns, value)
    patterns.any? do |p|
      Regexp.new(p.sub(/\A\^/, '\A').sub(/\$\z/, '\z')).match?(value)
    end
  end

  let(:patterns) do
    if requires_schema["anyOf"]
      requires_schema["anyOf"].map { |s| s.fetch("pattern") }
    else
      [ requires_schema.fetch("pattern") ]
    end
  end

  # Every requires entry declared by a manifest shipped in this repo.
  def self.shipped_requires
    root = File.expand_path("../../..", __dir__)
    Dir.glob(File.join(root, "{modules,templates}/**/manifest.yaml")).flat_map do |path|
      parsed = begin
        YAML.safe_load(File.read(path), aliases: true)
      rescue StandardError
        nil
      end
      next [] unless parsed.is_a?(Hash)

      Array(parsed.dig("dependencies", "requires")).map { |r| [ path, r.to_s ] }
    end
  end

  it "declares a pattern at all (an unconstrained string cannot reject a typo)" do
    expect(patterns).not_to be_empty
  end

  describe "accepts every requires entry shipped in this repo" do
    shipped = shipped_requires

    it "found manifests to check" do
      expect(shipped).not_to be_empty
    end

    shipped.each do |path, entry|
      it "accepts #{entry.inspect} from #{path.split('/extensions/system/').last}" do
        expect(matches?(patterns, entry)).to be(true)
      end
    end
  end

  describe "accepts the documented forms" do
    [
      "powernode/system-base@^1.0",   # name pin, caret — 100% of shipped pins
      "powernode/redis@~> 1.0",
      "postgres-primary",             # bare name
      "capability:os.userland",       # bare capability
      "capability:runtime.go@>= 1.25",
      "capability:database.postgres@>=16",
      "capability:database.postgres.primary"
    ].each do |entry|
      it entry.inspect do
        expect(matches?(patterns, entry)).to be(true)
      end
    end
  end

  # These are the whole point of the pattern. A capability constraint is parsed
  # by Gem::Requirement at import; caret syntax raises there, and before FIX C
  # that raise was swallowed into a nil that read as "no provider exists".
  describe "rejects malformed capability constraints" do
    [
      "capability:database.postgres@^16",     # npm caret — the realistic typo
      "capability:database.postgres@!!!bogus",
      "capability:database.postgres@>= 16, < 18", # needs array form, Gem raises
      "capability:"                            # empty tag
    ].each do |entry|
      it entry.inspect do
        expect(matches?(patterns, entry)).to be(false)
      end
    end
  end

  # Cross-check: anything the schema accepts as a capability constraint must
  # also be accepted by the runtime authority. Keeps the two layers honest.
  it "never accepts a capability constraint the resolver would reject" do
    accepted = [
      "capability:runtime.go@>= 1.25",
      "capability:database.postgres@>=16",
      "capability:x@~> 1.0",
      "capability:x@1.0"
    ]

    accepted.each do |entry|
      expect(matches?(patterns, entry)).to be(true), "schema rejected #{entry.inspect}"
      _tag, constraint = entry.sub(/\Acapability:/, "").split("@", 2)
      expect(System::CapabilityResolver.constraint_valid?(constraint))
        .to be(true), "resolver rejected #{constraint.inspect}"
    end
  end
end
