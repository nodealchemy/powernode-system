# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc-M — System::FulfillmentRequestSweepService: the tick that
# (a) advances open requests forward via the orchestrator (resuming ones parked
# at the build barrier / approved out-of-band) and (b) reaps task-scoped leases at
# expiry. Mirrors spec/services/system/ci_runner_lease_sweep_service coverage
# shape (advance + reap in one run).
RSpec.describe System::FulfillmentRequestSweepService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let!(:region)  { create(:system_provider_region, account: account, enabled: true) }
  let!(:itype)   { create(:system_provider_instance_type, account: account) }
  let!(:base_os) do
    create(:system_node_module, account: account, node_platform: platform, category: category,
           name: System::Ai::Skills::FulfillCapabilityRequestExecutor::DEFAULT_BASE_OS_MODULE_NAME)
  end

  def running_instance
    template = create(:system_node_template, account: account, node_platform: platform)
    node = create(:system_node, account: account, node_template: template)
    create(:system_node_instance, :running, node: node)
  end

  def composed(**attrs)
    ::System::FulfillmentRequest.create_composed!(
      account: account, request: "give me memcached",
      plan: { "execution" => { "count" => 1, "base_os_module_id" => base_os.id,
                               "base_os_module_name" => base_os.name, "reused_modules" => [],
                               "gaps" => [], "provider_region_id" => nil,
                               "provider_instance_type_id" => nil, "platform_id" => platform.id,
                               "template_name" => "fulfill-x-#{SecureRandom.hex(2)}" } },
      cost_estimate: {}, reused_modules: [], lease_ttl_seconds: 3600, **attrs
    )
  end

  describe "#advance_open! (drives open records via the orchestrator)" do
    it "advances an approved (no-gap, all-reused) request toward completion" do
      # An all-reused request (no gaps) has no build barrier — it authors a
      # template + provisions. With no region/type in the frozen plan, provision
      # parks and the run reaches `ready` with a park note (env-limited, honest).
      fr = composed
      fr.approve!

      summary = described_class.run!(account: account)

      expect(summary[:advanced]).to be >= 1
      fr.reload
      expect(fr).to be_ready
      expect(fr.parked.map { |p| p["step"] }).to include("provision")
    end

    it "does NOT touch composed (unapproved) requests" do
      fr = composed # stays composed
      described_class.run!(account: account)
      expect(fr.reload).to be_composed
    end
  end

  describe "#reap_expired! (task-scoped lease reaper)" do
    it "terminates a ready run's instances and expires it once past expires_at" do
      inst = running_instance
      fr = composed
      %i[approve! start_materializing! mark_templated! start_provisioning! start_smoking! mark_ready!]
        .each { |e| fr.public_send(e) }
      fr.record_instances!([ inst.id ])
      fr.update!(expires_at: 1.minute.ago)

      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(instance_double("Result", success?: true))

      summary = described_class.run!(account: account)

      expect(::System::ProvisioningService).to have_received(:terminate_instance).with(instance: inst)
      expect(summary[:requests_expired]).to eq(1)
      expect(fr.reload).to be_expired
    end

    it "terminates a stray task_scoped instance past its own lease_expires_at (backstop)" do
      inst = running_instance
      inst.update!(lifecycle_class: "task_scoped", lease_expires_at: 1.minute.ago)
      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(instance_double("Result", success?: true))

      described_class.run!(account: account)

      expect(::System::ProvisioningService).to have_received(:terminate_instance).with(instance: inst)
    end

    it "leaves a task_scoped instance whose lease has NOT elapsed alone" do
      inst = running_instance
      inst.update!(lifecycle_class: "task_scoped", lease_expires_at: 1.hour.from_now)
      allow(::System::ProvisioningService).to receive(:terminate_instance)

      described_class.run!(account: account)

      expect(::System::ProvisioningService).not_to have_received(:terminate_instance)
    end
  end
end
