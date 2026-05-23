# frozen_string_literal: true

require "rails_helper"

RSpec.describe ::System::Identity::UserAllocator, type: :service do
  before do
    ::System::ModuleUserDeclaration.delete_all
    ::System::ServiceUserGroupMembership.delete_all
    ::System::ServiceUser.delete_all
    ::System::ServiceGroup.delete_all
  end

  describe ".allocate!" do
    it "creates a ServiceUser plus an auto-allocated same-name primary group" do
      u = described_class.allocate!(username: "myapp-#{SecureRandom.hex(3)}")
      expect(u).to be_persisted
      expect(u.primary_group).to be_a(::System::ServiceGroup)
      expect(u.primary_group.groupname).to eq(u.username)
      expect(u.primary_gid).to eq(u.primary_group.gid)
    end

    it "uses the reserved-table UID for a well-known daemon name" do
      u = described_class.allocate!(username: "postgres")
      expect(u.uid).to eq(70_110)
      expect(u.primary_gid).to eq(70_110)
    end

    it "is idempotent — repeating with the same username returns the same row" do
      first  = described_class.allocate!(username: "redis")
      second = described_class.allocate!(username: "redis")
      expect(second.id).to eq(first.id)
    end

    it "applies updated rendering hints on re-allocation" do
      u = described_class.allocate!(username: "tweak-#{SecureRandom.hex(3)}",
                                    shell: "/bin/sh", home: "/var/lib/tweak", gecos: "v1")
      reclaimed = described_class.allocate!(username: u.username,
                                            shell: "/bin/bash", home: "/opt/tweak", gecos: "v2")
      expect(reclaimed.reload.shell).to eq("/bin/bash")
      expect(reclaimed.home).to eq("/opt/tweak")
      expect(reclaimed.gecos).to eq("v2")
    end

    it "creates supplementary group memberships and reconciles them on re-allocation" do
      u = described_class.allocate!(
        username: "ssl-#{SecureRandom.hex(3)}",
        supplementary_groups: %w[ssl-cert]
      )
      expect(u.supplementary_groups.map(&:groupname)).to contain_exactly("ssl-cert")

      # Re-allocate with a different set — the old membership should be revoked.
      described_class.allocate!(
        username: u.username,
        supplementary_groups: %w[adm]
      )
      expect(u.reload.supplementary_groups.map(&:groupname)).to contain_exactly("adm")
    end

    it "rejects invalid username format" do
      expect {
        described_class.allocate!(username: "BadName")
      }.to raise_error(::System::Identity::UserAllocator::InvalidArguments)
    end

    it "treats draining rows as still-allocated (does not reuse the UID)" do
      u1 = described_class.allocate!(username: "ephemeral-a")
      described_class.release!(u1)
      u2 = described_class.allocate!(username: "ephemeral-b")
      expect(u2.uid).not_to eq(u1.uid)
    end

    it "readopts a draining user when its name is re-declared" do
      u1 = described_class.allocate!(username: "phoenix-svc")
      original_uid = u1.uid
      described_class.release!(u1)
      expect(u1.reload.state).to eq("draining")

      reclaimed = described_class.allocate!(username: "phoenix-svc")
      expect(reclaimed.id).to eq(u1.id)
      expect(reclaimed.reload.state).to eq("active")
      expect(reclaimed.uid).to eq(original_uid)
    end
  end
end
