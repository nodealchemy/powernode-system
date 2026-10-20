# frozen_string_literal: true

# System extension associations for the core Account model.
# Loaded by the PowernodeSystem engine via config.to_prepare decorator loading.
#
# Mirrors the platform decorator pattern (see extensions/trading/server/app/
# decorators/models/account_decorator.rb): the System extension owns its
# namespaced models, but exposes them on the core Account via the
# `account.system_<plural>` convention so controllers can scope queries
# naturally as `current_account.system_<plural>`.
#
# === dependent: :restrict_with_error ===
# Deliberately NOT :destroy. Account deletion would cascade-delete platform
# rows for NodeInstances, ProviderVolumes, etc. — but the matching cloud
# resources (the actual EC2 instance, the actual managed disk) would remain
# allocated in AWS/Azure/GCP and continue to bill. Refusing the cascade
# forces an explicit "drain" workflow: operator must terminate every active
# instance and delete every volume through the operation pipeline first.
Account.class_eval do
  # Operations + workers
  has_many :system_tasks, class_name: "System::Task", dependent: :restrict_with_error

  # Nodes and node-related catalog
  has_many :system_nodes, class_name: "System::Node", dependent: :restrict_with_error
  # NOTE: System::NodeArchitecture is a PLATFORM-WIDE catalog (a single canonical
  # "x86_64" row shared across every account) — it is deliberately NOT account-scoped
  # and has no account_id column, so Account intentionally does NOT own it. A stale
  # account association to it queried the nonexistent system_node_architectures.account_id
  # and crashed seeds/account teardown with PG::UndefinedColumn (improvement 019f65bd).
  has_many :system_node_platforms, class_name: "System::NodePlatform", dependent: :restrict_with_error
  has_many :system_node_templates, class_name: "System::NodeTemplate", dependent: :restrict_with_error

  # Disk-image publication flow (Phase 2 — Chunk 1, plan wondrous-yawning-anchor.md).
  # Both per-account scoped — each account owns its CI workers, webhook
  # secrets, and publication history independently.
  has_many :system_disk_image_publications,
           class_name: "System::DiskImagePublication",
           dependent: :destroy
  has_many :system_disk_image_webhooks,
           class_name: "System::DiskImageWebhook",
           dependent: :destroy
  has_many :system_node_scripts, class_name: "System::NodeScript", dependent: :restrict_with_error

  # Storage assignments (Phase S5 — operator-facing CRUD over file_storage ×
  # node_instance pairings). Controller scopes via `current_account.system_storage_assignments`;
  # without this declaration the index/show actions raise NoMethodError that
  # the global rescue_from masks as a generic 500. Caught by P0.1 wave 1
  # controller spec.
  has_many :system_storage_assignments,
           class_name: "System::StorageAssignment",
           dependent: :restrict_with_error

  # Modules
  has_many :system_node_modules, class_name: "System::NodeModule", dependent: :restrict_with_error
  has_many :system_node_module_categories, class_name: "System::NodeModuleCategory", dependent: :restrict_with_error

  # Physical-device claim queue (Path C provisioning, plan wondrous-yawning-anchor.md).
  # destroy_all is safe here — UnclaimedDevice rows are ephemeral (24h default TTL,
  # auto-reaped by ExpireUnclaimedDevicesJob) and carry no cloud-resource state.
  has_many :system_unclaimed_devices, class_name: "System::UnclaimedDevice", dependent: :destroy

  # Provider catalog
  has_many :system_providers, class_name: "System::Provider", dependent: :restrict_with_error
  has_many :system_provider_connections, class_name: "System::ProviderConnection", dependent: :restrict_with_error
  has_many :system_provider_regions, class_name: "System::ProviderRegion", dependent: :restrict_with_error
  has_many :system_provider_instance_types, class_name: "System::ProviderInstanceType", dependent: :restrict_with_error
  has_many :system_provider_networks, class_name: "System::ProviderNetwork", dependent: :restrict_with_error
  has_many :system_provider_volumes, class_name: "System::ProviderVolume", dependent: :restrict_with_error
  has_many :system_provider_volume_snapshots, class_name: "System::ProviderVolumeSnapshot", dependent: :restrict_with_error

  # Puppet
  has_many :system_puppet_modules, class_name: "System::PuppetModule", dependent: :restrict_with_error

  # GitOps reconciliation (M-D2-3, comprehensive stabilization sweep P5)
  has_many :system_gitops_repositories,
           class_name: "System::GitopsRepository",
           dependent: :destroy

  # NodeInstance-as-Agent peers (F-3, comprehensive stabilization sweep P6)
  # destroy_all is safe — peers are derived from node_instances; if the
  # account is being destroyed, all instances are too.
  has_many :system_node_instance_peers,
           class_name: "System::NodeInstancePeer",
           dependent: :destroy

  # Account teardown (Account#run_account_teardown): system-owned rows that carry
  # an account_id FK with no ON DELETE. The restrict_with_error associations
  # above are the "drain first" guard for rows that map to cloud resources (the
  # teardown refuses BEFORE any side effect while those exist); everything below
  # is control-plane metadata that goes with the account. delete_all is used
  # only for leaf log/sample tables with no callbacks and no inbound FKs.
  has_many :system_federation_audit_shipments, class_name: "System::FederationAuditShipment", dependent: :destroy
  has_many :system_federation_schema_compatibility, class_name: "System::FederationSchemaCompatibility", dependent: :destroy
  has_many :system_fleet_events, class_name: "System::FleetEvent", dependent: :delete_all
  has_many :system_fleet_remediation_outcomes, class_name: "System::Fleet::RemediationOutcome", dependent: :destroy
  has_many :system_migration_chains, class_name: "System::MigrationChain", dependent: :destroy
  has_many :system_node_assignment_clearances, class_name: "System::NodeAssignmentClearance", dependent: :destroy
  has_many :system_node_module_copy_paths, class_name: "System::NodeModuleCopyPath", dependent: :destroy
  has_many :system_package_repositories, class_name: "System::PackageRepository", dependent: :destroy
  has_many :system_peer_capability_revocations, class_name: "System::PeerCapabilityRevocation", dependent: :destroy
  has_many :system_peer_capability_signing_keys, class_name: "System::PeerCapabilitySigningKey", dependent: :destroy
  has_many :system_platform_health_snapshots, class_name: "System::PlatformHealthSnapshot", dependent: :delete_all
  has_many :system_provider_volume_types, class_name: "System::ProviderVolumeType", dependent: :destroy
  has_many :system_sdwan_access_grants, class_name: "Sdwan::AccessGrant", dependent: :destroy
  has_many :system_sdwan_account_bgps, class_name: "Sdwan::AccountBgp", dependent: :destroy
  has_many :system_sdwan_configurations, class_name: "Sdwan::Configuration", dependent: :destroy
  has_many :system_sdwan_constellation_signing_keys, class_name: "Sdwan::ConstellationSigningKey", dependent: :destroy
  has_many :system_sdwan_firewall_rules, class_name: "Sdwan::FirewallRule", dependent: :destroy
  has_many :system_sdwan_flow_samples, class_name: "Sdwan::FlowSample", dependent: :delete_all
  has_many :system_sdwan_host_bridges, class_name: "Sdwan::HostBridge", dependent: :destroy
  has_many :system_sdwan_host_vrf_assignments, class_name: "Sdwan::HostVrfAssignment", dependent: :destroy
  has_many :system_sdwan_ipfix_collectors, class_name: "Sdwan::IpfixCollector", dependent: :destroy
  has_many :system_sdwan_membership_credentials, class_name: "Sdwan::MembershipCredential", dependent: :destroy
  has_many :system_sdwan_networks, class_name: "Sdwan::Network", dependent: :destroy
  has_many :system_sdwan_ovn_acls, class_name: "Sdwan::OvnAcl", dependent: :destroy
  has_many :system_sdwan_ovn_deployments, class_name: "Sdwan::OvnDeployment", dependent: :destroy
  has_many :system_sdwan_ovn_logical_switch_ports, class_name: "Sdwan::OvnLogicalSwitchPort", dependent: :destroy
  has_many :system_sdwan_ovn_logical_switches, class_name: "Sdwan::OvnLogicalSwitch", dependent: :destroy
  has_many :system_sdwan_peers, class_name: "Sdwan::Peer", dependent: :destroy
  has_many :system_sdwan_port_mappings, class_name: "Sdwan::PortMapping", dependent: :destroy
  has_many :system_sdwan_route_leaks, class_name: "Sdwan::RouteLeak", dependent: :destroy
  has_many :system_sdwan_route_policies, class_name: "Sdwan::RoutePolicy", dependent: :destroy
  has_many :system_sdwan_service_backends, class_name: "Sdwan::ServiceBackend", dependent: :destroy
  has_many :system_sdwan_services, class_name: "Sdwan::Service", dependent: :destroy
  has_many :system_sdwan_subnet_advertisements, class_name: "Sdwan::SubnetAdvertisement", dependent: :destroy
  has_many :system_sdwan_virtual_ips, class_name: "Sdwan::VirtualIp", dependent: :destroy
  has_many :system_storage_migrations, class_name: "System::StorageMigration", dependent: :destroy
  has_many :system_task_logs, class_name: "System::TaskLog", dependent: :delete_all

  # System uses platform's FileManagement::Object for kernels/ramdisks/images
  # and module data tarballs. The platform-level Account model already
  # declares `has_many :file_objects, class_name: "FileManagement::Object"`,
  # so no additional decorator association is needed here.
end

# Pre-flight for Account teardown: a package repository that a module is linked
# to has an ON DELETE RESTRICT foreign key (and a restrict_with_error), which
# would otherwise fire mid-cascade. Refuse up front while the account's
# repositories still have module links.
Account.register_teardown_guard(:system_package_module_links,
                                covers: [ %w[system_package_module_links package_repository_id] ]) do |account|
  linked = System::PackageModuleLink.where(package_repository_id: System::PackageRepository.where(account_id: account.id).select(:id))
  "Cannot delete account with package repositories that still have module links" if linked.exists?
end
