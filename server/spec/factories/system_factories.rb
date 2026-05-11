# frozen_string_literal: true

FactoryBot.define do
  # System::Provider
  factory :system_provider, class: "System::Provider" do
    association :account
    sequence(:name) { |n| "Provider #{n}" }
    provider_type { "aws" }
    enabled { true }
    config { {} }
    capabilities { {} }
  end

  # System::ProviderRegion
  factory :system_provider_region, class: "System::ProviderRegion" do
    association :account
    association :provider, factory: :system_provider
    sequence(:name) { |n| "Region #{n}" }
    sequence(:region_code) { |n| "us-east-#{n}" }
    enabled { true }
    capabilities { {} }
  end

  # System::ProviderConnection
  factory :system_provider_connection, class: "System::ProviderConnection" do
    association :account
    association :provider, factory: :system_provider
    sequence(:name) { |n| "Connection #{n}" }
    access_key { "test-access-key" }
    secret_key { "test-secret-key" }
    status { "connected" }
    config { {} }
  end

  # System::ProviderAvailabilityZone
  factory :system_provider_availability_zone, class: "System::ProviderAvailabilityZone" do
    association :provider_region, factory: :system_provider_region
    sequence(:name) { |n| "us-east-1#{('a'.ord + n % 6).chr}" }
    zone_code { name }
    enabled { true }
  end

  # System::ProviderInstanceType
  factory :system_provider_instance_type, class: "System::ProviderInstanceType" do
    association :account
    association :provider, factory: :system_provider
    sequence(:name) { |n| "t#{n}.micro" }
    sequence(:instance_type_code) { |n| "t#{n}.micro" }
    vcpus { 1 }
    memory_mb { 1024 }
    storage_gb { 8 }
    enabled { true }
    specs { {} }
  end

  # System::NodeArchitecture
  factory :system_node_architecture, class: "System::NodeArchitecture" do
    association :account
    sequence(:name) { |n| "Architecture #{n}" }
    kernel_options { "" }
    enabled { true }
    public { false }

    trait :with_checksums do
      kernel_checksum { Digest::SHA256.hexdigest("kernel_data") }
      ramdisk_checksum { Digest::SHA256.hexdigest("ramdisk_data") }
      image_checksum { Digest::SHA256.hexdigest("image_data") }
      kernel_version { "5.15.0-generic" }
      image_format { "qcow2" }
    end
  end

  # System::NodePlatform
  factory :system_node_platform, class: "System::NodePlatform" do
    association :account
    association :node_architecture, factory: :system_node_architecture
    sequence(:name) { |n| "Platform #{n}" }
    enabled { true }
    public { false }
    build_script { "#!/bin/bash\necho 'build'" }
    init_script { "#!/bin/bash\necho 'init'" }
    sync_script { "#!/bin/bash\necho 'sync'" }
  end

  # System::NodeTemplate
  factory :system_node_template, class: "System::NodeTemplate" do
    association :account
    association :node_platform, factory: :system_node_platform
    sequence(:name) { |n| "Template #{n}" }
    enabled { true }
    public { false }
    admin_user { "admin" }
    config { {} }
  end

  # System::Node
  factory :system_node, class: "System::Node" do
    association :account
    association :node_template, factory: :system_node_template
    sequence(:name) { |n| "Node #{n}" }
    enabled { true }
    config { {} }
    allocate_public_ip { false }
    runtime_amount { 0 }
    tmpfs_store { false }

    trait :with_runtime do
      runtime_amount { 120 } # 2 hours in minutes
    end

    trait :with_tmpfs do
      tmpfs_store { true }
    end
  end

  # System::NodeInstance
  factory :system_node_instance, class: "System::NodeInstance" do
    # `account` is a transient so callers can write
    #   create(:system_node_instance, account: account)
    # and have it routed through the node (NodeInstance has no account_id
    # column — account flows through node).
    transient { account { nil } }

    association :provider_region, factory: :system_provider_region
    association :provider_instance_type, factory: :system_provider_instance_type
    sequence(:name) { |n| "Instance #{n}" }
    variety { "cloud" }
    status { "pending" }
    config { {} }

    node { build(:system_node, account: account || create(:account)) }

    trait :running do
      status { "running" }
      private_ip_address { "10.0.1.#{rand(1..254)}" }
      public_ip_address { "203.0.113.#{rand(1..254)}" }
    end

    trait :stopped do
      status { "stopped" }
    end

    trait :physical do
      variety { "physical" }
    end

    trait :with_coordinates do
      latitude { 37.7749 }
      longitude { -122.4194 }
    end

    trait :with_mac_address do
      mac_address { "00:11:22:33:44:55" }
    end

    trait :with_netboot do
      variety { "physical" }
      mac_address { "00:11:22:33:44:55" }
      private_netboot { true }
    end
  end

  # System::ProviderVolumeType
  factory :system_provider_volume_type, class: "System::ProviderVolumeType" do
    association :account
    association :provider, factory: :system_provider
    sequence(:name) { |n| "gp#{n}" }
    volume_type { "gp2" }
    min_size_gb { 1 }
    max_size_gb { 16384 }
    min_iops { nil }
    max_iops { nil }
    enabled { true }
  end

  # System::ProviderVolume
  factory :system_provider_volume, class: "System::ProviderVolume" do
    association :account
    association :provider_region, factory: :system_provider_region
    association :volume_type, factory: :system_provider_volume_type
    sequence(:name) { |n| "Volume #{n}" }
    size_gb { 100 }
    status { "available" }

    trait :attached do
      status { "attached" }
      cloud_volume_id { "vol-#{SecureRandom.hex(8)}" }
    end

    trait :raid0 do
      raid_level { 0 }
      after(:create) do |volume|
        create_list(:system_provider_volume_member, 2, provider_volume: volume, status: "available")
      end
    end

    trait :raid1 do
      raid_level { 1 }
      after(:create) do |volume|
        create_list(:system_provider_volume_member, 2, provider_volume: volume, status: "available")
      end
    end
  end

  # System::ProviderVolumeMember
  factory :system_provider_volume_member, class: "System::ProviderVolumeMember" do
    association :provider_volume, factory: :system_provider_volume
    cloud_volume_id { "vol-#{SecureRandom.hex(8)}" }
    device_name { "/dev/sd#{('b'.ord + (rand(24))).chr}" }
    status { "pending" }
    size_gb { 100 }
    sequence(:member_index) { |n| n - 1 }
    config { {} }

    trait :available do
      status { "available" }
    end

    trait :attached do
      status { "attached" }
    end
  end

  # System::ProviderNetwork
  factory :system_provider_network, class: "System::ProviderNetwork" do
    association :account
    association :provider_region, factory: :system_provider_region
    sequence(:name) { |n| "Network #{n}" }
    cidr_block { "10.0.0.0/16" }
    status { "available" }
    config { {} }
  end

  # System::ProviderNetworkSubnet
  factory :system_provider_network_subnet, class: "System::ProviderNetworkSubnet" do
    association :provider_network, factory: :system_provider_network
    association :provider_availability_zone, factory: :system_provider_availability_zone
    sequence(:name) { |n| "Subnet #{n}" }
    cidr_block { "10.0.1.0/24" }
    status { "available" }
    config { {} }
  end

  # System::NodeModuleCategory
  factory :system_node_module_category, class: "System::NodeModuleCategory" do
    association :account
    sequence(:name) { |n| "Category #{n}" }
    enabled { true }
  end

  # System::NodeModule
  factory :system_node_module, class: "System::NodeModule" do
    association :account
    association :node_platform, factory: :system_node_platform
    association :category, factory: :system_node_module_category
    sequence(:name) { |n| "Module #{n}" }
    variety { "config" }
    enabled { true }
    public { false }
    priority { 50 }
    mask { {} }
    file_spec { {} }
    package_spec { {} }
    config { {} }
    lock_spec { false }
    current_version_number { 0 }

    trait :locked do
      lock_spec { true }
    end

    trait :with_data_file do
      data_file_name { "module_data.tar.gz" }
      data_checksum { Digest::SHA256.hexdigest("test data") }
      data_file_size { 1024 }
    end

    trait :versioned do
      after(:create) do |node_module|
        create(:system_node_module_version, node_module: node_module, version_number: 1)
        node_module.reload
      end
    end
  end

  # System::NodeModuleVersion
  factory :system_node_module_version, class: "System::NodeModuleVersion" do
    association :node_module, factory: :system_node_module
    sequence(:version_number) { |n| n }
    changelog { "Version changelog" }
    mask { {} }
    file_spec { {} }
    package_spec { {} }
    config { {} }

    trait :with_data_file do
      data_file_name { "module_v1.tar.gz" }
      data_checksum { Digest::SHA256.hexdigest("version data") }
      data_file_size { 2048 }
    end

    trait :with_creator do
      association :created_by, factory: :user
    end
  end

  # System::NodeScript
  factory :system_node_script, class: "System::NodeScript" do
    association :account
    sequence(:name) { |n| "Script #{n}" }
    variety { "custom" }
    data { "#!/bin/bash\necho 'hello'" }
    enabled { true }
    public { false }
  end

  # System::Task
  factory :system_task, class: "System::Task" do
    association :account
    association :operable, factory: :system_node
    command { "sync" }
    status { "pending" }
    progress { 0 }
    events { [] }
    options { {} }

    trait :running do
      status { "running" }
      progress { 50 }
      started_at { 1.minute.ago }
    end

    trait :complete do
      status { "complete" }
      progress { 100 }
      started_at { 5.minutes.ago }
      completed_at { Time.current }
    end

    trait :failed do
      status { "failed" }
      started_at { 5.minutes.ago }
      completed_at { Time.current }
      error_message { "Operation failed" }
    end
  end

  # System::PuppetModule
  factory :system_puppet_module, class: "System::PuppetModule" do
    association :account
    sequence(:name) { |n| "puppet-module-#{n}" }
    enabled { true }
    public { false }
  end

  # System::PuppetResource
  factory :system_puppet_resource, class: "System::PuppetResource" do
    association :puppet_module, factory: :system_puppet_module
    sequence(:name) { |n| "resource-#{n}" }
    path { "/etc/puppet/modules" }
    data { "file { '/tmp/test': ensure => present }" }
    enabled { true }
  end

  # System::NodeModuleAssignment
  factory :system_node_module_assignment, class: "System::NodeModuleAssignment" do
    association :node, factory: :system_node
    association :node_module, factory: :system_node_module
    enabled { true }
  end

  # System::ModuleDependency
  factory :system_module_dependency, class: "System::ModuleDependency" do
    association :node_module, factory: :system_node_module
    association :dependency, factory: :system_node_module
    required { true }
    dependency_type { "requires" }
  end

  # System::TemplateModule
  factory :system_template_module, class: "System::TemplateModule" do
    association :node_template, factory: :system_node_template
    association :node_module, factory: :system_node_module
    enabled { true }
    priority { 50 }
  end

  # System::ProviderVolumeSnapshot
  factory :system_provider_volume_snapshot, class: "System::ProviderVolumeSnapshot" do
    association :account
    association :volume, factory: :system_provider_volume
    sequence(:name) { |n| "Snapshot #{n}" }
    status { "completed" }
    size_gb { 100 }
    progress { 100 }
  end

  # System::NodeMountPoint — Phase S2: storage-backed types (nfs/cifs/efs/ebs/
  # s3fs) moved to System::StorageAssignment. Only synthetic types remain.
  factory :system_node_mount_point, class: "System::NodeMountPoint" do
    association :account
    sequence(:name) { |n| "Mount #{n}" }
    mount_path { "/mnt/data" }
    mount_type { "tmpfs" }
    source { "tmpfs" }
    options { { options: "size=64m" } }
    enabled { true }
    auto_mount { true }
  end

  # System::InstanceMountPoint
  factory :system_instance_mount_point, class: "System::InstanceMountPoint" do
    association :node_instance, factory: :system_node_instance
    association :mount_point, factory: :system_node_mount_point
    enabled { true }
    config { {} }
  end

  # Sdwan::Network — Phase S2 needs this to be createable from system specs
  # for storage-assignment integration. Mirrors the network model's slice-1
  # required fields (name, slug, cidr_64, routing_protocol, status).
  factory :sdwan_network, class: "Sdwan::Network" do
    association :account
    sequence(:name) { |n| "network-#{n}" }
    sequence(:slug) { |n| "network-#{n}" }
    sequence(:cidr_64) { |n| "fd00:abcd:#{format('%04x', n)}::/64" }
    routing_protocol { "static" }
    status { "registered" }
  end

  # System::StorageAssignment — Phase S2 join object (file_storage × instance).
  factory :system_storage_assignment, class: "System::StorageAssignment" do
    association :account
    association :node_instance, factory: :system_node_instance
    file_storage_id { SecureRandom.uuid } # caller usually overrides with a real :file_storage row
    mount_path { "/mnt/data" }
    encryption_mode { "inherit" }
    status { "pending" }
    enabled { true }
    auto_mount { true }
    read_only { false }
  end

  # System::StorageCredential — VaultCredential-backed per-instance access cred.
  factory :system_storage_credential, class: "System::StorageCredential" do
    association :storage_assignment, factory: :system_storage_assignment
    association :node_instance, factory: :system_node_instance
    kind { "peer_ip_acl" }
    status { "issued" }
    metadata { { peer_ip: "fd00::1" } }
  end

  # System::ModulePuppetAssignment
  factory :system_module_puppet_assignment, class: "System::ModulePuppetAssignment" do
    association :node_module, factory: :system_node_module
    association :puppet_module, factory: :system_puppet_module
    enabled { true }
    priority { 50 }
  end

  # System::NodeModuleCopyPath
  # Schema: name, source_path, destination_path (legacy used a single :path column;
  # the platform's split-path shape is in 20251215200003_create_powernode_system_modules.rb).
  factory :system_node_module_copy_path, class: "System::NodeModuleCopyPath" do
    association :account
    sequence(:name) { |n| "CopyPath #{n}" }
    source_path { "/opt/modules/source" }
    destination_path { "/opt/modules/dest" }
    enabled { true }
    recursive { false }
    preserve_permissions { true }
  end

  # System::UnclaimedDevice — physical device polling /node_api/claim
  # before being bound to a NodeInstance.
  factory :system_unclaimed_device, class: "System::UnclaimedDevice" do
    association :account
    claim_code { System::UnclaimedDevice.generate_claim_code }
    sequence(:discovered_mac) { |n| "AA:BB:CC:DD:EE:%02X" % (n % 256) }
    discovered_dmi_uuid { SecureRandom.uuid }
    discovered_hostname { "test-pi-#{SecureRandom.hex(2)}" }
    agent_version { "0.1.0-test" }
    architecture { "arm64" }
    platform_hint { "rpi4" }
    first_seen_at { Time.current }
    last_seen_at { Time.current }
    expires_at { 24.hours.from_now }
  end

  # System::DiskImageWebhook — per-account, per-pipeline HMAC secret.
  # Uses the model's create_with_secret! factory in tests that need
  # the plaintext (it's not recoverable post-create); this build path
  # bypasses for cases where verify_signature isn't being exercised.
  factory :system_disk_image_webhook, class: "System::DiskImageWebhook" do
    association :account
    sequence(:label) { |n| "test-pipeline-#{n}" }
    secret { "pndis_#{SecureRandom.urlsafe_base64(32)}" }
    secret_preview { "pndis_te" }
    status { "active" }
  end

  # System::DiskImagePublication — append-only history of CI builds.
  # Default factory creates a queued publication; use traits for
  # downstream states (e.g. :published, :failed, :retired).
  factory :system_disk_image_publication, class: "System::DiskImagePublication" do
    association :account
    association :node_platform, factory: :system_node_platform
    sequence(:git_sha) { |n| "test-sha-#{n}-#{SecureRandom.hex(4)}" }
    sha256 { "a" * 64 }
    size_bytes { 10_485_760 } # 10 MB
    arch { "arm64" }
    firmware_ref { "1.20240306" }
    oci_ref { "registry.example.com/powernode/disk-images/test:abc" }
    status { "queued" }
    payload { {} }

    trait :awaiting_upload do
      status { "awaiting_upload" }
    end

    trait :verifying do
      status { "verifying" }
    end

    trait :published do
      status { "published" }
      verified_at { Time.current }
      published_at { Time.current }
      after(:build) do |pub, _evaluator|
        pub.file_object ||= FactoryBot.create(:file_object,
          account: pub.account,
          filename: "test.img",
          file_size: pub.size_bytes,
          content_type: "application/octet-stream",
          checksum_sha256: pub.sha256
        )
      end
    end

    trait :failed do
      status { "failed" }
      error_message { "test failure" }
    end

    trait :retired do
      status { "retired" }
      verified_at { Time.current }
      published_at { 1.week.ago }
      retired_at { Time.current }
    end
  end

  # === Package repository ingestion factories (Phase 11) ===

  factory :system_package_repository, class: "System::PackageRepository" do
    association :account
    association :created_by, factory: :user
    sequence(:name) { |n| "test-repo-#{n}" }
    kind { "apt" }
    visibility { "account" }
    base_url { "https://archive.example.com/ubuntu" }
    architectures { ["amd64"] }
    apt_config { { "suite" => "noble", "components" => ["main"] } }
    rpm_config { {} }
    enabled { true }
    sync_status { "idle" }
    package_count { 0 }
    priority { 100 }

    trait :rpm do
      kind { "rpm" }
      apt_config { {} }
      rpm_config { { "releasever" => "40", "gpgcheck" => false } }
    end

    trait :shared do
      account { nil }
      visibility { "shared" }
    end

    trait :synced do
      sync_status { "idle" }
      last_synced_at { Time.current }
      package_count { 10 }
    end
  end

  factory :system_package, class: "System::Package" do
    association :package_repository, factory: :system_package_repository
    sequence(:name) { |n| "test-pkg-#{n}" }
    version { "1.0.0" }
    architecture { "amd64" }
    section_or_group { "utils" }
    summary { "Test package summary" }
    description { "Test package description" }
    installed_size_bytes { 100_000 }
    download_size_bytes { 50_000 }
    depends { [] }
    pre_depends { [] }
    recommends { [] }
    suggests { [] }
    conflicts { [] }
    provides { [] }
    replaces { [] }
    breaks { [] }
    raw_metadata { {} }

    # Convenient builder for the AND-of-OR shape: pass plain package names.
    transient do
      depends_on { [] }
      recommends_packages { [] }
      provides_caps { [] }
    end

    after(:build) do |pkg, ev|
      pkg.depends = Array(ev.depends_on).map { |n| [{ "name" => n, "op" => nil, "version" => nil }] } if ev.depends_on.any?
      pkg.recommends = Array(ev.recommends_packages).map { |n| [{ "name" => n, "op" => nil, "version" => nil }] } if ev.recommends_packages.any?
      pkg.provides = Array(ev.provides_caps).map { |n| [{ "name" => n, "op" => nil, "version" => nil }] } if ev.provides_caps.any?
    end
  end

  factory :system_package_module_link, class: "System::PackageModuleLink" do
    association :node_module, factory: :system_node_module
    association :package_repository, factory: :system_package_repository
    sequence(:package_name) { |n| "pkg-#{n}" }
    package_version { "1.0.0" }
    architecture { "amd64" }
    file_spec_source { "package_query" }
    alternatives_chosen { {} }
    recommends_chosen { [] }
    auto_generated { true }
    last_synced_at { Time.current }
  end
end
