# frozen_string_literal: true

require "rails_helper"

RSpec.describe ::System::Identity::ReservedIdentities do
  describe ".uid_for / .gid_for" do
    it "resolves a well-known daemon name from the 70xxx allocator range" do
      expect(described_class.uid_for("postgres")).to eq(70_110)
      expect(described_class.gid_for("postgres")).to eq(70_110)
    end

    it "returns nil for an unknown name" do
      expect(described_class.uid_for("totally-unknown-#{SecureRandom.hex(3)}")).to be_nil
    end

    it "resolves the baseline pnadmin account to its fixed uid/gid (1000)" do
      expect(described_class.uid_for("pnadmin")).to eq(1_000)
      expect(described_class.gid_for("pnadmin")).to eq(1_000)
    end

    it "does NOT reserve sequentially-allocated module users like pnrunner" do
      expect(described_class.uid_for("pnrunner")).to be_nil
      expect(described_class.gid_for("pnrunner")).to be_nil
    end
  end

  describe ".all_reserved_ids" do
    it "includes both 70xxx allocator entries and the baseline pnadmin uid" do
      ids = described_class.all_reserved_ids
      expect(ids).to include(70_110) # postgres
      expect(ids).to include(1_000)  # pnadmin (BASELINE — outside the 70xxx range)
    end
  end

  describe "BASELINE" do
    it "is folded into USERS and GROUPS" do
      expect(described_class::USERS["pnadmin"]).to eq(1_000)
      expect(described_class::GROUPS["pnadmin"]).to eq(1_000)
    end

    it "sits outside the 70xxx allocator range (SEQUENTIAL_FLOOR and reserved-table entries)" do
      described_class::BASELINE.each_value do |id|
        expect(id).to be < ::System::Identity::ReservedIdentities::SEQUENTIAL_FLOOR
      end
    end
  end
end
