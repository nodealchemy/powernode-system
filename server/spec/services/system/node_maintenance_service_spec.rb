# frozen_string_literal: true

require "rails_helper"

# Audit F5-08 — NodeMaintenanceService (exposed through worker_api and
# the internal nodes controller) had zero spec references. Pins the
# orchestration contract shared with InstanceMaintenanceService:
# allowlist filtering, per-task aggregation, and config persistence.
RSpec.describe System::NodeMaintenanceService do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:service)  { described_class.new }

  describe "#run_maintenance" do
    it "raises for a non-node argument (caller bug, not a Result)" do
      expect {
        described_class.run_maintenance(node: "not-a-node")
      }.to raise_error(ArgumentError, /must be a System::Node/)
    end

    it "refuses a disabled node" do
      node.update!(enabled: false)

      result = described_class.run_maintenance(node: node)

      expect(result.success?).to be false
      expect(result.error).to match(/disabled/i)
    end

    it "filters unknown task names against the MAINTENANCE_TASKS allowlist" do
      allow(service).to receive(:task_health_check).and_return({ success: true })

      result = service.run_maintenance(node: node, tasks: %w[health_check drop_tables])

      expect(result.success?).to be true
      expect(result.data[:results].keys).to eq(%w[health_check])
    end

    it "aggregates per-task failures without aborting remaining tasks and persists to node.config" do
      allow(service).to receive(:task_health_check).and_return({ success: false, error: "instance unreachable" })
      allow(service).to receive(:task_log_rotation).and_return({ success: true })

      result = service.run_maintenance(node: node, tasks: %w[health_check log_rotation])

      expect(result.success?).to be false
      expect(result.error).to match(/1 task\(s\) failed/)
      expect(result.data[:results]["log_rotation"][:success]).to be true

      record = node.reload.config["last_maintenance"]
      expect(record["tasks"]).to contain_exactly("health_check", "log_rotation")
      expect(record["success"]).to be false
    end

    it "converts a raising task into a recorded failure and still runs the rest" do
      allow(service).to receive(:task_health_check).and_raise(RuntimeError, "provider timeout")
      allow(service).to receive(:task_log_rotation).and_return({ success: true })

      result = nil
      expect {
        result = service.run_maintenance(node: node, tasks: %w[health_check log_rotation])
      }.not_to raise_error

      expect(result.success?).to be false
      expect(result.data[:results]["health_check"][:success]).to be false
      expect(result.data[:results]["health_check"][:error]).to match(/provider timeout/)
      expect(result.data[:results]["log_rotation"][:success]).to be true
    end
  end
end
