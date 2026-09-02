# frozen_string_literal: true

# IMP-249aa98969bd — System::Fleet::PromotionCriteria means to require that a
# module version has been RUNNING on enough instances for long enough, but the
# platform recorded no per-(instance, module) "started running this digest at"
# fact, so the criteria substituted `min(last_heartbeat_at)`. That measured how
# long ago the stalest qualifying instance was last HEARD FROM: a healthy fleet
# heartbeating normally kept the anchor fresh and could never clear dwell, while
# a fleet silent past DWELL_TIME (30 minutes — ten times
# InstanceStatusSensor::SILENT_THRESHOLD) cleared it on evidence the platform
# was concurrently treating as a fault.
#
# This column is that missing fact: { module_id => iso8601 } recording when the
# instance FIRST reported the digest it currently reports for that module, while
# running. Written by System::NodeInstance#record_heartbeat! alongside
# running_module_digests, whose keys it shadows for every module reported while
# status == 'running': an entry is stamped once, never overwritten while both the
# digest and the boot identity hold, re-stamped when either changes (a stamp
# carried across a reboot would count downtime as dwell), and dropped when the
# module stops being reported.
#
# Backfill is a documented APPROXIMATION, not a measurement: instances already
# reporting a digest are stamped with COALESCE(last_heartbeat_at, updated_at) —
# the earliest moment the platform can prove it knew about that instance's
# current report. It understates true dwell for a long-running instance (making
# the gate more conservative on the first pass, which is the safe direction) and
# self-corrects on the next digest change.
class AddModuleFirstSeenRunningAtToSystemNodeInstances < ActiveRecord::Migration[8.0]
  def up
    add_column :system_node_instances, :module_first_seen_running_at, :jsonb,
               default: {}, null: false

    execute(<<~SQL.squish)
      UPDATE system_node_instances
         SET module_first_seen_running_at = (
               SELECT jsonb_object_agg(
                        key,
                        to_jsonb(to_char(
                          COALESCE(last_heartbeat_at, updated_at) AT TIME ZONE 'UTC',
                          'YYYY-MM-DD"T"HH24:MI:SS"Z"'
                        ))
                      )
                 FROM jsonb_each_text(running_module_digests)
             )
       WHERE status = 'running'
         AND running_module_digests <> '{}'::jsonb
    SQL
  end

  def down
    remove_column :system_node_instances, :module_first_seen_running_at
  end
end
