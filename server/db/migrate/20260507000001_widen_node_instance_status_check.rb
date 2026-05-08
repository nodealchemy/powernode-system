# frozen_string_literal: true

# `System::NodeInstance::STATUSES` (model) has always advertised the full
# AASM state vocabulary including the transient `starting`, `stopping`,
# and `rebooting` states the state machine traverses. The original
# check constraint on `system_node_instances.status`
# (`20251215200001_create_powernode_system_node_core.rb`) only allowed the
# steady-state values, so `start!`/`stop!`/`reboot!` event transitions
# raised `PG::CheckViolation` despite the model's own validation passing.
#
# This widens the constraint to match the model's allow-list so the AASM
# transitions actually persist.
class WidenNodeInstanceStatusCheck < ActiveRecord::Migration[8.0]
  CONSTRAINT_NAME = "system_node_instances_status_check"

  ALLOWED_STATUSES = %w[
    pending
    provisioning
    starting
    running
    stopping
    stopped
    rebooting
    terminated
    error
  ].freeze

  ORIGINAL_STATUSES = %w[
    pending
    provisioning
    running
    stopped
    terminated
    error
  ].freeze

  def up
    remove_check_constraint :system_node_instances, name: CONSTRAINT_NAME
    add_check_constraint :system_node_instances,
      "status IN (#{ALLOWED_STATUSES.map { |s| "'#{s}'" }.join(', ')})",
      name: CONSTRAINT_NAME
  end

  def down
    remove_check_constraint :system_node_instances, name: CONSTRAINT_NAME
    add_check_constraint :system_node_instances,
      "status IN (#{ORIGINAL_STATUSES.map { |s| "'#{s}'" }.join(', ')})",
      name: CONSTRAINT_NAME
  end
end
