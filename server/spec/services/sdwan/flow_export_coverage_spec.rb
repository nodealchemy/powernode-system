# frozen_string_literal: true

require "rails_helper"

# IMP-5a018031cc29 — the IPFIX pipe had a complete CONSUMER and no producer.
#
# `Sdwan::TopologyCompiler.ipfix_payload_for` stamps an exporter block on every
# ovs-kind HostBridge as soon as an account holds one active
# `Sdwan::IpfixCollector`, and `Sdwan::IpfixIngestService` will happily persist
# whatever a sidecar POSTs. Nothing in the repo deployed that sidecar: no
# module seed, no agent component, no provisioner. So creating a collector
# registered an endpoint that nothing exported to, and every consumer saw the
# same thing it sees when an exporter has DIED — no samples.
#
# This spec pins the distinction the whole task turns on. Three hosts that a
# naive "did any flow arrive?" check cannot tell apart:
#
#   * a LIGHTWEIGHT (linux-bridge) host, which cannot do IPFIX at all — OVS's
#     native exporter is the only source and a Linux bridge has none. That is
#     genuine UNAVAILABILITY and must read as such, never as "configured".
#   * an ovs-capable host with the exporter DEPLOYED whose collector has heard
#     nothing — a dead producer.
#   * an ovs-capable host with the exporter NOT deployed — the defect this
#     task exists to close.
#
# An assertion that merely checks "no samples" holds for all three. Every
# example below therefore asserts on the STATE, and the first example asserts
# the three states are mutually distinct.
RSpec.describe Sdwan::FlowExportCoverage do
  let(:account) { create(:account) }

  # A node + one instance on it, at the requested profile.
  def host(profile:, status: "running")
    node = create(:system_node, account: account)
    create(:system_node_instance,
           account: account, node: node, network_profile: profile, status: status)
  end

  def bridge!(instance, kind:, state: "active")
    create(:sdwan_host_bridge,
           account: account, node_instance: instance, kind: kind, state: state)
  end

  # The seeded producer module. Created directly rather than by loading the
  # seed so this spec pins the COVERAGE semantics only; the seed itself has its
  # own spec.
  #
  # `built:` controls whether the module carries a published version. It
  # defaults TRUE because the interesting states (stalled/reporting) are about
  # a real producer; the unbuilt case is exercised explicitly below. A module
  # with no current_version has no artifact for composition to deliver, so an
  # assignment pointing at it runs nothing on the host.
  def exporter_module!(built: true)
    mod = System::NodeModule.find_or_create_by!(
      account: account, name: described_class::MODULE_NAME
    ) do |m|
      m.variety = "subscription"
      m.enabled = true
    end
    if built && mod.current_version_id.nil?
      version = create(:system_node_module_version, node_module: mod)
      mod.update!(current_version: version, current_version_number: version.version_number)
    end
    mod
  end

  def deploy_exporter!(instance, built: true, enabled: true)
    System::NodeModuleAssignment.find_or_create_by!(
      node: instance.node, node_module: exporter_module!(built: built)
    ) { |a| a.enabled = enabled }
  end

  def collector!(host_value: "127.0.0.1")
    create(:sdwan_ipfix_collector, account: account, host: host_value, port: 4739)
  end

  def state_for(instance)
    described_class.for_account(account).fetch(instance.id).fetch(:state)
  end

  describe "the honest-unavailability contract" do
    it "gives a lightweight host, a dead-exporter host and an undeployed host three DIFFERENT states" do
      collector!

      light = host(profile: "lightweight")
      bridge!(light, kind: "linux")

      dead = host(profile: "heavyweight")
      bridge!(dead, kind: "ovs")
      deploy_exporter!(dead)

      undeployed = host(profile: "heavyweight")
      bridge!(undeployed, kind: "ovs")

      states = [ state_for(light), state_for(dead), state_for(undeployed) ]

      expect(states.uniq.size).to eq(3)
      expect(state_for(light)).to eq("unsupported")
      expect(state_for(dead)).to eq("stalled")
      expect(state_for(undeployed)).to eq("undeployed")
    end

    it "reports a lightweight host as unavailable rather than as expecting an exporter" do
      collector!
      light = host(profile: "lightweight")
      bridge!(light, kind: "linux")

      entry = described_class.for_account(account).fetch(light.id)

      expect(entry[:state]).to eq("unsupported")
      expect(entry[:reason]).to eq("linux_bridge_only")
      expect(entry[:exporter_expected]).to be(false)
      expect(entry[:available]).to be(false)
    end

    # The heavyweight/linux override the allocator supports: a heavyweight host
    # whose only bridge was explicitly allocated kind=linux has no IPFIX source
    # either. Capability is read off the SAME predicate the compiler stamps on
    # (compilable + kind=="ovs"), never off the profile column alone.
    it "reports an ovs-less heavyweight host as unavailable, distinct from lightweight" do
      collector!
      heavy = host(profile: "heavyweight")
      bridge!(heavy, kind: "linux")

      entry = described_class.for_account(account).fetch(heavy.id)

      expect(entry[:state]).to eq("unsupported")
      expect(entry[:reason]).to eq("no_ovs_bridge")
    end

    it "does not treat a non-compilable ovs bridge as a source" do
      collector!
      heavy = host(profile: "heavyweight")
      bridge!(heavy, kind: "ovs", state: "removed")

      expect(state_for(heavy)).to eq("unsupported")
    end
  end

  describe "capable hosts" do
    let!(:heavy) do
      h = host(profile: "heavyweight")
      bridge!(h, kind: "ovs")
      h
    end

    it "is 'unconfigured' when the account has no active collector" do
      entry = described_class.for_account(account).fetch(heavy.id)

      expect(entry[:state]).to eq("unconfigured")
      expect(entry[:available]).to be(true)
      expect(entry[:exporter_expected]).to be(false)
    end

    it "is 'undeployed' when a collector exists but no producer module is assigned" do
      collector!

      entry = described_class.for_account(account).fetch(heavy.id)

      expect(entry[:state]).to eq("undeployed")
      expect(entry[:exporter_expected]).to be(true)
      expect(entry[:exporter_deployed]).to be(false)
    end

    it "is 'stalled' when the producer is deployed but the collector has heard nothing" do
      collector!
      deploy_exporter!(heavy)

      entry = described_class.for_account(account).fetch(heavy.id)

      expect(entry[:state]).to eq("stalled")
      expect(entry[:exporter_deployed]).to be(true)
      expect(entry[:last_sample_at]).to be_nil
    end

    it "is 'reporting' when the producer is deployed and samples arrived in the window" do
      c = collector!
      deploy_exporter!(heavy)
      create(:sdwan_flow_sample, account: account, ipfix_collector: c, observed_at: 1.minute.ago)

      entry = described_class.for_account(account).fetch(heavy.id)

      expect(entry[:state]).to eq("reporting")
      expect(entry[:last_sample_at]).to be_present
    end

    # B2 — the state the fleet is in the instant the catalog row is seeded and
    # before an operator builds it. Reporting this as `stalled` would make the
    # one state that names a DEAD producer the default state of a healthy
    # fleet, which destroys the meaning of the signal.
    it "is 'unbuilt' — not 'stalled' — when the attached module has no published version" do
      collector!
      deploy_exporter!(heavy, built: false)

      entry = described_class.for_account(account).fetch(heavy.id)

      expect(entry[:state]).to eq("unbuilt")
      expect(entry[:reason]).to eq("producer_module_has_no_published_version")
      expect(entry[:exporter_deployed]).to be(true)
    end

    it "does not read 'unbuilt' once the module carries a published version" do
      collector!
      deploy_exporter!(heavy, built: false)
      expect(state_for(heavy)).to eq("unbuilt")

      version = create(:system_node_module_version, node_module: exporter_module!(built: false))
      exporter_module!(built: false)
        .update!(current_version: version, current_version_number: version.version_number)

      expect(described_class.for_account(account).fetch(heavy.id)[:state]).to eq("stalled")
    end

    # B1 — System::Runtime::SyncModules commits only enabled assignments, so a
    # disabled row delivers nothing. Counting it as deployed would report a
    # host the operator switched off as "deployed and dead".
    it "treats a DISABLED assignment as undeployed, not as a dead producer" do
      collector!
      deploy_exporter!(heavy, enabled: false)

      entry = described_class.for_account(account).fetch(heavy.id)

      expect(entry[:state]).to eq("undeployed")
      expect(entry[:exporter_deployed]).to be(false)
    end

    it "falls back to 'stalled' when the only samples predate the window" do
      c = collector!
      deploy_exporter!(heavy)
      create(:sdwan_flow_sample, account: account, ipfix_collector: c,
             observed_at: (described_class::DEFAULT_WINDOW_SECONDS + 600).seconds.ago)

      expect(state_for(heavy)).to eq("stalled")
    end
  end

  describe "collector placement" do
    let!(:heavy) do
      h = host(profile: "heavyweight")
      bridge!(h, kind: "ovs")
      h
    end

    # A loopback target means the exporter must run on the exporting host
    # itself: each host's OVS talks to its own sidecar.
    it "expects a host-local producer for a loopback collector target" do
      collector!(host_value: "127.0.0.1")

      expect(described_class.placement_for(account).mode).to eq(:host_local)
    end

    # A target that resolves to one of the account's own peers is a CENTRAL
    # collector on a fleet host: exactly one machine must run the producer, and
    # we know which, because the address is a peer's assigned_address.
    it "expects a single fleet producer when the collector target is one of our peers" do
      peer_host = host(profile: "heavyweight")
      network = create(:sdwan_network, account: account)
      create(:sdwan_peer, account: account, network: network,
             node_instance: peer_host, assigned_address: "fd00:abcd:1::5")
      collector!(host_value: "fd00:abcd:1::5")

      placement = described_class.placement_for(account)

      expect(placement.mode).to eq(:fleet_host)
      expect(placement.node_ids).to eq([ peer_host.node_id ])
    end

    # An address the platform does not own is an operator-run collector. We do
    # not pretend to deploy anything there, and we say so rather than reporting
    # the hosts as broken.
    it "reports 'external' — never 'undeployed' — for an off-fleet collector target" do
      collector!(host_value: "198.51.100.7")

      entry = described_class.for_account(account).fetch(heavy.id)

      expect(described_class.placement_for(account).mode).to eq(:external)
      expect(entry[:state]).to eq("external")
      expect(entry[:exporter_expected]).to be(false)
      expect(entry[:available]).to be(true)
    end
  end

  describe ".summary" do
    it "counts hosts by state and never counts an unsupported host as a gap" do
      collector!
      light = host(profile: "lightweight")
      bridge!(light, kind: "linux")
      heavy = host(profile: "heavyweight")
      bridge!(heavy, kind: "ovs")

      summary = described_class.summary(account)

      expect(summary[:by_state]).to include("unsupported" => 1, "undeployed" => 1)
      expect(described_class::GAP_STATES).to include("unbuilt")
      expect(summary[:unsupported_host_ids]).to eq([ light.id ])
      expect(summary[:gap_host_ids]).to eq([ heavy.id ])
    end
  end
end
