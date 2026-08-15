# frozen_string_literal: true

require "rails_helper"
require_relative "support/line_safe_name_shared_examples"

RSpec.describe Sdwan::VirtualIp, type: :model do
  it_behaves_like "a line-safe named model", :sdwan_virtual_ip

  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::VirtualIp.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
    Sdwan::Configuration.where(account_id: account.id).delete_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "vip-net-#{SecureRandom.hex(3)}") }
  let!(:node) { sdwan_test_node(account: account) }
  let!(:inst1) { sdwan_test_node_instance(node: node) }
  let!(:inst2) { sdwan_test_node_instance(node: node) }
  let!(:hub) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst1,
                        publicly_reachable: true, endpoint_host_v6: "2001:db8::1", endpoint_port: 51820)
  end
  let!(:spoke) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst2,
                        publicly_reachable: false)
  end

  describe "validations" do
    it "rejects anycast VIPs with fewer than two holders" do
      vip = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                name: "bad-anycast", cidr: "192.0.2.10/32",
                                anycast: true, holder_peer_ids: [ hub.id ], state: "pending")
      expect(vip).not_to be_valid
      expect(vip.errors[:holder_peer_ids].join).to match(/at least 2 holders/)
    end

    it "accepts anycast VIPs with two or more holders" do
      vip = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                name: "good-anycast", cidr: "192.0.2.20/32",
                                anycast: true, holder_peer_ids: [ hub.id, spoke.id ], state: "active")
      expect(vip).to be_valid
    end

    it "rejects holder peers from another network" do
      other_net = Sdwan::Network.create!(account_id: account.id, name: "other-net-#{SecureRandom.hex(3)}")
      foreign = Sdwan::Peer.create!(account: account, sdwan_network_id: other_net.id,
                                    node_instance: inst1, publicly_reachable: false)
      vip = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                name: "cross-net", cidr: "192.0.2.30/32",
                                holder_peer_ids: [ foreign.id ], state: "pending")
      expect(vip).not_to be_valid
      expect(vip.errors[:holder_peer_ids].join).to match(/another network/)
    end

    it "enforces CIDR format" do
      vip = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                name: "bad-cidr", cidr: "not-a-cidr", state: "pending")
      expect(vip).not_to be_valid
      expect(vip.errors[:cidr]).to be_present
    end

    # IMP-43cf1e6b5541 — the cap this task's fix to #failover! makes safe to
    # enforce. Gated to on-change (will_save_change_to_holder_peer_ids?) so
    # legacy rows that already carry a stray extra holder don't start
    # failing validation on an unrelated field save — only a fresh WRITE to
    # holder_peer_ids itself must respect the cap.
    it "rejects a non-anycast VIP given more than one holder in the same write" do
      vip = described_class.new(account_id: account.id, sdwan_network_id: network.id,
                                name: "multi-holder", cidr: "192.0.2.40/32",
                                anycast: false, holder_peer_ids: [ hub.id, spoke.id ], state: "active")
      expect(vip).not_to be_valid
      expect(vip.errors[:holder_peer_ids].join).to match(/at most one holder/)
    end

    it "does not re-validate the cap on a save that leaves holder_peer_ids untouched" do
      vip = described_class.create!(account_id: account.id, sdwan_network_id: network.id,
                                    name: "legacy-multi-holder", cidr: "192.0.2.41/32",
                                    anycast: false, holder_peer_ids: [ hub.id ], state: "active")
      # Simulate pre-existing phantom-holder debris (written before this
      # validation existed) without re-triggering the on-change guard.
      described_class.where(id: vip.id).update_all(holder_peer_ids: [ hub.id, spoke.id ])
      vip.reload

      vip.description = "unrelated edit"
      expect(vip).to be_valid
    end
  end

  describe "#failover!" do
    let!(:vip) do
      described_class.create!(account_id: account.id, sdwan_network_id: network.id,
                              name: "fo-vip", cidr: "192.0.2.50/32",
                              holder_peer_ids: [ hub.id ],
                              failover_holder_peer_ids: [ spoke.id ], state: "active")
    end

    it "promotes the head of failover_holder_peer_ids and writes an assignment row" do
      expect { vip.failover! }
        .to change { Sdwan::VirtualIpAssignment.where(sdwan_virtual_ip_id: vip.id).count }.by(1)
      vip.reload
      # IMP-43cf1e6b5541 — the demoted holder must be POPPED off
      # holder_peer_ids, not merely pushed behind the promoted one. A
      # non-anycast VIP has exactly one active holder; asserting `eq`
      # (not `start_with`/`include`) is the deliberate semantic
      # tightening — the old assertions were satisfied by the
      # doc-comment-contradicting size-2 array this task fixes.
      expect(vip.holder_peer_ids).to eq([ spoke.id ])
      expect(vip.failover_holder_peer_ids).to eq([ hub.id ])
    end

    it "raises StateError on anycast VIPs (BGP handles their failover)" do
      vip.update!(anycast: true, holder_peer_ids: [ hub.id, spoke.id ])
      expect { vip.failover! }.to raise_error(Sdwan::VirtualIp::StateError, /anycast/)
    end

    it "raises StateError when failover_holder_peer_ids is empty" do
      vip.update!(failover_holder_peer_ids: [])
      expect { vip.failover! }.to raise_error(Sdwan::VirtualIp::StateError, /no failover candidates/)
    end
  end

  # IMP-0e44cf2fc80b — the canonical diff-based holder-transition sync, ONE
  # method for the update surfaces (Sdwan::Executors::UpdateVirtualIp and
  # Ai::Tools::SdwanTool#update_virtual_ip both delegate here; the two copies
  # had already drifted on attribution, so it is a parameter). #failover!
  # stays positional on purpose — see the method comment.
  describe "#sync_holder_assignments!" do
    let(:operator) { create(:user, account: account) }
    let!(:vip) do
      described_class.create!(account_id: account.id, sdwan_network_id: network.id,
                              name: "sync-vip", cidr: "192.0.2.60/32",
                              holder_peer_ids: [ hub.id ], state: "active")
    end
    let!(:current_assignment) do
      vip.assignments.create!(peer: hub, assumed_at: 1.hour.ago, reason: "initial")
    end

    it "releases departed holders and opens attributed rows for arrivals" do
      previous = Array(vip.holder_peer_ids).dup
      vip.update!(holder_peer_ids: [ spoke.id ])

      vip.sync_holder_assignments!(previous, triggered_by_user: operator)

      expect(current_assignment.reload.released_at).to be_present
      arrived = vip.assignments.where(sdwan_peer_id: spoke.id, released_at: nil).first
      expect(arrived).to be_present, "holder change left phantom current state with no history row"
      expect(arrived.reason).to eq("holder_changed")
      expect(arrived.triggered_by_user_id).to eq(operator.id)
    end

    it "is a no-op when holders are unchanged" do
      expect { vip.sync_holder_assignments!(Array(vip.holder_peer_ids).dup) }
        .not_to change { Sdwan::VirtualIpAssignment.where(sdwan_virtual_ip_id: vip.id).count }
      expect(current_assignment.reload.released_at).to be_nil
    end

    # IMP-43cf1e6b5541 — "truncation removal last with stray-id history
    # backfill". A stray extra holder on a non-anycast VIP is legacy debris
    # from a write path this task does not touch (`update_columns` bypasses
    # validations here to reproduce that debris without a live writer). The
    # OLD `.first(1)` truncation made sync blind to it forever — it would
    # never gain a history row even on a real subsequent holder change,
    # which is the phantom-holder defect. With the truncation gone, the
    # very next diff-based sync call self-heals it: the stray id reads as
    # an "arrival" relative to whatever the caller captured as
    # previous_holders, and gets its own attributed assignment row.
    it "opens a history row for a pre-existing stray (phantom) holder on the next sync" do
      previous = Array(vip.holder_peer_ids).dup # [ hub.id ] — what the caller saw before this write
      vip.update_columns(holder_peer_ids: [ hub.id, spoke.id ]) # simulate legacy debris

      vip.sync_holder_assignments!(previous, triggered_by_user: operator)

      phantom_row = vip.assignments.where(sdwan_peer_id: spoke.id, released_at: nil).first
      expect(phantom_row).to be_present, "stray holder must not remain invisible to the assignment history"
      expect(phantom_row.reason).to eq("holder_changed")
      expect(current_assignment.reload.released_at).to be_nil, "the untouched primary holder must not be released"
    end
  end
end
