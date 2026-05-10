# frozen_string_literal: true

# Adds the `network_profile` column to `system_node_instances`. This is the
# host-side dial that picks which BridgeApplier (and, downstream in O3+,
# which CNI) the on-node agent runs:
#
#   * `lightweight` (default, safe everywhere) — Linux bridge applier, no
#     OVS/OVN daemons. Fits Pi 4 ≤4GB / Pi Zero 2W / Alpine aarch64 hosts
#     where the ~150–200MB RAM cost of OVS+OVN is prohibitive.
#   * `heavyweight` — OVS bridge applier (Phase O2) + OVN-controller +
#     OVN-K8s CNI (Phase O3+). Targeted at x86_64 ≥4GB / Pi 5 / Pi 4 8GB
#     hosts with the headroom for three additional daemons.
#
# Operator-explicit selection always wins. When an operator does NOT
# choose, `System::NodeInstance#suggest_network_profile` returns the
# recommended value from the host's hardware fields (architecture +
# provider_instance_type.memory_mb + config hardware-model hints) so the
# autonomy fleet / provisioning service can act on the recommendation.
#
# Default is `lightweight` because:
#   1. It works on every supported host (no hardware floor risk).
#   2. It matches the existing fleet behaviour from Phase O1 (Linux bridge
#      via Sdwan::HostBridge with `kind: "linux"`).
#   3. Promoting a host to `heavyweight` is a deliberate operator (or
#      autonomy-policy) decision — never auto-applied at row-creation time.
#
# Phase O2 of the OVS+OVN dual-profile roadmap (heavyweight track —
# server-side foundation).
class AddNetworkProfileToSystemNodeInstances < ActiveRecord::Migration[8.1]
  CONSTRAINT_NAME = "system_node_instances_network_profile_check"
  ALLOWED_PROFILES = %w[lightweight heavyweight].freeze

  def up
    add_column :system_node_instances,
               :network_profile, :string,
               null: false, default: "lightweight",
               comment: "OVS+OVN dual-profile selector — see " \
                        "System::NodeInstance::NETWORK_PROFILES"

    # Read-side filter for FleetAutonomyService / dashboards. Index is
    # tiny (two distinct values fleet-wide) but the equality scan is hot
    # on the autonomy reconcile path.
    add_index :system_node_instances, :network_profile,
              name: "index_system_node_instances_on_network_profile"

    add_check_constraint :system_node_instances,
      "network_profile IN (#{ALLOWED_PROFILES.map { |p| "'#{p}'" }.join(', ')})",
      name: CONSTRAINT_NAME
  end

  def down
    remove_check_constraint :system_node_instances, name: CONSTRAINT_NAME
    remove_index :system_node_instances, name: "index_system_node_instances_on_network_profile"
    remove_column :system_node_instances, :network_profile
  end
end
