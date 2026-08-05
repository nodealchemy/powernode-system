# frozen_string_literal: true

require "rails_helper"

# Confirms the system extension's engine initializer
# ("powernode_system.register_audit_actions", lib/powernode_system/engine.rb)
# actually ran at boot and registered System::LifecycleAuditable::AUDITED_ACTIONS
# into the core AuditActions seam (server/app/models/concerns/audit_actions.rb).
# AUDITED_ACTIONS is also the constant record_lifecycle_audit! builds its
# "system.node_instance.<event>" tokens from, so drift between emitter and
# registration is structurally impossible here — this spec is asserting the
# registration ran at all (a disabled/unloaded extension would leave it empty).
RSpec.describe "PowernodeSystem audit actions registration", type: :lib do
  it "registers System::LifecycleAuditable::AUDITED_ACTIONS under the \"system\" namespace" do
    # The engine registers LifecycleAuditable::AUDITED_ACTIONS +
    # InternalCaService::AUDITED_ACTIONS under one "system" namespace, so an
    # exact `eq` against just the first breaks whenever another emitter joins —
    # which is what happened when internal_ca landed. Assert INCLUSION of each
    # contributing set instead: that still fails loudly if the initializer never
    # ran (the stated purpose), without pinning the namespace to one emitter.
    registered = AuditActions.extension_actions["system"]
    expect(registered).to include(*System::LifecycleAuditable::AUDITED_ACTIONS)
    expect(registered).to include(*System::InternalCaService::AUDITED_ACTIONS)
  end

  it "makes every audited lifecycle action valid on the dynamic union" do
    System::LifecycleAuditable::AUDITED_ACTIONS.each do |action|
      expect(AuditActions.valid_action?(action)).to be(true), "expected #{action} to be a valid audit action"
    end
  end
end
