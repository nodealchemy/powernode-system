# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::MembershipCredential, type: :model do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::MembershipCredential.where(account_id: account.id).delete_all
    Sdwan::ConstellationSigningKey.where(account_id: account.id).delete_all
    Sdwan::Peer.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
    Sdwan::Configuration.where(account_id: account.id).delete_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "mc-net-#{SecureRandom.hex(3)}") }
  let!(:node)    { sdwan_test_node(account: account) }
  let!(:inst)    { sdwan_test_node_instance(node: node) }
  let!(:peer) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst,
                        publicly_reachable: true, endpoint_host_v6: "2001:db8::1", endpoint_port: 51820)
  end

  # Build a barebones MC record skipping the signer for pure model tests.
  def build_mc(overrides = {})
    now = Time.current
    described_class.new({
      account: account,
      peer: peer,
      network: network,
      revision: 1,
      issued_at: now,
      not_before: now,
      not_after: now + 3600,
      refresh_after: now + 1800,
      envelope_json: "{}",
      signature_b64: "AAAA",
      constellation_handle: "acct-test"
    }.merge(overrides))
  end

  describe "validations" do
    it "is valid with a complete row" do
      mc = build_mc
      expect(mc).to be_valid
    end

    it "rejects an unknown status" do
      mc = build_mc(status: "explosive")
      expect(mc).not_to be_valid
      expect(mc.errors[:status]).to be_present
    end

    it "rejects not_after <= not_before" do
      now = Time.current
      mc = build_mc(not_before: now, not_after: now)
      expect(mc).not_to be_valid
      expect(mc.errors[:not_after].join).to match(/must be after/)
    end

    it "rejects refresh_after outside the window" do
      now = Time.current
      mc = build_mc(not_before: now, not_after: now + 3600, refresh_after: now + 7200)
      expect(mc).not_to be_valid
      expect(mc.errors[:refresh_after].join).to match(/on or before/)
    end

    it "rejects negative revision" do
      mc = build_mc(revision: -1)
      expect(mc).not_to be_valid
      expect(mc.errors[:revision]).to be_present
    end
  end

  describe "AASM lifecycle" do
    it "starts in pending" do
      mc = build_mc(status: "pending")
      expect(mc).to be_pending
    end

    it "transitions pending → active via issue" do
      mc = build_mc(status: "pending")
      mc.save!
      expect(mc.issue).to be true
      expect(mc).to be_active
    end

    it "transitions active → expiring via mark_expiring" do
      mc = build_mc(status: "active")
      mc.save!
      mc.mark_expiring
      expect(mc).to be_expiring
    end

    it "transitions active → revoked via revoke (sets reason + timestamp)" do
      mc = build_mc(status: "active")
      mc.save!
      mc.revoke(reason: "operator_action")
      expect(mc).to be_revoked
      expect(mc.revoked_at).to be_present
      expect(mc.revocation_reason).to eq("operator_action")
    end

    it "transitions active → revoked via supersede with default reason" do
      mc = build_mc(status: "active")
      mc.save!
      mc.supersede
      expect(mc).to be_revoked
      expect(mc.revocation_reason).to eq("superseded")
    end

    it "refuses to transition revoked → active" do
      mc = build_mc(status: "active")
      mc.save!
      mc.revoke
      mc.save!
      # whiny_transitions: false → returns false instead of raising
      expect(mc.issue).to be false
      expect(mc).to be_revoked
    end
  end

  describe "scopes" do
    let(:now) { Time.current }
    before do
      build_mc(status: "active",   not_after: now + 3600, refresh_after: now + 1800).save!
      build_mc(status: "expiring", not_after: now + 600,  refresh_after: now,        revision: 2).save!(validate: false)
      build_mc(status: "revoked",  not_after: now + 7200, refresh_after: now + 3600, revision: 3, revoked_at: now).save!(validate: false)
    end

    it "active_status returns only :active rows" do
      expect(described_class.active_status.pluck(:status)).to eq(["active"])
    end

    it "live returns active + expiring" do
      expect(described_class.live.pluck(:status)).to contain_exactly("active", "expiring")
    end

    it "revoked returns only revoked rows" do
      expect(described_class.revoked.pluck(:status)).to eq(["revoked"])
    end

    it "due_for_refresh picks up rows past refresh_after" do
      ids = described_class.due_for_refresh(now: now + 1).pluck(:revision)
      expect(ids).to include(2)
      expect(ids).not_to include(3) # revoked excluded
    end

    it "expiring_within picks up rows whose not_after falls inside the window" do
      ids = described_class.expiring_within(15.minutes, now: now).pluck(:revision)
      expect(ids).to include(2)        # not_after = now + 600
      expect(ids).not_to include(1)    # not_after = now + 3600
    end
  end

  describe "#usable?" do
    let(:now) { Time.current }

    it "is true for an active row inside the window" do
      mc = build_mc(status: "active", not_before: now - 60, not_after: now + 60, refresh_after: now + 30)
      expect(mc.usable?(now: now)).to be true
    end

    it "is false past not_after" do
      mc = build_mc(status: "active", not_before: now - 7200, not_after: now - 60, refresh_after: now - 3600)
      expect(mc.usable?(now: now)).to be false
    end

    it "is false before not_before" do
      mc = build_mc(status: "active", not_before: now + 60, not_after: now + 3600, refresh_after: now + 1800)
      expect(mc.usable?(now: now)).to be false
    end

    it "is false for a revoked row" do
      mc = build_mc(status: "revoked", not_before: now - 60, not_after: now + 3600, refresh_after: now + 1800,
                    revoked_at: now)
      expect(mc.usable?(now: now)).to be false
    end
  end

  describe "#refresh_due?" do
    let(:now) { Time.current }

    it "is true once now >= refresh_after but < not_after" do
      mc = build_mc(status: "active", not_before: now - 60, not_after: now + 600, refresh_after: now - 30)
      expect(mc.refresh_due?(now: now)).to be true
    end

    it "is false before refresh_after" do
      mc = build_mc(status: "active", not_before: now - 60, not_after: now + 3600, refresh_after: now + 60)
      expect(mc.refresh_due?(now: now)).to be false
    end

    it "is false past not_after" do
      mc = build_mc(status: "active", not_before: now - 7200, not_after: now - 60, refresh_after: now - 3600)
      expect(mc.refresh_due?(now: now)).to be false
    end
  end

  describe "#to_wire" do
    it "emits the agent-facing envelope shape" do
      mc = build_mc
      mc.save!
      wire = mc.to_wire
      expect(wire[:envelope]).to eq(mc.envelope_json)
      expect(wire[:signature]).to eq(mc.signature_b64)
      expect(wire[:constellation_handle]).to eq("acct-test")
      expect(wire[:revision]).to eq(1)
      expect(wire[:not_before]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe "partial unique index on (peer, network) WHERE status = 'active'" do
    it "rejects two active rows for the same (peer, network)" do
      build_mc(status: "active").save!
      duplicate = build_mc(status: "active", revision: 2)
      expect { duplicate.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows multiple non-active rows" do
      build_mc(status: "revoked", revoked_at: Time.current).save!(validate: false)
      build_mc(status: "revoked", revoked_at: Time.current, revision: 2).save!(validate: false)
      expect(described_class.where(sdwan_peer_id: peer.id, sdwan_network_id: network.id).count).to eq(2)
    end
  end
end
