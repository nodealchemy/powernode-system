# frozen_string_literal: true

require "rails_helper"

# An operator hold blocks the platform from starting an instance while offline
# work is happening on its disks.
#
# The incident it exists for (2026-07-27, ops-hub): the control plane was
# stopped so its /persist could be edited from the hypervisor, and something
# issued a start 30 SECONDS later. For about a minute the guest and the host
# both had the same ext4 mounted read-write. A blob copied in during that window
# landed as a zero-byte file in the guest's view while hashing correctly from
# the host's — so every tool reported success — and the node's frozen boot-LKG
# was left pointing at a truncated blob. A latent brick, invisible until a
# later boot.
RSpec.describe "instance ops hold" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }
  let(:node)    { create(:system_node, account: account) }
  let(:instance) do
    create(:system_node_instance, node: node, account: account, status: "stopped", key: "dna:qemu:600")
  end

  # No provider connection in specs — Registry.for_instance raises, the service
  # degrades to platform-only enforcement, and that path is itself worth
  # covering since it is what any provider without a lock primitive gets.
  describe System::InstanceOpsHoldService do
    describe ".hold!" do
      it "records who, why and until when" do
        result = described_class.hold!(instance: instance, user: user, reason: "offline /persist edit", ttl: 2.hours)

        expect(result).to be_ok
        instance.reload
        expect(instance).to be_ops_held
        expect(instance.ops_hold_reason).to eq("offline /persist edit")
        expect(instance.ops_hold_by_id).to eq(user.id)
        expect(instance.ops_hold_expires_at).to be_within(1.minute).of(2.hours.from_now)
      end

      # An unattributed flag that blocks starts is indistinguishable from a bug
      # six months later.
      it "refuses a hold with no reason" do
        result = described_class.hold!(instance: instance, user: user, reason: "")
        expect(result).not_to be_ok
        expect(result.error).to match(/reason is required/i)
        expect(instance.reload).not_to be_ops_held
      end

      it "refuses to double-hold and names the existing holder" do
        described_class.hold!(instance: instance, user: user, reason: "first")
        result = described_class.hold!(instance: instance, user: user, reason: "second")

        expect(result).not_to be_ok
        expect(result.error).to match(/already/i)
        expect(result.error).to include("first")
      end

      # "held" must not silently mean two different things depending on provider.
      it "says plainly when the provider cannot enforce the hold" do
        result = described_class.hold!(instance: instance, user: user, reason: "offline edit")
        expect(result.provider_enforced).to be false
        expect(result.message).to match(/cannot enforce/i)
      end
    end

    describe ".release!" do
      it "clears the lease" do
        described_class.hold!(instance: instance, user: user, reason: "offline edit")
        result = described_class.release!(instance: instance, user: user)

        expect(result).to be_ok
        expect(instance.reload).not_to be_ops_held
        expect(instance.ops_hold_reason).to be_nil
      end

      it "reports when there is nothing to release" do
        expect(described_class.release!(instance: instance, user: user)).not_to be_ok
      end
    end

    # Expiry ALERTS, it does not release. A hold that lifts itself part-way
    # through maintenance is worse than no hold, because the operator believes
    # they are still protected.
    describe "expiry" do
      it "stays held past its lease and says so" do
        described_class.hold!(instance: instance, user: user, reason: "long edit", ttl: 1.hour)
        instance.update!(ops_hold_expires_at: 5.minutes.ago)

        expect(instance).to be_ops_held
        expect(instance).to be_ops_hold_expired
        expect(instance.ops_hold_summary).to match(/expired/i)
      end
    end
  end

  describe System::InstanceControlService do
    before { System::InstanceOpsHoldService.hold!(instance: instance, user: user, reason: "offline /persist edit") }

    # THE regression.
    it "refuses to start a held instance" do
      result = described_class.execute(instance: instance, action: :start)

      expect(result.success).to be false
      expect(result.error).to match(/ops hold/i)
      expect(result.error).to include("offline /persist edit")
    end

    it "refuses reboot and terminate too" do
      %i[reboot terminate].each do |action|
        expect(described_class.execute(instance: instance, action: action).success).to be false
      end
    end

    # force exists for provider stubbornness, not for overriding a human who
    # said "do not start this while I have its disk mounted".
    it "is not overridable with force" do
      result = described_class.execute(instance: instance, action: :start, force: true)
      expect(result.success).to be false
      expect(result.error).to match(/not overridable with force/i)
    end

    # The point of a hold is that the instance is DOWN, so stopping one that is
    # somehow up moves toward the operator's intent.
    it "still permits stop" do
      result = described_class.execute(instance: instance, action: :stop)
      expect(result.error.to_s).not_to match(/ops hold/i)
    end

    it "permits start again once released" do
      System::InstanceOpsHoldService.release!(instance: instance, user: user)
      result = described_class.execute(instance: instance.reload, action: :start)
      expect(result.error.to_s).not_to match(/ops hold/i)
    end
  end
end
