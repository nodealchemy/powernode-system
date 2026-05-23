# frozen_string_literal: true

require "rails_helper"

RSpec.describe ::System::Identity::GroupAllocator, type: :service do
  before do
    # The identity tables are platform-global (no account scoping), so
    # tests need a clean slate to avoid cross-test interference.
    ::System::ModuleUserDeclaration.delete_all
    ::System::ServiceUserGroupMembership.delete_all
    ::System::ServiceUser.delete_all
    ::System::ServiceGroup.delete_all
  end

  describe ".allocate!" do
    it "creates a new ServiceGroup at the sequential floor (71000) for an unknown name" do
      g = described_class.allocate!(groupname: "qux-#{SecureRandom.hex(3)}")
      expect(g).to be_persisted
      expect(g.gid).to eq(71_000)
      expect(g.state).to eq("active")
    end

    it "uses the reserved-table GID for a well-known daemon name" do
      g = described_class.allocate!(groupname: "postgres")
      expect(g.gid).to eq(70_110)
    end

    it "is idempotent — calling twice returns the same row" do
      first  = described_class.allocate!(groupname: "redis")
      second = described_class.allocate!(groupname: "redis")
      expect(second.id).to eq(first.id)
      expect(::System::ServiceGroup.where(groupname: "redis").count).to eq(1)
    end

    it "skips reserved-pool GIDs when assigning sequentially" do
      # Allocate one non-reserved name; should land at 71000 (above reserved range).
      g1 = described_class.allocate!(groupname: "alpha-svc")
      g2 = described_class.allocate!(groupname: "beta-svc")
      expect([g1.gid, g2.gid]).to eq([71_000, 71_001])
      expect(g1.gid).to be >= ::System::Identity::ReservedIdentities::SEQUENTIAL_FLOOR
    end

    it "rejects invalid group names" do
      expect {
        described_class.allocate!(groupname: "Bad Name")
      }.to raise_error(::System::Identity::GroupAllocator::InvalidArguments)
    end

    it "treats draining rows as still-allocated (does not reuse the GID)" do
      g1 = described_class.allocate!(groupname: "gamma-svc")
      described_class.release!(g1)  # transitions to draining
      g2 = described_class.allocate!(groupname: "delta-svc")
      expect(g2.gid).not_to eq(g1.gid)
    end

    it "readopts a draining row when its name is re-declared before the reaper sweeps it" do
      g1 = described_class.allocate!(groupname: "eps-svc")
      described_class.release!(g1)
      expect(g1.reload.state).to eq("draining")

      reclaimed = described_class.allocate!(groupname: "eps-svc")
      expect(reclaimed.id).to eq(g1.id)
      expect(reclaimed.reload.state).to eq("active")
    end
  end
end
