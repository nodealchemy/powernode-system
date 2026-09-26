# frozen_string_literal: true

# IMP-caef5c00d63f — records that a service row's `capabilities` was written
# by the presence-preserving manifest import (IMP-074fcd68284f), where a
# stored `[]` is a real "grant nothing" and NULL is "inherit the ceiling".
# A row written before that import holds `[]` for "never declared" as well,
# so its `[]` carries no intent.
#
# The node-api serializer emits a module-level service_capabilities_presence
# marker only when EVERY service row of the module has this flag; the agent
# honours an explicit [] as zero only under that marker. Existing rows start
# false (unknown provenance) and flip to true on the module's next import, so
# an un-republished module keeps today's module-level behaviour.
class AddCapabilitiesPresenceRecordedToSystemModuleServices < ActiveRecord::Migration[8.1]
  def change
    add_column :system_module_services, :capabilities_presence_recorded, :boolean, null: false, default: false
  end
end
