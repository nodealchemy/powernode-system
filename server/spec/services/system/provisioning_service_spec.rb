# frozen_string_literal: true

require "rails_helper"

# Phase-0 hardening specs for the provision happy-path's failure + retry
# semantics. The provider adapter is stubbed so we exercise ProvisioningService's
# own state-management (no real cloud calls).
RSpec.describe System::ProvisioningService do
  let(:account)       { create(:account) }
  let(:node)          { create(:system_node, account: account) }
  let(:region)        { create(:system_provider_region) }
  let(:instance_type) { create(:system_provider_instance_type) }
  let(:adapter)       { instance_double("System::Providers::BaseProvider", provider_type: "mock", supports?: true) }

  before do
    allow(System::Providers::Registry).to receive(:for_node).and_return(adapter)
  end

  def provision(operation_id: nil)
    described_class.provision_instance(
      node: node,
      provider_region_id: region.id,
      provider_instance_type_id: instance_type.id,
      operation_id: operation_id
    )
  end

  # Audit F4-06 — capability gate: refuse before creating the NodeInstance
  # row when the adapter has no instance surface.
  describe "capability gate" do
    it "returns a structured error without creating an instance row when unsupported" do
      allow(adapter).to receive(:supports?).with(:instances).and_return(false)

      result = nil
      expect { result = provision }.not_to change(System::NodeInstance, :count)

      expect(result.success?).to be(false)
      expect(result.error).to match(/does not support instance/i)
    end
  end

  describe "failure recovery — no orphaned :pending instances" do
    it "transitions the instance to :error when the provider raises a ProviderError" do
      allow(adapter).to receive(:create_instance)
        .and_raise(System::Providers::BaseProvider::ProviderError, "cloud exploded")

      result = provision

      expect(result.success?).to be(false)
      expect(System::NodeInstance.where(node: node, status: "pending")).to be_empty
      instance = System::NodeInstance.where(node: node).order(:created_at).last
      expect(instance).not_to be_nil
      expect(instance.status).to eq("error")
    end

    it "transitions the instance to :error on an unexpected StandardError" do
      allow(adapter).to receive(:create_instance).and_raise(StandardError, "kaboom")

      provision

      expect(System::NodeInstance.where(node: node, status: "pending")).to be_empty
      expect(System::NodeInstance.where(node: node).order(:created_at).last.status).to eq("error")
    end

    it "transitions the instance to :error when the provider reports success: false" do
      allow(adapter).to receive(:create_instance).and_return(success: false, error: "quota exceeded")

      result = provision

      expect(result.success?).to be(false)
      expect(System::NodeInstance.where(node: node, status: "pending")).to be_empty
      expect(System::NodeInstance.where(node: node).order(:created_at).last.status).to eq("error")
    end
  end

  describe "idempotency — repeated operation_id does not duplicate" do
    before do
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: "i-123", status: "running")
    end

    it "reuses the existing instance for a repeated operation_id" do
      first  = provision(operation_id: "op-abc-123")
      second = provision(operation_id: "op-abc-123")

      expect(first.success?).to be(true)
      expect(second.success?).to be(true)
      expect(System::NodeInstance.where(node: node).count).to eq(1)
      expect(second.data[:instance].id).to eq(first.data[:instance].id)
    end

    it "creates distinct instances for distinct operation_ids" do
      provision(operation_id: "op-1")
      provision(operation_id: "op-2")

      expect(System::NodeInstance.where(node: node).count).to eq(2)
    end

    it "stamps the operation_id onto the instance config" do
      result = provision(operation_id: "op-xyz")
      expect(result.data[:instance].config["operation_id"]).to eq("op-xyz")
    end

    # F1-07: an errored instance keeps its operation_id; reusing it on retry
    # returns a dead instance (no cloud VM) that poisons fleet enrollment.
    it "does not reuse an errored instance — a retry provisions fresh" do
      allow(adapter).to receive(:create_instance)
        .and_return({ success: false, error: "quota exceeded" },
                    { success: true, cloud_instance_id: "i-456", status: "running" })

      first = provision(operation_id: "op-retry-1")
      expect(first.success?).to be(false)
      expect(first.data[:instance].status).to eq("error")

      second = provision(operation_id: "op-retry-1")

      expect(second.success?).to be(true)
      expect(second.data[:instance].id).not_to eq(first.data[:instance].id)
      expect(second.data[:instance].status).not_to eq("error")
    end
  end

  describe "fleet-event observability" do
    it "emits a system.instance_provisioned event on success" do
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: "i-1", status: "running")

      provision

      ev = System::FleetEvent.where(account: account, kind: "system.instance_provisioned").last
      expect(ev).not_to be_nil
      expect(ev.severity).to eq("low")
      expect(ev.node_instance_id).to be_present
      expect(ev.source).to eq("provisioning_service")
    end

    it "emits a system.instance_provision_failed event (severity high) when the provider raises" do
      allow(adapter).to receive(:create_instance)
        .and_raise(System::Providers::BaseProvider::ProviderError, "boom")

      provision

      ev = System::FleetEvent.where(account: account, kind: "system.instance_provision_failed").last
      expect(ev).not_to be_nil
      expect(ev.severity).to eq("high")
      expect(ev.payload["error"]).to eq("boom")
    end
  end

  # Audit finding F4-02: terminating a not-yet-up instance destroyed the
  # cloud resource but left the row wedged in a non-terminal status, and a
  # provider-side NotFound made retries error instead of finalizing.
  describe "#terminate_instance" do
    let(:instance) do
      create(:system_node_instance, node: node, status: "starting",
             config: { "cloud_instance_id" => "i-123" })
    end

    before do
      allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter)
    end

    def terminate
      described_class.terminate_instance(instance: instance)
    end

    it "terminates an instance still in :starting" do
      allow(adapter).to receive(:terminate_instance).with("i-123").and_return({ success: true })

      result = terminate

      expect(result.success?).to be(true)
      expect(instance.reload.status).to eq("terminated")
    end

    it "treats a provider NotFound result as already-terminated (idempotent retry)" do
      allow(adapter).to receive(:terminate_instance)
        .and_return({ success: false, error_code: "NotFound", error: "Instance not found" })

      result = terminate

      expect(result.success?).to be(true)
      expect(instance.reload.status).to eq("terminated")
    end

    it "treats a raised ResourceNotFoundError as already-terminated (idempotent retry)" do
      allow(adapter).to receive(:terminate_instance)
        .and_raise(System::Providers::BaseProvider::ResourceNotFoundError, "no such instance")

      result = terminate

      expect(result.success?).to be(true)
      expect(instance.reload.status).to eq("terminated")
    end

    it "warns and skips re-metering when the row is already terminated" do
      instance.update_columns(status: "terminated")
      allow(adapter).to receive(:terminate_instance).and_return({ success: true })
      allow(Rails.logger).to receive(:warn)
      expect_any_instance_of(described_class).not_to receive(:record_meter_event)

      result = terminate

      expect(result.success?).to be(true)
      expect(Rails.logger).to have_received(:warn).with(/already|cannot transition/i)
    end

    it "returns an error and leaves the status unchanged on non-NotFound provider failures" do
      allow(adapter).to receive(:terminate_instance)
        .and_return({ success: false, error: "rate limited" })

      result = terminate

      expect(result.success?).to be(false)
      expect(instance.reload.status).to eq("starting")
    end

    # F4-09 — codify the F4-02 fix across the full status matrix: terminate
    # must drive ANY non-terminal status to "terminated", not only the
    # steady-state ones. Pre-fix, a not-yet-up instance (pending/starting)
    # destroyed the cloud resource but left the row wedged.
    %w[running stopped error pending].each do |from_status|
      it "terminates an instance from :#{from_status}" do
        from = create(:system_node_instance, node: node, status: from_status,
                      config: { "cloud_instance_id" => "i-#{from_status}" })
        allow(adapter).to receive(:terminate_instance)
          .with("i-#{from_status}").and_return({ success: true })

        result = described_class.terminate_instance(instance: from)

        expect(result.success?).to be(true)
        expect(from.reload.status).to eq("terminated")
      end
    end
  end
end
