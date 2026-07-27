# frozen_string_literal: true

require "rails_helper"

# With Proxmox HA deliberately not used (design §6.2 — enabling it would have
# armed the softdog self-fence on the host running the production firewall),
# NOTHING involuntarily terminates a control-plane VM. This gate is the only
# thing between a partition and dual-active, so every test here is really the
# same question: does it stand down when it cannot prove it should act?
RSpec.describe System::Autonomy::ControlPlaneRole do
  # Real `corosync-quorumtool -s` output for the RCP guest quorum: two members
  # plus the qnetd QDevice, which appears in the membership table as a node with
  # id 0. That row is why this fixture is verbatim rather than trimmed.
  def quorumtool_output(quorate: "Yes", local_id: 1)
    <<~OUT
      Quorum information
      ------------------
      Date:             Sun Jul 26 16:35:49 2026
      Quorum provider:  corosync_votequorum
      Nodes:            2
      Node ID:          #{local_id}
      Ring ID:          1.4ee0
      Quorate:          #{quorate}

      Votequorum information
      ----------------------
      Expected votes:   3
      Highest expected: 3
      Total votes:      3
      Quorum:           2
      Flags:            Quorate Qdevice

      Membership information
      ----------------------
          Nodeid      Votes    Qdevice Name
               1          1    A,V,NMW ops-hub-a (local)
               2          1    A,V,NMW ops-hub-b
               0          1            Qdevice
    OUT
  end

  def arm!(coordinator: "rcp-quorum", freshness: nil)
    allow(::SiteSetting).to receive(:get).with(described_class::COORDINATOR_KEY).and_return(coordinator)
    allow(::SiteSetting).to receive(:get).with(described_class::FRESHNESS_KEY).and_return(freshness)
  end

  def reader_returns(output)
    described_class.quorum_reader = -> { output }
  end

  after { described_class.reset_quorum_reader! }

  describe "when UNARMED (single-plane — today, and core-mode forever)" do
    before { arm!(coordinator: nil) }

    it "is active, so a single-plane deployment behaves exactly as before" do
      expect(described_class.active?).to be true
    end

    it "never consults the quorum at all — no corosync required to run one plane" do
      called = false
      described_class.quorum_reader = -> { called = true; quorumtool_output }
      described_class.active?
      expect(called).to be false
    end
  end

  describe "when ARMED" do
    before { arm! }

    it "is active when quorate and holding the lowest member id" do
      reader_returns(quorumtool_output(local_id: 1))
      expect(described_class.active?).to be true
    end

    # THE bug this fixture exists to catch. The QDevice sits in the membership
    # table as nodeid 0. Counting it makes 0 the minimum, so no real node is ever
    # the lowest and BOTH planes stand down forever — a total control-plane
    # outage that looks exactly like correct fail-closed behaviour.
    it "excludes the QDevice pseudo-node (id 0) from the election" do
      reader_returns(quorumtool_output(local_id: 1))
      reading = described_class.current_reading
      expect(reading.member_node_ids).to eq([ 1, 2 ])
      expect(reading.member_node_ids).not_to include(0)
      expect(reading.elected?).to be true
    end

    it "stands down on the higher-ranked plane, so exactly one side acts" do
      reader_returns(quorumtool_output(local_id: 2))
      expect(described_class.active?).to be false
    end

    it "stands down when inquorate" do
      reader_returns(quorumtool_output(quorate: "No", local_id: 1))
      expect(described_class.active?).to be false
    end
  end

  # Every one of these would be a dual-active window if it returned true.
  describe "fail-closed once armed" do
    before { arm! }

    it "stands down when the quorum command is missing (binary absent ⇒ nil)" do
      reader_returns(nil)
      expect(described_class.active?).to be false
    end

    it "stands down when the quorum reader raises" do
      described_class.quorum_reader = -> { raise Errno::ENOENT, "corosync-quorumtool" }
      expect(described_class.active?).to be false
    end

    it "stands down on unparseable output rather than guessing" do
      reader_returns("corosync-quorumtool: Cannot initialize QUORUM service\n")
      expect(described_class.active?).to be false
    end

    it "stands down when the output omits the local node id" do
      reader_returns("Quorum information\nQuorate:          Yes\n")
      expect(described_class.active?).to be false
    end

    it "stands down when quorate but membership is empty — nothing to be lowest of" do
      reader_returns("Node ID:          1\nQuorate:          Yes\n")
      expect(described_class.active?).to be false
    end

    it "stands down rather than raising when the gate itself errors unexpectedly" do
      allow(described_class).to receive(:current_reading).and_raise(RuntimeError, "boom")
      expect(described_class.active?).to be false
    end
  end

  describe "freshness — a stale reading is no reading" do
    before { arm! }

    # The carried-reading path, which is what freshness actually protects: an
    # irreversible action captures a reading, carries it with the plan, and
    # re-asserts before committing. A plan authored while quorate must not be
    # committable after quorum was lost.
    it "refuses a CARRIED reading once it is older than the TTL" do
      reader_returns(quorumtool_output(local_id: 1))
      t0 = Time.current
      carried = described_class.current_reading(now: t0)

      expect(described_class.active?(now: t0, reading: carried)).to be true

      later = t0 + described_class::DEFAULT_FRESHNESS_SECONDS + 1
      expect(carried.fresh?(later)).to be false
      expect(described_class.active?(now: later, reading: carried)).to be false
    end

    it "still elects on a carried reading that is within the TTL" do
      reader_returns(quorumtool_output(local_id: 1))
      t0 = Time.current
      carried = described_class.current_reading(now: t0)
      just_inside = t0 + described_class::DEFAULT_FRESHNESS_SECONDS - 1
      expect(described_class.active?(now: just_inside, reading: carried)).to be true
    end

    it "observes afresh when no reading is carried" do
      reader_returns(quorumtool_output(local_id: 1))
      expect(described_class.active?).to be true
    end

    it "clamps a configured freshness to the maximum, so the window can't be widened arbitrarily" do
      arm!(freshness: 3600)
      expect(described_class.freshness_seconds).to eq(described_class::MAX_FRESHNESS_SECONDS)
    end

    it "falls back to the default for absent or nonsense values" do
      arm!(freshness: nil)
      expect(described_class.freshness_seconds).to eq(described_class::DEFAULT_FRESHNESS_SECONDS)
      arm!(freshness: 0)
      expect(described_class.freshness_seconds).to eq(described_class::DEFAULT_FRESHNESS_SECONDS)
    end

    it "re-reads the quorum on every call — never memoized across calls" do
      calls = 0
      described_class.quorum_reader = -> { calls += 1; quorumtool_output(local_id: 1) }
      3.times { described_class.active? }
      expect(calls).to eq(3)
    end
  end

  describe "arming is read fresh" do
    it "takes effect without a process restart when disarmed mid-flight" do
      arm!
      reader_returns(quorumtool_output(local_id: 2))
      expect(described_class.active?).to be false

      # Operator disarms during an incident; the plane must resume single-plane
      # behaviour immediately rather than after a restart.
      arm!(coordinator: nil)
      expect(described_class.active?).to be true
    end
  end

  describe "node id parsing" do
    before { arm! }

    it "accepts the 0x-prefixed form some corosync builds print" do
      reader_returns(<<~OUT)
        Node ID:          0x00000001
        Quorate:          Yes

        Membership information
        ----------------------
            Nodeid      Votes Name
        0x00000001          1 ops-hub-a (local)
        0x00000002          1 ops-hub-b
      OUT
      reading = described_class.current_reading
      expect(reading.local_node_id).to eq(1)
      expect(reading.member_node_ids).to eq([ 1, 2 ])
      expect(described_class.active?).to be true
    end
  end
end
