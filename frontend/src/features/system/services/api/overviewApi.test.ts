import { overviewApi } from './overviewApi';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/** Build a double-envelope AxiosResponse for a non-paginated endpoint. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

/**
 * Build a double-envelope AxiosResponse for a paginated endpoint.
 * meta sits at the BODY root (response.data.meta), NOT inside data.
 */
function paginatedEnvelope<T>(data: T, total = 0) {
  return {
    data: {
      success: true,
      data,
      meta: {
        current_page: 1,
        per_page: 100,
        total_count: total,
        total_pages: 1,
        next_page: null,
        prev_page: null,
      },
    },
  };
}

// =============================================================================
// Fixtures
// =============================================================================

const NODE_ENABLED = {
  id: 'node-1',
  name: 'node-1',
  enabled: true,
  allocate_public_ip: false,
  config: {},
  instance_count: 5,
  running_instances_count: 3,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const NODE_DISABLED = {
  id: 'node-2',
  name: 'node-2',
  enabled: false,
  allocate_public_ip: false,
  config: {},
  instance_count: 2,
  running_instances_count: 0,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TEMPLATE_PUBLIC = {
  id: 'tpl-1',
  name: 'tpl-public',
  enabled: true,
  public: true,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TEMPLATE_PRIVATE = {
  id: 'tpl-2',
  name: 'tpl-private',
  enabled: true,
  public: false,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PLATFORM_ENABLED = {
  id: 'plat-1',
  name: 'ubuntu-22',
  enabled: true,
  public: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PLATFORM_DISABLED = {
  id: 'plat-2',
  name: 'centos-7',
  enabled: false,
  public: false,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PROVIDER_QEMU = {
  id: 'prov-1',
  name: 'local-qemu',
  provider_type: 'qemu',
  enabled: true,
  public: false,
  config: {},
  capabilities: {},
  region_count: 2,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PROVIDER_PROXMOX = {
  id: 'prov-2',
  name: 'pve-cluster',
  provider_type: 'proxmox',
  enabled: false,
  public: false,
  config: {},
  capabilities: {},
  region_count: 1,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const MODULE_CONFIG = {
  id: 'mod-1',
  name: 'base-config',
  variety: 'config' as const,
  enabled: true,
  public: false,
  priority: 10,
  mask: [],
  file_spec: [],
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const MODULE_INSTANCE = {
  id: 'mod-2',
  name: 'docker-engine',
  variety: 'instance' as const,
  enabled: false,
  public: false,
  priority: 20,
  mask: [],
  file_spec: [],
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const MODULE_SUBSCRIPTION = {
  id: 'mod-3',
  name: 'monitoring-agent',
  variety: 'subscription' as const,
  enabled: true,
  public: false,
  priority: 5,
  mask: [],
  file_spec: [],
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TASK_PENDING = {
  id: 'task-1',
  command: 'provision',
  status: 'pending' as const,
  progress: 0,
  exclusive: false,
  events: [],
  options: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TASK_SCHEDULED = {
  id: 'task-2',
  command: 'upgrade',
  status: 'scheduled' as const,
  progress: 0,
  exclusive: false,
  events: [],
  options: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TASK_RUNNING = {
  id: 'task-3',
  command: 'sync',
  status: 'running' as const,
  progress: 50,
  exclusive: false,
  events: [],
  options: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TASK_COMPLETE = {
  id: 'task-4',
  command: 'build',
  status: 'complete' as const,
  progress: 100,
  exclusive: false,
  events: [],
  options: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TASK_FAILED = {
  id: 'task-5',
  command: 'deprovision',
  status: 'failed' as const,
  progress: 0,
  exclusive: false,
  events: [],
  options: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TASK_ABORTED = {
  id: 'task-6',
  command: 'configure',
  status: 'aborted' as const,
  progress: 0,
  exclusive: false,
  events: [],
  options: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PUPPET_MODULE_A = {
  id: 'pup-1',
  name: 'puppet-nginx',
  enabled: true,
  public: false,
  dependencies: [],
  config: {},
  metadata: {},
  resource_count: 12,
  assigned_modules_count: 3,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PUPPET_MODULE_B = {
  id: 'pup-2',
  name: 'puppet-postgresql',
  enabled: true,
  public: false,
  dependencies: [],
  config: {},
  metadata: {},
  resource_count: 8,
  assigned_modules_count: 2,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const SDWAN_NETWORK = {
  id: 'net-1',
  name: 'production',
  slug: 'production',
  status: 'active' as const,
  cidr_64: 'fd00::/64',
  peer_count: 4,
  created_at: '2026-01-01T00:00:00Z',
};

const SDWAN_HOST_BRIDGE_LINUX = {
  id: 'hb-1',
  node_instance_id: 'inst-1',
  short_id: 1,
  bridge_name: 'br-pn0',
  kind: 'linux' as const,
  state: 'active' as const,
};

const SDWAN_HOST_BRIDGE_OVS = {
  id: 'hb-2',
  node_instance_id: 'inst-2',
  short_id: 2,
  bridge_name: 'br-ovs0',
  kind: 'ovs' as const,
  state: 'active' as const,
};

const SDWAN_OVN_ACTIVE = {
  id: 'ovn-1',
  status: 'active' as const,
  nb_db_endpoint: 'tcp:10.0.0.1:6641',
  sb_db_endpoint: 'tcp:10.0.0.1:6642',
  switch_count: 3,
  port_count: 12,
};

const SDWAN_OVN_PENDING = {
  id: 'ovn-2',
  status: 'pending' as const,
  nb_db_endpoint: 'tcp:10.0.0.2:6641',
  sb_db_endpoint: 'tcp:10.0.0.2:6642',
  switch_count: 0,
  port_count: 0,
};

const SDWAN_IPFIX_ACTIVE = {
  id: 'ipfix-1',
  name: 'primary-collector',
  host: '10.0.0.10',
  port: 4739,
  target_endpoint: '10.0.0.10:4739',
  sampling_rate: 100,
  state: 'active' as const,
  is_winning_collector: true,
};

const SDWAN_IPFIX_DISABLED = {
  id: 'ipfix-2',
  name: 'backup-collector',
  host: '10.0.0.11',
  port: 4739,
  target_endpoint: '10.0.0.11:4739',
  sampling_rate: 100,
  state: 'disabled' as const,
  is_winning_collector: false,
};

// Helper to set up all 11 mock responses in the order Promise.all calls them.
function setupAllMocks({
  nodes = [NODE_ENABLED, NODE_DISABLED],
  templates = [TEMPLATE_PUBLIC, TEMPLATE_PRIVATE],
  platforms = [PLATFORM_ENABLED, PLATFORM_DISABLED],
  providers = [PROVIDER_QEMU, PROVIDER_PROXMOX],
  modules = [MODULE_CONFIG, MODULE_INSTANCE, MODULE_SUBSCRIPTION],
  tasks = [TASK_PENDING, TASK_RUNNING, TASK_COMPLETE, TASK_FAILED],
  puppetModules = [PUPPET_MODULE_A, PUPPET_MODULE_B],
  sdwanNetworks = [SDWAN_NETWORK],
  sdwanHostBridges = [SDWAN_HOST_BRIDGE_LINUX, SDWAN_HOST_BRIDGE_OVS],
  sdwanOvnDeployments = [SDWAN_OVN_ACTIVE, SDWAN_OVN_PENDING],
  sdwanIpfixCollectors = [SDWAN_IPFIX_ACTIVE, SDWAN_IPFIX_DISABLED],
} = {}) {
  mockGet
    .mockResolvedValueOnce(paginatedEnvelope({ nodes }, nodes.length))
    .mockResolvedValueOnce(paginatedEnvelope({ node_templates: templates }, templates.length))
    .mockResolvedValueOnce(envelope({ node_platforms: platforms }))
    .mockResolvedValueOnce(envelope({ providers }))
    .mockResolvedValueOnce(paginatedEnvelope({ node_modules: modules }, modules.length))
    .mockResolvedValueOnce(paginatedEnvelope({ tasks }, tasks.length))
    .mockResolvedValueOnce(paginatedEnvelope({ puppet_modules: puppetModules }, puppetModules.length))
    .mockResolvedValueOnce(paginatedEnvelope({ networks: sdwanNetworks }, sdwanNetworks.length))
    .mockResolvedValueOnce(envelope({ host_bridges: sdwanHostBridges }))
    .mockResolvedValueOnce(envelope({ ovn_deployments: sdwanOvnDeployments }))
    .mockResolvedValueOnce(envelope({ ipfix_collectors: sdwanIpfixCollectors }));
}

// =============================================================================
// Tests
// =============================================================================

describe('overviewApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // getOverviewStats — API call coverage
  // ---------------------------------------------------------------------------

  describe('getOverviewStats — API requests', () => {
    it('fires all 11 GET requests in parallel with the correct URLs', async () => {
      setupAllMocks();

      await overviewApi.getOverviewStats();

      expect(mockGet).toHaveBeenCalledTimes(11);
      expect(mockGet).toHaveBeenCalledWith('/system/nodes');
      expect(mockGet).toHaveBeenCalledWith('/system/node_templates');
      expect(mockGet).toHaveBeenCalledWith('/system/node_platforms');
      expect(mockGet).toHaveBeenCalledWith('/system/providers');
      expect(mockGet).toHaveBeenCalledWith('/system/node_modules');
      expect(mockGet).toHaveBeenCalledWith('/system/tasks');
      expect(mockGet).toHaveBeenCalledWith('/system/puppet_modules');
      expect(mockGet).toHaveBeenCalledWith('/system/sdwan/networks');
      expect(mockGet).toHaveBeenCalledWith('/system/sdwan/host_bridges');
      expect(mockGet).toHaveBeenCalledWith('/system/sdwan/ovn_deployments');
      expect(mockGet).toHaveBeenCalledWith('/system/sdwan/ipfix_collectors');
    });
  });

  // ---------------------------------------------------------------------------
  // getOverviewStats — nodes aggregation
  // ---------------------------------------------------------------------------

  describe('getOverviewStats — nodes', () => {
    it('counts total, enabled, and disabled nodes correctly', async () => {
      setupAllMocks({ nodes: [NODE_ENABLED, NODE_DISABLED] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.nodes.total).toBe(2);
      expect(stats.nodes.enabled).toBe(1);
      expect(stats.nodes.disabled).toBe(1);
    });

    it('returns zero counts when no nodes exist', async () => {
      setupAllMocks({ nodes: [] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.nodes.total).toBe(0);
      expect(stats.nodes.enabled).toBe(0);
      expect(stats.nodes.disabled).toBe(0);
    });

    it('sums instance_count and running_instances_count across nodes', async () => {
      setupAllMocks({ nodes: [NODE_ENABLED, NODE_DISABLED] });

      const stats = await overviewApi.getOverviewStats();

      // NODE_ENABLED: instance_count=5, running=3
      // NODE_DISABLED: instance_count=2, running=0
      expect(stats.instances.total).toBe(7);
      expect(stats.instances.running).toBe(3);
    });

    it('handles nodes missing instance_count fields (treats as 0)', async () => {
      const bareNode = {
        id: 'node-bare',
        name: 'bare',
        enabled: true,
        allocate_public_ip: false,
        config: {},
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
        // no instance_count or running_instances_count
      };
      setupAllMocks({ nodes: [bareNode] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.instances.total).toBe(0);
      expect(stats.instances.running).toBe(0);
    });

    it('always returns stopped=0 and pending=0 in instances (hardcoded)', async () => {
      setupAllMocks({ nodes: [NODE_ENABLED] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.instances.stopped).toBe(0);
      expect(stats.instances.pending).toBe(0);
    });
  });

  // ---------------------------------------------------------------------------
  // getOverviewStats — templates
  // ---------------------------------------------------------------------------

  describe('getOverviewStats — templates', () => {
    it('counts total, public, and private templates', async () => {
      setupAllMocks({ templates: [TEMPLATE_PUBLIC, TEMPLATE_PRIVATE] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.templates.total).toBe(2);
      expect(stats.templates.public).toBe(1);
      expect(stats.templates.private).toBe(1);
    });

    it('returns zeros when no templates', async () => {
      setupAllMocks({ templates: [] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.templates.total).toBe(0);
      expect(stats.templates.public).toBe(0);
      expect(stats.templates.private).toBe(0);
    });
  });

  // ---------------------------------------------------------------------------
  // getOverviewStats — platforms
  // ---------------------------------------------------------------------------

  describe('getOverviewStats — platforms', () => {
    it('counts total and enabled platforms', async () => {
      setupAllMocks({ platforms: [PLATFORM_ENABLED, PLATFORM_DISABLED] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.platforms.total).toBe(2);
      expect(stats.platforms.enabled).toBe(1);
    });
  });

  // ---------------------------------------------------------------------------
  // getOverviewStats — providers
  // ---------------------------------------------------------------------------

  describe('getOverviewStats — providers', () => {
    it('counts total and enabled providers', async () => {
      setupAllMocks({ providers: [PROVIDER_QEMU, PROVIDER_PROXMOX] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.providers.total).toBe(2);
      expect(stats.providers.enabled).toBe(1);
    });

    it('collects unique provider types', async () => {
      setupAllMocks({ providers: [PROVIDER_QEMU, PROVIDER_PROXMOX] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.providers.types).toContain('qemu');
      expect(stats.providers.types).toContain('proxmox');
      expect(stats.providers.types).toHaveLength(2);
    });

    it('deduplicates provider types when multiple providers share a type', async () => {
      const anotherQemu = { ...PROVIDER_QEMU, id: 'prov-3', name: 'second-qemu' };
      setupAllMocks({ providers: [PROVIDER_QEMU, anotherQemu] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.providers.types).toEqual(['qemu']);
      expect(stats.providers.types).toHaveLength(1);
    });

    it('sums region_count across providers', async () => {
      setupAllMocks({ providers: [PROVIDER_QEMU, PROVIDER_PROXMOX] });

      const stats = await overviewApi.getOverviewStats();

      // PROVIDER_QEMU: region_count=2, PROVIDER_PROXMOX: region_count=1
      expect(stats.regions.total).toBe(3);
    });

    it('handles providers missing region_count (treats as 0)', async () => {
      const noRegionProvider = {
        ...PROVIDER_QEMU,
        id: 'prov-bare',
        region_count: undefined,
      };
      setupAllMocks({ providers: [noRegionProvider] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.regions.total).toBe(0);
    });
  });

  // ---------------------------------------------------------------------------
  // getOverviewStats — modules
  // ---------------------------------------------------------------------------

  describe('getOverviewStats — modules', () => {
    it('counts total, enabled, and modules by variety', async () => {
      setupAllMocks({ modules: [MODULE_CONFIG, MODULE_INSTANCE, MODULE_SUBSCRIPTION] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.modules.total).toBe(3);
      // MODULE_CONFIG is enabled; MODULE_INSTANCE is disabled; MODULE_SUBSCRIPTION is enabled
      expect(stats.modules.enabled).toBe(2);
      expect(stats.modules.by_variety.config).toBe(1);
      expect(stats.modules.by_variety.instance).toBe(1);
      expect(stats.modules.by_variety.subscription).toBe(1);
    });

    it('returns zeros for all module counts when no modules', async () => {
      setupAllMocks({ modules: [] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.modules.total).toBe(0);
      expect(stats.modules.enabled).toBe(0);
      expect(stats.modules.by_variety.config).toBe(0);
      expect(stats.modules.by_variety.instance).toBe(0);
      expect(stats.modules.by_variety.subscription).toBe(0);
    });
  });

  // ---------------------------------------------------------------------------
  // getOverviewStats — operations (tasks)
  // ---------------------------------------------------------------------------

  describe('getOverviewStats — operations', () => {
    it('counts operations by status correctly', async () => {
      // pending + scheduled → pending bucket; aborted → failed bucket
      setupAllMocks({
        tasks: [TASK_PENDING, TASK_SCHEDULED, TASK_RUNNING, TASK_COMPLETE, TASK_FAILED, TASK_ABORTED],
      });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.operations.total).toBe(6);
      expect(stats.operations.pending).toBe(2); // pending + scheduled
      expect(stats.operations.running).toBe(1);
      expect(stats.operations.completed).toBe(1); // complete
      expect(stats.operations.failed).toBe(2); // failed + aborted
    });

    it('returns zero operation counts when no tasks', async () => {
      setupAllMocks({ tasks: [] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.operations.total).toBe(0);
      expect(stats.operations.pending).toBe(0);
      expect(stats.operations.running).toBe(0);
      expect(stats.operations.completed).toBe(0);
      expect(stats.operations.failed).toBe(0);
    });
  });

  // ---------------------------------------------------------------------------
  // getOverviewStats — puppet modules
  // ---------------------------------------------------------------------------

  describe('getOverviewStats — puppet', () => {
    it('counts puppet module count and sums resource_count and assigned_modules_count', async () => {
      setupAllMocks({ puppetModules: [PUPPET_MODULE_A, PUPPET_MODULE_B] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.puppet.modules).toBe(2);
      expect(stats.puppet.resources).toBe(20); // 12 + 8
      expect(stats.puppet.assignments).toBe(5); // 3 + 2
    });

    it('handles puppet modules missing resource_count and assigned_modules_count', async () => {
      const barePuppet = {
        id: 'pup-bare',
        name: 'puppet-bare',
        enabled: true,
        public: false,
        dependencies: [],
        config: {},
        metadata: {},
        // resource_count and assigned_modules_count absent
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };
      setupAllMocks({ puppetModules: [barePuppet] });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.puppet.modules).toBe(1);
      expect(stats.puppet.resources).toBe(0);
      expect(stats.puppet.assignments).toBe(0);
    });
  });

  // ---------------------------------------------------------------------------
  // getOverviewStats — hardcoded volumes/networks
  // ---------------------------------------------------------------------------

  describe('getOverviewStats — volumes and networks', () => {
    it('always returns volumes total=0 and total_size_gb=0 (not yet fetched)', async () => {
      setupAllMocks();

      const stats = await overviewApi.getOverviewStats();

      expect(stats.volumes.total).toBe(0);
      expect(stats.volumes.total_size_gb).toBe(0);
    });

    it('always returns networks total=0 (not yet fetched)', async () => {
      setupAllMocks();

      const stats = await overviewApi.getOverviewStats();

      expect(stats.networks.total).toBe(0);
    });
  });

  // ---------------------------------------------------------------------------
  // getOverviewStats — SDWAN section
  // ---------------------------------------------------------------------------

  describe('getOverviewStats — sdwan', () => {
    it('counts sdwan networks, host bridges, ovn deployments, and ipfix collectors', async () => {
      setupAllMocks({
        sdwanNetworks: [SDWAN_NETWORK],
        sdwanHostBridges: [SDWAN_HOST_BRIDGE_LINUX, SDWAN_HOST_BRIDGE_OVS],
        sdwanOvnDeployments: [SDWAN_OVN_ACTIVE, SDWAN_OVN_PENDING],
        sdwanIpfixCollectors: [SDWAN_IPFIX_ACTIVE, SDWAN_IPFIX_DISABLED],
      });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.sdwan).toBeDefined();
      expect(stats.sdwan!.networks).toBe(1);
      expect(stats.sdwan!.host_bridges).toBe(2);
      expect(stats.sdwan!.bridges_by_kind.linux).toBe(1);
      expect(stats.sdwan!.bridges_by_kind.ovs).toBe(1);
      expect(stats.sdwan!.ovn_deployments).toBe(2);
      expect(stats.sdwan!.ovn_active).toBe(1); // only SDWAN_OVN_ACTIVE has status='active'
      expect(stats.sdwan!.ipfix_collectors).toBe(2);
      expect(stats.sdwan!.ipfix_active).toBe(1); // only SDWAN_IPFIX_ACTIVE has state='active'
    });

    it('gracefully handles SDWAN 403: softFetch returns zero counts', async () => {
      const permissionError = Object.assign(new Error('Forbidden'), { response: { status: 403 } });

      // First 7 succeed; all 4 SDWAN calls reject
      mockGet
        .mockResolvedValueOnce(paginatedEnvelope({ nodes: [] }, 0))
        .mockResolvedValueOnce(paginatedEnvelope({ node_templates: [] }, 0))
        .mockResolvedValueOnce(envelope({ node_platforms: [] }))
        .mockResolvedValueOnce(envelope({ providers: [] }))
        .mockResolvedValueOnce(paginatedEnvelope({ node_modules: [] }, 0))
        .mockResolvedValueOnce(paginatedEnvelope({ tasks: [] }, 0))
        .mockResolvedValueOnce(paginatedEnvelope({ puppet_modules: [] }, 0))
        .mockRejectedValueOnce(permissionError)   // sdwan/networks
        .mockRejectedValueOnce(permissionError)   // sdwan/host_bridges
        .mockRejectedValueOnce(permissionError)   // sdwan/ovn_deployments
        .mockRejectedValueOnce(permissionError);  // sdwan/ipfix_collectors

      const stats = await overviewApi.getOverviewStats();

      // softFetch swallows the errors and returns the fallback (empty arrays)
      expect(stats.sdwan!.networks).toBe(0);
      expect(stats.sdwan!.host_bridges).toBe(0);
      expect(stats.sdwan!.bridges_by_kind.linux).toBe(0);
      expect(stats.sdwan!.bridges_by_kind.ovs).toBe(0);
      expect(stats.sdwan!.ovn_deployments).toBe(0);
      expect(stats.sdwan!.ovn_active).toBe(0);
      expect(stats.sdwan!.ipfix_collectors).toBe(0);
      expect(stats.sdwan!.ipfix_active).toBe(0);
    });

    it('does NOT swallow errors from the main (non-SDWAN) endpoints', async () => {
      const serverError = Object.assign(new Error('Internal Server Error'), { response: { status: 500 } });

      mockGet.mockRejectedValueOnce(serverError);

      await expect(overviewApi.getOverviewStats()).rejects.toThrow('Internal Server Error');
    });

    it('handles empty SDWAN data (all zero counts)', async () => {
      setupAllMocks({
        sdwanNetworks: [],
        sdwanHostBridges: [],
        sdwanOvnDeployments: [],
        sdwanIpfixCollectors: [],
      });

      const stats = await overviewApi.getOverviewStats();

      expect(stats.sdwan!.networks).toBe(0);
      expect(stats.sdwan!.host_bridges).toBe(0);
      expect(stats.sdwan!.bridges_by_kind.linux).toBe(0);
      expect(stats.sdwan!.bridges_by_kind.ovs).toBe(0);
      expect(stats.sdwan!.ovn_deployments).toBe(0);
      expect(stats.sdwan!.ovn_active).toBe(0);
      expect(stats.sdwan!.ipfix_collectors).toBe(0);
      expect(stats.sdwan!.ipfix_active).toBe(0);
    });
  });

  // ---------------------------------------------------------------------------
  // getRecentActivity
  // ---------------------------------------------------------------------------

  describe('getRecentActivity', () => {
    it('calls /system/tasks with per_page=10 by default', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ tasks: [] }, 0));

      await overviewApi.getRecentActivity();

      expect(mockGet).toHaveBeenCalledWith('/system/tasks', { params: { per_page: 10 } });
    });

    it('calls /system/tasks with custom limit when provided', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ tasks: [] }, 0));

      await overviewApi.getRecentActivity(25);

      expect(mockGet).toHaveBeenCalledWith('/system/tasks', { params: { per_page: 25 } });
    });

    it('maps tasks to SystemRecentActivity shape', async () => {
      const task = {
        id: 'task-rca',
        command: 'node:provision',
        status: 'complete' as const,
        description: 'Provisioning node-42',
        progress: 100,
        exclusive: false,
        events: [],
        options: {},
        operable_type: 'SystemNode',
        operable_id: 'node-42',
        initiated_by_name: 'alice@example.com',
        created_at: '2026-06-01T12:00:00Z',
        updated_at: '2026-06-01T12:05:00Z',
      };
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ tasks: [task] }, 1));

      const activities = await overviewApi.getRecentActivity();

      expect(activities).toHaveLength(1);
      const act = activities[0];
      expect(act.id).toBe('task-rca');
      expect(act.type).toBe('operation');
      expect(act.action).toBe('node:provision');
      expect(act.description).toBe('Provisioning node-42');
      expect(act.status).toBe('complete');
      expect(act.entity_name).toBe('SystemNode');
      expect(act.entity_id).toBe('node-42');
      expect(act.initiated_by).toBe('alice@example.com');
      expect(act.timestamp).toBe('2026-06-01T12:00:00Z');
    });

    it('falls back to generated description when task.description is absent', async () => {
      const task = {
        id: 'task-nodesc',
        command: 'sync',
        status: 'running' as const,
        progress: 30,
        exclusive: false,
        events: [],
        options: {},
        // description: absent
        created_at: '2026-06-01T00:00:00Z',
        updated_at: '2026-06-01T00:00:00Z',
      };
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ tasks: [task] }, 1));

      const activities = await overviewApi.getRecentActivity();

      expect(activities[0].description).toBe('Operation: sync');
    });

    it('falls back to operable_type=System when operable_type is absent', async () => {
      const task = {
        id: 'task-notype',
        command: 'cleanup',
        status: 'complete' as const,
        progress: 100,
        exclusive: false,
        events: [],
        options: {},
        // operable_type: absent
        created_at: '2026-06-01T00:00:00Z',
        updated_at: '2026-06-01T00:00:00Z',
      };
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ tasks: [task] }, 1));

      const activities = await overviewApi.getRecentActivity();

      expect(activities[0].entity_name).toBe('System');
    });

    it('falls back entity_id to task id when operable_id is absent', async () => {
      const task = {
        id: 'task-noid',
        command: 'cleanup',
        status: 'complete' as const,
        progress: 100,
        exclusive: false,
        events: [],
        options: {},
        // operable_id: absent
        created_at: '2026-06-01T00:00:00Z',
        updated_at: '2026-06-01T00:00:00Z',
      };
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ tasks: [task] }, 1));

      const activities = await overviewApi.getRecentActivity();

      expect(activities[0].entity_id).toBe('task-noid');
    });

    it('returns an empty array when no tasks are returned', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ tasks: [] }, 0));

      const activities = await overviewApi.getRecentActivity();

      expect(activities).toEqual([]);
    });

    it('returns all activities matching the task count', async () => {
      const tasks = Array.from({ length: 5 }, (_, i) => ({
        id: `task-${i}`,
        command: `cmd-${i}`,
        status: 'complete' as const,
        progress: 100,
        exclusive: false,
        events: [],
        options: {},
        created_at: '2026-06-01T00:00:00Z',
        updated_at: '2026-06-01T00:00:00Z',
      }));
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ tasks }, tasks.length));

      const activities = await overviewApi.getRecentActivity();

      expect(activities).toHaveLength(5);
    });
  });
});
