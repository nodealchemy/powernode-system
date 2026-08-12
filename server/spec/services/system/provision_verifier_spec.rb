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

  # INC-4: the mirror image, for scale-in. A removal's victims are asserted
  # ABSENT — and the assertion has to reach the provider for the same reason
  # the presence one does. A DB row that says "terminated" over a guest the
  # hypervisor is still running is the F2 phantom inverted: nothing in the
  # platform can see it, and it bills forever.
  describe ".reconcile_absent_instances" do
    def reconcile_absent(instance_id)
      described_class.reconcile_absent_instances(
        account: account, expectations: [ { node_instance_id: instance_id } ]
      ).first
    end

    it "confirms an instance the provider no longer has" do
      instance = make_instance(cloud_instance_id: "dna/qemu/9200", status: "terminated")
      stub_adapter(success: false, error_code: "NotFound", error: "not found")

      r = reconcile_absent(instance.id)
      expect(r[:ok]).to be true
      expect(r[:detail]).to match(/no record|gone/i)
    end

    it "FAILS a terminated row whose guest the provider still reports running" do
      instance = make_instance(cloud_instance_id: "dna/qemu/9201", status: "terminated")
      stub_adapter(success: true, status: "running")

      r = reconcile_absent(instance.id)
      expect(r[:ok]).to be false
      expect(r[:detail]).to match(/still/i)
    end

    it "FAILS a terminated row whose guest the provider still reports STOPPED" do
      instance = make_instance(cloud_instance_id: "dna/qemu/9204", status: "terminated")
      # A stopped guest still exists, still holds its disks, and on most
      # providers still bills. "Not running" is not "gone" — PVE normalizes
      # paused/suspended to stopped and shutdown to stopping, so treating
      # anything-but-running as removed certifies the exact survivor this
      # check was added to catch (a qm destroy that failed after shutdown).
      stub_adapter(success: true, status: "stopped")

      r = reconcile_absent(instance.id)
      expect(r[:ok]).to be false
      expect(r[:detail]).to match(/stopped/)
    end

    it "confirms a guest the provider reports terminated" do
      instance = make_instance(cloud_instance_id: "dna/qemu/9205", status: "terminated")
      stub_adapter(success: true, status: "terminated")

      r = reconcile_absent(instance.id)
      expect(r[:ok]).to be true
    end

    it "FAILS an unknown or blank provider status rather than reading it as gone" do
      instance = make_instance(cloud_instance_id: "dna/qemu/9206", status: "terminated")
      stub_adapter(success: true, status: nil)

      r = reconcile_absent(instance.id)
      expect(r[:ok]).to be false
    end

    it "accepts a message-only not-found, as the platform's own detection does" do
      instance = make_instance(cloud_instance_id: "dna/qemu/9207", status: "terminated")
      # Several adapters report not-found without an error_code; matching only
      # the code fails a correctly-completed removal on those providers.
      stub_adapter(success: false, error: "VM 9207 not found")

      r = reconcile_absent(instance.id)
      expect(r[:ok]).to be true
    end

    it "does not certify another account's instance as removed" do
      foreign = create(:account)
      foreign_node = create(:system_node, account: foreign)
      instance = create(:system_node_instance, node: foreign_node, provider_region: region,
                                               status: "running", cloud_instance_id: "dna/qemu/9208")

      r = reconcile_absent(instance.id)
      expect(r[:ok]).to be false
    end

    it "FAILS a row the platform never marked terminated" do
      instance = make_instance(cloud_instance_id: "dna/qemu/9202", status: "running")
      stub_adapter(success: false, error_code: "NotFound", error: "not found")

      r = reconcile_absent(instance.id)
      expect(r[:ok]).to be false
      expect(r[:detail]).to match(/status=running/)
    end

    it "does not certify a row it cannot find at all" do
      # terminate_instance transitions the row, it never destroys it — so a
      # genuinely removed victim always HAS a row, and "no row" means the id
      # was foreign, blank, or hand-destroyed. Blessing it would let a
      # removal certify itself with no provider call at all.
      r = reconcile_absent(SecureRandom.uuid)
      expect(r[:ok]).to be false
      expect(r[:detail]).to match(/no NodeInstance row/i)
    end

    it "fails CLOSED when the provider cannot be reached" do
      instance = make_instance(cloud_instance_id: "dna/qemu/9203", status: "terminated")
      stub_adapter { raise StandardError, "connect timeout" }

      r = reconcile_absent(instance.id)
      expect(r[:ok]).to be false
      expect(r[:detail]).to match(/timeout|provider check failed/i)
    end
  end
end
