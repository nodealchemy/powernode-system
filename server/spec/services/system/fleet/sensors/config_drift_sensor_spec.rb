# frozen_string_literal: true

require "rails_helper"

# Audit F3-09 — ConfigDriftSensor's payload carried node_id/module_id/
# assignment_id but no instance reference, while the decision engine's
# config_drift binding and reconcile-task dispatch resolve the remediation
# target from the payload's instance ids. Every config-drift skill
# invocation ran with instance_id: nil and failed.
RSpec.describe System::Fleet::Sensors::ConfigDriftSensor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let!(:running_instance) { create(:system_node_instance, :running, node: node) }

  let(:sensor) { described_class.new(account: account) }

  # The sensor's staleness window is 5 minutes from the assignment's
  # updated_at — update_columns avoids touching the timestamp back to now.
  def stale_assignment!
    create(:system_node_module_assignment, node: node).tap do |a|
      a.update_columns(updated_at: 10.minutes.ago)
    end
  end

  it "emits config_drift carrying the node's running instance ids" do
    assignment = stale_assignment!

    signals = sensor.sense

    expect(signals.size).to eq(1)
    signal = signals.first
    expect(signal.kind).to eq("system.config_drift")
    expect(signal.payload["assignment_id"]).to eq(assignment.id)
    expect(signal.payload["instance_ids"]).to eq([ running_instance.id ])
  end

  it "excludes non-running instances from the payload" do
    create(:system_node_instance, node: node, status: "stopped")
    stale_assignment!

    expect(sensor.sense.first.payload["instance_ids"]).to eq([ running_instance.id ])
  end
end
