# frozen_string_literal: true

# IMP-c7d663f24a0b — service-level connectivity observability.
#
# Until now every SDWAN sensor answered "is the pipe up?" (drift,
# reachability, BGP health, VIP reachability, credential expiry) and none
# answered "is the thing at the end of the pipe serving?". Sdwan::Service
# carried no health column at all, so a published service could be dead for
# a day while every infra sensor read green.
#
# Two additive, reversible columns give SdwanServiceHealthSensor a durable
# read model:
#
#   last_observed_flow_at — the newest IPFIX FlowSample observed_at that
#                           correlated to this service's backend VIP+port.
#                           nil means "never observed" (which is NOT the
#                           same as "observed zero traffic" — the sensor
#                           refuses to infer silence when telemetry is not
#                           flowing at all).
#   health_state          — unknown | serving | silent. Defaults to
#                           "unknown" so existing rows carry an honest
#                           "no observation yet" rather than a fabricated
#                           healthy value.
#
# Live installs auto-apply migrations, so this stays purely additive: no
# backfill, no constraint that could reject a legacy row.
class AddHealthObservabilityToSdwanServices < ActiveRecord::Migration[8.0]
  def change
    add_column :system_sdwan_services, :last_observed_flow_at, :datetime
    add_column :system_sdwan_services, :health_state, :string,
               default: "unknown", null: false

    # The sensor sweeps active services per account and operators filter
    # dashboards by health_state; both ride this composite.
    add_index :system_sdwan_services, %i[account_id health_state],
              name: "index_system_sdwan_services_on_account_id_and_health_state"
  end
end
