# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::OvnLogicalSwitch, type: :model do
  let(:account) { Account.first || create(:account) }
  let(:deployment) do
    Sdwan::OvnDeployment.create!(
      account: account,
      nb_db_endpoint: "tcp:10.0.0.1:6641",
      sb_db_endpoint: "tcp:10.0.0.1:6642"
    )
  end

  before do
    Sdwan::OvnLogicalSwitchPort.where(account_id: account.id).delete_all
    Sdwan::OvnLogicalSwitch.where(account_id: account.id).delete_all
    Sdwan::OvnDeployment.where(account_id: account.id).delete_all
  end

  def build_switch(overrides = {})
    @name_counter ||= 0
    @name_counter += 1
    described_class.new({
      account: account,
      sdwan_ovn_deployment_id: deployment.id,
      name: "ls-#{@name_counter}",
      description: "test"
    }.merge(overrides))
  end

  describe "validations" do
    it "is valid with deployment + name" do
      expect(build_switch).to be_valid
    end

    it "rejects blank names" do
      s = build_switch(name: "")
      expect(s).not_to be_valid
      expect(s.errors[:name]).to be_present
    end

    it "rejects names longer than the OVN 63-char cap" do
      s = build_switch(name: "x" * 64)
      expect(s).not_to be_valid
      expect(s.errors[:name]).to be_present
    end

    it "accepts names exactly at the 63-char ceiling" do
      s = build_switch(name: "x" * 63)
      expect(s).to be_valid
    end

    it "rejects names with whitespace or special chars" do
      expect(build_switch(name: "ls one")).not_to be_valid
      expect(build_switch(name: "ls/two")).not_to be_valid
    end

    it "accepts names with letters, digits, _, -, ." do
      expect(build_switch(name: "ls_1.staging-east")).to be_valid
    end

    it "enforces per-deployment name uniqueness" do
      build_switch(name: "dup").save!
      collision = build_switch(name: "dup")
      expect(collision).not_to be_valid
      expect(collision.errors[:name]).to include("has already been taken")
    end

    it "permits the same name across different deployments" do
      other_account = Account.create!(name: "other-#{SecureRandom.hex(4)}")
      other_deployment = Sdwan::OvnDeployment.create!(
        account: other_account,
        nb_db_endpoint: "tcp:10.0.0.2:6641",
        sb_db_endpoint: "tcp:10.0.0.2:6642"
      )
      build_switch(name: "shared").save!
      other = described_class.new(
        account: other_account,
        sdwan_ovn_deployment_id: other_deployment.id,
        name: "shared"
      )
      expect(other).to be_valid
    end

    it "rejects unknown state values" do
      s = build_switch(state: "ghost")
      expect(s).not_to be_valid
      expect(s.errors[:state]).to be_present
    end
  end

  describe "AASM lifecycle" do
    let(:switch) { build_switch.tap(&:save!) }

    it "starts in :pending" do
      expect(switch.state).to eq("pending")
    end

    it "transitions pending → active and stamps activated_at" do
      expect { switch.mark_active! }
        .to change(switch, :state).from("pending").to("active")
      expect(switch.activated_at).to be_present
    end

    it "transitions active → removed and stamps removed_at" do
      switch.mark_active!
      expect { switch.mark_removed! }
        .to change(switch, :state).from("active").to("removed")
      expect(switch.removed_at).to be_present
    end

    it "supports straight pending → removed" do
      expect { switch.mark_removed! }
        .to change(switch, :state).from("pending").to("removed")
    end

    it "readopt clears removed_at and sets back to active" do
      switch.mark_active!
      switch.mark_removed!
      switch.readopt!
      expect(switch.state).to eq("active")
      expect(switch.removed_at).to be_nil
      expect(switch.activated_at).to be_present
    end
  end

  describe "scopes" do
    let!(:s_pending) { build_switch.tap(&:save!) }
    let!(:s_active)  { build_switch.tap { |s| s.save!; s.mark_active! } }
    let!(:s_removed) { build_switch.tap { |s| s.save!; s.mark_removed! } }

    it "active returns only active rows" do
      expect(described_class.active.pluck(:id)).to contain_exactly(s_active.id)
    end

    it "pending returns only pending rows" do
      expect(described_class.pending.pluck(:id)).to contain_exactly(s_pending.id)
    end

    it "compilable returns only active rows (excludes pending and removed)" do
      ids = described_class.compilable.pluck(:id)
      expect(ids).to include(s_active.id)
      expect(ids).not_to include(s_pending.id)
      expect(ids).not_to include(s_removed.id)
    end

    it "for_deployment scopes to a single deployment" do
      expect(described_class.for_deployment(deployment).pluck(:id))
        .to contain_exactly(s_pending.id, s_active.id, s_removed.id)
    end
  end

  describe "DB-level guards" do
    it "the check constraint rejects state values outside the enum" do
      s = build_switch.tap(&:save!)
      s.state = "ghost"
      expect { s.save(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "the column length cap rejects name > 63 chars" do
      s = build_switch
      s.name = "x" * 64
      expect { s.save(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "the unique index rejects duplicate (deployment, name)" do
      build_switch(name: "dup").save!
      dup = build_switch(name: "dup")
      expect { dup.save(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "associations" do
    it "destroys child ports on destroy" do
      s = build_switch.tap(&:save!)
      Sdwan::OvnLogicalSwitchPort.create!(
        account: account,
        sdwan_ovn_logical_switch_id: s.id,
        name: "p1",
        kind: "vm"
      )
      expect { s.destroy }.to change(Sdwan::OvnLogicalSwitchPort, :count).by(-1)
    end
  end
end
