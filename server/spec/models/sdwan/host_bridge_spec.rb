# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::HostBridge, type: :model do
  let(:account) { Account.first || create(:account) }
  let(:node)    { sdwan_test_node(account: account) }
  let(:host_a)  { sdwan_test_node_instance(node: node) }
  let(:host_b)  { sdwan_test_node_instance(node: node) }

  before do
    Sdwan::HostBridge.where(account_id: account.id).delete_all
  end

  def build_bridge(overrides = {})
    # short_id auto-increments per call so each row gets a unique
    # per-host id without explicit overrides everywhere.
    @short_id_counter ||= 0
    @short_id_counter += 1
    described_class.new({
      account: account,
      node_instance: host_a,
      short_id: @short_id_counter,
      bridge_name: described_class.derive_bridge_name(@short_id_counter),
      kind: "linux"
    }.merge(overrides))
  end

  describe "validations" do
    it "is valid with allocator-shaped attributes" do
      expect(build_bridge).to be_valid
    end

    it "rejects short_id below the 1 floor" do
      b = build_bridge(short_id: 0)
      expect(b).not_to be_valid
      expect(b.errors[:short_id]).to be_present
    end

    it "rejects short_id above 9999" do
      b = build_bridge(short_id: 10_000)
      expect(b).not_to be_valid
      expect(b.errors[:short_id]).to be_present
    end

    it "rejects bridge_name longer than IFNAMSIZ (15 chars)" do
      b = build_bridge(bridge_name: "x" * 16)
      expect(b).not_to be_valid
      expect(b.errors[:bridge_name]).to be_present
    end

    it "rejects unknown kind values" do
      b = build_bridge(kind: "vxlan")
      expect(b).not_to be_valid
      expect(b.errors[:kind]).to be_present
    end

    it "accepts both linux and ovs as kind values" do
      expect(build_bridge(kind: "linux")).to be_valid
      expect(build_bridge(kind: "ovs")).to be_valid
    end

    it "enforces per-host short_id uniqueness via the application validator" do
      build_bridge.save!
      collision = build_bridge(short_id: 1, bridge_name: "pwnbr-other")
      collision.short_id = 1
      expect(collision).not_to be_valid
      expect(collision.errors[:short_id]).to include("has already been taken")
    end

    it "enforces per-host bridge_name uniqueness via the application validator" do
      build_bridge.save!
      collision = build_bridge(bridge_name: described_class.derive_bridge_name(1))
      expect(collision).not_to be_valid
      expect(collision.errors[:bridge_name]).to include("has already been taken")
    end

    it "permits the same short_id on a different host" do
      build_bridge.save!
      build_bridge(node_instance: host_b, short_id: 1,
                   bridge_name: described_class.derive_bridge_name(1)).tap(&:save!)
      expect(described_class.where(short_id: 1).count).to eq(2)
    end
  end

  describe ".derive_bridge_name" do
    it "produces pwnbr-<short_id> format" do
      expect(described_class.derive_bridge_name(1)).to eq("pwnbr-1")
      expect(described_class.derive_bridge_name(9999)).to eq("pwnbr-9999")
    end

    it "stays within IFNAMSIZ (15 chars) at the 9999 ceiling" do
      name = described_class.derive_bridge_name(9999)
      expect(name.length).to be <= described_class::BRIDGE_NAME_MAX
    end
  end

  describe "AASM lifecycle" do
    let(:bridge) { build_bridge.tap(&:save!) }

    it "starts in :pending" do
      expect(bridge.state).to eq("pending")
    end

    it "transitions pending → active and stamps applied_at" do
      expect { bridge.mark_active! }.to change(bridge, :state).from("pending").to("active")
      expect(bridge.applied_at).to be_present
    end

    it "transitions active → draining and stamps draining_at" do
      bridge.mark_active!
      expect { bridge.start_drain! }.to change(bridge, :state).from("active").to("draining")
      expect(bridge.draining_at).to be_present
    end

    it "transitions draining → removed and stamps removed_at" do
      bridge.mark_active!
      bridge.start_drain!
      expect { bridge.mark_removed! }.to change(bridge, :state).from("draining").to("removed")
      expect(bridge.removed_at).to be_present
    end

    it "supports straight pending → removed for never-applied bridges" do
      expect { bridge.mark_removed! }.to change(bridge, :state).from("pending").to("removed")
    end

    it "readopt clears removed_at and re-stamps applied_at" do
      bridge.mark_active!
      bridge.mark_removed!
      bridge.readopt!
      expect(bridge.state).to eq("active")
      expect(bridge.removed_at).to be_nil
      expect(bridge.applied_at).to be_present
    end
  end

  describe "scopes" do
    let!(:b_pending)  { build_bridge.tap(&:save!) }
    let!(:b_active)   { build_bridge(node_instance: host_b).tap { |b| b.save!; b.mark_active! } }

    it "active returns only active rows" do
      expect(described_class.active.pluck(:id)).to contain_exactly(b_active.id)
    end

    it "pending returns only pending rows" do
      expect(described_class.pending.pluck(:id)).to contain_exactly(b_pending.id)
    end

    it "compilable includes active + draining (excludes pending and removed)" do
      b_active.start_drain!
      expect(described_class.compilable.pluck(:id)).to include(b_active.id)
      expect(described_class.compilable.pluck(:id)).not_to include(b_pending.id)
    end

    it "for_host filters to a single host" do
      expect(described_class.for_host(host_a).pluck(:id)).to eq([b_pending.id])
    end
  end

  describe "DB-level guards" do
    it "the check constraint rejects short_id outside 1..9999 if model validation is bypassed" do
      b = build_bridge
      b.short_id = 10_000
      expect { b.save(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "the check constraint rejects state values outside the enum" do
      b = build_bridge.tap(&:save!)
      b.state = "ghost"
      expect { b.save(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "the check constraint rejects kind values outside the enum" do
      b = build_bridge
      b.kind = "vxlan"
      expect { b.save(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "enforces per-host (host, short_id) uniqueness at the DB level" do
      build_bridge.save!
      dup = build_bridge(short_id: 1, bridge_name: "pwnbr-x")
      expect { dup.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
