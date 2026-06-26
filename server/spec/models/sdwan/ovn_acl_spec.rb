# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::OvnAcl, type: :model do
  let(:account) { Account.first || create(:account) }
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
    Sdwan::OvnAcl.where(account_id: account.id).delete_all
    Sdwan::OvnLogicalSwitch.where(account_id: account.id).delete_all
    Sdwan::OvnDeployment.where(account_id: account.id).delete_all
  end

  def build_acl(overrides = {})
    @name_counter ||= 0
    @name_counter += 1
    described_class.new({
      account: account,
      sdwan_ovn_logical_switch_id: switch.id,
      name: "acl-#{@name_counter}",
      direction: "from-lport",
      action: "allow",
      match: "ip4.src == 10.0.0.0/24"
    }.merge(overrides))
  end

  # Persist a row and drive it to :active (so it participates in the
  # active-only collision guard).
  def create_active_acl(overrides = {})
    acl = build_acl(overrides).tap(&:save!)
    acl.mark_active!
    acl
  end

  describe "validations" do
    it "is valid with switch + direction + action + match" do
      expect(build_acl).to be_valid
    end

    it "defaults priority to 1000 when omitted" do
      acl = build_acl.tap(&:save!)
      expect(acl.priority).to eq(Sdwan::OvnAcl::DEFAULT_PRIORITY)
    end
  end

  describe "active (switch, direction, priority) collision guard" do
    # Reproduces the policy-bypass bug: two active ACLs that both omit
    # priority land at the 1000 default. OVN evaluates by `priority`, and
    # equal-priority matches on the same packet have UNDEFINED selection —
    # so a broad allow can silently shadow a specific drop. Guard rejects
    # the second active row.
    it "rejects a second active ACL with the same (switch, direction, priority)" do
      create_active_acl(name: "broad-allow", action: "allow")

      collision = build_acl(name: "specific-drop", action: "drop")
      collision.state = "active"
      expect(collision).not_to be_valid
      expect(collision.errors[:priority]).to be_present
    end

    it "rejects the default-priority collision (both omit priority -> both 1000)" do
      create_active_acl(name: "a", action: "allow")
      collision = build_acl(name: "b", action: "drop")
      collision.state = "active"
      expect(collision.priority).to eq(Sdwan::OvnAcl::DEFAULT_PRIORITY)
      expect(collision).not_to be_valid
    end

    it "permits a second active ACL with a different priority" do
      create_active_acl(name: "allow-1000", priority: 1000)
      ok = build_acl(name: "drop-2000", action: "drop", priority: 2000)
      ok.state = "active"
      expect(ok).to be_valid
    end

    it "permits the same priority across different directions" do
      create_active_acl(name: "from", direction: "from-lport", priority: 1000)
      ok = build_acl(name: "to", direction: "to-lport", priority: 1000)
      ok.state = "active"
      expect(ok).to be_valid
    end

    it "permits the same priority across different switches" do
      other = Sdwan::OvnLogicalSwitch.create!(
        account: account,
        sdwan_ovn_deployment_id: deployment.id,
        name: "other-#{SecureRandom.hex(3)}"
      )
      create_active_acl(name: "here", priority: 1000)
      ok = described_class.new(
        account: account,
        sdwan_ovn_logical_switch_id: other.id,
        name: "there",
        direction: "from-lport",
        action: "drop",
        match: "ip4.src == 10.0.0.0/24",
        priority: 1000
      )
      ok.state = "active"
      expect(ok).to be_valid
    end

    it "ignores non-active rows when looking for collisions (pending existing row)" do
      # Existing row is pending (not emitted) -> a new active row may take
      # the same priority.
      build_acl(name: "pending-1000", priority: 1000).save!
      ok = build_acl(name: "active-1000", action: "drop", priority: 1000)
      ok.state = "active"
      expect(ok).to be_valid
    end

    it "does not enforce the guard for a pending row colliding with an active one" do
      # A pending row isn't compiled, so it may share a priority with an
      # active row until it is itself activated.
      create_active_acl(name: "active-1000", priority: 1000)
      pending = build_acl(name: "pending-1000", action: "drop", priority: 1000)
      expect(pending.state).to eq("pending")
      expect(pending).to be_valid
    end

    it "allows re-saving an active row without self-collision" do
      acl = create_active_acl(name: "self", priority: 1000)
      acl.match = "ip4.src == 10.0.0.0/16"
      expect(acl).to be_valid
    end
  end
end
