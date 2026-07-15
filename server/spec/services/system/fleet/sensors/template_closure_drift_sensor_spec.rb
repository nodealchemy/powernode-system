# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 §2.4.3 — ModuleDriftSensor only diffs a RUNNING
# instance's reported digests against its ALREADY-ASSIGNED modules; it
# never re-resolves the template, so a template mutation after
# provisioning (a new TemplateModule / `requires` edge) never reaches an
# already-provisioned instance. TemplateClosureDriftSensor closes that gap.
RSpec.describe System::Fleet::Sensors::TemplateClosureDriftSensor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:module_a) { create(:system_node_module, account: account, name: "already-assigned-#{SecureRandom.hex(3)}") }
  let(:module_b) { create(:system_node_module, account: account, name: "newly-required-#{SecureRandom.hex(3)}") }

  let(:sensor) { described_class.new(account: account) }

  # module_a is already on the template AND already assigned to the node —
  # the steady state every already-provisioned instance starts from.
  before do
    create(:system_template_module, node_template: template, node_module: module_a)
    create(:system_node_module_assignment, node: node, node_module: module_a)
  end

  def payload_value(signal, key)
    signal.payload[key.to_s]
  end

  it "does not signal when assignments already match the template's current closure" do
    create(:system_node_instance, :running, node: node)

    expect(sensor.sense).to be_empty
  end

  it "detects closure drift when the template gains a module (a new TemplateModule / requires edge)" do
    instance = create(:system_node_instance, :running, node: node)
    create(:system_template_module, node_template: template, node_module: module_b)

    signals = sensor.sense

    expect(signals.size).to eq(1)
    signal = signals.first
    expect(signal.kind).to eq("system.template_closure_drift")
    expect(payload_value(signal, :instance_id)).to eq(instance.id)
    expect(payload_value(signal, :node_id)).to eq(node.id)
    expect(payload_value(signal, :template_id)).to eq(template.id)
    expect(payload_value(signal, :missing_module_ids)).to contain_exactly(module_b.id)
    expect(payload_value(signal, :missing_count)).to eq(1)
    expect(signal.fingerprint).to eq("template_closure_drift:#{instance.id}")
  end

  it "carries TemplateApprovalPolicy's classification — always blast-radius > 0 once an instance exists" do
    create(:system_node_instance, :running, node: node)
    create(:system_template_module, node_template: template, node_module: module_b)

    signal = sensor.sense.first
    expect(payload_value(signal, :requires_approval)).to be true
    expect(payload_value(signal, :blast_radius_reason)).to match(/propagates to live fleet/)
  end

  it "flags pivot_boot: true for a direct_kernel instance (composed union is boot-time-fixed)" do
    template.update!(config: { "boot_mode" => "direct_kernel" })
    create(:system_node_instance, :running, node: node)
    create(:system_template_module, node_template: template, node_module: module_b)

    signal = sensor.sense.first
    expect(payload_value(signal, :pivot_boot)).to be true
  end

  it "flags pivot_boot: true for a uefi_disk instance" do
    template.update!(config: { "boot_mode" => "uefi_disk" })
    create(:system_node_instance, :running, node: node)
    create(:system_template_module, node_template: template, node_module: module_b)

    signal = sensor.sense.first
    expect(payload_value(signal, :pivot_boot)).to be true
  end

  it "flags pivot_boot: false for a cloud_init (default boot_mode) instance" do
    create(:system_node_instance, :running, node: node)
    create(:system_template_module, node_template: template, node_module: module_b)

    signal = sensor.sense.first
    expect(payload_value(signal, :pivot_boot)).to be false
  end

  it "is registered in FleetAutonomyService::SENSORS" do
    expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
  end
end
