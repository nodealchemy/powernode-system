# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::FederationCapability, type: :model do
  describe "constants" do
    it "defines DIRECTIONS, POLICIES, CONFLICT_RESOLUTIONS" do
      expect(described_class::DIRECTIONS).to include("push_local_to_remote", "pull_remote_to_local", "bidirectional", "migration_only")
      expect(described_class::POLICIES).to include("manual", "auto_on_change", "auto_periodic", "on_match_filter")
      expect(described_class::CONFLICT_RESOLUTIONS).to include("newer_wins_logical_clock")
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:federation_peer).class_name("System::FederationPeer") }
  end

  describe "validations" do
    subject { build(:system_federation_capability) }

    it { is_expected.to validate_inclusion_of(:direction).in_array(described_class::DIRECTIONS) }
    it { is_expected.to validate_inclusion_of(:policy).in_array(described_class::POLICIES) }
    it { is_expected.to validate_inclusion_of(:conflict_resolution).in_array(described_class::CONFLICT_RESOLUTIONS) }
    it { is_expected.to validate_presence_of(:resource_kind) }

    it "enforces uniqueness on (peer, resource_kind, direction)" do
      existing = create(:system_federation_capability,
                        resource_kind: "skill", direction: "bidirectional")
      dup = build(:system_federation_capability,
                  federation_peer: existing.federation_peer,
                  account: existing.account,
                  resource_kind: "skill",
                  direction: "bidirectional")
      expect(dup).not_to be_valid
      expect(dup.errors[:resource_kind]).to include("has already been taken")
    end

    it "allows same kind in different directions" do
      first = create(:system_federation_capability,
                     resource_kind: "skill", direction: "push_local_to_remote")
      second = build(:system_federation_capability,
                     federation_peer: first.federation_peer,
                     account: first.account,
                     resource_kind: "skill",
                     direction: "pull_remote_to_local")
      expect(second).to be_valid
    end
  end

  describe "scopes" do
    let!(:manual)        { create(:system_federation_capability, policy: "manual") }
    let!(:auto_periodic) { create(:system_federation_capability, :auto_periodic) }
    let!(:outbound)      { create(:system_federation_capability, :outbound_only) }
    let!(:inbound)       { create(:system_federation_capability, :inbound_only) }

    it ".auto_flow excludes manual" do
      expect(described_class.auto_flow).to include(auto_periodic)
      expect(described_class.auto_flow).not_to include(manual)
    end

    it ".outbound includes push + bidirectional but not pull-only" do
      expect(described_class.outbound).to include(manual, auto_periodic, outbound)
      expect(described_class.outbound).not_to include(inbound)
    end

    it ".inbound includes pull + bidirectional but not push-only" do
      expect(described_class.inbound).to include(manual, auto_periodic, inbound)
      expect(described_class.inbound).not_to include(outbound)
    end
  end

  describe "#auto?" do
    it "returns false for manual policy" do
      expect(build(:system_federation_capability, policy: "manual").auto?).to be false
    end

    it "returns true for any non-manual policy" do
      %w[auto_on_change auto_periodic on_match_filter].each do |p|
        expect(build(:system_federation_capability, policy: p).auto?).to be true
      end
    end
  end

  describe "#covers_direction?" do
    it "matches the exact direction" do
      cap = build(:system_federation_capability, direction: "push_local_to_remote")
      expect(cap.covers_direction?("push_local_to_remote")).to be true
      expect(cap.covers_direction?("pull_remote_to_local")).to be false
    end

    it "matches both sub-directions for bidirectional" do
      cap = build(:system_federation_capability, direction: "bidirectional")
      expect(cap.covers_direction?("push_local_to_remote")).to be true
      expect(cap.covers_direction?("pull_remote_to_local")).to be true
    end
  end

  describe "#filter_matches?" do
    it "returns true when filter is empty (no constraint)" do
      cap = build(:system_federation_capability, filter: {})
      expect(cap.filter_matches?({ tags: [ "public" ] })).to be true
    end

    it "returns true when array filter intersects record value" do
      cap = build(:system_federation_capability, filter: { "tags" => [ "public", "shared" ] })
      expect(cap.filter_matches?({ "tags" => [ "public" ] })).to be true
    end

    it "returns false when filter doesn't match" do
      cap = build(:system_federation_capability, filter: { "tags" => [ "public" ] })
      expect(cap.filter_matches?({ "tags" => [ "private" ] })).to be false
    end
  end
end
