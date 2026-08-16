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

    # IMP-43cf1e6b5541 — the cap has TWO inputs (anycast, holder_peer_ids),
    # so gating on holder_peer_ids alone lets a write that flips anycast to
    # false — without also touching holder_peer_ids — mint a FRESH
    # instance of the bug this validation exists to prevent, invisible to
    # a guard keyed on one input only.
    it "re-validates the cap when anycast flips to false without touching holder_peer_ids" do
      vip = described_class.create!(account_id: account.id, sdwan_network_id: network.id,
                                    name: "was-anycast", cidr: "192.0.2.42/32",
                                    anycast: true, holder_peer_ids: [ hub.id, spoke.id ], state: "active")

      vip.anycast = false
      expect(vip).not_to be_valid
      expect(vip.errors[:holder_peer_ids].join).to match(/at most one holder/)
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

    # IMP-43cf1e6b5541 — review-caught regression: non_anycast_single_holder
    # validates the SAME update! failover! issues, so a VIP that already
    # carries stray debris (predating that validation) would raise and roll
    # back on the very operation meant to recover it, stranding it
    # permanently unfailoverable. failover! must normalize debris away
    # rather than trip over it.
    it "normalizes pre-existing stray holder debris instead of raising, and releases its assignment too" do
      inst3  = sdwan_test_node_instance(node: node)
      stray  = Sdwan::Peer.create!(account: account, sdwan_network_id: network.id,
                                   node_instance: inst3, publicly_reachable: false)
      # Simulate debris predating non_anycast_single_holder — bypasses the
      # validation, exactly as a legacy write from before it existed would.
      vip.update_columns(holder_peer_ids: [ hub.id, stray.id ])
      stray_assignment = vip.assignments.create!(peer: stray, assumed_at: 2.hours.ago, reason: "phantom_backfill")

      expect { vip.failover! }.not_to raise_error

      vip.reload
      expect(vip.holder_peer_ids).to eq([ spoke.id ])
      expect(stray_assignment.reload.released_at).to be_present,
                                                     "the swept stray's dangling assignment must be released too"
    end

    # The old_holder == new_holder trap (a parked failover-candidate edit
    # can name the current primary — see UpdateVirtualIp's replay-baseline
    # comment): must not raise a uniqueness violation by trying to create a
    # second active assignment for the same peer.
    it "releases and re-creates the assignment cleanly when the failover candidate is already the primary holder" do
      original_assignment = vip.assignments.create!(peer: hub, assumed_at: 1.hour.ago, reason: "initial")
      vip.update!(failover_holder_peer_ids: [ hub.id ])

      expect { vip.failover! }.not_to raise_error

      vip.reload
      expect(vip.holder_peer_ids).to eq([ hub.id ])
      expect(original_assignment.reload.released_at).to be_present, "release must run even when old_holder == new_holder"
      expect(vip.assignments.where(sdwan_peer_id: hub.id, released_at: nil).count).to eq(1),
                                                                                       "exactly one fresh active assignment, not a uniqueness collision"
    end

    # IMP-d952c791e264 — the tombstone standby used to surface as a bare
    # ActiveRecord::RecordNotFound from ::Sdwan::Peer.find(new_holder), deep
    # inside the transaction and after every pre-gate check had passed it.
    it "raises StateError, not RecordNotFound, when the standby it would promote was deleted" do
      vip.update!(failover_holder_peer_ids: [ tombstone_peer_id ])

      expect { vip.failover! }
        .to raise_error(Sdwan::VirtualIp::StateError, /is not a live peer/)
    end
  end

  # IMP-d952c791e264 — the ONE place that answers "can this VIP fail over, and
  # to which standby". #failover!'s two StateError guards had been hand-copied
  # into System::Ai::Skills::SdwanVipFailoverExecutor (wording already drifted)
  # and into Ai::Tools::SdwanTool#failover_virtual_ip's pre-gate mirror, and
  # all three missed the same third doomed case: a standby whose peer row was
  # deleted. failover_holder_peer_ids is a bare uuid[] with no FK,
  # Sdwan::Executors::DeletePeer never scrubs it, and
  # holder_peers_belong_to_network only flags ids that EXIST in another
  # network — so the tombstone passed every pre-gate check on both surfaces,
  # parked a require_approval DeferredOperation, and only failed hours later
  # inside #failover!'s transaction.
  describe "#failover_blocker" do
    let!(:vip) do
      described_class.create!(account_id: account.id, sdwan_network_id: network.id,
                              name: "blocker-vip", cidr: "192.0.2.70/32",
                              holder_peer_ids: [ hub.id ],
                              failover_holder_peer_ids: [ spoke.id ], state: "active")
    end

    it "is nil for a non-anycast VIP whose standby is a live peer" do
      expect(vip.failover_blocker).to be_nil
    end

    it "names the anycast refusal" do
      vip.update!(anycast: true, holder_peer_ids: [ hub.id, spoke.id ])

      expect(vip.failover_blocker).to match(/anycast/)
    end

    it "names the candidate-less refusal" do
      vip.update!(failover_holder_peer_ids: [])

      expect(vip.failover_blocker).to match(/no failover candidates/)
    end

    # The finding. Note the setup itself is the proof that
    # holder_peers_belong_to_network is blind to this: update! SAVES a VIP
    # whose only standby no longer exists.
    it "refuses when the standby it would promote has been deleted, naming the dead id" do
      dead = tombstone_peer_id
      vip.update!(failover_holder_peer_ids: [ dead ])

      expect(vip.failover_blocker).to include(dead).and match(/not a live peer/)
    end

    it "refuses a blank candidate head rather than promoting nothing" do
      # A uuid[] column accepts NULL elements, and every writer builds the
      # array with a bare Array(params[...]) — so [nil] is reachable from the
      # MCP surface. update!, not update_columns, precisely because that is
      # the claim: holder_peers_belong_to_network compacts the array away and
      # non_anycast_single_holder never looks at it, so an ordinary validated
      # write persists this. #failover! would then write holder_peer_ids: []
      # and still call the VIP "active" — a holderless active VIP with no
      # assignment row.
      expect(vip.update(failover_holder_peer_ids: [ nil ])).to be(true),
                                                               "the reachability this example rests on is gone: [nil] no longer survives validation"

      expect(vip.failover_blocker).to match(/not a live peer/)
    end

    # The cross-network candidate is the same doomed-approval shape wearing a
    # different exception: ::Sdwan::Peer.find would SUCCEED, and #failover!'s
    # update! would then be rejected by holder_peers_belong_to_network with an
    # ActiveRecord::RecordInvalid from inside the transaction. The predicate
    # asks the membership question that validation will ask, not a bare
    # existence question. update_columns here is deliberate — the write path
    # this legacy shape comes from predates that validation.
    it "refuses a candidate that is a live peer of ANOTHER network" do
      other_network = Sdwan::Network.create!(account_id: account.id, name: "other-#{SecureRandom.hex(3)}")
      foreign = Sdwan::Peer.create!(account: account, sdwan_network_id: other_network.id,
                                    node_instance: sdwan_test_node_instance(node: node),
                                    publicly_reachable: false)
      vip.update_columns(failover_holder_peer_ids: [ foreign.id ])

      expect(vip.failover_blocker).to include(foreign.id).and match(/not a live peer/)
    end

    # Deliberately NOT blocked: #failover! promotes the head, so debris
    # further down the queue is not this failover's problem. Without this
    # control an over-strict "any dead candidate" predicate would pass every
    # refusal example above.
    it "permits a failover whose head is live even when a dead candidate sits behind it" do
      vip.update!(failover_holder_peer_ids: [ spoke.id, tombstone_peer_id ])

      expect(vip.failover_blocker).to be_nil
    end

    # Sdwan::Executors::FailoverVirtualIp#prefer_target! moves an operator's
    # named target to the head BEFORE calling failover!, so the predicate has
    # to answer for that peer and not for today's head.
    it "answers for the operator's named target rather than the queue head" do
      dead = tombstone_peer_id
      vip.update!(failover_holder_peer_ids: [ spoke.id, dead ])

      expect(vip.failover_blocker(target_peer_id: dead)).to include(dead)
      expect(vip.failover_blocker(target_peer_id: spoke.id)).to be_nil
    end

    # prefer_target! no-ops on a target that is not a configured candidate, so
    # the predicate must fall back to the head exactly as failover! will.
    it "ignores a target that is not a configured candidate" do
      expect(vip.failover_blocker(target_peer_id: tombstone_peer_id)).to be_nil
    end
  end

  # A peer row that existed when the VIP was written and does not exist now —
  # the exact sequence Sdwan::Executors::DeletePeer produces, since it destroys
  # the peer without scrubbing the uuid[] arrays that name it.
  def tombstone_peer_id
    peer = Sdwan::Peer.create!(account: account, sdwan_network_id: network.id,
                               node_instance: sdwan_test_node_instance(node: node),
                               publicly_reachable: false)
    peer.destroy!
    peer.id
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

    # IMP-43cf1e6b5541 — the real value of removing `.first(1)`: it fixed an
    # asymmetry, not added a "self-heal". previous_holders is the RAW
    # pre-write array (never truncated) but `current` (computed inside this
    # method) WAS truncated for non-anycast — so on a debris-laden row left
    # untouched by the current write, previous_holders still contained the
    # stray but truncated `current` did not, and the diff spuriously
    # computed the stray as "departed" on every unrelated save (an
    # UPDATE query per call, and would have released a real open
    # assignment on a save that expressed no opinion about holders at
    # all). Diffing the untruncated array restores "holders unchanged" as
    # a true no-op — pinned here on the assignment NOT being released, in
    # addition to the count already covering the row.
    it "does not touch a stray holder's assignment when an unrelated save leaves holder_peer_ids untouched" do
      stray = create(:sdwan_peer, account: account, network: network)
      vip.update_columns(holder_peer_ids: [ hub.id, stray.id ]) # simulate legacy debris
      stray_assignment = vip.assignments.create!(peer: stray, assumed_at: 1.hour.ago, reason: "phantom_backfill")
      previous = Array(vip.holder_peer_ids).dup # captured from the SAME (debris-laden) row, as the real caller does

      vip.sync_holder_assignments!(previous, triggered_by_user: operator)

      expect(current_assignment.reload.released_at).to be_nil
      expect(stray_assignment.reload.released_at).to be_nil
    end

    # A stray id already in BOTH previous_holders and current is neither
    # departed nor arrived — it does NOT gain a history row here even
    # though it IS included this time (that gap is what
    # Sdwan::VirtualIpPhantomHolderBackfillService closes). What this
    # method DOES do for debris, once holder_peer_ids genuinely changes, is
    # sweep it into "departed" alongside the real primary — a dangling
    # assignment (if it has one) gets released rather than left open
    # forever.
    it "releases stray debris alongside the departing primary when holder_peer_ids genuinely changes" do
      stray = create(:sdwan_peer, account: account, network: network)
      vip.update_columns(holder_peer_ids: [ hub.id, stray.id ]) # simulate legacy debris
      stray_assignment = vip.assignments.create!(peer: stray, assumed_at: 1.hour.ago, reason: "phantom_backfill")
      previous = Array(vip.holder_peer_ids).dup

      vip.update!(holder_peer_ids: [ spoke.id ])
      vip.sync_holder_assignments!(previous, triggered_by_user: operator)

      expect(current_assignment.reload.released_at).to be_present
      expect(stray_assignment.reload.released_at).to be_present
      arrived = vip.assignments.where(sdwan_peer_id: spoke.id, released_at: nil).first
      expect(arrived).to be_present
      expect(vip.assignments.where(sdwan_peer_id: stray.id, released_at: nil)).not_to exist
    end
  end
end
