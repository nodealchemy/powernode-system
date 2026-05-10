# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::HostVrfAssignment, type: :model do
  let(:account) { Account.first || create(:account) }
  let(:node)    { sdwan_test_node(account: account) }
  let(:host_a)  { sdwan_test_node_instance(node: node) }
  let(:host_b)  { sdwan_test_node_instance(node: node) }

  before do
    Sdwan::HostVrfAssignment.where(account_id: account.id).delete_all
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
  end

  let(:network) do
    Sdwan::Network.create!(account_id: account.id,
                           name: "vrf-net-#{SecureRandom.hex(3)}")
  end

  def build_assignment(overrides = {})
    # short_id auto-increments per call so each row gets a unique
    # per-host id without needing explicit overrides everywhere. table_id
    # stays at 100 by default — tests that exercise table_id collision
    # explicitly override it.
    @short_id_counter ||= 0
    @short_id_counter += 1
    described_class.new({
      account: account,
      node_instance: host_a,
      network: network,
      table_id: 100,
      short_id: @short_id_counter,
      vrf_name: "sdwan-#{@short_id_counter}"
    }.merge(overrides))
  end

  describe "validations" do
    it "is valid with allocator-shaped attributes" do
      expect(build_assignment).to be_valid
    end

    it "rejects table_id below the 100 floor" do
      a = build_assignment(table_id: 99)
      expect(a).not_to be_valid
      expect(a.errors[:table_id]).to be_present
    end

    it "rejects table_id above 65535" do
      a = build_assignment(table_id: 65_536)
      expect(a).not_to be_valid
      expect(a.errors[:table_id]).to be_present
    end

    it "rejects kernel-reserved table ids 0/253/254/255" do
      [0, 253, 254, 255].each do |reserved|
        a = build_assignment(table_id: reserved)
        expect(a).not_to be_valid, "expected table_id=#{reserved} rejected"
        expect(a.errors[:table_id].join).to match(/reserved/)
      end
    end

    it "rejects vrf_name longer than IFNAMSIZ (15 chars)" do
      a = build_assignment(vrf_name: "x" * 16)
      expect(a).not_to be_valid
      expect(a.errors[:vrf_name]).to be_present
    end

    it "enforces (host, network) uniqueness via the application validator + DB index" do
      build_assignment.save!
      dup = build_assignment(table_id: 101, vrf_name: "sdwan-other-x")
      expect { dup.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "enforces per-host table_id uniqueness" do
      build_assignment.save!

      other_net = Sdwan::Network.create!(
        account_id: account.id, name: "vrf-net2-#{SecureRandom.hex(3)}"
      )
      collision = build_assignment(network: other_net, table_id: 100,
                                   vrf_name: "sdwan-#{other_net.network_handle}")
      expect(collision).not_to be_valid
      expect(collision.errors[:table_id]).to include("has already been taken")
    end

    it "permits the same table_id on a different host" do
      build_assignment.save!

      build_assignment(node_instance: host_b,
                       vrf_name: "sdwan-#{network.network_handle}").tap(&:save!)
      # If we got here without exception, the per-host scope works.
      expect(described_class.where(network: network, table_id: 100).count).to eq(2)
    end
  end

  describe "AASM lifecycle" do
    let(:assignment) { build_assignment.tap(&:save!) }

    it "starts in :pending" do
      expect(assignment.state).to eq("pending")
    end

    it "transitions pending → active and stamps applied_at" do
      expect { assignment.mark_active! }.to change(assignment, :state).from("pending").to("active")
      expect(assignment.applied_at).to be_present
    end

    it "transitions active → draining and stamps draining_at" do
      assignment.mark_active!
      expect { assignment.start_drain! }.to change(assignment, :state).from("active").to("draining")
      expect(assignment.draining_at).to be_present
    end

    it "transitions draining → removed and stamps removed_at" do
      assignment.mark_active!
      assignment.start_drain!
      expect { assignment.mark_removed! }.to change(assignment, :state).from("draining").to("removed")
      expect(assignment.removed_at).to be_present
    end

    it "supports straight pending → removed for never-applied assignments" do
      expect { assignment.mark_removed! }.to change(assignment, :state).from("pending").to("removed")
    end

    it "readopt clears removed_at and re-stamps applied_at" do
      assignment.mark_active!
      assignment.mark_removed!
      assignment.readopt!
      expect(assignment.state).to eq("active")
      expect(assignment.removed_at).to be_nil
      expect(assignment.applied_at).to be_present
    end
  end

  describe "scopes" do
    let!(:a_pending)  { build_assignment.tap(&:save!) }
    let!(:a_active)   { build_assignment(node_instance: host_b).tap { |a| a.save!; a.mark_active! } }

    it "active returns only active rows" do
      expect(described_class.active.pluck(:id)).to contain_exactly(a_active.id)
    end

    it "pending returns only pending rows" do
      expect(described_class.pending.pluck(:id)).to contain_exactly(a_pending.id)
    end

    it "compilable includes active + draining (excludes pending and removed)" do
      a_active.start_drain!
      expect(described_class.compilable.pluck(:id)).to include(a_active.id)
      expect(described_class.compilable.pluck(:id)).not_to include(a_pending.id)
    end

    it "for_host filters to a single host" do
      expect(described_class.for_host(host_a).pluck(:id)).to eq([a_pending.id])
    end
  end

  describe "DB-level guards" do
    it "the check constraint rejects kernel-reserved ids if model validation is bypassed" do
      a = build_assignment
      a.table_id = 254
      expect { a.save(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "the check constraint rejects state values outside the enum" do
      a = build_assignment.tap(&:save!)
      a.state = "ghost"
      expect { a.save(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end
end
