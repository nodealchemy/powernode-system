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
  has_many :system_node_architectures, class_name: "System::NodeArchitecture", dependent: :restrict_with_error
  has_many :system_node_platforms, class_name: "System::NodePlatform", dependent: :restrict_with_error
  has_many :system_node_templates, class_name: "System::NodeTemplate", dependent: :restrict_with_error
  has_many :system_node_scripts, class_name: "System::NodeScript", dependent: :restrict_with_error
  has_many :system_node_mount_points, class_name: "System::NodeMountPoint", dependent: :restrict_with_error

  # Modules
  has_many :system_node_modules, class_name: "System::NodeModule", dependent: :restrict_with_error
  has_many :system_node_module_categories, class_name: "System::NodeModuleCategory", dependent: :restrict_with_error

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

  # System uses platform's FileManagement::Object for kernels/ramdisks/images
  # and module data tarballs. The platform-level Account model already
  # declares `has_many :file_objects, class_name: "FileManagement::Object"`,
  # so no additional decorator association is needed here.
end
