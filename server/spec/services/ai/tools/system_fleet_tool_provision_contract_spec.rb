# frozen_string_literal: true

require "rails_helper"

# IMP-2679c830ea1a — system_provision_instance advertised itself as
# "asynchronous; returns task_id". Both halves were false: ProvisioningService
# calls the provider adapter inline and creates no System::Task at all, and the
# executor never returned a task_id. An agent reading the catalog would poll for
# a handle that can never exist, or report "provisioning started" for a call
# that had already errored.
#
# These specs pin the SYNCHRONOUS contract from both ends: what the executor
# actually produces, and what the description advertises. The description half
# is the disclosure surface an agent reads BEFORE it chooses to call, so it is
# asserted here rather than left to review.
RSpec.describe Ai::Tools::SystemFleetTool, "system_provision_instance contract" do
  let(:account)       { create(:account) }
  let(:node)          { create(:system_node, account: account) }
  let(:region)        { create(:system_provider_region) }
  let(:instance_type) { create(:system_provider_instance_type) }
  let(:adapter)       { instance_double("System::Providers::BaseProvider", provider_type: "mock", supports?: true) }
  let(:tool)          { described_class.new(account: account, internal: true) }

  # The real ProvisioningService runs; only the cloud adapter is stubbed. That
  # is what makes "the returned id names a real row" a meaningful oracle — a
  # stubbed service would just hand back the double we fed it.
  before do
    allow(::System::Providers::Registry).to receive(:for_node).and_return(adapter)
    # A spec account carries no Billing subscription, so with the business
    # extension loaded the quota guard denies before the provider is ever
    # reached. Same idiom as server/spec/services/ai/tools/provisioning_tool_spec.rb.
    if defined?(::Billing::ProvisioningQuotaGuard)
      allow(::Billing::ProvisioningQuotaGuard).to receive(:allow?).and_return([ true, nil ])
    end
  end

  def provision
    tool.execute(params: { action: "system_provision_instance",
                           node_id: node.id,
                           provider_region_id: region.id,
                           provider_instance_type_id: instance_type.id })
  end

  def last_row
    ::System::NodeInstance.where(node: node).order(:created_at).last
  end

  describe "the advertised description" do
    let(:description) { described_class.action_definitions.fetch("system_provision_instance")[:description] }

    # Scoped to the PROMISE shape, not to the token: the clearest disclosure an
    # agent can read is the explicit negative ("there is no task_id"), so a
    # blanket ban on the word would forbid the very sentence that fixes this.
    it "does not promise a task_id, because none is ever returned" do
      expect(description).not_to match(/returns?\s+(a\s+|the\s+)?task_id/i),
                                 "the description promises a task_id the executor never returns"
    end

    it "says outright that there is no task_id, so an agent stops looking for one" do
      expect(description).to match(/no task_id/i),
                             "an agent scanning for a polling handle finds no statement that none exists"
    end

    it "does not claim asynchrony, because no Task is ever created to poll" do
      expect(description).not_to match(/asynchronous/i),
                                 "the description claims asynchrony; ProvisioningService runs the provider call inline"
    end

    # \b matters: /synchronous/ is a substring of "asynchronous", so the
    # unanchored form passes against the exact text this task exists to remove.
    it "says plainly that the call is synchronous" do
      expect(description).to match(/\bsynchronous\b/i),
                             "an agent has no way to learn from the catalog that the call blocks to completion"
    end
  end

  describe "the success payload" do
    before do
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: "i-abc123", status: "running",
                    private_ip_address: "10.0.0.7", public_ip_address: nil)
    end

    # Equality, not inclusion: an existence check cannot see a field the
    # description promises and the payload silently drops, nor one added
    # without the description catching up.
    it "returns exactly the fields the corrected description names" do
      r = provision

      expect(r[:success]).to be(true), "provision failed: #{r[:error]}"
      expect(r[:data].keys).to match_array(%i[provisioned instance cloud_instance_id])
    end

    it "returns an instance id that names a real row, in the state that row is actually in" do
      r = provision

      row = ::System::NodeInstance.find_by(id: r[:data][:instance][:id])
      expect(row).not_to be_nil, "the returned instance id resolves to no NodeInstance row"
      expect(r[:data][:instance][:status]).to eq(row.reload.status)
      expect(r[:data][:cloud_instance_id]).to eq(row.cloud_instance_id)
    end

    it "creates no System::Task — there is nothing for the caller to poll" do
      expect { provision }.not_to change(::System::Task, :count)
    end
  end

  describe "the failure payload" do
    # The failure arm is the one the corrected description warns about: the
    # call has ALREADY failed on return, and ProvisioningService has left a
    # row behind in :error that may still own a billable cloud resource. A
    # caller that gets only a message cannot find it.
    before { allow(adapter).to receive(:create_instance).and_return(success: false, error: "quota exceeded") }

    it "reports the provider's error" do
      r = provision

      expect(r[:success]).to be false
      expect(r[:error]).to include("quota exceeded")
    end

    it "hands back the errored row's id and state so the caller can follow it" do
      r = provision

      row = last_row
      expect(row).not_to be_nil
      expect(r.dig(:data, :instance)).to be_a(Hash),
                                         "the failure payload carries no instance — the errored row is unreachable"
      expect(r.dig(:data, :instance, :id)).to eq(row.id)
      expect(r.dig(:data, :instance, :status)).to eq(row.reload.status)
      expect(row.status).to eq("error")
    end

    # The dig path a caller already uses on the success arm. ProvisionClusterExecutor
    # reads dig(:data, :instance, :id) and previously had nothing to read here.
    it "puts the instance on the SAME path as the success arm, with cloud_instance_id beside it" do
      r = provision

      expect(r[:data].keys).to match_array(%i[instance cloud_instance_id])
      expect(r.dig(:data, :cloud_instance_id)).to eq(last_row.cloud_instance_id)
    end

    it "creates no System::Task on the failure path either" do
      expect { provision }.not_to change(::System::Task, :count)
    end

    # A pre-row failure (bad region, quota guard, unsupported provider) has no
    # instance to hand back. The payload must not fabricate one.
    it "omits the instance when the call failed before any row was created" do
      allow(adapter).to receive(:supports?).with(:instances).and_return(false)

      r = nil
      expect { r = provision }.not_to change(::System::NodeInstance, :count)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/does not support instance/i),
                           "failed for some reason other than the pre-create capability gate"
      expect(r).not_to have_key(:data)
    end
  end

  # The arm the corrected description actually tells an agent to act on: the
  # provider RAISED after the row (and possibly the cloud VM) already existed,
  # so the row can be stranded holding a live billable resource.
  # terminate_orphaned_cloud_instance is best-effort and swallows its own
  # failures, so cloud_instance_id on this arm is the operator's only handle.
  describe "the failure payload when the provider raises after the row exists" do
    before do
      allow(adapter).to receive(:create_instance)
        .and_raise(::System::Providers::BaseProvider::ProviderError, "cloud exploded mid-create")
    end

    it "still returns the row on the success arm's dig path, so the strand is recoverable" do
      r = provision

      row = last_row
      expect(r[:success]).to be false
      expect(r[:error]).to include("cloud exploded mid-create")
      expect(r.dig(:data, :instance, :id)).to eq(row.id)
      expect(r.dig(:data, :instance, :status)).to eq(row.reload.status)
      expect(r[:data]).to have_key(:cloud_instance_id)
    end
  end
end
