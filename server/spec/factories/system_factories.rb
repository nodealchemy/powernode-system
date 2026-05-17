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

  # System::NodeArchitecture — platform-wide catalog (no account scoping).
  factory :system_node_architecture, class: "System::NodeArchitecture" do
    sequence(:name) { |n| "test_arch_#{n}" }
    family { "other" }
    is_canonical { false }
    kernel_options { "" }
    enabled { true }
    public { false }

    trait :canonical do
      is_canonical { true }
      family { "x86" }
    end

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

  factory :system_module_service, class: "System::ModuleService" do
    association :node_module, factory: :system_node_module
    account { node_module&.account }
    sequence(:name) { |n| "service-#{n}" }
    start_command { "/usr/bin/true" }
    restart_policy { "always" }
    health_method { "GET" }
    health_interval_seconds { 30 }
    health_timeout_seconds { 5 }
    health_initial_delay_seconds { 10 }
    env { {} }
    exposed_ports { [] }
    capabilities { [] }
    metadata { {} }

    trait :rails do
      name { "rails" }
      start_command { "bundle exec puma -C config/puma.rb" }
      health_endpoint { "/up" }
      exposed_ports { [{ "port" => 3000, "protocol" => "tcp", "name" => "http" }] }
      env { { "RAILS_ENV" => "production" } }
    end

    trait :sidekiq do
      name { "sidekiq" }
      start_command { "bundle exec sidekiq -C config/sidekiq.yml" }
      health_endpoint { nil }
      restart_policy { "on-failure" }
    end

    trait :postgres do
      name { "postgres" }
      start_command { "/usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/main" }
      health_endpoint { nil }
      exposed_ports { [{ "port" => 5432, "protocol" => "tcp", "name" => "postgres" }] }
      run_as_user { "postgres" }
    end
  end

  factory :system_module_service_dependency, class: "System::ModuleServiceDependency" do
    association :module_service, factory: :system_module_service
    depends_on_module_service { association :system_module_service, node_module: module_service&.node_module }
    kind { "requires_health" }
  end

  factory :system_federation_peer, class: "System::FederationPeer" do
    association :account
    sequence(:remote_instance_url) { |n| "https://peer-#{n}.example.com" }
    sequence(:remote_instance_id) { SecureRandom.uuid }
    status { "proposed" }
    peer_kind { "sdwan_only" }
    endpoints { [] }
    extension_slugs { [] }
    capabilities { {} }
    sync_cursor { {} }
    metadata { {} }

    trait :platform do
      peer_kind { "platform" }
      spawn_role { "symmetric" }
      spawn_mode { "out_of_band" }
    end

    trait :accepted do
      status { "accepted" }
      signed_at { Time.current }
    end

    trait :enrolled do
      platform
      status { "enrolled" }
      last_handshake_at { Time.current }
    end

    trait :active do
      platform
      status { "active" }
      last_handshake_at { 1.hour.ago }
      last_heartbeat_at { Time.current }
    end

    trait :spawned_child do
      platform
      spawn_mode { "managed_child" }
      spawn_role { "child" }
    end

    trait :spawned_parent_managed do
      platform
      spawn_mode { "managed_child" }
      spawn_role { "parent" }
    end
  end

  factory :sdwan_virtual_ip, class: "Sdwan::VirtualIp" do
    association :network, factory: :sdwan_network
    account { network&.account }
    sequence(:name) { |n| "vip-#{n}" }
    sequence(:cidr) { |n| "fd00:beef::#{format('%x', n)}/128" }
    state { "pending" }
    advertised_med { 100 }
    advertised_local_pref { 100 }
    anycast { false }
    holder_peer_ids { [] }
  end

  factory :system_federation_network_bridge, class: "System::FederationNetworkBridge" do
    association :account
    federation_peer { association :system_federation_peer, :platform, account: account }
    sdwan_network { association :sdwan_network, account: account }
    state { "proposed" }
    metadata { {} }

    trait :active do
      state { "active" }
      activated_at { Time.current }
    end

    trait :suspended do
      state { "suspended" }
      activated_at { 1.hour.ago }
      suspended_at { Time.current }
    end
  end

  factory :system_federation_capability, class: "System::FederationCapability" do
    association :account
    federation_peer { association :system_federation_peer, :platform, account: account }
    sequence(:resource_kind) { |n| "kind-#{n}" }
    direction { "bidirectional" }
    policy { "manual" }
    conflict_resolution { "newer_wins_logical_clock" }
    filter { {} }
    sync_cursor { {} }

    trait :auto_periodic do
      policy { "auto_periodic" }
    end

    trait :outbound_only do
      direction { "push_local_to_remote" }
    end

    trait :inbound_only do
      direction { "pull_remote_to_local" }
    end

    trait :migration_only do
      direction { "migration_only" }
    end
  end

  factory :system_federation_grant, class: "System::FederationGrant" do
    association :account
    federation_peer { association :system_federation_peer, :platform, account: account }
    grantor_user { association :user, account: account }
    sequence(:remote_subject) { |n| "subject-#{n}@peer.example.com" }
    sequence(:resource_kind) { |n| "kind-#{n}" }
    resource_id { nil }
    permission_scopes { [ "read" ] }
    issued_at { Time.current }
    expires_at { 30.days.from_now }
    metadata { {} }

    trait :revoked do
      revoked_at { 1.day.ago }
      revocation_reason { "operator revoked" }
    end

    trait :archived do
      revoked
      archived_at { Time.current }
    end

    trait :expired do
      issued_at { 60.days.ago }
      expires_at { 1.day.ago }
    end

    trait :migrate_scope do
      permission_scopes { %w[read migrate] }
    end
  end

  factory :system_migration, class: "System::Migration" do
    association :account
    operation { "duplicate" }
    sequence(:root_resource_kind) { |n| "kind_#{n}" }
    root_resource_id { SecureRandom.uuid }
    status { "planned" }
    dry_run { false }
    plan_summary { {} }
    conflict_log { [] }
    audit_log { [] }
    metadata { {} }

    trait :duplicate   do operation { "duplicate" } end
    trait :migrate     do operation { "migrate" } end
    trait :dry_run     do dry_run { true } end
    trait :validating  do status { "validating" } end
    trait :transferring do status { "transferring" }; started_at { Time.current } end
    trait :completed   do status { "completed" }; completed_at { Time.current } end
    trait :failed      do status { "failed" }; failed_at { Time.current }; error_message { "failed for test" } end
    trait :conflict    do status { "conflict" } end
  end

  factory :system_migration_plan_step, class: "System::MigrationPlanStep" do
    association :migration, factory: :system_migration
    sequence(:step_order) { |n| n }
    sequence(:resource_kind) { |n| "kind_#{n}" }
    resource_id { SecureRandom.uuid }
    action { "create" }
    conflict_policy { "fail" }
    payload { {} }
    metadata { {} }
  end

  factory :system_federation_contract_version, class: "System::FederationContractVersion" do
    sequence(:version) { |n| n + 1 }
    contract_text { "The Twelve Commitments v#{version}\n\nOperator acknowledges..." }
    effective_at { Date.current }
    metadata { {} }
  end

  factory :system_platform_deployment, class: "System::PlatformDeployment" do
    association :account
    association :node_template, factory: :system_node_template
    virtual_ip { nil }
    sequence(:name) { |n| "deployment-#{n}" }
    service_role { "api" }
    target_replicas { 1 }
    metadata { {} }

    trait :api do
      service_role { "api" }
      sequence(:name) { |n| "hub-api-#{n}" }
    end

    trait :worker do
      service_role { "worker" }
      sequence(:name) { |n| "hub-worker-#{n}" }
    end

    trait :with_vip do
      virtual_ip { association :sdwan_virtual_ip, account: account }
    end

    trait :with_dns do
      sequence(:public_dns_hostname) { |n| "hub-#{n}.example.com" }
    end

    trait :satellite do
      service_role { "satellite-runtime" }
      sequence(:satellite_extension_slug) { |n| "ext-#{n}" }
    end
  end

  factory :system_acme_dns_credential, class: "System::AcmeDnsCredential" do
    association :account
    sequence(:name) { |n| "dns-cred-#{n}" }
    provider { "cloudflare" }
    status { "untested" }
    metadata { {} }

    trait :valid do
      status { "valid" }
      last_validated_at { Time.current }
    end

    trait :invalid do
      status { "invalid" }
      last_validated_at { Time.current }
    end

    trait :route53 do
      provider { "route53" }
    end
  end

  factory :system_acme_certificate, class: "System::AcmeCertificate" do
    association :account
    association :dns_credential, factory: :system_acme_dns_credential
    sequence(:common_name) { |n| "cert-#{n}.example.com" }
    sans { [] }
    issuer { "letsencrypt-prod" }
    challenge_type { "dns-01" }
    status { "pending" }
    # acme_email is required by CertificateManager#resolve_acme_email
    # for any path that triggers issuance/renewal. Tests can override
    # via metadata: { acme_email: ... }.
    metadata { { "acme_email" => "test-ops@example.com" } }

    trait :issuing do
      status { "issuing" }
      last_renewal_attempt_at { Time.current }
    end

    trait :valid do
      status { "valid" }
      issued_at { Time.current }
      expires_at { 90.days.from_now }
    end

    trait :expiring_soon do
      status { "valid" }
      issued_at { 60.days.ago }
      expires_at { 20.days.from_now }
    end

    trait :expired do
      status { "expired" }
      issued_at { 100.days.ago }
      expires_at { 10.days.ago }
    end

    trait :revoked do
      status { "revoked" }
    end

    trait :http01 do
      challenge_type { "http-01" }
      dns_credential { nil }
    end
  end

  factory :system_federation_service_offering, class: "System::Federation::ServiceOffering" do
    association :account
    sequence(:slug) { |n| "service-#{n}" }
    sequence(:name) { |n| "Service ##{n}" }
    protocol { "https" }
    backend_host { "backend.example.com" }
    backend_port { 443 }
    status { "draft" }
    default_grant_ttl_days { 30 }
    default_grant_scopes { %w[read] }
    capacity_metadata { {} }
    latency_metadata { {} }
    metadata { {} }

    trait :active do
      status { "active" }
    end

    trait :deprecated do
      status { "deprecated" }
      deprecated_at { Time.current }
    end

    trait :retired do
      status { "retired" }
      retired_at { Time.current }
    end

    trait :tcp do
      protocol { "tcp" }
      backend_port { 5432 }
    end

    trait :capped do
      capacity_metadata { { "max_subscribers" => 5 } }
    end
  end

  factory :system_federation_service_subscription, class: "System::Federation::ServiceSubscription" do
    association :account
    association :federation_peer, factory: [ :system_federation_peer, :platform, :active ]
    association :federation_grant, factory: :system_federation_grant
    association :acme_certificate, factory: [ :system_acme_certificate, :valid ]
    sequence(:service_offering_slug) { |n| "service-#{n}" }
    service_offering_id { SecureRandom.uuid }
    sequence(:local_hostname) { |n| "svc-#{n}.example.com" }
    protocol { "https" }
    backend_vip { nil }
    backend_port { 443 }
    status { "pending" }
    metadata { {} }

    trait :active do
      status { "active" }
      activated_at { Time.current }
    end

    trait :suspended do
      status { "suspended" }
      suspended_at { Time.current }
    end

    trait :cancelled do
      status { "cancelled" }
      cancelled_at { Time.current }
    end

    trait :site_local do
      sequence(:local_hostname) { |n| "localhost:#{5432 + n}" }
      protocol { "tcp" }
      acme_certificate { nil }
    end

    trait :tcp do
      protocol { "tcp" }
      backend_port { 5432 }
    end
  end
end
