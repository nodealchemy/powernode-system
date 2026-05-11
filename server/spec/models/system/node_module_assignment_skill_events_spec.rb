# frozen_string_literal: true

require "rails_helper"

# Covers the FleetEvent emission path added to NodeModuleAssignment's
# register/unregister callbacks. Before 2026-05-11 these rescues
# silently logged a warning; operators had no dashboard visibility
# into skill-registrar failures. The new emit_skill_event_failure!
# helper produces a system.module_skill_registration_failed FleetEvent
# in addition to the log line.
RSpec.describe System::NodeModuleAssignment, "skill registration failure events" do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:node) { create(:system_node, account: account) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "evt-spec-mod-#{SecureRandom.hex(3)}")
  end

  describe "register failure" do
    before do
      allow(::System::ModuleSkillRegistrar).to receive(:register_for_module!)
        .and_raise(StandardError, "boom: kaboom registrar")
    end

    it "logs a warning and emits a FleetEvent with operation=register" do
      expect(Rails.logger).to receive(:warn).with(/skill register failed: boom: kaboom/)
      expect(::System::Fleet::EventBroadcaster).to receive(:emit!).with(
        hash_including(
          account: account,
          kind: "system.module_skill_registration_failed",
          severity: :medium,
          source: "node_module_assignment"
        )
      ).and_call_original

      create(:system_node_module_assignment, node: node, node_module: node_module, enabled: true)
    end

    it "carries operation, node_module_id, node_id, error_class, error_message in payload" do
      assignment = create(:system_node_module_assignment, node: node, node_module: node_module,
                          enabled: true)
      event = ::System::FleetEvent.where(account: account,
                                         kind: "system.module_skill_registration_failed").last
      expect(event).not_to be_nil
      expect(event.payload["operation"]).to eq("register")
      expect(event.payload["node_module_id"]).to eq(node_module.id)
      expect(event.payload["node_id"]).to eq(node.id)
      expect(event.payload["assignment_id"]).to eq(assignment.id)
      expect(event.payload["error_class"]).to eq("StandardError")
      expect(event.payload["error_message"]).to match(/boom: kaboom/)
    end

    it "does not raise — the assignment is still created when registrar fails" do
      expect {
        create(:system_node_module_assignment, node: node, node_module: node_module, enabled: true)
      }.not_to raise_error
    end
  end

  describe "unregister failure" do
    let!(:assignment) do
      # Create with a working stub so the on-create event doesn't fire.
      allow(::System::ModuleSkillRegistrar).to receive(:register_for_module!).and_return(true)
      create(:system_node_module_assignment, node: node, node_module: node_module, enabled: true)
    end

    it "logs a warning and emits a FleetEvent with operation=unregister on the last destroy" do
      allow(::System::ModuleSkillRegistrar).to receive(:unregister_for_module!)
        .and_raise(StandardError, "unreg explode")

      expect(Rails.logger).to receive(:warn).with(/skill unregister failed: unreg explode/)
      expect(::System::Fleet::EventBroadcaster).to receive(:emit!).with(
        hash_including(
          kind: "system.module_skill_registration_failed",
          source: "node_module_assignment"
        )
      ).and_call_original

      assignment.destroy
    end
  end
end
