# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("../extensions/system/server/lib/system/cve_ops/version_matcher")

# Comprehensive stabilization sweep P4 — VersionMatcher.
RSpec.describe System::CveOps::VersionMatcher do
  describe ".vulnerable?" do
    context "with no constraint (NVD unknown-range convention)" do
      it "returns true for blank constraints" do
        expect(described_class.vulnerable?(version: "1.0.0", constraint: nil)).to be true
        expect(described_class.vulnerable?(version: "1.0.0", constraint: "")).to be true
        expect(described_class.vulnerable?(version: "1.0.0", constraint: "*")).to be true
      end

      it "returns false for blank versions when constraint is non-blank" do
        expect(described_class.vulnerable?(version: "", constraint: ">=1.0.0")).to be false
        expect(described_class.vulnerable?(version: nil, constraint: ">=1.0.0")).to be false
      end
    end

    context "with simple operators" do
      it "matches >= for versions at or above the floor" do
        expect(described_class.vulnerable?(version: "2.0.0", constraint: ">=2.0.0")).to be true
        expect(described_class.vulnerable?(version: "2.5.3", constraint: ">=2.0.0")).to be true
        expect(described_class.vulnerable?(version: "1.9.99", constraint: ">=2.0.0")).to be false
      end

      it "matches < for versions strictly below the ceiling" do
        expect(described_class.vulnerable?(version: "2.5.2", constraint: "<2.5.3")).to be true
        expect(described_class.vulnerable?(version: "2.5.3", constraint: "<2.5.3")).to be false
        expect(described_class.vulnerable?(version: "3.0.0", constraint: "<2.5.3")).to be false
      end

      it "matches <= for versions at or below the ceiling" do
        expect(described_class.vulnerable?(version: "2.5.3", constraint: "<=2.5.3")).to be true
        expect(described_class.vulnerable?(version: "2.5.4", constraint: "<=2.5.3")).to be false
      end

      it "matches exact equality" do
        expect(described_class.vulnerable?(version: "1.2.3", constraint: "==1.2.3")).to be true
        expect(described_class.vulnerable?(version: "1.2.3", constraint: "=1.2.3")).to be true
        expect(described_class.vulnerable?(version: "1.2.3", constraint: "1.2.3")).to be true
        expect(described_class.vulnerable?(version: "1.2.4", constraint: "1.2.3")).to be false
      end
    end

    context "with compound ranges" do
      it "matches both ends of a >=,< range" do
        # vulnerable: >=2.0.0,<2.5.3
        expect(described_class.vulnerable?(version: "2.0.0", constraint: ">=2.0.0,<2.5.3")).to be true
        expect(described_class.vulnerable?(version: "2.5.2", constraint: ">=2.0.0,<2.5.3")).to be true
        expect(described_class.vulnerable?(version: "2.5.3", constraint: ">=2.0.0,<2.5.3")).to be false
        expect(described_class.vulnerable?(version: "1.9.0", constraint: ">=2.0.0,<2.5.3")).to be false
      end
    end

    context "with whitespace in the constraint" do
      it "handles whitespace gracefully" do
        expect(described_class.vulnerable?(version: "2.0.0", constraint: ">= 2.0.0")).to be true
        expect(described_class.vulnerable?(version: "2.5.0", constraint: ">= 2.0.0 , < 2.5.3")).to be true
        expect(described_class.vulnerable?(version: "2.5.3", constraint: ">= 2.0.0 , < 2.5.3")).to be false
      end
    end

    context "with golang-style v-prefix versions" do
      it "strips the v prefix and compares" do
        # vulnerable: <v1.21.0
        expect(described_class.vulnerable?(version: "v1.20.5", constraint: "<v1.21.0")).to be true
        expect(described_class.vulnerable?(version: "v1.21.0", constraint: "<v1.21.0")).to be false
      end
    end

    context "with pre-release / build suffixes" do
      it "ignores suffixes for comparison purposes (reasonable approximation)" do
        # 2.0.0-alpha vs 2.0.0 — treated as equal in this matcher
        expect(described_class.vulnerable?(version: "2.0.0-alpha", constraint: "==2.0.0")).to be true
        # but suffix < release shows up as equal too — caller should be aware
      end
    end

    context "with malformed input" do
      it "returns false on parse failure (fail-safe)" do
        expect(described_class.vulnerable?(version: "not-a-version", constraint: ">=1.0.0")).to be false
      end
    end
  end

  describe ".compare" do
    it "compares semver components element-wise" do
      expect(described_class.compare("1.0.0", "2.0.0")).to be < 0
      expect(described_class.compare("2.0.0", "2.0.0")).to eq 0
      expect(described_class.compare("2.5.3", "2.5.2")).to be > 0
    end

    it "treats short versions as zero-padded" do
      expect(described_class.compare("2.0", "2.0.0")).to eq 0
      expect(described_class.compare("2", "2.0.0.0")).to eq 0
    end
  end
end
