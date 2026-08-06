# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::CveOps::VersionMatcher do
  # Hygiene, NOT a fix for the known flake below. DebVersionComparator memoizes
  # `dpkg --compare-versions` in a PROCESS-WIDE class-level cache that nothing
  # resets between examples (`reset_cache!` had no caller anywhere in the
  # suite), and several specs in this tree stub Open3 broadly. A cache that
  # outlives an example has no business deciding a later one's result, so it is
  # cleared here regardless.
  before { System::CveOps::DebVersionComparator.reset_cache! }

  # RESOLVED: six rows here used to fail in a full-suite run and pass in every
  # isolation. Cause was a DUPLICATE definition of System::CveOps::VersionMatcher
  # at extensions/system/server/lib/system/cve_ops/version_matcher.rb — a naive
  # numeric-tuple matcher that dropped pre-release/epoch/tilde/post semantics.
  # It was Zeitwerk-SHADOWED (app/services precedes lib/ on the autoload path)
  # so production never saw it, but spec/lib/.../version_matcher_spec.rb
  # `require`d it by absolute path, bypassing Zeitwerk and REOPENING the class
  # — clobbering .vulnerable? for every example in the process. RSpec loads all
  # spec files before running any example, so command-line order was irrelevant:
  # merely INCLUDING that spec file was the trigger, and the CI matrix includes
  # spec/lib while none of the isolations did. Both files are deleted; their
  # unique nil-input coverage is ported into the edge-case block below.

  describe ".vulnerable?" do
    # Table-driven tests grouped by ecosystem. Each row exercises one
    # representative case: range bounds, edge values, ecosystem-specific
    # quirks (epochs for deb, tilde for rpm, alpha/post for pypi).
    {
      "gem (semver)" => [
        [ "1.2.3",  "<2.0.0",          true ],
        [ "2.0.0",  "<2.0.0",          false ],
        [ "1.0.0",  "=1.0.0",          true ],
        [ "1.0.0",  "*",               true ],
        [ "1.0.0",  "",                true ],
        [ "v1.2.3", "<2.0.0",          true ],   # leading v stripped
        [ "1.0.0-alpha", "<1.0.0",     true ],   # pre-release < release
        [ "1.0.0",  "<1.0.0-alpha",    false ]
      ],
      "npm (semver, conjunctive ranges)" => [
        [ "1.2.3", ">=1.0.0,<2.0.0", true ],
        [ "2.5.0", ">=1.0.0,<2.0.0", false ],
        [ "1.0.0", ">=1.0.0,<2.0.0", true ],   # inclusive lower bound
        [ "2.0.0", ">=1.0.0,<2.0.0", false ]   # exclusive upper bound
      ],
      "deb" => [
        [ "3.1.3",       "<3.1.4",     true ],
        [ "3.1.4",       "<3.1.4",     false ],
        [ "1:2.0",       ">1.0",       true ],   # epoch wins
        [ "2:0.1",       ">3.0",       true ],   # epoch dominates
        [ "1.0-1ubuntu1", ">=1.0",     true ]    # debian revision
      ],
      "rpm" => [
        [ "2.0.0",   "<2.0.0",     false ],
        [ "1.0~rc1", "<1.0",       true ],    # tilde pre-release
        [ "1.0",     "<1.0~rc1",   false ],
        [ "1.0",     "=1.0",       true ]
      ],
      "pypi (PEP 440)" => [
        [ "1.2.3",     "<2.0.0",       true ],
        [ "2.0.0a1",   "<2.0.0",       true ],   # alpha < release
        [ "2.0.0",     "<2.0.0a1",     false ],
        [ "1.0.0",     "<1.0.0.post1", true ]    # post > release
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

      # nil, not "" — a distinct path (parse_constraint takes constraint.to_s;
      # vulnerable? takes version.to_s.strip). Ported from the deleted
      # spec/lib/system/cve_ops/version_matcher_spec.rb, which was the only
      # coverage of the nil cases and is removed in this commit.
      it "returns true for a nil constraint" do
        result = described_class.vulnerable?(version: "1.0.0", constraint: nil, ecosystem: "gem")
        expect(result).to be true
      end

      it "returns false for a nil version when the constraint is non-blank" do
        result = described_class.vulnerable?(version: nil, constraint: ">=1.0.0", ecosystem: "gem")
        expect(result).to be false
      end

      it "returns false for a malformed constraint (graceful degradation)" do
        # A garbage constraint shouldn't crash the per-tick CVE responder.
        result = described_class.vulnerable?(version: "1.0.0", constraint: "@@@@@", ecosystem: "gem")
        # May parse-and-skip OR may return false; either is acceptable as
        # long as no exception escapes.
        expect([ true, false ]).to include(result)
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
      expect(described_class.parse_constraint("<2.0.0")).to eq([ [ :lt, "2.0.0" ] ])
    end

    it "parses conjunctive ranges (AND)" do
      expect(described_class.parse_constraint(">=1.0.0,<2.0.0")).to eq([
        [ :ge, "1.0.0" ], [ :lt, "2.0.0" ]
      ])
    end

    it "defaults missing operator to equality" do
      expect(described_class.parse_constraint("1.2.3")).to eq([ [ :eq, "1.2.3" ] ])
    end
  end

  # IMP-4487d0c048b9 — RANGE_REGEX matched the FIRST `=` of PEP 440's `==` as
  # the operator and kept the second inside the version string, so "==1.0.0"
  # compared against "=1.0.0", whose leading segment Integer-rescued to 0: a
  # silently wrong CVE exposure verdict for canonical pypi constraints.
  describe "PEP 440 == operator" do
    it "parses ==x.y.z with a clean version string" do
      expect(described_class.parse_constraint("==1.0.0")).to eq([ [ :eq, "1.0.0" ] ])
    end

    it "evaluates canonical pypi equality constraints correctly" do
      expect(described_class.vulnerable?(version: "1.0.0", constraint: "==1.0.0", ecosystem: "pypi")).to be true
      expect(described_class.vulnerable?(version: "1.0.1", constraint: "==1.0.0", ecosystem: "pypi")).to be false
    end

    it "refuses an unsupported operator loudly — logged false, never a silent wrong answer" do
      expect(Rails.logger).to receive(:warn).with(/unsupported operator/).at_least(:once)
      expect(described_class.vulnerable?(version: "1.0.0", constraint: "~=1.0", ecosystem: "pypi")).to be false
    end
  end
end
