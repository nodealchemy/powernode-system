// System Types for Powernode System Management

export interface SystemNode {
  id: string;
  name: string;
  description?: string;
  enabled: boolean;
  status?: string;
  public_address?: string;
  allocate_public_ip: boolean;
  config: Record<string, unknown>;
  node_template_id?: string;
  node_template_name?: string;
  worker_id?: string;
  instance_count?: number;
  running_instances_count?: number;
  created_at: string;
  updated_at: string;
}

export interface SystemNodeInstance {
  id: string;
  name: string;
  variety: 'cloud' | 'physical' | 'dynamic';
  status: string;
  private_ip_address?: string;
  public_ip_address?: string;
  vpn_ip_address?: string;
  config: Record<string, unknown>;
  node_id: string;
  node_name?: string;
  provider_region_id?: string;
  provider_instance_type_id?: string;
  // Physical-device claim flow (Path C provisioning).
  // Plan: docs/plans/wondrous-yawning-anchor.md
  mac_address?: string;
  private_netboot?: boolean;
  claim_code?: string;
  claimed_at?: string;
  discovered_mac?: string;
  discovered_dmi_uuid?: string;
  discovered_hostname?: string;
  discovered_at?: string;
  claimed?: boolean;
  active?: boolean;
  description?: string;
  created_at: string;
  updated_at: string;
}

// UnclaimedDevice — a physical device polling /api/v1/system/node_api/claim
// before being bound to a NodeInstance. Surfaces in the operator's
// "Unclaimed Devices" panel for confirm-and-claim.
export interface SystemUnclaimedDevice {
  id: string;
  claim_code: string;
  discovered_mac: string;
  discovered_dmi_uuid?: string;
  discovered_hostname?: string;
  agent_version?: string;
  architecture?: string;
  platform_hint?: string;
  first_seen_at: string;
  last_seen_at: string;
  expires_at: string;
  claimed_at?: string;
  claimed_node_instance_id?: string;
}

// Disk image download metadata for a NodePlatform (the generic .img
// operators flash to provision physical devices via the claim flow).
export interface SystemDiskImage {
  url: string;
  expires_at: string;
  sha256: string;
  size_bytes: number;
  built_at?: string;
  filename: string;
}

export interface SystemNodeTemplateModuleSummary {
  id: string;
  name: string;
  variety: string;
  priority: number;
  template_module_id: string;
}

export interface SystemNodeTemplate {
  id: string;
  name: string;
  description?: string;
  enabled: boolean;
  public: boolean;
  admin_user?: string;
  config: Record<string, unknown>;
  node_platform_id?: string;
  node_platform_name?: string;
  node_count?: number;
  // Lightweight module summary embedded by NodeTemplateSerializer so the
  // list page can render module chips without an N+1 fetch. The full
  // NodeModule payload is still fetched on-demand by TemplateDetailModal.
  module_count?: number;
  modules?: SystemNodeTemplateModuleSummary[];
  created_at: string;
  updated_at: string;
}

export interface SystemNodePlatform {
  id: string;
  name: string;
  description?: string;
  enabled: boolean;
  public: boolean;
  build_script?: string;
  init_script?: string;
  sync_script?: string;
  node_architecture_id?: string;
  architecture_name?: string;
  template_count?: number;
  module_count?: number;
  // Disk image (claim-flow physical provisioning) — set when CI has
  // built and uploaded a generic .img for this platform.
  disk_image_file_object_id?: string;
  disk_image_sha256?: string;
  disk_image_size_bytes?: number;
  disk_image_built_at?: string;
  created_at: string;
  updated_at: string;
}

export interface SystemNodeArchitecture {
  id: string;
  name: string;
  description?: string;
  kernel_options?: string;
  enabled: boolean;
  public: boolean;
  platform_count?: number;
  created_at: string;
  updated_at: string;
}

export interface SystemNodeScript {
  id: string;
  name: string;
  description?: string;
  variety: 'build' | 'init' | 'sync' | 'custom';
  data?: string;
  enabled: boolean;
  public: boolean;
  created_at: string;
  updated_at: string;
}

export interface SystemProvider {
  id: string;
  name: string;
  description?: string;
  provider_type: string;
  enabled: boolean;
  public: boolean;
  config: Record<string, unknown>;
  capabilities: Record<string, unknown>;
  region_count?: number;
  connection_count?: number;
  created_at: string;
  updated_at: string;
}

export interface SystemProviderRegion {
  id: string;
  name: string;
  description?: string;
  endpoint_url?: string;
  region_code?: string;
  capabilities: Record<string, unknown>;
  provider_id: string;
  provider_name?: string;
  zone_count?: number;
  instance_type_count?: number;
  created_at: string;
  updated_at: string;
}

export interface SystemProviderConnection {
  id: string;
  name: string;
  description?: string;
  endpoint_url?: string;
  config: Record<string, unknown>;
  provider_id: string;
  provider_name?: string;
  created_at: string;
  updated_at: string;
}

export interface SystemProviderInstanceType {
  id: string;
  name: string;
  description?: string;
  instance_type_code: string;
  vcpus?: number;
  memory_mb?: number;
  memory_gb?: number;
  storage_gb?: number;
  hourly_price?: number;
  enabled: boolean;
  specs: Record<string, unknown>;
  display_name?: string;
  provider_id: string;
  provider_name?: string;
  region_count?: number;
  created_at: string;
  updated_at: string;
}

export interface SystemProviderAvailabilityZone {
  id: string;
  name: string;
  zone_code: string;
  status: 'available' | 'impaired' | 'unavailable';
  enabled: boolean;
  capabilities: Record<string, unknown>;
  provider_region_id: string;
  region_name?: string;
  provider_name?: string;
  operational: boolean;
  created_at: string;
  updated_at: string;
}

export interface SystemProviderNetworkSubnet {
  id: string;
  name: string;
  description?: string;
  cidr_block?: string;
  status: string;
  is_public: boolean;
  enabled: boolean;
  config: Record<string, unknown>;
  provider_network_id: string;
  network_name?: string;
  provider_availability_zone_id?: string;
  availability_zone_name?: string;
  created_at: string;
  updated_at: string;
}

export interface SystemNodeModule {
  id: string;
  name: string;
  description?: string;
  variety: 'config' | 'instance' | 'subscription';
  enabled: boolean;
  public: boolean;
  priority: number;
  // rsync-glob spec fields. Wire shape is base64-encoded glob lines,
  // one per array element. The `_text` companion fields are pre-decoded
  // newline-joined strings convenient for textarea rendering.
  mask: string[];
  mask_text?: string;
  file_spec: string[];
  file_spec_text?: string;
  package_spec?: string[];
  package_spec_text?: string;
  dependency_spec?: string[];
  dependency_spec_text?: string;
  // protected_spec: paths this module CLAIMS as sensitive. The build
  // pipeline folds these into every neighbor's effective_mask, so no
  // other module ships them — preventing union-mount overrides of
  // security-sensitive content (e.g. /etc/shadow).
  protected_spec?: string[];
  protected_spec_text?: string;
  lock_spec?: boolean;
  init_start?: string;
  init_stop?: string;
  init_restart?: string;
  reboot_required?: boolean;
  config: Record<string, unknown>;
  node_platform_id?: string;
  node_platform_name?: string;
  category_id?: string;
  category_name?: string;
  // Dependant-module hierarchy. When `dependant: true` (i.e. parent_module_id
  // is set), this module is a config-variety or instance-variety override of
  // its parent. Its `file_spec` (and `file_spec_text`) returns the parent's
  // `dependency_spec` rather than its own column — editing the column has no
  // effect; the canonical edit point is the parent's `dependency_spec`.
  parent_module_id?: string;
  parent_module_name?: string;
  dependant?: boolean;
  dependencies_count?: number;
  dependents_count?: number;
  assignments_count?: number;
  templates_count?: number;
  puppet_modules_count?: number;
  created_at: string;
  updated_at: string;
}

export interface SystemNodeModuleCategory {
  id: string;
  name: string;
  description?: string;
  parent_id?: string;
  parent_name?: string;
  depth: number;
  children_count?: number;
  module_count?: number;
  created_at: string;
  updated_at: string;
}

export interface SystemTask {
  id: string;
  command: string;
  status: 'pending' | 'scheduled' | 'running' | 'complete' | 'failed' | 'aborted' | 'cancelled';
  description?: string;
  progress: number;
  exclusive: boolean;
  scheduled_at?: string;
  started_at?: string;
  completed_at?: string;
  error_message?: string;
  events: Array<Record<string, unknown>>;
  options: Record<string, unknown>;
  operable_type?: string;
  operable_id?: string;
  initiated_by_id?: string;
  initiated_by_name?: string;
  created_at: string;
  updated_at: string;
}

export interface SystemPuppetModule {
  id: string;
  name: string;
  description?: string;
  enabled: boolean;
  public: boolean;
  version?: string;
  author?: string;
  license?: string;
  source_url?: string;
  project_url?: string;
  forge_name?: string;
  dependencies: Array<{ name: string; version_requirement?: string }>;
  config: Record<string, unknown>;
  metadata: Record<string, unknown>;
  resource_count?: number;
  resource_types?: string[];
  assigned_modules_count?: number;
  created_at: string;
  updated_at: string;
}

export interface SystemPuppetResource {
  id: string;
  name: string;
  description?: string;
  resource_type: string;
  title?: string;
  path?: string;
  data?: string;
  enabled: boolean;
  exported: boolean;
  parameters: Record<string, unknown>;
  config: Record<string, unknown>;
  puppet_module_id: string;
  puppet_module_name?: string;
  resource_identifier?: string;
  created_at: string;
  updated_at: string;
}

export interface SystemProviderVolume {
  id: string;
  name: string;
  description?: string;
  size_gb: number;
  status: string;
  volume_type: string;
  device_name?: string;
  iops?: number;
  throughput?: number;
  encrypted: boolean;
  config: Record<string, unknown>;
  volume_type_id?: string;
  volume_type_name?: string;
  provider_region_id: string;
  provider_region_name?: string;
  region_name?: string;
  node_instance_id?: string;
  attached_instance_id?: string;
  snapshot_count?: number;
  created_at: string;
  updated_at: string;
}

export interface SystemProviderNetwork {
  id: string;
  name: string;
  description?: string;
  cidr_block?: string;
  status: string;
  is_default?: boolean;
  dns_support?: boolean;
  dns_hostnames?: boolean;
  config: Record<string, unknown>;
  provider_region_id?: string;
  provider_region_name?: string;
  region_name?: string;
  subnet_count?: number;
  created_at: string;
  updated_at: string;
}

// Overview Statistics Types
export interface SystemOverviewStats {
  nodes: {
    total: number;
    enabled: number;
    disabled: number;
  };
  instances: {
    total: number;
    running: number;
    stopped: number;
    pending: number;
  };
  templates: {
    total: number;
    public: number;
    private: number;
  };
  platforms: {
    total: number;
    enabled: number;
  };
  providers: {
    total: number;
    enabled: number;
    types: string[];
  };
  regions: {
    total: number;
  };
  modules: {
    total: number;
    enabled: number;
    by_variety: {
      config: number;
      instance: number;
      subscription: number;
    };
  };
  operations: {
    total: number;
    pending: number;
    running: number;
    completed: number;
    failed: number;
  };
  puppet: {
    modules: number;
    resources: number;
    assignments: number;
  };
  volumes: {
    total: number;
    total_size_gb: number;
  };
  networks: {
    total: number;
  };
}

export interface SystemRecentActivity {
  id: string;
  type: 'operation' | 'node' | 'instance' | 'module' | 'provider';
  action: string;
  description: string;
  status?: string;
  entity_name: string;
  entity_id: string;
  initiated_by?: string;
  timestamp: string;
}
