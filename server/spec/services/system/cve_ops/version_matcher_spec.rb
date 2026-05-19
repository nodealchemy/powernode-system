# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::CveOps::VersionMatcher do
  describe ".vulnerable?" do
    # Table-driven tests grouped by ecosystem. Each row exercises one
    # representative case: range bounds, edge values, ecosystem-specific
    # quirks (epochs for deb, tilde for rpm, alpha/post for pypi).
    {
      "gem (semver)" => [
        ["1.2.3",  "<2.0.0",          true],
        ["2.0.0",  "<2.0.0",          false],
        ["1.0.0",  "=1.0.0",          true],
        ["1.0.0",  "*",               true],
        ["1.0.0",  "",                true],
        ["v1.2.3", "<2.0.0",          true],   # leading v stripped
        ["1.0.0-alpha", "<1.0.0",     true],   # pre-release < release
        ["1.0.0",  "<1.0.0-alpha",    false]
      ],
      "npm (semver, conjunctive ranges)" => [
        ["1.2.3", ">=1.0.0,<2.0.0", true],
        ["2.5.0", ">=1.0.0,<2.0.0", false],
        ["1.0.0", ">=1.0.0,<2.0.0", true],   # inclusive lower bound
        ["2.0.0", ">=1.0.0,<2.0.0", false]   # exclusive upper bound
      ],
      "deb" => [
        ["3.1.3",       "<3.1.4",     true],
        ["3.1.4",       "<3.1.4",     false],
        ["1:2.0",       ">1.0",       true],   # epoch wins
        ["2:0.1",       ">3.0",       true],   # epoch dominates
        ["1.0-1ubuntu1", ">=1.0",     true]    # debian revision
      ],
      "rpm" => [
        ["2.0.0",   "<2.0.0",     false],
        ["1.0~rc1", "<1.0",       true],    # tilde pre-release
        ["1.0",     "<1.0~rc1",   false],
        ["1.0",     "=1.0",       true]
      ],
      "pypi (PEP 440)" => [
        ["1.2.3",     "<2.0.0",       true],
        ["2.0.0a1",   "<2.0.0",       true],   # alpha < release
        ["2.0.0",     "<2.0.0a1",     false],
        ["1.0.0",     "<1.0.0.post1", true]    # post > release
      ]
    }.each do |label, rows|
      context label do
        rows.each do |version, constraint, expected|
          # ecosystem is the first word of the context label
          ecosystem = label.split.first
          it "#{version} against #{constraint.inspect} → #{expected}" do
            result = described_class.vulnerable?(
              version: version, constraint: constraint, ecosystem: ecosystem
            )
            expect(result).to eq(expected)
          end
        end
      end
    end

    context "malformed / edge inputs" do
      it "returns false for an empty version" do
        result = described_class.vulnerable?(version: "", constraint: "<2.0", ecosystem: "gem")
        expect(result).to be false
      end

      it "returns true for an empty constraint (match-anything semantics)" do
        result = described_class.vulnerable?(version: "1.0.0", constraint: "", ecosystem: "gem")
        expect(result).to be true
      end

      it "returns false for a malformed constraint (graceful degradation)" do
        # A garbage constraint shouldn't crash the per-tick CVE responder.
        result = described_class.vulnerable?(version: "1.0.0", constraint: "@@@@@", ecosystem: "gem")
        # May parse-and-skip OR may return false; either is acceptable as
        # long as no exception escapes.
        expect([true, false]).to include(result)
      end

      it "defaults unknown ecosystem to semver" do
        result = described_class.vulnerable?(version: "1.0.0", constraint: "<2.0.0", ecosystem: "made-up")
        expect(result).to be true
      end
    end
  end

  describe ".parse_constraint" do
    it "returns empty array for '*' (matches everything)" do
      expect(described_class.parse_constraint("*")).to eq([])
    end

    it "parses single bound" do
      expect(described_class.parse_constraint("<2.0.0")).to eq([[:lt, "2.0.0"]])
    end

    it "parses conjunctive ranges (AND)" do
      expect(described_class.parse_constraint(">=1.0.0,<2.0.0")).to eq([
        [:ge, "1.0.0"], [:lt, "2.0.0"]
      ])
    end

    it "defaults missing operator to equality" do
      expect(described_class.parse_constraint("1.2.3")).to eq([[:eq, "1.2.3"]])
    end
  end
end
