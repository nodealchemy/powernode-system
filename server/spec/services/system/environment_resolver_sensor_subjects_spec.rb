# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 6 — every SENSOR-DRIVEN remediation lands in
# the plane of the thing it acts on.
#
# The autonomy gate varies its verdict by plane only when the resolver can
# place the action's params. When it cannot, Ai::EnvironmentResolution.resolve
# answers nil and the gate applies NO overlay — the permissive, pre-campaign
# verdict. That is a silent pass, not a refusal: three of the eight
# side-effectful fleet bindings named a subject the resolver did not know
# (`certificate_id`, `virtual_ip_id`, `federation_peer_id`), so a certificate
# rotation or a VIP failover in front of the CONTROL PLANE was gated as
# leniently as one in dev.
RSpec.describe System::EnvironmentResolver, "sensor-driven subjects" do
  let(:account) { create(:account) }
  let(:dev)     { account.environments.find_by!(slug: "dev") }
  let(:ops)     { account.environments.find_by!(slug: "ops") }

  # One network per plane, each with a peer bound to an instance in that plane.
  # A peer's plane is its INSTANCE's plane, so the fixtures are built through
  # templates the way the fleet builds them.
  def instance_in(environment)
    template = create(:system_node_template, account: account, environment: environment)
    node = create(:system_node, account: account, node_template: template)
    create(:system_node_instance, node: node)
  end

  def network_in(environment)
    network = create(:sdwan_network, account: account)
    create(:sdwan_peer, account: account, network: network, node_instance: instance_in(environment))
    network
  end

  describe "a virtual IP" do
    it "is placed where an action on its network is placed" do
      vip = create(:sdwan_virtual_ip, network: network_in(ops))
      expect(described_class.call(account: account, params: { virtual_ip_id: vip.id })).to eq(ops)
      expect(described_class.blast_radius(account: account, params: { virtual_ip_id: vip.id })).to eq(1)
    end

    it "resolves to nothing for a VIP this account does not have" do
      foreign = create(:sdwan_virtual_ip, network: create(:sdwan_network, account: create(:account)))
      expect(described_class.call(account: account, params: { virtual_ip_id: foreign.id })).to be_nil
    end
  end

  describe "an ACME certificate" do
    # The chain under test: cert → the services holding it → those services'
    # VIPs → those VIPs' networks → the peers' instances.
    it "is placed through the services that terminate it" do
      cert = create(:system_acme_certificate, account: account)
      vip = create(:sdwan_virtual_ip, network: network_in(ops))
      create(:sdwan_service, account: account, local_certificate: cert, backend_vip: vip)

      expect(described_class.call(account: account, params: { certificate_id: cert.id })).to eq(ops)
      expect(described_class.blast_radius(account: account, params: { certificate_id: cert.id })).to eq(1)
    end

    it "takes the STRICTEST plane when it fronts services on more than one" do
      cert = create(:system_acme_certificate, account: account)
      create(:sdwan_service, account: account, local_certificate: cert,
                             backend_vip: create(:sdwan_virtual_ip, network: network_in(dev)))
      create(:sdwan_service, account: account, local_certificate: cert,
                             backend_vip: create(:sdwan_virtual_ip, network: network_in(ops)))

      expect(described_class.call(account: account, params: { certificate_id: cert.id })).to eq(ops)
      expect(described_class.blast_radius(account: account, params: { certificate_id: cert.id })).to eq(2)
    end

    # Honest nil: a cert fronting a static backend_host has no fleet row behind
    # it to place, and inventing dev here would be worse than admitting it.
    it "resolves to nothing when nothing VIP-backed terminates it" do
      cert = create(:system_acme_certificate, account: account)
      create(:sdwan_service, account: account, local_certificate: cert)
      expect(described_class.call(account: account, params: { certificate_id: cert.id })).to be_nil
      expect(described_class.blast_radius(account: account, params: { certificate_id: cert.id })).to be_nil
    end
  end

  describe "a federation peer" do
    it "is read from its own environment_id — it represents a remote cell, not an instance here" do
      peer = create(:system_federation_peer, account: account, environment: ops)
      expect(described_class.call(account: account, params: { federation_peer_id: peer.id })).to eq(ops)
    end

    it "leaves the blast radius unmeasured, because the rows it touches are not this account's" do
      peer = create(:system_federation_peer, account: account, environment: ops)
      expect(described_class.blast_radius(account: account, params: { federation_peer_id: peer.id })).to be_nil
    end

    it "resolves to nothing while unplaced" do
      peer = create(:system_federation_peer, account: account)
      expect(described_class.call(account: account, params: { federation_peer_id: peer.id })).to be_nil
    end
  end

  describe "an SDWAN peer" do
    it "now measures its blast radius as the one instance it runs on" do
      peer = create(:sdwan_peer, account: account, network: create(:sdwan_network, account: account),
                                 node_instance: instance_in(ops))
      expect(described_class.call(account: account, params: { peer_id: peer.id })).to eq(ops)
      expect(described_class.blast_radius(account: account, params: { peer_id: peer.id })).to eq(1)
    end
  end

  # The explicit plane stays a FLOOR, not an override, on the new subjects too.
  it "combines a named plane with the subject's, strictest winning" do
    vip = create(:sdwan_virtual_ip, network: network_in(ops))
    resolved = described_class.call(account: account,
                                   params: { virtual_ip_id: vip.id, environment: "dev" })
    expect(resolved).to eq(ops)
  end
end
