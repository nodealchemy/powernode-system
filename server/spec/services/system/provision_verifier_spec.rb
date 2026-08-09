# frozen_string_literal: true

require "rails_helper"

# The live half of F2 (IMP 019fe4c4-c7c4): core's VerificationService hands a
# list of {node_instance_id, provider_region_id} expectations to the
# `provision_verifier` registry seam; this reconciler answers from the ROW and
# the LIVE PROVIDER, fail-closed:
#   - missing row / missing provider identity (the phantom shape) → not ok
#   - region mismatch (silent misplacement) → not ok
#   - provider has no record, reports non-running, or cannot be reached → not ok
#   - physical instances have no provider to ask — DB status only, annotated
RSpec.describe System::ProvisionVerifier do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:region) { create(:system_provider_region, account: account) }

  def make_instance(**attrs)
    create(:system_node_instance, { node: node, provider_region: region, status: "running" }.merge(attrs))
  end

  def reconcile_one(instance_id, region_id: region.id)
    described_class.reconcile_instances(
      account: account,
      expectations: [ { node_instance_id: instance_id, provider_region_id: region_id } ]
    ).first
  end

  def stub_adapter(result = nil, &blk)
    adapter = double("adapter")
    if blk
      allow(adapter).to receive(:get_instance, &blk)
    else
      allow(adapter).to receive(:get_instance).and_return(result)
    end
    allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter)
    adapter
  end

  it "confirms a running instance the provider agrees exists" do
    instance = make_instance(cloud_instance_id: "dna/qemu/9100")
    stub_adapter(success: true, status: "running")

    r = reconcile_one(instance.id)
    expect(r[:ok]).to be true
    expect(r[:detail]).to match(/running/)
  end

  it "fails a missing row" do
    r = reconcile_one(SecureRandom.uuid)
    expect(r[:ok]).to be false
    expect(r[:detail]).to match(/no NodeInstance/i)
  end

  it "fails the phantom shape: cloud instance without provider identity" do
    instance = make_instance(provider_identity: false, status: "error")
    r = reconcile_one(instance.id)
    expect(r[:ok]).to be false
    expect(r[:detail]).to match(/identity|cloud_instance_id/i)
  end

  it "fails when the provider has no record of the instance" do
    instance = make_instance(cloud_instance_id: "dna/qemu/9101")
    stub_adapter(success: false, error_code: "NotFound", error: "not found")

    r = reconcile_one(instance.id)
    expect(r[:ok]).to be false
    expect(r[:detail]).to match(/no record/i)
  end

  it "fails when the provider reports a non-running state" do
    instance = make_instance(cloud_instance_id: "dna/qemu/9102")
    stub_adapter(success: true, status: "stopped")

    r = reconcile_one(instance.id)
    expect(r[:ok]).to be false
    expect(r[:detail]).to match(/stopped/)
  end

  it "fails CLOSED when the provider cannot be reached" do
    instance = make_instance(cloud_instance_id: "dna/qemu/9103")
    stub_adapter { raise StandardError, "connect timeout" }

    r = reconcile_one(instance.id)
    expect(r[:ok]).to be false
    expect(r[:detail]).to match(/timeout|provider check failed/i)
  end

  it "fails a region mismatch — placement the operator never approved" do
    other_region = create(:system_provider_region, account: account)
    instance = make_instance(cloud_instance_id: "dna/qemu/9104")
    stub_adapter(success: true, status: "running")

    r = reconcile_one(instance.id, region_id: other_region.id)
    expect(r[:ok]).to be false
    expect(r[:detail]).to match(/region/i)
  end

  it "does not consider another account's instance" do
    foreign = create(:account)
    foreign_node = create(:system_node, account: foreign)
    instance = create(:system_node_instance, node: foreign_node, provider_region: region,
                                             status: "running", cloud_instance_id: "dna/qemu/9105")
    r = reconcile_one(instance.id)
    expect(r[:ok]).to be false
    expect(r[:detail]).to match(/no NodeInstance/i)
  end

  it "verifies a physical instance from the row alone, and says so" do
    instance = make_instance(variety: "physical", cloud_instance_id: nil)
    r = reconcile_one(instance.id)
    expect(r[:ok]).to be true
    expect(r[:detail]).to match(/physical|db-only/i)
  end
end
