# frozen_string_literal: true

# Increment 21 follow-up (campaign 019f3458) — option A2: `unit_body`
# lets a manifest's `services:` entry carry a verbatim systemd unit
# body instead of the generated Service/ExecStart/Restart fields. This
# is how dev-cell and claude-tmux (the only 2 modules still on the
# legacy `init:` + raw file_spec unit carve-out) move onto the blessed
# services: write/enable/detach lifecycle without losing their
# hand-tuned Type=oneshot/RemainAfterExit/RestartSec/StartLimit*/
# ExecStartPre semantics that the structured Service fields can't
# express. See System::ModuleService's exactly-one-of validation.
class AddUnitBodyToSystemModuleServices < ActiveRecord::Migration[8.1]
  def change
    add_column :system_module_services, :unit_body, :text
    change_column_null :system_module_services, :start_command, true
  end
end
