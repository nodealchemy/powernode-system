# frozen_string_literal: true

require "rails_helper"

# IMP-4e49eb79c5e0 — a replacement hub peer inherited a DEAD endpoint by
# construction.
#
# System::Ai::Skills::ReplaceInstanceExecutor#inherited_peer_attributes copies
# the failed peer's routing attributes onto the replacement so a hub does not
# silently become a spoke. It copied the ENDPOINT columns with them —
# endpoint_host / _v4 / _v6 / endpoint_port — and those name the address of the
# instance that just died. The comment above the method is honest about it
# ("An inherited endpoint is stale and visible"), and it is right that DROPPING
# them is worse: Sdwan::Peer#hub_must_have_endpoint rejects a publicly_reachable
# peer with no endpoint, so a hub with its endpoint dropped either fails to
# enrol or is demoted to a spoke that every peer on the network still dials.
#
# But there was a third option nobody took: the replacement HAS addresses of
# its own, and the whole operation exists because it is taking over the dead
# one's role. Re-deriving the endpoint from the replacement's own addresses at
# enrol time satisfies the validation AND leaves a hub reachable, and it is the
# only outcome under which "re-enrol it on every network the failed one held"
# is true of the DATA PLANE rather than only of the row.
#
# The oracle is the PEER ROW's endpoint columns, never the enroller's
# arguments: a spec that asserted on what PeerEnroller was called with would
# pass for a derivation the model then rejected or normalised away.
RSpec.describe "APO-4 replacement peer endpoint (IMP-4e49eb79c5e0)", type: :service do
  let(:account)                { create(:account) }
  let(:node_template)          { create(:system_node_template, account: account) }
  let(:provider_region)        { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }

  let(:pool) do
    System::InstancePool.create!(
      account: account, node_template: node_template, name: "dr-pool",
      target_size: 2, min_size: 1, max_size: 4, lifecycle_class: "ephemeral",
      status: "active", provider_region: provider_region,
      provider_instance_type: provider_instance_type
    )
  end

  def pool_member(pool_state:, status:, **attrs)
    node = create(:system_node, account: account, node_template: node_template)
    create(:system_node_instance,
           node: node, name: "m-#{SecureRandom.hex(3)}", variety: "cloud",
           status: status, provider_region: provider_region,
           provider_instance_type: provider_instance_type,
           instance_pool_id: pool.id, pool_state: pool_state,
           pool_warming_started_at: 5.minutes.ago, **attrs)
  end

  let!(:failed) do
    pool_member(pool_state: "claimed", status: "error", public_ip_address: "198.51.100.10")
  end
  let!(:spare) do
    pool_member(pool_state: "ready", status: "running", public_ip_address: "198.51.100.77")
  end

  let(:network) { create(:sdwan_network, account: account) }

  let(:provider) { instance_double(System::Providers::MockProvider, provider_type: "mock") }

  before do
    allow(System::Providers::Registry).to receive(:for_volume).and_return(provider)
    allow(System::Providers::Registry).to receive(:for_instance).and_return(provider)
    allow(provider).to receive(:terminate_instance).and_return({ success: true })
  end

  def run(operation_id: "op-endpoint")
    System::Ai::Skills::ReplaceInstanceExecutor
      .new(account: account, agent: nil, user: nil)
      .execute(gated: true, instance_id: failed.id, operation_id: operation_id)
  end

  def replacement_peer
    Sdwan::Peer.find_by(sdwan_network_id: network.id, node_instance_id: spare.id)
  end

  context "when the dead peer was a publicly reachable HUB" do
    let!(:old_peer) do
      create(:sdwan_peer, :active, account: account, network: network, node_instance: failed,
                                   publicly_reachable: true,
                                   endpoint_host_v4: "198.51.100.10",
                                   endpoint_host_v6: nil, endpoint_host: nil,
                                   endpoint_port: 51_820, listen_port: 51_820)
    end

    it "keeps the peer a hub" do
      result = run
      expect(result[:success]).to be(true), "the replace failed: #{result[:error]}"

      expect(replacement_peer).to be_present
      expect(replacement_peer.publicly_reachable).to be(true)
    end

    it "points the endpoint at the REPLACEMENT's address, not the dead one's" do
      run

      peer = replacement_peer
      expect(peer.endpoint_host_v4).to eq("198.51.100.77")
      expect([ peer.endpoint_host_v4, peer.endpoint_host_v6, peer.endpoint_host ])
        .not_to include("198.51.100.10"),
                "the replacement hub is advertising the dead instance's address"
    end

    it "keeps the endpoint PORT, which is network configuration and not an address" do
      run

      expect(replacement_peer.endpoint_port).to eq(51_820)
    end

    # #primary_endpoint prefers v6 over v4. A derivation that wrote the
    # replacement's v4 address while leaving the dead peer's v6 host in place
    # would satisfy the assertion above and still hand every dialling peer the
    # dead address.
    it "does not leave a stale host in a column the replacement did not fill" do
      old_peer.update!(endpoint_host_v6: "2001:db8::10", endpoint_host: "dead.example.test")

      run

      peer = replacement_peer
      expect(peer.primary_endpoint&.fetch(:host)).to eq("198.51.100.77")
      expect(peer.endpoint_host_v6).to be_blank
      expect(peer.endpoint_host).to be_blank
    end
  end

  context "when the replacement has no address of its own yet" do
    let!(:old_peer) do
      create(:sdwan_peer, :active, account: account, network: network, node_instance: failed,
                                   publicly_reachable: true,
                                   endpoint_host_v4: "198.51.100.10",
                                   endpoint_port: 51_820, listen_port: 51_820)
    end

    before { spare.update!(public_ip_address: nil, private_ip_address: nil) }

    # The fallback is deliberately the OLD behaviour: an inherited (stale)
    # endpoint is visible and fixable, whereas dropping it demotes a hub every
    # spoke on the network still dials. Enrolment must not fail either.
    it "falls back to the inherited endpoint rather than demoting the hub" do
      result = run
      expect(result[:success]).to be(true), "the replace failed: #{result[:error]}"

      peer = replacement_peer
      expect(peer).to be_present, "the hub failed to enrol at all"
      expect(peer.publicly_reachable).to be(true)
      expect(peer.endpoint_host_v4).to eq("198.51.100.10")
    end
  end

  context "when the dead peer was a SPOKE carrying no endpoint" do
    let!(:old_peer) do
      create(:sdwan_peer, :active, account: account, network: network, node_instance: failed,
                                   publicly_reachable: false,
                                   endpoint_host: nil, endpoint_host_v4: nil,
                                   endpoint_host_v6: nil, endpoint_port: nil)
    end

    # A spoke advertises no endpoint on purpose. Minting one from the
    # replacement's public address would publish a listener nobody asked for.
    it "mints no endpoint for it" do
      run

      peer = replacement_peer
      expect(peer).to be_present
      expect(peer.publicly_reachable).to be(false)
      expect(peer.primary_endpoint).to be_nil
    end
  end

  # A DNS NAME IS NOT A DEAD ADDRESS. The premise of the re-derivation — "these
  # columns name the address of the instance that just died" — is false for a
  # hostname: a record the operator repoints is the standard way to make a hub
  # replaceable, and the pool member's literal is ephemeral. Overwriting the
  # name would defeat that failover and pin the fabric to an address the NEXT
  # replace invalidates again.
  context "when the dead peer advertised a HOSTNAME rather than an address" do
    let!(:old_peer) do
      create(:sdwan_peer, :active, account: account, network: network, node_instance: failed,
                                   publicly_reachable: true,
                                   endpoint_host: "hub.example.test",
                                   endpoint_host_v4: nil, endpoint_host_v6: nil,
                                   endpoint_port: 51_820, listen_port: 51_820)
    end

    it "keeps the hostname instead of pinning the fabric to the replacement's literal" do
      result = run
      expect(result[:success]).to be(true), "the replace failed: #{result[:error]}"

      peer = replacement_peer
      expect(peer.endpoint_host).to eq("hub.example.test")
      expect([ peer.endpoint_host_v4, peer.endpoint_host_v6 ]).to all(be_blank)
      expect(peer.primary_endpoint&.fetch(:host)).to eq("hub.example.test")
    end

    # The same is true of a name parked in a FAMILY column — the validators
    # admit one there, and Sdwan::Peer.endpoint_column_for classifies by the
    # string, not by the column it came out of.
    it "keeps a hostname stored in a family column too" do
      old_peer.update!(endpoint_host: nil, endpoint_host_v4: "hub4.example.test")

      run

      peer = replacement_peer
      expect(peer.endpoint_host_v4).to eq("hub4.example.test")
      expect(peer.endpoint_host_v4).not_to eq("198.51.100.77")
    end
  end

  context "when the dead peer's endpoint was half-filled" do
    # A host with no port is not an endpoint — #primary_endpoint returns nil
    # for it, and no peer can dial it. Deriving one from the replacement would
    # mint a WORKING listener where there had been none, which is a topology
    # change a replace is not entitled to make. The stale half is carried
    # forward untouched instead, exactly as before.
    let!(:old_peer) do
      create(:sdwan_peer, :active, account: account, network: network, node_instance: failed,
                                   publicly_reachable: false,
                                   endpoint_host_v4: "198.51.100.10", endpoint_port: nil)
    end

    it "carries the unusable pair forward rather than completing it" do
      run

      peer = replacement_peer
      expect(peer.endpoint_host_v4).to eq("198.51.100.10")
      expect(peer.endpoint_port).to be_nil
      expect(peer.primary_endpoint).to be_nil
    end
  end

  describe "Sdwan::Peer.endpoint_attributes_for" do
    # The model owns the family rules (endpoint_host_v6_must_be_v6_or_hostname
    # and its v4 twin), so it — not the executor — is where an address is
    # classified. A caller that sorted the columns itself would be a second
    # implementation of those validations, free to drift.
    it "routes an IPv4 literal to the v4 column" do
      expect(Sdwan::Peer.endpoint_attributes_for(node_instance: spare, port: 51_820))
        .to eq(endpoint_host_v4: "198.51.100.77", endpoint_port: 51_820)
    end

    it "routes an IPv6 literal to the v6 column" do
      spare.update!(public_ip_address: "2001:db8::77")

      expect(Sdwan::Peer.endpoint_attributes_for(node_instance: spare, port: 51_820))
        .to eq(endpoint_host_v6: "2001:db8::77", endpoint_port: 51_820)
    end

    # An endpoint is what OTHER peers DIAL — Sdwan::MembershipCredentialSigner
    # emits both #primary_endpoint and #fallback_endpoint as `"kind" => "wan"`.
    # A private address is not a WAN endpoint: unreachable off-LAN at best, and
    # at worst colliding with the dialling peer's own 10.0.0.0/8. So a public
    # address is not JOINED by a private one to synthesise the v6/v4 pair
    # #fallback_endpoint reads — that pair is two PUBLIC addresses.
    it "does not advertise a private address alongside a public one" do
      spare.update!(public_ip_address: "2001:db8::77", private_ip_address: "10.0.0.77")

      expect(Sdwan::Peer.endpoint_attributes_for(node_instance: spare, port: 51_820))
        .to eq(endpoint_host_v6: "2001:db8::77", endpoint_port: 51_820)
    end

    # ...but a private address IS the endpoint when there is no public one:
    # the internal-hub case, where the LAN address really is how the network
    # reaches it.
    it "falls back to the private address when the instance has no public one" do
      spare.update!(public_ip_address: nil, private_ip_address: "10.0.0.77")

      expect(Sdwan::Peer.endpoint_attributes_for(node_instance: spare, port: 51_820))
        .to eq(endpoint_host_v4: "10.0.0.77", endpoint_port: 51_820)
    end

    it "returns nothing for an instance with no addresses" do
      spare.update!(public_ip_address: nil, private_ip_address: nil)

      expect(Sdwan::Peer.endpoint_attributes_for(node_instance: spare, port: 51_820)).to eq({})
    end

    # The derived attributes have to SURVIVE the model's own validations —
    # a classification the validators then reject is worse than no derivation.
    it "produces a peer the model accepts" do
      attrs = Sdwan::Peer.endpoint_attributes_for(node_instance: spare, port: 51_820)
      peer  = Sdwan::Peer.new(account: account, network: network, node_instance: spare,
                              publicly_reachable: true, status: "pending", **attrs)

      expect(peer).to be_valid, peer.errors.full_messages.to_sentence
    end
  end
end
