# frozen_string_literal: true

require "rails_helper"

# P9.3 — Federation::SchemaVersionNegotiator spec.
#
# Locks the three-tier resolution rule (operator override > seeded
# default > implicit N-1) and the implicit-rule edge cases.
RSpec.describe ::Federation::SchemaVersionNegotiator, type: :service do
  describe ".current_platform_version" do
    it "reads the VERSION file" do
      version = described_class.current_platform_version
      expect(version).to match(/\A\d+\.\d+\.\d+/)
    end
  end

  describe ".negotiate" do
    it "returns incompatible when remote_version is blank" do
      result = described_class.negotiate(local_version: "0.3.1", remote_version: "")
      expect(result.status).to eq("incompatible")
      expect(result.source).to eq("implicit")
      expect(result.notes).to match(/didn't report/)
    end

    context "implicit N-1 rule" do
      it "is compatible when same major + same minor" do
        result = described_class.negotiate(local_version: "0.3.1", remote_version: "0.3.0")
        expect(result.status).to eq("compatible")
        expect(result.source).to eq("implicit")
      end

      it "is compatible when same major + minor delta == 1" do
        result = described_class.negotiate(local_version: "0.3.1", remote_version: "0.4.0")
        expect(result.status).to eq("compatible")
        expect(result.source).to eq("implicit")
      end

      it "is incompatible when minor delta > 1" do
        result = described_class.negotiate(local_version: "0.3.1", remote_version: "0.5.0")
        expect(result.status).to eq("incompatible")
        expect(result.source).to eq("implicit")
        expect(result.notes).to match(/minor delta > 1/)
      end

      it "is incompatible when major differs" do
        result = described_class.negotiate(local_version: "0.3.1", remote_version: "1.0.0")
        expect(result.status).to eq("incompatible")
        expect(result.source).to eq("implicit")
      end

      it "is incompatible when version is unparseable" do
        result = described_class.negotiate(local_version: "0.3.1", remote_version: "garbage")
        expect(result.status).to eq("incompatible")
        expect(result.notes).to match(/unparseable/)
      end
    end

    context "with a seeded default row" do
      before do
        ::System::FederationSchemaCompatibility.create!(
          local_version: "0.3.1", remote_version: "0.5.0",
          status: "compatible", source: "default",
          notes: "vendor-blessed 0.3.1 ↔ 0.5.0 pair (per matrix bootstrap)"
        )
      end

      it "honors the seeded row even when implicit rule says no" do
        result = described_class.negotiate(local_version: "0.3.1", remote_version: "0.5.0")
        expect(result.status).to eq("compatible")
        expect(result.source).to eq("default")
        expect(result.notes).to match(/vendor-blessed/)
      end
    end

    context "with an operator override row" do
      before do
        ::System::FederationSchemaCompatibility.create!(
          local_version: "0.3.1", remote_version: "0.3.0",
          status: "incompatible", source: "operator",
          notes: "production incident on 0.3.0; pinning incompatible"
        )
      end

      it "overrides what the implicit N-1 rule would have said" do
        # Implicit rule would say 0.3.1 ↔ 0.3.0 = compatible (same major,
        # minor delta 0). Operator says incompatible — operator wins.
        result = described_class.negotiate(local_version: "0.3.1", remote_version: "0.3.0")
        expect(result.status).to eq("incompatible")
        expect(result.source).to eq("operator")
        expect(result.notes).to match(/incident/)
      end
    end

    context "uniqueness invariant" do
      it "rejects a duplicate (local_version, remote_version) row" do
        ::System::FederationSchemaCompatibility.create!(
          local_version: "0.3.1", remote_version: "0.4.0",
          status: "compatible", source: "default"
        )
        dup = ::System::FederationSchemaCompatibility.new(
          local_version: "0.3.1", remote_version: "0.4.0",
          status: "incompatible", source: "operator"
        )
        expect(dup).not_to be_valid
        expect(dup.errors[:local_version]).to be_present
      end
    end
  end
end
