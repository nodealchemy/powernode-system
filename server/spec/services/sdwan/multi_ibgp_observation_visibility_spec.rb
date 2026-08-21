# frozen_string_literal: true

require "rails_helper"

# IMP-2f34679b6b73 — the second half of the fix: a BGP observation the
# platform refuses to attribute must be VISIBLE, not merely absent. This
# covers the whole path — the enrollment seam that records the shape, the
# writer that reads it, the sensor that surfaces it, and the DecisionEngine
# binding that decides whether the signal reaches anyone at all.
RSpec.describe "multi-iBGP BGP observation visibility", type: :service do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::BgpSession.delete_all
    Sdwan::Network.where(account_id: account.id).destroy_all
    Sdwan::Configuration.where(account_id: account.id).destroy_all
  end

  let!(:net_a) do
    Sdwan::Network.create!(account_id: account.id, name: "vis-a-#{SecureRandom.hex(3)}", routing_protocol: "ibgp")
  end
  let!(:net_b) do
    Sdwan::Network.create!(account_id: account.id, name: "vis-b-#{SecureRandom.hex(3)}", routing_protocol: "ibgp")
  end
  let!(:net_static) do
    Sdwan::Network.create!(account_id: account.id, name: "vis-s-#{SecureRandom.hex(3)}", routing_protocol: "static")
  end

  let!(:node) { sdwan_test_node(account: account) }
  let!(:host) { sdwan_test_node_instance(node: node) }
  let!(:other_host) { sdwan_test_node_instance(node: node) }

  def enroll(network)
    Sdwan::PeerEnroller.call(network: network, node_instance: host)
  end

  describe Sdwan::MultiIbgpHostFlagger do
    it "does not flag a host with a single iBGP membership" do
      peer = enroll(net_a)
      expect(peer.reload.bgp_session_state[described_class::KEY]).to be_nil
    end

    it "does not flag a host whose second membership is a static network" do
      peer_a = enroll(net_a)
      enroll(net_static)
      expect(peer_a.reload.bgp_session_state[described_class::KEY]).to be_nil
    end

    it "flags EVERY peer on the host once a second iBGP network is enrolled" do
      peer_a = enroll(net_a)
      peer_b = enroll(net_b)

      [ peer_a, peer_b ].each do |peer|
        flag = peer.reload.bgp_session_state[described_class::KEY]
        expect(flag).to be_present
        expect(flag["network_ids"]).to match_array([ net_a.id, net_b.id ])
        expect(flag["risk"]).to eq(described_class::RISK)
      end
    end

    it "clears the flag when the host drops back to one iBGP network" do
      peer_a = enroll(net_a)
      enroll(net_b)
      expect(peer_a.reload.bgp_session_state[described_class::KEY]).to be_present

      Sdwan::PeerDetacher.call(node_instance: host, network: net_b)

      expect(peer_a.reload.bgp_session_state[described_class::KEY]).to be_nil
    end

    # The FKs from system_sdwan_bgp_sessions to system_sdwan_peers are NO
    # ACTION in the baseline schema, and Sdwan::Peer declared no association
    # for them: peer.destroy! raised InvalidForeignKey for any peer that had
    # ever been OBSERVED, which is every iBGP peer this change is about — so
    # the destroy callback below could never run on the hosts that need it.
    it "destroys a peer that has BGP session rows, and takes them with it" do
      peer_a = enroll(net_a)
      neighbor = Sdwan::PeerEnroller.call(network: net_a, node_instance: other_host)
      owned = Sdwan::BgpSession.create!(
        sdwan_peer_id: peer_a.id, sdwan_network_id: net_a.id,
        neighbor_peer_id: neighbor.id,
        neighbor_address: neighbor.assigned_address.to_s.split("/").first,
        state: "established", last_observed_at: Time.current, last_state_change_at: Time.current
      )

      expect { neighbor.destroy! }.not_to raise_error
      # The session belongs to the peer that OBSERVED it, so losing the
      # neighbour only loses the FK-resolved name.
      expect(owned.reload.neighbor_peer_id).to be_nil

      expect { peer_a.destroy! }.not_to raise_error
      expect(Sdwan::BgpSession.where(id: owned.id)).to be_empty
    end

    # PeerDetacher is NOT the path operators and autonomy actually take —
    # Sdwan::Executors::DeletePeer calls peer.destroy! directly, as do several
    # composition skills. A flag that only cleared via PeerDetacher would keep
    # a critical-severity signal firing for a condition that ended.
    it "clears the flag when the peer is destroyed outside PeerDetacher" do
      peer_a = enroll(net_a)
      peer_b = enroll(net_b)
      expect(peer_a.reload.bgp_session_state[described_class::KEY]).to be_present

      peer_b.destroy!

      expect(peer_a.reload.bgp_session_state[described_class::KEY]).to be_nil
    end

    it "clears the flag when the whole network is destroyed (dependent: :destroy cascade)" do
      peer_a = enroll(net_a)
      enroll(net_b)
      expect(peer_a.reload.bgp_session_state[described_class::KEY]).to be_present

      net_b.destroy!

      expect(peer_a.reload.bgp_session_state[described_class::KEY]).to be_nil
    end

    # Both the enrollment stamp and the agent's per-tick observation stamp
    # write this one jsonb column from different request cycles. A
    # read-modify-write of the whole document from either erases the other.
    it "does not clobber a sibling key written concurrently" do
      peer_a = enroll(net_a)
      peer_b = enroll(net_b)

      Sdwan::BgpSessionWriter.new(
        instance: host, peer_by_network: { net_a.id => peer_a, net_b.id => peer_b },
        networks_payload: [ { network_id: net_b.id, measured: true, sessions: [] } ]
      ).write!

      state = peer_b.reload.bgp_session_state
      expect(state["observation"]).to be_present
      expect(state[described_class::KEY]).to be_present
    end
  end

  describe Sdwan::BgpSessionWriter do
    # The silent case the containment guard alone cannot catch: an unscoped
    # agent whose single global poll came back EMPTY. Nothing is rejected, so
    # there is nothing to reject — but a poll that never named this network's
    # VRF still measured nothing about it.
    it "refuses to call an unscoped agent's empty report a measurement on a flagged host" do
      peer_a = enroll(net_a)
      peer_b = enroll(net_b)

      described_class.new(
        instance: host,
        peer_by_network: { net_a.id => peer_a, net_b.id => peer_b },
        networks_payload: [ { network_id: net_b.id, sessions: [] } ] # no `measured` key = legacy agent
      ).write!

      observation = peer_b.reload.bgp_session_state["observation"]
      expect(observation["status"]).to eq("unattributable")
      expect(observation["reason"]).to eq("legacy_unscoped_agent")
      expect(observation["agent_vrf_scoped"]).to be(false)
    end

    # The flag is PROVENANCE, not the gate. Every host that was already
    # multi-iBGP before this shipped has no flag, and a missing flag must not
    # read as "single network, so that zero is real".
    it "refuses an unscoped agent's empty report on a multi-iBGP host with NO flag stamped" do
      peer_a = enroll(net_a)
      peer_b = enroll(net_b)
      # Simulate the pre-existing fleet: the shape is live, the stamp is not.
      [ peer_a, peer_b ].each do |p|
        Sdwan::MultiIbgpHostFlagger.delete_key!(peer_id: p.id, key: Sdwan::MultiIbgpHostFlagger::KEY)
      end
      expect(peer_b.reload.bgp_session_state[Sdwan::MultiIbgpHostFlagger::KEY]).to be_nil

      described_class.new(
        instance: host, peer_by_network: { net_a.id => peer_a, net_b.id => peer_b },
        networks_payload: [ { network_id: net_b.id, sessions: [] } ]
      ).write!

      observation = peer_b.reload.bgp_session_state["observation"]
      expect(observation["status"]).to eq("unattributable")
      expect(observation["reason"]).to eq("legacy_unscoped_agent")
    end

    # A payload that says `measured: null` asserts nothing. Treating it as a
    # VRF-scoped agent would hand the weakest possible input the strongest
    # possible claim.
    it "treats a null `measured` as the legacy shape, not as a scoped agent" do
      peer_a = enroll(net_a)
      peer_b = enroll(net_b)

      described_class.new(
        instance: host, peer_by_network: { net_a.id => peer_a, net_b.id => peer_b },
        networks_payload: [ { network_id: net_b.id, measured: nil, sessions: [] } ]
      ).write!

      observation = peer_b.reload.bgp_session_state["observation"]
      expect(observation["agent_vrf_scoped"]).to be(false)
      expect(observation["status"]).to eq("unattributable")
    end

    # The rows the OLD code already filed under the wrong network must not
    # simply be abandoned: refusing to refresh them freezes the lie in place
    # and the routing dashboard keeps serving it.
    it "retracts a session row it previously misattributed to this network" do
      peer_a = enroll(net_a)
      peer_b = enroll(net_b)
      foreign = "#{net_a.cidr_64.split('/').first}7"

      stale = Sdwan::BgpSession.create!(
        sdwan_peer_id: peer_b.id, sdwan_network_id: net_b.id,
        neighbor_address: foreign, state: "established",
        last_observed_at: 1.minute.ago, last_state_change_at: 1.minute.ago
      )

      described_class.new(
        instance: host, peer_by_network: { net_a.id => peer_a, net_b.id => peer_b },
        networks_payload: [ { network_id: net_b.id, measured: true,
                              sessions: [ { neighbor_address: foreign, state: "established" } ] } ]
      ).write!

      expect(Sdwan::BgpSession.where(id: stale.id)).to be_empty
    end

    # Bgp::ConfigCompiler emits NO global `router bgp` block, so once this
    # host's network has a VRF, an unscoped poll asks an instance that does
    # not exist. Its empty answer is an absence, not a zero — and it is a
    # plain absence, not a misattribution, because with one network no wrong
    # row can have been written.
    it "refuses an unscoped agent's empty report on a single VRF-isolated iBGP network" do
      peer_a = enroll(net_a)
      expect(Sdwan::HostVrfAssignment.compilable
               .exists?(node_instance_id: host.id, sdwan_network_id: net_a.id)).to be(true)

      described_class.new(
        instance: host, peer_by_network: { net_a.id => peer_a },
        networks_payload: [ { network_id: net_a.id, sessions: [] } ]
      ).write!

      observation = peer_a.reload.bgp_session_state["observation"]
      expect(observation["status"]).to eq("not_measured")
      expect(observation["reason"]).to eq("legacy_unscoped_agent_vrf_isolated")
    end

    # `compilable` is deliberately the same scope Bgp::ConfigCompiler uses to
    # decide whether to emit a VRF block. A network with no compilable
    # assignment gets no `router bgp` block at all, so the global instance is
    # not hiding anything from an unscoped poll and zero really is zero.
    it "does not treat a network with no compilable VRF assignment as VRF-isolated" do
      peer_a = enroll(net_a)
      Sdwan::HostVrfAssignment.where(node_instance_id: host.id, sdwan_network_id: net_a.id)
                              .update_all(state: "removed")

      described_class.new(
        instance: host, peer_by_network: { net_a.id => peer_a },
        networks_payload: [ { network_id: net_a.id, sessions: [] } ]
      ).write!

      expect(peer_a.reload.bgp_session_state["observation"]["status"]).to eq("measured")
    end

    # An absence is not evidence a row is wrong — on the VRF-isolated arm
    # too, which reaches the retraction guard rather than the early return.
    it "does not retract on the VRF-isolated not_measured arm" do
      peer_a = enroll(net_a)
      foreign = "fd7e:dead:beef::7"
      stale = Sdwan::BgpSession.create!(
        sdwan_peer_id: peer_a.id, sdwan_network_id: net_a.id,
        neighbor_address: foreign, state: "established",
        last_observed_at: 1.minute.ago, last_state_change_at: 1.minute.ago
      )

      described_class.new(
        instance: host, peer_by_network: { net_a.id => peer_a },
        networks_payload: [ { network_id: net_a.id, sessions: [] } ]
      ).write!

      expect(peer_a.reload.bgp_session_state["observation"]["status"]).to eq("not_measured")
      expect(Sdwan::BgpSession.where(id: stale.id)).to be_present
    end

    # ...but a poll that came back with this network's OWN neighbours is
    # evidence it did answer for this network. Do not manufacture an absence
    # on top of a real measurement.
    it "accepts an unscoped agent's report that carries this network's own neighbours" do
      peer_a = enroll(net_a)
      neighbor = Sdwan::PeerEnroller.call(network: net_a, node_instance: other_host)

      described_class.new(
        instance: host, peer_by_network: { net_a.id => peer_a },
        networks_payload: [ { network_id: net_a.id,
                              sessions: [ { neighbor_address: neighbor.assigned_address.split("/").first,
                                            state: "established" } ] } ]
      ).write!

      observation = peer_a.reload.bgp_session_state["observation"]
      expect(observation["status"]).to eq("measured")
      expect(observation["sessions_accepted"]).to eq(1)
    end

    # A static network is not a BGP fabric; counting it would flip a
    # single-iBGP host into the multi-iBGP arm.
    it "does not count a static network toward the multi-iBGP gate" do
      peer_a = enroll(net_a)
      enroll(net_static)
      neighbor = Sdwan::PeerEnroller.call(network: net_a, node_instance: other_host)

      described_class.new(
        instance: host, peer_by_network: { net_a.id => peer_a },
        networks_payload: [ { network_id: net_a.id,
                              sessions: [ { neighbor_address: neighbor.assigned_address.split("/").first,
                                            state: "established" } ] } ]
      ).write!

      expect(peer_a.reload.bgp_session_state["observation"]["status"]).to eq("measured")
    end

    # Once the agent is rebuilt, a VRF-scoped poll never mentions the other
    # network's neighbours again — so a retraction driven only by the current
    # report's rejects would leave every row the OLD code filed frozen in
    # place forever.
    it "retracts a row the old code filed even when the new report never mentions it" do
      peer_a = enroll(net_a)
      peer_b = enroll(net_b)
      foreign = "#{net_a.cidr_64.split('/').first}7"

      stale = Sdwan::BgpSession.create!(
        sdwan_peer_id: peer_b.id, sdwan_network_id: net_b.id,
        neighbor_address: foreign, state: "established",
        last_observed_at: 1.minute.ago, last_state_change_at: 1.minute.ago
      )

      # A rebuilt agent's clean, VRF-scoped report for network B. It says
      # nothing at all about the address above.
      described_class.new(
        instance: host, peer_by_network: { net_a.id => peer_a, net_b.id => peer_b },
        networks_payload: [ { network_id: net_b.id, measured: true, sessions: [] } ]
      ).write!

      expect(Sdwan::BgpSession.where(id: stale.id)).to be_empty
    end

    # An absence is not evidence that a row is wrong. A report the agent
    # disclaimed must not be used to delete anything.
    it "does not retract on a report the agent declared not measured" do
      peer_a = enroll(net_a)
      peer_b = enroll(net_b)
      foreign = "#{net_a.cidr_64.split('/').first}7"

      stale = Sdwan::BgpSession.create!(
        sdwan_peer_id: peer_b.id, sdwan_network_id: net_b.id,
        neighbor_address: foreign, state: "established",
        last_observed_at: 1.minute.ago, last_state_change_at: 1.minute.ago
      )

      described_class.new(
        instance: host, peer_by_network: { net_a.id => peer_a, net_b.id => peer_b },
        networks_payload: [ { network_id: net_b.id, measured: false,
                              not_measured_reason: "vtysh_unavailable", sessions: [] } ]
      ).write!

      expect(Sdwan::BgpSession.where(id: stale.id)).to be_present
    end
  end

  describe System::Fleet::Sensors::SdwanBgpSessionHealthSensor do
    let(:sensor) { described_class.new(account: account) }

    # Writes the one key the way production does — a read-modify-write of the
    # whole column here would clobber the multi_ibgp_host flag the enroller
    # stamped, which is the very hazard merge_key! exists to avoid.
    def stamp!(peer, observation)
      Sdwan::MultiIbgpHostFlagger.merge_key!(peer_id: peer.id, key: "observation", value: observation)
    end

    let(:base_observation) do
      {
        "status" => "unattributable", "reason" => "legacy_unscoped_agent",
        "observed_at" => Time.current.utc.iso8601, "sessions_accepted" => 0,
        "sessions_rejected" => 2, "rejected_neighbors" => [ "fd00:a::2", "fd00:a::3" ],
        "agent_vrf_scoped" => false
      }
    end

    it "emits an unattributable signal that names the rebuild boundary" do
      peer_a = enroll(net_a)
      peer_b = enroll(net_b)
      stamp!(peer_b, base_observation)

      signals = sensor.sense.select { |s| s.kind == "system.sdwan_bgp_observation_unattributable" }
      expect(signals.size).to eq(1)

      payload = signals.first.payload.with_indifferent_access
      expect(payload["peer_id"]).to eq(peer_b.id)
      expect(payload["agent_vrf_scoped"]).to be(false)
      expect(payload["recommended_action"]).to eq("roll_out_vrf_scoped_agent")
      expect(payload["multi_ibgp_network_ids"]).to match_array([ net_a.id, net_b.id ])
      expect(payload["rejected_neighbors"]).to eq([ "fd00:a::2", "fd00:a::3" ])
      expect(signals.first.severity).to eq(:high)
    end

    it "emits a distinct, lower-severity signal when the agent itself declared nothing measured" do
      peer_a = enroll(net_a)
      stamp!(peer_a, base_observation.merge("status" => "not_measured", "reason" => "vtysh_unavailable",
                                            "sessions_rejected" => 0, "rejected_neighbors" => [],
                                            "agent_vrf_scoped" => true))

      signals = sensor.sense.select { |s| s.kind.start_with?("system.sdwan_bgp_observation") }
      expect(signals.map(&:kind)).to eq([ "system.sdwan_bgp_observation_not_measured" ])
      expect(signals.first.severity).to eq(:medium)
    end

    it "stays silent for a peer whose observation was a clean measurement" do
      peer_a = enroll(net_a)
      stamp!(peer_a, base_observation.merge("status" => "measured", "reason" => nil,
                                            "sessions_rejected" => 0, "rejected_neighbors" => [],
                                            "agent_vrf_scoped" => true))

      expect(sensor.sense.map(&:kind)).not_to include(
        "system.sdwan_bgp_observation_unattributable",
        "system.sdwan_bgp_observation_not_measured"
      )
    end

    # The persisted flag's one behavioural read: a misattribution that has
    # been standing for a day is not the same operator problem as one that
    # started an hour ago.
    it "escalates to critical when the host has been multi-iBGP for over a day" do
      peer_a = enroll(net_a)
      peer_b = enroll(net_b)
      Sdwan::MultiIbgpHostFlagger.merge_key!(
        peer_id: peer_b.id, key: Sdwan::MultiIbgpHostFlagger::KEY,
        value: { "network_ids" => [ net_a.id, net_b.id ].sort,
                 "flagged_at" => 3.days.ago.utc.iso8601,
                 "risk" => Sdwan::MultiIbgpHostFlagger::RISK }
      )
      stamp!(peer_b, base_observation)

      signal = sensor.sense.find { |s| s.kind == "system.sdwan_bgp_observation_unattributable" }
      expect(signal.severity).to eq(:critical)
      expect(signal.payload.with_indifferent_access["multi_ibgp_since"]).to be_present
    end

    # The pre-existing fleet: multi-iBGP for real, never stamped. The sensor
    # must still emit, at :high, rather than raising on a nil flag and taking
    # the whole tick down with it.
    it "emits at high severity for an unflagged host with no provenance stamp" do
      peer_a = enroll(net_a)
      peer_b = enroll(net_b)
      [ peer_a, peer_b ].each do |p|
        Sdwan::MultiIbgpHostFlagger.delete_key!(peer_id: p.id, key: Sdwan::MultiIbgpHostFlagger::KEY)
      end
      stamp!(peer_b, base_observation)

      signals = sensor.sense.select { |s| s.kind == "system.sdwan_bgp_observation_unattributable" }
      expect(signals.size).to eq(1)
      expect(signals.first.severity).to eq(:high)
      expect(signals.first.payload.with_indifferent_access["multi_ibgp_since"]).to be_nil
    end

    # An observation block that stopped being refreshed is the stale family's
    # subject; re-emitting here would double-report one condition.
    it "ages out an observation that stopped being refreshed" do
      peer_a = enroll(net_a)
      stamp!(peer_a, base_observation.merge("observed_at" => 1.hour.ago.utc.iso8601))

      expect(sensor.sense.map(&:kind)).not_to include("system.sdwan_bgp_observation_unattributable")
    end
  end

  # A signal kind DecisionEngine has no binding for is classified :skipped and
  # reaches nobody — the sensor would be inert at its far end.
  describe System::Fleet::DecisionEngine do
    it "binds both attribution kinds to a seeded, non-remediating category" do
      bindings = described_class::SIGNAL_BINDINGS

      %w[system.sdwan_bgp_observation_unattributable
         system.sdwan_bgp_observation_not_measured].each do |kind|
        binding = bindings[kind]
        expect(binding).to be_present, "no DecisionEngine binding for #{kind}"
        expect(binding[:skill]).to be_nil
        expect(binding[:action_category]).to eq("system.sdwan_bgp_observation_investigate")
      end

      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.sdwan_bgp_observation_investigate")
    end

    # A category that is bound and seeded but NOT registered in the engine is
    # swept by system_autonomy_orphan_cleanup on every `rails db:seed`, after
    # which FleetAutonomyService blocks the signal as not_permitted — the lane
    # looks wired and reaches nobody.
    it "registers the category with the engine so the seeded policy survives db:seed" do
      expect(Ai::InterventionPolicy.category_registered?("system.sdwan_bgp_observation_investigate"))
        .to be(true),
        "the category is bound and seeded but not registered in lib/powernode_system/engine.rb: " \
        "system_autonomy_orphan_cleanup destroys its policy row on every rails db:seed, after which " \
        "FleetAutonomyService blocks every attribution signal as not_permitted"
    end
  end
end
