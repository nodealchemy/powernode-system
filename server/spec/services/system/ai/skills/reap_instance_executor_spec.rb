# frozen_string_literal: true

require "rails_helper"

# APO-4 (DR-1), the DESTRUCTIVE half of a replace.
#
# WHY IT IS A CLASS OF ITS OWN rather than a flag on
# System::Ai::Skills::ReplaceInstanceExecutor. The gate BaseSkillExecutor
# evaluates resolves the CLASS's single `action_category`. A `reap_only:` input
# on the replace executor therefore ran the terminate under
# `system.instance_replace` — the ADDITIVE category — so any caller that could
# reach a replace could terminate an instance, and an operator releasing an
# approval whose card reads "replace an unrecoverable instance ... the
# terminate is a SEPARATE approval" got the terminate. Splitting the class is
# what makes the second approval real: this executor's own category IS
# `system.instance_reap`, so an ungated call gates on the reap policy.
RSpec.describe System::Ai::Skills::ReapInstanceExecutor, type: :service do
  let(:account)                { create(:account) }
  let(:node_template)          { create(:system_node_template, account: account) }
  let(:provider_region)        { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }

  let!(:failed) do
    node = create(:system_node, account: account, node_template: node_template)
    inst = create(:system_node_instance,
                  node: node, name: "dead-#{SecureRandom.hex(3)}", variety: "cloud",
                  status: "error", provider_region: provider_region,
                  provider_instance_type: provider_instance_type)
    inst.update!(cloud_instance_id: "mock-#{SecureRandom.hex(6)}")
    inst
  end

  let(:provider) { instance_double(System::Providers::MockProvider, provider_type: "mock") }

  before do
    allow(System::Providers::Registry).to receive(:for_instance).and_return(provider)
    allow(provider).to receive(:terminate_instance).and_return({ success: true })
  end

  def reap(gated:, operation_id: "op-reap")
    described_class.new(account: account, agent: nil, user: nil)
                   .execute(gated: gated, instance_id: failed.id, operation_id: operation_id)
  end

  it "declares the reap's own action_category, not the replace's" do
    expect(described_class.action_category).to eq("system.instance_reap")
  end

  describe "an UNGATED call" do
    it "parks an approval on system.instance_reap instead of terminating" do
      result = reap(gated: false, operation_id: "op-ungated")

      expect(provider).not_to have_received(:terminate_instance)
      expect(failed.reload.status).to eq("error")

      op = Ai::DeferredOperation.where(account: account).order(:created_at).last
      expect(op).to be_present, "an ungated reap neither terminated nor parked anything: #{result.inspect}"
      expect(op.action_category).to eq("system.instance_reap")
      expect(op.executor_class).to eq(described_class.name)
    end
  end

  describe "the released approval" do
    it "terminates the failed instance and records the step on the replace ledger" do
      result = reap(gated: true, operation_id: "op-released")

      expect(result[:success]).to be(true), "reap failed: #{result[:error]}"
      expect(result.dig(:data, :reaped)).to be(true)
      expect(provider).to have_received(:terminate_instance).once

      event = System::FleetEvent
                .where(account_id: account.id, kind: "system.instance_replace.reap")
                .where("payload->>'operation_id' = ?", "op-released").first
      expect(event).to be_present
      expect(event.payload["failed_instance_id"]).to eq(failed.id)
    end

    it "is idempotent on operation_id, so a double release cannot terminate twice" do
      reap(gated: true, operation_id: "op-twice")
      second = reap(gated: true, operation_id: "op-twice")

      expect(second[:success]).to be(true)
      expect(second.dig(:data, :replayed)).to be(true)
      expect(provider).to have_received(:terminate_instance).once
    end
  end

  it "refuses an instance outside the account scope" do
    other = create(:system_node_instance, name: "not-mine")

    result = described_class.new(account: account, agent: nil, user: nil)
                            .execute(gated: true, instance_id: other.id, operation_id: "op-scope")

    expect(result[:success]).to be(false)
    expect(result[:error]).to match(/not found in account scope/i)
    expect(provider).not_to have_received(:terminate_instance)
  end
end
