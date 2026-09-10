# frozen_string_literal: true

require "rails_helper"

# Campaign 01a08c9b increment A2 — core's Platform::Status::SweepRunner fences a
# STANDBY control plane out of sweeping, and resolves the role through the
# generic provider seam because it must not name this extension.
#
# WHY THIS SPEC EXISTS AT ALL: core documents a nil provider as "inert, sweep
# normally", which is right for core mode and wrong for a dual-plane
# deployment — the fence would silently permit both planes to act. An
# unregistered provider is therefore not a missing feature, it is an inert
# safety device, and the failure is invisible: the sweep returns normally.
# Nothing else in the tree asserts the registration, so this does.
RSpec.describe "control_plane_role provider registration" do
  let(:provider) { Powernode::ExtensionRegistry.provider(:control_plane_role) }

  # Real `corosync-quorumtool -s` output, verbatim from the RCP guest quorum:
  # two members plus the qnetd QDevice, which appears with node id 0. Copied
  # from control_plane_role_spec.rb rather than trimmed, because the id-0 row is
  # the one a tidy fixture would have hidden.
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

  def arm!(coordinator: "rcp-quorum")
    allow(::SiteSetting).to receive(:get).and_call_original
    allow(::SiteSetting).to receive(:get)
      .with(System::Autonomy::ControlPlaneRole::COORDINATOR_KEY).and_return(coordinator)
    allow(::SiteSetting).to receive(:get)
      .with(System::Autonomy::ControlPlaneRole::FRESHNESS_KEY).and_return(nil)
  end

  after { System::Autonomy::ControlPlaneRole.reset_quorum_reader! }

  it "resolves to ControlPlaneRole itself" do
    # The seam constantizes and returns the CLASS, and `active?` is a class
    # method whose keywords all default — so no adapter sits in between and
    # nothing can drift out of sync with the gate's own contract.
    expect(provider).to eq(System::Autonomy::ControlPlaneRole)
    expect(provider).to respond_to(:active?)
    expect(provider.method(:active?).arity).to be <= 0
  end

  it "reports active on the plane the quorum elects" do
    arm!
    System::Autonomy::ControlPlaneRole.quorum_reader = -> { quorumtool_output(local_id: 1) }

    expect(provider.active?).to be(true)
    expect(Platform::Status::SweepRunner.control_plane_active?).to be(true)
  end

  it "reports not active on the standby plane" do
    # Same quorate reading, read from node 2. Lowest live node id wins, so B
    # stands down while A acts — the whole point of the fence.
    arm!
    System::Autonomy::ControlPlaneRole.quorum_reader = -> { quorumtool_output(local_id: 2) }

    expect(provider.active?).to be(false)
    expect(Platform::Status::SweepRunner.control_plane_active?).to be(false)
  end

  it "stands the plane down when the quorum cannot be read at all" do
    arm!
    System::Autonomy::ControlPlaneRole.quorum_reader = -> { nil }

    expect(Platform::Status::SweepRunner.control_plane_active?).to be(false)
  end

  it "stays inert while the gate is unarmed, so a single-plane deployment sweeps" do
    allow(::SiteSetting).to receive(:get).and_call_original
    allow(::SiteSetting).to receive(:get)
      .with(System::Autonomy::ControlPlaneRole::COORDINATOR_KEY).and_return(nil)

    expect(provider.active?).to be(true)
    expect(Platform::Status::SweepRunner.control_plane_active?).to be(true)
  end

  describe "the runner actually halts on the standby verdict" do
    let(:account) { create(:account) }

    it "skips the sweep with reason standby, and runs it when active" do
      arm!
      System::Autonomy::ControlPlaneRole.quorum_reader = -> { quorumtool_output(local_id: 2) }

      standby = Platform::Status::SweepRunner.run!(account)
      expect(standby[:skipped]).to be(true)
      expect(standby[:reason]).to eq(Platform::Status::SweepRunner::REASON_STANDBY)

      System::Autonomy::ControlPlaneRole.quorum_reader = -> { quorumtool_output(local_id: 1) }

      active = Platform::Status::SweepRunner.run!(account)
      expect(active[:skipped]).to be(false)
    end
  end
end
