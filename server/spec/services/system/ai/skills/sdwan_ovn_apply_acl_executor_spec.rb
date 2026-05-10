# frozen_string_literal: true

require "rails_helper"

# Phase O6 follow-up of the OVS+OVN dual-profile networking roadmap.
RSpec.describe System::Ai::Skills::SdwanOvnApplyAclExecutor do
  let(:account)    { create(:account) }
  let(:exec)       { described_class.new(account: account) }

  let(:deployment) do
    ::Sdwan::OvnDeployment.create!(
      account_id: account.id,
      nb_db_endpoint: "tcp:127.0.0.1:6641",
      sb_db_endpoint: "tcp:127.0.0.1:6642"
    )
  end
  let!(:switch) do
    s = ::Sdwan::OvnLogicalSwitch.create!(
      account_id: account.id, sdwan_ovn_deployment_id: deployment.id, name: "ls-app"
    )
    s.mark_active!
    s
  end

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, and instance-method rollback" do
      d = described_class.descriptor

      expect(d[:name]).to eq("sdwan_ovn_apply_acl")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :logical_switch_id, :required)).to be true
      expect(d.dig(:inputs, :acls, :required)).to be true
      expect(d.dig(:outputs, :outputs)).to include(:logical_switch_id, :ovn_acl_ids,
                                                   :allocations, :compiled_plan)
      expect(d[:rollback]).to eq(:rollback_sdwan_ovn_apply_acl)
      expect(d[:blast_radius]).to eq(:medium)
    end
  end

  describe "#execute" do
    let(:base_acl) do
      { name: "deny-tenant-b", direction: "to-lport", priority: 1500,
        match: "ip4.src == 10.20.0.0/16", action: "drop" }
    end

    context "with no acls" do
      it "rejects" do
        r = exec.execute(logical_switch_id: switch.id, acls: [])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/at least one entry/)
      end
    end

    context "with a missing logical_switch_id" do
      it "rejects" do
        r = exec.execute(logical_switch_id: " ", acls: [ base_acl ])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/logical_switch_id is required/)
      end
    end

    context "with a switch from another account" do
      it "rejects" do
        other = create(:account)
        other_dep = ::Sdwan::OvnDeployment.create!(
          account_id: other.id,
          nb_db_endpoint: "tcp:127.0.0.1:6641", sb_db_endpoint: "tcp:127.0.0.1:6642"
        )
        other_switch = ::Sdwan::OvnLogicalSwitch.create!(
          account_id: other.id, sdwan_ovn_deployment_id: other_dep.id, name: "stranger"
        )
        r = exec.execute(logical_switch_id: other_switch.id, acls: [ base_acl ])
        expect(r[:success]).to be false
        expect(r[:error]).to include("not found in account")
      end
    end

    context "with an unknown direction" do
      it "rejects" do
        r = exec.execute(logical_switch_id: switch.id,
                         acls: [ base_acl.merge(direction: "sideways") ])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/direction must be one of/)
      end
    end

    context "with an unknown action" do
      it "rejects" do
        r = exec.execute(logical_switch_id: switch.id,
                         acls: [ base_acl.merge(action: "annoy") ])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/action must be one of/)
      end
    end

    context "with an out-of-range priority" do
      it "rejects" do
        r = exec.execute(logical_switch_id: switch.id,
                         acls: [ base_acl.merge(priority: 99_999) ])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/priority must be between/)
      end
    end

    context "with an empty match" do
      it "rejects" do
        r = exec.execute(logical_switch_id: switch.id,
                         acls: [ base_acl.merge(match: " ") ])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/match is required/)
      end
    end

    context "in dry_run mode" do
      it "returns a plan without persisting ACL rows" do
        expect {
          r = exec.execute(logical_switch_id: switch.id, acls: [ base_acl ], dry_run: true)
          expect(r[:success]).to be true
          d = r[:data]
          expect(d[:dry_run]).to be true
          expect(d[:acl_count]).to eq(1)
          expect(d[:outputs][:ovn_acl_ids]).to eq([])
          expect(d[:planned_actions].first[:step]).to eq("create_or_reuse_acl")
          expect(d[:planned_actions].last[:step]).to eq("compile_topology")
        }.not_to change(::Sdwan::OvnAcl, :count)
      end
    end

    context "live execute on a switch with no existing ACLs" do
      it "creates the ACL + activates it + re-compiles the topology plan" do
        r = exec.execute(logical_switch_id: switch.id, acls: [ base_acl ])
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:acl_count]).to eq(1)
        expect(d[:outputs][:ovn_acl_ids].size).to eq(1)
        expect(d[:outputs][:allocations].first[:reused]).to be false
        expect(d[:outputs][:compiled_plan]).to be_present

        # Compiler picks up the new ACL and emits an acl-add line
        plan = d[:outputs][:compiled_plan][:plan]
        acl_entries = plan.select { |e| e[:cmd] == "acl-add" }
        expect(acl_entries.size).to eq(1)
        expect(acl_entries.first[:args]).to eq([ "ls-app", "to-lport", "1500", "ip4.src == 10.20.0.0/16", "drop" ])
      end
    end

    context "idempotency" do
      it "returns reused=true on second execute with the same name" do
        first  = exec.execute(logical_switch_id: switch.id, acls: [ base_acl ])
        second = exec.execute(logical_switch_id: switch.id, acls: [ base_acl ])
        expect(second[:success]).to be true
        expect(second[:data][:outputs][:ovn_acl_ids]).to eq(first[:data][:outputs][:ovn_acl_ids])
        expect(second[:data][:outputs][:allocations].first[:reused]).to be true
        expect(::Sdwan::OvnAcl.where(sdwan_ovn_logical_switch_id: switch.id).count).to eq(1)
      end

      it "does not mutate match/action on reuse" do
        exec.execute(logical_switch_id: switch.id, acls: [ base_acl ])
        exec.execute(logical_switch_id: switch.id,
                     acls: [ base_acl.merge(match: "tcp.dst == 1234", action: "allow") ])
        existing = ::Sdwan::OvnAcl.where(sdwan_ovn_logical_switch_id: switch.id).first
        expect(existing.match).to eq("ip4.src == 10.20.0.0/16")
        expect(existing.action).to eq("drop")
      end
    end
  end

  describe "#rollback_sdwan_ovn_apply_acl" do
    it "destroys only newly-created ACLs" do
      r = exec.execute(logical_switch_id: switch.id, acls: [
                         { name: "doomed", direction: "to-lport",
                           match: "ip4.src == 10.30.0.0/16", action: "drop" }
                       ])
      acl_id = r[:data][:outputs][:ovn_acl_ids].first
      expect(::Sdwan::OvnAcl.find_by(id: acl_id)).to be_present

      rb = exec.rollback_sdwan_ovn_apply_acl(allocations: r[:data][:outputs][:allocations])
      expect(rb[:success]).to be true
      expect(::Sdwan::OvnAcl.find_by(id: acl_id)).to be_nil
    end

    it "leaves re-used ACLs alone" do
      first = exec.execute(logical_switch_id: switch.id, acls: [
                             { name: "keepable", direction: "to-lport",
                               match: "ip4.src == 10.40.0.0/16", action: "drop" }
                           ])
      acl_id = first[:data][:outputs][:ovn_acl_ids].first
      second = exec.execute(logical_switch_id: switch.id, acls: [
                              { name: "keepable", direction: "to-lport",
                                match: "ip4.src == 10.40.0.0/16", action: "drop" }
                            ])
      exec.rollback_sdwan_ovn_apply_acl(allocations: second[:data][:outputs][:allocations])
      expect(::Sdwan::OvnAcl.find_by(id: acl_id)).to be_present
    end
  end
end
