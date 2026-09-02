# frozen_string_literal: true

# IMP-ca485128072e (APO-2e) — operator-settable fleet sensor thresholds.
#
# Every fleet sensor read its thresholds from class constants, and the APO-2b
# sensor had layered ENV overrides on top of them. Neither is operator
# configuration: a constant needs a redeploy, and an ENV var needs a redeploy
# AND a systemd unit edit on every node running the reconciler — while
# docs/FLEET_SENSORS.md had documented a `Fleet::SensorConfig` row for these
# values long before any such table existed.
#
# One row per [account, sensor]; `config` holds only the keys the operator has
# actually overridden, so a sensor whose constant later changes moves for every
# account that never tuned it. Resolution (System::Fleet::Sensors::BaseSensor)
# merges this over the class constants and falls back to the constant for any
# key that is absent or unusable.
class CreateSystemFleetSensorConfigs < ActiveRecord::Migration[8.0]
  def change
    create_table :system_fleet_sensor_configs, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :account_id, null: false
      # The sensor's key, not its class name: BaseSensor.sensor_key demodulizes
      # and drops the "_sensor" suffix (InstanceStatusSensor -> instance_status),
      # which is the name the docs and the MCP verbs already use.
      t.string :sensor, null: false
      t.jsonb :config, null: false, default: {}

      t.timestamps
    end

    # Upsert key. Unique so a double write cannot leave two rows disagreeing
    # about one sensor's thresholds — the resolver reads exactly one.
    add_index :system_fleet_sensor_configs, %i[account_id sensor], unique: true,
              name: "idx_fleet_sensor_configs_on_account_and_sensor"
  end
end
