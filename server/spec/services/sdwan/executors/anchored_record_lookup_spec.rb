# frozen_string_literal: true

require "rails_helper"

# IMP-134062908364 (part B, operator direction "the remaining bare finds").
#
# Every SDWAN / federation-peer executor that resolves its OWN subject row from
# params now does so through Base#resolve_scoped, anchored on the operation's
# account. Before this, these lookups were a bare `Model.find(params[...])`,
# backstopped only by a coincidence: every live dispatcher (the REST
# controllers' account-scoped set_* guards, the SdwanTool arms' account_*
# finds) happens to pass the same id into the gate's source_id and into params.
# That coincidence is not a check — the gate replays params verbatim hours
# later, and any dispatcher that records a different source (or none) would
# have had these executors act on another account's row.
#
# The unanchored passthrough (deferred_operation: nil) is unchanged and stays
# covered by each executor's own spec; this file pins the anchored arm, both
# sides: a foreign row is refused and left untouched, and a same-account row is
# still acted on (so a helper that refused everything could not pass here).
#
# The refusal compares the SUBJECT row's own account_id, while the REST
# dispatchers scope children (peer, rule, mapping, grant) through the network.
# Every writer stamps a child with its network's account, so the two agree; a
# row where they diverged would be accepted at the request and refused at
# execution — fail-closed, not a leak.
RSpec.describe "Sdwan executors resolve their subject through the operation's account", type: :model do
  let(:account)         { create(:account) }
  let(:foreign_account) { create(:account) }
  let(:foreign_network) { create(:sdwan_network, account: foreign_account) }

  def operation_for(owner, executor)
    ::Ai::DeferredOperation.create!(
      account: owner,
      action_category: executor::ACTION_CATEGORY,
      executor_class: executor.name,
      params: {}
    )
  end

  def run_as(owner, executor, params)
    executor.execute(params, deferred_operation: operation_for(owner, executor))
  end

  def expect_refused(executor, params)
    expect { run_as(account, executor, params) }
      .to raise_error(::Ai::DeferredOperation::CrossAccountError, /is not in account #{account.id}\z/)
  end

  describe Sdwan::Executors::DeleteNetwork do
    it "refuses another account's network and leaves it in place" do
      expect_refused(described_class, { network_id: foreign_network.id })
      expect(::Sdwan::Network.exists?(foreign_network.id)).to be true
    end

    # Under an anchor, "exists nowhere" and "exists in another account" are one
    # refusal (Base#resolve_scoped, IMP-dae0de4e562b) — no existence oracle.
    it "refuses a missing network with the same refusal as a foreign one" do
      expect_refused(described_class, { network_id: SecureRandom.uuid })
    end

    it "deletes the operation account's own network" do
      network = create(:sdwan_network, account: account)
      expect(run_as(account, described_class, { network_id: network.id })[:success]).to be true
      expect(::Sdwan::Network.exists?(network.id)).to be false
    end
  end

  describe Sdwan::Executors::DeletePeer do
    it "refuses another account's peer and leaves it in place" do
      peer = create(:sdwan_peer, account: foreign_account, network: foreign_network)
      expect_refused(described_class, { peer_id: peer.id })
      expect(::Sdwan::Peer.exists?(peer.id)).to be true
    end

    it "deletes the operation account's own peer" do
      network = create(:sdwan_network, account: account)
      peer = create(:sdwan_peer, account: account, network: network)
      expect(run_as(account, described_class, { peer_id: peer.id })[:success]).to be true
      expect(::Sdwan::Peer.exists?(peer.id)).to be false
    end
  end

  describe Sdwan::Executors::DeleteFirewallRule do
    it "refuses another account's rule and leaves it in place" do
      rule = create(:sdwan_firewall_rule, account: foreign_account, network: foreign_network)
      expect_refused(described_class, { rule_id: rule.id })
      expect(::Sdwan::FirewallRule.exists?(rule.id)).to be true
    end

    it "deletes the operation account's own rule" do
      network = create(:sdwan_network, account: account)
      rule = create(:sdwan_firewall_rule, account: account, network: network)
      expect(run_as(account, described_class, { rule_id: rule.id })[:success]).to be true
      expect(::Sdwan::FirewallRule.exists?(rule.id)).to be false
    end
  end

  describe Sdwan::Executors::DeletePortMapping do
    it "refuses another account's port mapping and leaves it in place" do
      mapping = create(:sdwan_port_mapping, account: foreign_account, network: foreign_network)
      expect_refused(described_class, { mapping_id: mapping.id })
      expect(::Sdwan::PortMapping.exists?(mapping.id)).to be true
    end

    it "deletes the operation account's own port mapping" do
      network = create(:sdwan_network, account: account)
      mapping = create(:sdwan_port_mapping, account: account, network: network)
      expect(run_as(account, described_class, { mapping_id: mapping.id })[:success]).to be true
      expect(::Sdwan::PortMapping.exists?(mapping.id)).to be false
    end
  end

  describe Sdwan::Executors::DeleteVirtualIp do
    it "refuses another account's VIP and leaves it in place" do
      vip = create(:sdwan_virtual_ip, network: foreign_network)
      expect_refused(described_class, { vip_id: vip.id })
      expect(::Sdwan::VirtualIp.exists?(vip.id)).to be true
    end

    it "deletes the operation account's own VIP" do
      vip = create(:sdwan_virtual_ip, network: create(:sdwan_network, account: account))
      expect(run_as(account, described_class, { vip_id: vip.id })[:success]).to be true
      expect(::Sdwan::VirtualIp.exists?(vip.id)).to be false
    end
  end

  describe Sdwan::Executors::FailoverVirtualIp do
    it "refuses another account's VIP before touching its holder queue" do
      vip = create(:sdwan_virtual_ip, network: foreign_network, failover_holder_peer_ids: [ SecureRandom.uuid ])
      before = vip.reload.attributes

      expect_refused(described_class, { vip_id: vip.id })
      expect(vip.reload.attributes).to eq(before)
    end

    # Past the anchor, the same stale-standby VIP reaches the model's own
    # precondition — proof the refusal above is the anchor, not the VIP state.
    it "lets the operation account's own VIP through to the failover preconditions" do
      vip = create(:sdwan_virtual_ip, network: create(:sdwan_network, account: account),
                                      failover_holder_peer_ids: [ SecureRandom.uuid ])
      expect { run_as(account, described_class, { vip_id: vip.id }) }
        .to raise_error(::Sdwan::VirtualIp::StateError)
    end
  end

  describe Sdwan::Executors::RevokeAccessGrant do
    it "refuses another account's grant and leaves it active" do
      grant = create(:sdwan_access_grant, account: foreign_account, network: foreign_network)
      expect_refused(described_class, { grant_id: grant.id })
      expect(grant.reload.status).to eq("active")
    end

    it "revokes the operation account's own grant" do
      network = create(:sdwan_network, account: account)
      grant = create(:sdwan_access_grant, account: account, network: network)
      expect(run_as(account, described_class, { grant_id: grant.id })[:success]).to be true
      expect(grant.reload.status).not_to eq("active")
    end
  end

  # Nested lookups: the OUTER row is the one that carries account_id, and the
  # inner association find keeps the pairing check it always performed.
  describe Sdwan::Executors::DeleteAccessGrant do
    it "refuses a grant reached through another account's network" do
      grant = create(:sdwan_access_grant, account: foreign_account, network: foreign_network)
      expect_refused(described_class, { network_id: foreign_network.id, grant_id: grant.id })
      expect(::Sdwan::AccessGrant.exists?(grant.id)).to be true
    end

    it "deletes a grant on the operation account's own network" do
      network = create(:sdwan_network, account: account)
      grant = create(:sdwan_access_grant, account: account, network: network)
      expect(run_as(account, described_class, { network_id: network.id, grant_id: grant.id })[:success]).to be true
      expect(::Sdwan::AccessGrant.exists?(grant.id)).to be false
    end
  end

  describe Sdwan::Executors::RevokeUserDevice do
    it "refuses a device reached through another account's grant" do
      grant = create(:sdwan_access_grant, account: foreign_account, network: foreign_network)
      device = create(:sdwan_user_device, access_grant: grant)
      before = device.reload.attributes

      expect_refused(described_class, { grant_id: grant.id, device_id: device.id })
      expect(device.reload.attributes).to eq(before)
    end

    it "revokes a device on the operation account's own grant" do
      network = create(:sdwan_network, account: account)
      grant = create(:sdwan_access_grant, account: account, network: network)
      device = create(:sdwan_user_device, access_grant: grant)
      before = device.reload.attributes

      expect(run_as(account, described_class, { grant_id: grant.id, device_id: device.id })[:success]).to be true
      expect(device.reload.attributes).not_to eq(before)
    end
  end

  describe Sdwan::Executors::RevokeFederationPeer do
    it "refuses another account's federation peer and leaves it accepted" do
      peer = create(:system_federation_peer, account: foreign_account, status: "accepted")
      expect_refused(described_class, { federation_peer_id: peer.id })
      expect(peer.reload.status).to eq("accepted")
    end

    it "revokes the operation account's own federation peer" do
      peer = create(:system_federation_peer, account: account, status: "accepted")
      expect(run_as(account, described_class, { federation_peer_id: peer.id })[:success]).to be true
      expect(peer.reload.status).to eq("revoked")
    end
  end

  describe Sdwan::Executors::AcceptFederationPeer do
    it "refuses another account's proposed peer and leaves it proposed" do
      peer = create(:system_federation_peer, account: foreign_account, status: "proposed")
      expect_refused(described_class, { federation_peer_id: peer.id })
      expect(peer.reload.status).to eq("proposed")
    end

    it "accepts the operation account's own proposed peer" do
      peer = create(:system_federation_peer, account: account, status: "proposed")
      expect(run_as(account, described_class, { federation_peer_id: peer.id })[:success]).to be true
      expect(peer.reload.status).to eq("accepted")
    end
  end

  describe Sdwan::Executors::SetFederationPeerDataResidency do
    it "refuses another account's federation peer and leaves its residency unchanged" do
      peer = create(:system_federation_peer, account: foreign_account, data_residency: "eu")
      expect_refused(described_class, { federation_peer_id: peer.id, attributes: { data_residency: "us" } })
      expect(peer.reload.data_residency).to eq("eu")
    end

    it "sets residency on the operation account's own federation peer" do
      peer = create(:system_federation_peer, account: account, data_residency: "eu")
      result = run_as(account, described_class, { federation_peer_id: peer.id, attributes: { data_residency: "us" } })
      expect(result[:success]).to be true
      expect(peer.reload.data_residency).to eq("us")
    end
  end
end
