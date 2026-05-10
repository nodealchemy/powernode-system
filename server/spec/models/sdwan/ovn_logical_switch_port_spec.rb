# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::OvnLogicalSwitchPort, type: :model do
  let(:account) { Account.first || create(:account) }
  let(:node)    { sdwan_test_node(account: account) }
  let(:host)    { sdwan_test_node_instance(node: node) }
  let(:deployment) do
    Sdwan::OvnDeployment.create!(
      account: account,
      nb_db_endpoint: "tcp:10.0.0.1:6641",
      sb_db_endpoint: "tcp:10.0.0.1:6642"
    )
  end
  let(:switch) do
    Sdwan::OvnLogicalSwitch.create!(
      account: account,
      sdwan_ovn_deployment_id: deployment.id,
      name: "ls-#{SecureRandom.hex(3)}"
    )
  end

  before do
    Sdwan::OvnLogicalSwitchPort.where(account_id: account.id).delete_all
    Sdwan::OvnLogicalSwitch.where(account_id: account.id).delete_all
    Sdwan::OvnDeployment.where(account_id: account.id).delete_all
  end

  def build_port(overrides = {})
    @name_counter ||= 0
    @name_counter += 1
    described_class.new({
      account: account,
      sdwan_ovn_logical_switch_id: switch.id,
      host_node_instance: host,
      name: "p-#{@name_counter}",
      kind: "vm",
      addresses: ["10.0.0.#{@name_counter}"]
    }.merge(overrides))
  end

  describe "validations" do
    it "is valid with switch + name + kind" do
      expect(build_port).to be_valid
    end

    it "auto-generates a locally-administered MAC when blank" do
      p = build_port(mac: nil)
      expect(p).to be_valid
      p.save!
      expect(p.mac).to match(/\A02:[0-9a-f]{2}(:[0-9a-f]{2}){4}\z/)
    end

    it "preserves caller-supplied MACs" do
      p = build_port(mac: "0a:bb:cc:dd:ee:ff")
      expect(p).to be_valid
      p.save!
      expect(p.mac).to eq("0a:bb:cc:dd:ee:ff")
    end

    it "rejects malformed MACs" do
      p = build_port(mac: "not-a-mac")
      expect(p).not_to be_valid
      expect(p.errors[:mac]).to be_present
    end

    it "rejects unknown kind values" do
      p = build_port(kind: "router")
      expect(p).not_to be_valid
      expect(p.errors[:kind]).to be_present
    end

    it "accepts vm, container, and external kinds" do
      expect(build_port(kind: "vm")).to be_valid
      expect(build_port(kind: "container")).to be_valid
      # External ports leave host_node_instance unset
      expect(build_port(kind: "external", host_node_instance: nil)).to be_valid
    end

    it "rejects names longer than the OVN 63-char cap" do
      p = build_port(name: "x" * 64)
      expect(p).not_to be_valid
      expect(p.errors[:name]).to be_present
    end

    it "enforces per-switch name uniqueness" do
      build_port(name: "dup").save!
      collision = build_port(name: "dup")
      expect(collision).not_to be_valid
      expect(collision.errors[:name]).to include("has already been taken")
    end

    it "permits the same name across different switches" do
      other = Sdwan::OvnLogicalSwitch.create!(
        account: account,
        sdwan_ovn_deployment_id: deployment.id,
        name: "other-#{SecureRandom.hex(3)}"
      )
      build_port(name: "shared").save!
      ok = described_class.new(
        account: account,
        sdwan_ovn_logical_switch_id: other.id,
        name: "shared",
        kind: "vm"
      )
      expect(ok).to be_valid
    end

    it "rejects addresses that aren't a string array" do
      p = build_port(addresses: { ip: "10.0.0.1" })
      expect(p).not_to be_valid
      expect(p.errors[:addresses]).to be_present
    end

    it "rejects addresses with non-string members" do
      p = build_port(addresses: ["10.0.0.1", 42])
      expect(p).not_to be_valid
      expect(p.errors[:addresses]).to be_present
    end

    it "accepts an empty addresses array" do
      p = build_port(addresses: [])
      expect(p).to be_valid
    end
  end

  describe ".generate_mac" do
    it "always returns a locally-administered MAC (02: prefix)" do
      100.times do
        mac = described_class.generate_mac
        expect(mac).to match(/\A02:[0-9a-f]{2}(:[0-9a-f]{2}){4}\z/)
      end
    end

    it "produces collision-free MACs across many calls" do
      macs = Array.new(500) { described_class.generate_mac }
      expect(macs.uniq.size).to eq(macs.size)
    end
  end

  describe "AASM lifecycle" do
    let(:port) { build_port.tap(&:save!) }

    it "starts in :pending" do
      expect(port.state).to eq("pending")
    end

    it "transitions pending → active and stamps activated_at" do
      expect { port.mark_active! }
        .to change(port, :state).from("pending").to("active")
      expect(port.activated_at).to be_present
    end

    it "transitions active → removed and stamps removed_at" do
      port.mark_active!
      expect { port.mark_removed! }
        .to change(port, :state).from("active").to("removed")
      expect(port.removed_at).to be_present
    end

    it "readopt clears removed_at and re-stamps activated_at" do
      port.mark_active!
      port.mark_removed!
      port.readopt!
      expect(port.state).to eq("active")
      expect(port.removed_at).to be_nil
      expect(port.activated_at).to be_present
    end
  end

  describe "scopes" do
    let!(:p_pending)  { build_port.tap(&:save!) }
    let!(:p_active)   { build_port.tap { |p| p.save!; p.mark_active! } }
    let!(:p_external) do
      build_port(kind: "external", host_node_instance: nil).tap(&:save!)
    end

    it "active returns only active rows" do
      expect(described_class.active.pluck(:id)).to contain_exactly(p_active.id)
    end

    it "compilable returns only active rows" do
      expect(described_class.compilable.pluck(:id)).to contain_exactly(p_active.id)
    end

    it "for_switch scopes to a switch" do
      expect(described_class.for_switch(switch).pluck(:id))
        .to contain_exactly(p_pending.id, p_active.id, p_external.id)
    end

    it "for_host filters to vm/container ports on a host" do
      ids = described_class.for_host(host).pluck(:id)
      expect(ids).to include(p_pending.id, p_active.id)
      expect(ids).not_to include(p_external.id)
    end

    it "external returns only external ports" do
      expect(described_class.external.pluck(:id)).to contain_exactly(p_external.id)
    end
  end

  describe "DB-level guards" do
    it "the check constraint rejects state values outside the enum" do
      p = build_port.tap(&:save!)
      p.state = "ghost"
      expect { p.save(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "the check constraint rejects kind values outside the enum" do
      p = build_port.tap(&:save!)
      p.kind = "router"
      expect { p.save(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "the unique index rejects duplicate (switch, name)" do
      build_port(name: "dup").save!
      # We bypass model validations here to prove the DB index is the
      # last line of defense. Pass a literal MAC because validate:false
      # also skips the before_validation hook that auto-generates one.
      dup = build_port(name: "dup", mac: "02:99:99:99:99:99")
      expect { dup.save(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
