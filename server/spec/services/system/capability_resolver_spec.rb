# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::CapabilityResolver do
  let(:account) { create(:account) }

  def provider(*capabilities, name: "provider", priority: 50)
    create(:system_node_module,
           account: account,
           name: name,
           priority: priority,
           capabilities: capabilities)
  end

  describe ".resolve" do
    it "returns the provider advertising a bare tag" do
      pg = provider("database.postgres")

      expect(described_class.resolve(account_id: account.id, tag: "database.postgres")).to eq(pg)
    end

    it "returns nil when no module provides the tag" do
      expect(described_class.resolve(account_id: account.id, tag: "storage.nowhere")).to be_nil
    end

    it "honours a version constraint against versioned provides" do
      provider("database.postgres@15", name: "pg-15")
      pg16 = provider("database.postgres@16", name: "pg-16")

      resolved = described_class.resolve(
        account_id: account.id, tag: "database.postgres", constraint: ">= 16"
      )

      expect(resolved).to eq(pg16)
    end

    it "does not let a bare tag satisfy a versioned constraint" do
      provider("database.postgres")

      resolved = described_class.resolve(
        account_id: account.id, tag: "database.postgres", constraint: ">= 16"
      )

      expect(resolved).to be_nil
    end
  end

  # === FIX C (IMP-ac345fc6c4e6) ===
  # A malformed constraint must be distinguishable from "nobody provides this".
  # Before the fix both collapsed to nil, so a typo'd constraint was reported as
  # a capability GAP and routed to the operator approval gate as though the
  # fleet were missing a module.
  describe ".constraint_valid?" do
    it "accepts the Gem::Requirement forms capability constraints are matched with" do
      [ nil, "", ">= 16", ">=16", "~> 1.0", "1.0", "16" ].each do |c|
        expect(described_class.constraint_valid?(c)).to be(true), "expected #{c.inspect} to be valid"
      end
    end

    # `^1.0` is npm/caret syntax. Gem::Requirement raises on it, so before the
    # fix `capability:foo@^16` silently became a capability gap. This is not a
    # hypothetical: every module-to-module pin shipped in this repo uses the
    # caret form, and the authoring runbook teaches it.
    it "rejects caret and garbage constraints that Gem::Requirement cannot parse" do
      [ "^1.0", "^16", "!!!bogus", ">= 16, < 18" ].each do |c|
        expect(described_class.constraint_valid?(c)).to be(false), "expected #{c.inspect} to be invalid"
      end
    end
  end

  describe ".parse_requirement_string" do
    it "splits a capability requirement into tag and constraint" do
      expect(described_class.parse_requirement_string("capability:runtime.go@>= 1.25"))
        .to eq([ "runtime.go", ">= 1.25" ])
    end

    it "returns a nil constraint for a bare capability requirement" do
      expect(described_class.parse_requirement_string("capability:runtime.go"))
        .to eq([ "runtime.go", nil ])
    end

    it "returns nil for a name-based requirement" do
      expect(described_class.parse_requirement_string("powernode/system-base@^1.0")).to be_nil
    end

    # Keeps a malformed constraint OUT of the capability-gap channel. The gap
    # sensor filter_maps over this method, so returning nil here is what stops
    # a manifest typo from being reported to the operator as a missing module.
    # The typo is surfaced instead as an import-time validation error.
    it "returns nil for a capability requirement whose constraint is malformed" do
      expect(described_class.parse_requirement_string("capability:database.postgres@^16")).to be_nil
    end
  end

  # === FIX B (IMP-9ab204776516) ===
  # Public seam so DependencyResolutionService can re-check a stored constraint
  # without owning a second copy of the constraint semantics.
  describe ".satisfied_by?" do
    it "is true when the module advertises a satisfying version" do
      expect(described_class.satisfied_by?(provider("database.postgres@16"), "database.postgres", ">= 16"))
        .to be(true)
    end

    it "is false when the module has drifted below the constraint" do
      expect(described_class.satisfied_by?(provider("database.postgres@15"), "database.postgres", ">= 16"))
        .to be(false)
    end

    it "is true for a blank constraint when the tag is present at all" do
      expect(described_class.satisfied_by?(provider("cache.redis"), "cache.redis", nil)).to be(true)
    end

    it "is false when the module does not advertise the tag" do
      expect(described_class.satisfied_by?(provider("cache.redis"), "database.postgres", nil)).to be(false)
    end
  end
end
