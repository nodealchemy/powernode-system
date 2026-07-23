// Behavioral tests for the systemApi facade (systemApi.ts).
//
// The facade is a pure aggregator: it spreads 11 domain modules into a single
// object and re-exports the modules for direct import. There are no HTTP calls
// in the facade itself — HTTP happens inside each domain module. The tests
// therefore verify:
//
//   1. The facade object exposes every method from each domain module (spread
//      semantics are correct).
//   2. The packageRepositories and packages domains are namespaced, not spread
//      (avoiding method-name collisions).
//   3. Named re-exports are resolvable (each domain module is independently
//      importable via the named export).
//   4. The facade delegates to the underlying apiClient with the correct URLs
//      and payloads (behavioral contract verified through a representative
//      selection of methods spanning reads, writes, deletes, and actions).

import {
  systemApi,
  overviewApi,
  nodesApi,
  templatesApi,
  platformsApi,
  architecturesApi,
  scriptsApi,
  providersApi,
  modulesApi,
  tasksApi,
  puppetApi,
  packageRepositoriesApi,
  packagesApi,
  volumesApi,
  networksApi,
  unclaimedDevicesApi,
} from '@system/features/system/services/systemApi';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// =============================================================================
// Envelope helpers
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function paginatedEnvelope<T>(data: T, totalCount = 1) {
  return {
    data: {
      success: true,
      data,
      meta: {
        current_page: 1,
        per_page: 25,
        total_count: totalCount,
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

const NODE = {
  id: 'node-1',
  name: 'web-01',
  enabled: true,
  instance_count: 2,
  running_instances_count: 1,
};

const NODE_INSTANCE = {
  id: 'inst-1',
  name: 'web-01-a',
  variety: 'cloud' as const,
  status: 'running',
};

const TEMPLATE = {
  id: 'tpl-1',
  name: 'ubuntu-base',
  enabled: true,
  public: true,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PLATFORM = {
  id: 'plat-1',
  name: 'ubuntu-22.04',
  enabled: true,
};

const ARCH = {
  id: 'arch-1',
  name: 'x86_64',
  family: 'x86_64' as const,
  enabled: true,
};

const SCRIPT = {
  id: 'script-1',
  name: 'init-script',
  variety: 'init' as const,
  enabled: true,
};

const PROVIDER = {
  id: 'prov-1',
  name: 'hetzner',
  provider_type: 'hetzner',
  enabled: true,
};

const MODULE = {
  id: 'mod-1',
  name: 'nginx',
  variety: 'instance' as const,
  enabled: true,
};

const TASK = {
  id: 'task-1',
  command: 'provision',
  status: 'running',
  created_at: '2026-01-01T00:00:00Z',
};

const PUPPET_MODULE = {
  id: 'pup-1',
  name: 'apache',
  enabled: true,
  resource_count: 3,
  assigned_modules_count: 1,
};

const VOLUME = {
  id: 'vol-1',
  name: 'data-volume',
  size_gb: 20,
  status: 'available',
};

const NETWORK = {
  id: 'net-1',
  name: 'prod-net',
  enabled: true,
};

const PACKAGE_REPO = {
  id: 'repo-1',
  name: 'ubuntu-noble',
  kind: 'apt' as const,
  visibility: 'account' as const,
  base_url: 'http://example.com',
  architectures: ['amd64'],
  priority: 100,
  enabled: true,
  sync_status: 'idle' as const,
  package_count: 500,
  shared: false,
  node_platform_ids: [],
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PACKAGE = {
  id: 'pkg-1',
  name: 'nginx',
  version: '1.25.0',
  architecture: 'amd64',
  package_repository_id: 'repo-1',
};

const UNCLAIMED_DEVICE = {
  id: 'dev-1',
  mac_address: 'aa:bb:cc:dd:ee:ff',
  created_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Setup
// =============================================================================

beforeEach(() => {
  mockGet.mockReset();
  mockPost.mockReset();
  mockPut.mockReset();
  mockDelete.mockReset();
});

// =============================================================================
// 1. Structural: named re-exports are resolvable
// =============================================================================

describe('named re-exports', () => {
  it('exports each domain module under its own name', () => {
    expect(typeof overviewApi).toBe('object');
    expect(typeof nodesApi).toBe('object');
    expect(typeof templatesApi).toBe('object');
    expect(typeof platformsApi).toBe('object');
    expect(typeof architecturesApi).toBe('object');
    expect(typeof scriptsApi).toBe('object');
    expect(typeof providersApi).toBe('object');
    expect(typeof modulesApi).toBe('object');
    expect(typeof tasksApi).toBe('object');
    expect(typeof puppetApi).toBe('object');
    expect(typeof packageRepositoriesApi).toBe('object');
    expect(typeof packagesApi).toBe('object');
    expect(typeof volumesApi).toBe('object');
    expect(typeof networksApi).toBe('object');
    expect(typeof unclaimedDevicesApi).toBe('object');
  });
});

// =============================================================================
// 2. Structural: systemApi exposes spread methods + namespaced sub-objects
// =============================================================================

describe('systemApi structure', () => {
  it('exposes nodesApi methods directly (spread)', () => {
    expect(typeof systemApi.getNodes).toBe('function');
    expect(typeof systemApi.getNode).toBe('function');
    expect(typeof systemApi.createNode).toBe('function');
    expect(typeof systemApi.updateNode).toBe('function');
    expect(typeof systemApi.deleteNode).toBe('function');
    expect(typeof systemApi.getNodeInstances).toBe('function');
    expect(typeof systemApi.createNodeInstance).toBe('function');
    expect(typeof systemApi.startInstance).toBe('function');
    expect(typeof systemApi.stopInstance).toBe('function');
    expect(typeof systemApi.rebootInstance).toBe('function');
    expect(typeof systemApi.terminateInstance).toBe('function');
  });

  it('exposes templatesApi methods directly (spread)', () => {
    expect(typeof systemApi.getTemplates).toBe('function');
    expect(typeof systemApi.getTemplate).toBe('function');
    expect(typeof systemApi.createTemplate).toBe('function');
    expect(typeof systemApi.updateTemplate).toBe('function');
    expect(typeof systemApi.deleteTemplate).toBe('function');
    expect(typeof systemApi.getTemplateModules).toBe('function');
    expect(typeof systemApi.assignModuleToTemplate).toBe('function');
    expect(typeof systemApi.unassignModuleFromTemplate).toBe('function');
    expect(typeof systemApi.composePreview).toBe('function');
  });

  it('exposes platformsApi methods directly (spread)', () => {
    expect(typeof systemApi.getPlatforms).toBe('function');
    expect(typeof systemApi.createPlatform).toBe('function');
    expect(typeof systemApi.updatePlatform).toBe('function');
    expect(typeof systemApi.deletePlatform).toBe('function');
  });

  it('exposes architecturesApi methods directly (spread)', () => {
    expect(typeof systemApi.getArchitectures).toBe('function');
    expect(typeof systemApi.createArchitecture).toBe('function');
    expect(typeof systemApi.updateArchitecture).toBe('function');
    expect(typeof systemApi.deleteArchitecture).toBe('function');
  });

  it('exposes scriptsApi methods directly (spread)', () => {
    expect(typeof systemApi.getScripts).toBe('function');
    expect(typeof systemApi.createScript).toBe('function');
    expect(typeof systemApi.updateScript).toBe('function');
    expect(typeof systemApi.deleteScript).toBe('function');
  });

  it('exposes providersApi methods directly (spread)', () => {
    expect(typeof systemApi.getProviders).toBe('function');
    expect(typeof systemApi.createProvider).toBe('function');
    expect(typeof systemApi.getProviderRegions).toBe('function');
    expect(typeof systemApi.getProviderConnections).toBe('function');
    expect(typeof systemApi.testProviderConnection).toBe('function');
  });

  it('exposes modulesApi methods directly (spread)', () => {
    expect(typeof systemApi.getModules).toBe('function');
    expect(typeof systemApi.createModule).toBe('function');
    expect(typeof systemApi.updateModule).toBe('function');
    expect(typeof systemApi.getModuleCategories).toBe('function');
    expect(typeof systemApi.addModuleDependency).toBe('function');
    expect(typeof systemApi.markModuleAsCanary).toBe('function');
    expect(typeof systemApi.unmarkModuleAsCanary).toBe('function');
  });

  it('exposes tasksApi methods directly (spread)', () => {
    expect(typeof systemApi.getTasks).toBe('function');
    expect(typeof systemApi.getTask).toBe('function');
    expect(typeof systemApi.createTask).toBe('function');
    expect(typeof systemApi.cancelTask).toBe('function');
  });

  it('exposes puppetApi methods directly (spread)', () => {
    expect(typeof systemApi.getPuppetModules).toBe('function');
    expect(typeof systemApi.getPuppetModule).toBe('function');
    expect(typeof systemApi.createPuppetModule).toBe('function');
    expect(typeof systemApi.getPuppetResources).toBe('function');
    expect(typeof systemApi.getPuppetResourceDsl).toBe('function');
  });

  it('exposes volumesApi methods directly (spread)', () => {
    expect(typeof systemApi.getVolumes).toBe('function');
    expect(typeof systemApi.createVolume).toBe('function');
    expect(typeof systemApi.attachVolume).toBe('function');
    expect(typeof systemApi.detachVolume).toBe('function');
    expect(typeof systemApi.createVolumeSnapshot).toBe('function');
  });

  it('exposes networksApi methods directly (spread)', () => {
    expect(typeof systemApi.getNetworks).toBe('function');
    expect(typeof systemApi.createNetwork).toBe('function');
    expect(typeof systemApi.updateNetwork).toBe('function');
    expect(typeof systemApi.getNetworkSubnets).toBe('function');
  });

  it('namespaces packageRepositoriesApi under systemApi.packageRepositories', () => {
    expect(typeof systemApi.packageRepositories).toBe('object');
    expect(typeof systemApi.packageRepositories.list).toBe('function');
    expect(typeof systemApi.packageRepositories.get).toBe('function');
    expect(typeof systemApi.packageRepositories.create).toBe('function');
    expect(typeof systemApi.packageRepositories.update).toBe('function');
    expect(typeof systemApi.packageRepositories.delete).toBe('function');
    expect(typeof systemApi.packageRepositories.sync).toBe('function');
    expect(typeof systemApi.packageRepositories.linkPlatform).toBe('function');
    expect(typeof systemApi.packageRepositories.unlinkPlatform).toBe('function');
  });

  it('namespaces packagesApi under systemApi.packages', () => {
    expect(typeof systemApi.packages).toBe('object');
    expect(typeof systemApi.packages.search).toBe('function');
    expect(typeof systemApi.packages.discoverByIntent).toBe('function');
    expect(typeof systemApi.packages.get).toBe('function');
    expect(typeof systemApi.packages.resolveDependencies).toBe('function');
    expect(typeof systemApi.packages.createModuleFromPackage).toBe('function');
    expect(typeof systemApi.packages.suggestArchitectures).toBe('function');
  });

  it('does NOT spread packageRepositoriesApi.list directly onto systemApi', () => {
    // The list method must be accessed via systemApi.packageRepositories.list,
    // NOT systemApi.list — a spread would shadow other domain methods silently.
    expect((systemApi as Record<string, unknown>)['list']).toBeUndefined();
  });

  it('does NOT spread packagesApi.search directly onto systemApi', () => {
    expect((systemApi as Record<string, unknown>)['search']).toBeUndefined();
  });
});

// =============================================================================
// 3. Delegation: systemApi methods call the correct URLs + payloads
// =============================================================================

describe('nodesApi delegation', () => {
  it('getNodes: GET /system/nodes with params', async () => {
    mockGet.mockResolvedValue(paginatedEnvelope({ nodes: [NODE] }));
    const result = await systemApi.getNodes({ enabled: true });
    expect(mockGet).toHaveBeenCalledWith('/system/nodes', { params: { enabled: true } });
    expect(result.nodes).toHaveLength(1);
    expect(result.nodes[0].id).toBe('node-1');
    expect(result.meta.total_count).toBe(1);
  });

  it('getNode: GET /system/nodes/:id', async () => {
    mockGet.mockResolvedValue(envelope({ node: NODE }));
    const result = await systemApi.getNode('node-1');
    expect(mockGet).toHaveBeenCalledWith('/system/nodes/node-1');
    expect(result.id).toBe('node-1');
  });

  it('createNode: POST /system/nodes with wrapped payload', async () => {
    mockPost.mockResolvedValue(envelope({ node: NODE }));
    const result = await systemApi.createNode({ name: 'web-01' });
    expect(mockPost).toHaveBeenCalledWith('/system/nodes', { node: { name: 'web-01' } });
    expect(result.id).toBe('node-1');
  });

  it('updateNode: PUT /system/nodes/:id with wrapped payload', async () => {
    mockPut.mockResolvedValue(envelope({ node: { ...NODE, name: 'web-02' } }));
    const result = await systemApi.updateNode('node-1', { name: 'web-02' });
    expect(mockPut).toHaveBeenCalledWith('/system/nodes/node-1', { node: { name: 'web-02' } });
    expect(result.name).toBe('web-02');
  });

  it('deleteNode: DELETE /system/nodes/:id', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });
    await systemApi.deleteNode('node-1');
    expect(mockDelete).toHaveBeenCalledWith('/system/nodes/node-1');
  });

  it('getNodeInstances: GET /system/nodes/:nodeId/node_instances', async () => {
    mockGet.mockResolvedValue(envelope({ node_instances: [NODE_INSTANCE] }));
    const result = await systemApi.getNodeInstances('node-1');
    expect(mockGet).toHaveBeenCalledWith('/system/nodes/node-1/node_instances');
    expect(result.node_instances).toHaveLength(1);
    expect(result.node_instances[0].id).toBe('inst-1');
  });

  it('startInstance: POST /system/nodes/:nodeId/node_instances/:instanceId/start', async () => {
    mockPost.mockResolvedValue(envelope({ node_instance: { ...NODE_INSTANCE, status: 'running' } }));
    const result = await systemApi.startInstance('node-1', 'inst-1');
    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-1/node_instances/inst-1/start');
    expect(result.status).toBe('running');
  });

  it('stopInstance: POST /system/nodes/:nodeId/node_instances/:instanceId/stop', async () => {
    mockPost.mockResolvedValue(envelope({ node_instance: { ...NODE_INSTANCE, status: 'stopped' } }));
    await systemApi.stopInstance('node-1', 'inst-1');
    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-1/node_instances/inst-1/stop');
  });

  it('rebootInstance: POST /system/nodes/:nodeId/node_instances/:instanceId/reboot', async () => {
    mockPost.mockResolvedValue(envelope({ node_instance: NODE_INSTANCE }));
    await systemApi.rebootInstance('node-1', 'inst-1');
    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-1/node_instances/inst-1/reboot');
  });

  it('terminateInstance: POST /system/nodes/:nodeId/node_instances/:instanceId/terminate', async () => {
    mockPost.mockResolvedValue(envelope({ node_instance: NODE_INSTANCE }));
    await systemApi.terminateInstance('node-1', 'inst-1');
    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-1/node_instances/inst-1/terminate');
  });
});

describe('templatesApi delegation', () => {
  it('getTemplates: GET /system/node_templates with params, renames key to templates', async () => {
    mockGet.mockResolvedValue(paginatedEnvelope({ node_templates: [TEMPLATE] }));
    const result = await systemApi.getTemplates({ page: 1 });
    expect(mockGet).toHaveBeenCalledWith('/system/node_templates', { params: { page: 1 } });
    expect(result.templates).toHaveLength(1);
    expect(result.templates[0].id).toBe('tpl-1');
  });

  it('createTemplate: POST /system/node_templates with wrapped payload', async () => {
    mockPost.mockResolvedValue(envelope({ node_template: TEMPLATE }));
    const result = await systemApi.createTemplate({ name: 'ubuntu-base', enabled: true });
    expect(mockPost).toHaveBeenCalledWith('/system/node_templates', {
      node_template: { name: 'ubuntu-base', enabled: true },
    });
    expect(result.id).toBe('tpl-1');
  });

  it('assignModuleToTemplate: POST /system/node_templates/:id/modules', async () => {
    const assignment = { id: 'assign-1', node_template_id: 'tpl-1', node_module_id: 'mod-1', enabled: true, priority: 0 };
    mockPost.mockResolvedValue(envelope({ template_module: assignment }));
    const result = await systemApi.assignModuleToTemplate('tpl-1', 'mod-1');
    expect(mockPost).toHaveBeenCalledWith('/system/node_templates/tpl-1/modules', {
      node_module_id: 'mod-1',
    });
    expect(result.id).toBe('assign-1');
  });

  it('unassignModuleFromTemplate: DELETE /system/node_templates/:templateId/modules/:moduleId', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });
    await systemApi.unassignModuleFromTemplate('tpl-1', 'mod-1');
    expect(mockDelete).toHaveBeenCalledWith('/system/node_templates/tpl-1/modules/mod-1');
  });

  it('composePreview: POST /system/node_templates/compose_preview with module_ids', async () => {
    const preview = {
      modules: [],
      conflicts: [],
      footprint: { module_count: 0, estimated_package_count: 0, architectures: [] },
      dependency_graph: { nodes: [], edges: [] },
    };
    mockPost.mockResolvedValue(envelope(preview));
    const result = await systemApi.composePreview(['mod-1', 'mod-2']);
    expect(mockPost).toHaveBeenCalledWith('/system/node_templates/compose_preview', {
      module_ids: ['mod-1', 'mod-2'],
    });
    expect(result.conflicts).toHaveLength(0);
  });
});

describe('platformsApi delegation', () => {
  it('getPlatforms: GET /system/node_platforms', async () => {
    mockGet.mockResolvedValue(envelope({ node_platforms: [PLATFORM] }));
    const result = await systemApi.getPlatforms();
    expect(mockGet).toHaveBeenCalledWith('/system/node_platforms');
    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('plat-1');
  });

  it('createPlatform: POST /system/node_platforms with wrapped payload', async () => {
    mockPost.mockResolvedValue(envelope({ node_platform: PLATFORM }));
    await systemApi.createPlatform({ name: 'ubuntu-22.04' });
    expect(mockPost).toHaveBeenCalledWith('/system/node_platforms', {
      node_platform: { name: 'ubuntu-22.04' },
    });
  });

  it('deletePlatform: DELETE /system/node_platforms/:id', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });
    await systemApi.deletePlatform('plat-1');
    expect(mockDelete).toHaveBeenCalledWith('/system/node_platforms/plat-1');
  });
});

describe('architecturesApi delegation', () => {
  it('getArchitectures: GET /system/node_architectures with optional filters', async () => {
    mockGet.mockResolvedValue(envelope({ node_architectures: [ARCH] }));
    const result = await systemApi.getArchitectures({ family: 'x86_64', enabled: true });
    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', {
      params: { family: 'x86_64', enabled: 'true' },
    });
    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('arch-1');
  });

  it('getArchitectures: GET /system/node_architectures without filters', async () => {
    mockGet.mockResolvedValue(envelope({ node_architectures: [] }));
    await systemApi.getArchitectures();
    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', { params: {} });
  });

  it('createArchitecture: POST /system/node_architectures with wrapped payload', async () => {
    mockPost.mockResolvedValue(envelope({ node_architecture: ARCH }));
    await systemApi.createArchitecture({ name: 'x86_64', family: 'x86_64' });
    expect(mockPost).toHaveBeenCalledWith('/system/node_architectures', {
      node_architecture: { name: 'x86_64', family: 'x86_64' },
    });
  });

  it('deleteArchitecture: DELETE /system/node_architectures/:id', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });
    await systemApi.deleteArchitecture('arch-1');
    expect(mockDelete).toHaveBeenCalledWith('/system/node_architectures/arch-1');
  });
});

describe('scriptsApi delegation', () => {
  it('getScripts: GET /system/node_scripts', async () => {
    mockGet.mockResolvedValue(envelope({ node_scripts: [SCRIPT] }));
    const result = await systemApi.getScripts();
    expect(mockGet).toHaveBeenCalledWith('/system/node_scripts');
    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('script-1');
  });

  it('createScript: POST /system/node_scripts with wrapped payload', async () => {
    mockPost.mockResolvedValue(envelope({ node_script: SCRIPT }));
    await systemApi.createScript({ name: 'init-script', variety: 'init' });
    expect(mockPost).toHaveBeenCalledWith('/system/node_scripts', {
      node_script: { name: 'init-script', variety: 'init' },
    });
  });

  it('deleteScript: DELETE /system/node_scripts/:id', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });
    await systemApi.deleteScript('script-1');
    expect(mockDelete).toHaveBeenCalledWith('/system/node_scripts/script-1');
  });
});

describe('providersApi delegation', () => {
  it('getProviders: GET /system/providers', async () => {
    mockGet.mockResolvedValue(envelope({ providers: [PROVIDER] }));
    const result = await systemApi.getProviders();
    expect(mockGet).toHaveBeenCalledWith('/system/providers');
    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('prov-1');
  });

  it('createProvider: POST /system/providers with wrapped payload', async () => {
    mockPost.mockResolvedValue(envelope({ provider: PROVIDER }));
    await systemApi.createProvider({ name: 'hetzner', provider_type: 'hetzner' });
    expect(mockPost).toHaveBeenCalledWith('/system/providers', {
      provider: { name: 'hetzner', provider_type: 'hetzner' },
    });
  });

  it('deleteProvider: DELETE /system/providers/:id', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });
    await systemApi.deleteProvider('prov-1');
    expect(mockDelete).toHaveBeenCalledWith('/system/providers/prov-1');
  });

  it('getProviderRegions: GET /system/providers/:id/regions', async () => {
    const region = { id: 'reg-1', name: 'eu-central', region_code: 'euc1' };
    mockGet.mockResolvedValue(envelope({ regions: [region] }));
    const result = await systemApi.getProviderRegions('prov-1');
    expect(mockGet).toHaveBeenCalledWith('/system/providers/prov-1/regions');
    expect(result).toHaveLength(1);
  });

  it('testProviderConnection: POST /system/provider_connections/:id/test', async () => {
    mockPost.mockResolvedValue(envelope({ success: true, message: 'Connected' }));
    const result = await systemApi.testProviderConnection('conn-1');
    expect(mockPost).toHaveBeenCalledWith('/system/provider_connections/conn-1/test');
    expect(result.success).toBe(true);
  });

  it('getProviderInstanceTypes without providerId: GET /system/provider_instance_types', async () => {
    mockGet.mockResolvedValue(envelope({ instance_types: [] }));
    await systemApi.getProviderInstanceTypes();
    expect(mockGet).toHaveBeenCalledWith('/system/provider_instance_types');
  });

  it('getProviderInstanceTypes with providerId: GET /system/providers/:id/instance_types', async () => {
    mockGet.mockResolvedValue(envelope({ instance_types: [] }));
    await systemApi.getProviderInstanceTypes('prov-1');
    expect(mockGet).toHaveBeenCalledWith('/system/providers/prov-1/instance_types');
  });
});

describe('modulesApi delegation', () => {
  it('getModules: GET /system/node_modules with params, renames to modules', async () => {
    mockGet.mockResolvedValue(paginatedEnvelope({ node_modules: [MODULE] }));
    const result = await systemApi.getModules({ variety: 'instance' });
    expect(mockGet).toHaveBeenCalledWith('/system/node_modules', { params: { variety: 'instance' } });
    expect(result.modules).toHaveLength(1);
    expect(result.modules[0].id).toBe('mod-1');
  });

  it('createModule: POST /system/node_modules with wrapped payload', async () => {
    mockPost.mockResolvedValue(envelope({ node_module: MODULE }));
    await systemApi.createModule({ name: 'nginx', variety: 'instance' });
    expect(mockPost).toHaveBeenCalledWith('/system/node_modules', {
      node_module: { name: 'nginx', variety: 'instance' },
    });
  });

  it('deleteModule: DELETE /system/node_modules/:id', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });
    await systemApi.deleteModule('mod-1');
    expect(mockDelete).toHaveBeenCalledWith('/system/node_modules/mod-1');
  });

  it('getModuleCategories: GET /system/node_module_categories', async () => {
    mockGet.mockResolvedValue(envelope({ node_module_categories: [] }));
    await systemApi.getModuleCategories();
    expect(mockGet).toHaveBeenCalledWith('/system/node_module_categories');
  });

  it('addModuleDependency: POST /system/node_modules/:id/dependencies with dependency payload', async () => {
    mockPost.mockResolvedValue({ data: { success: true } });
    await systemApi.addModuleDependency('mod-1', 'mod-2', { required: true });
    expect(mockPost).toHaveBeenCalledWith('/system/node_modules/mod-1/dependencies', {
      module_dependency: { dependency_id: 'mod-2', required: true },
    });
  });

  it('removeModuleDependency: DELETE /system/node_modules/:id/dependencies/:depId', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });
    await systemApi.removeModuleDependency('mod-1', 'mod-2');
    expect(mockDelete).toHaveBeenCalledWith('/system/node_modules/mod-1/dependencies/mod-2');
  });

  it('markModuleAsCanary: POST /system/node_modules/:id/mark_canary with lure_kind', async () => {
    mockPost.mockResolvedValue(envelope({ node_module: { ...MODULE, config: { canary: true } } }));
    await systemApi.markModuleAsCanary('mod-1', 'honeypot');
    expect(mockPost).toHaveBeenCalledWith('/system/node_modules/mod-1/mark_canary', {
      lure_kind: 'honeypot',
    });
  });

  it('markModuleAsCanary: POST /system/node_modules/:id/mark_canary without lure_kind', async () => {
    mockPost.mockResolvedValue(envelope({ node_module: MODULE }));
    await systemApi.markModuleAsCanary('mod-1');
    expect(mockPost).toHaveBeenCalledWith('/system/node_modules/mod-1/mark_canary', {});
  });

  it('unmarkModuleAsCanary: POST /system/node_modules/:id/unmark_canary', async () => {
    mockPost.mockResolvedValue(envelope({ node_module: MODULE }));
    await systemApi.unmarkModuleAsCanary('mod-1');
    expect(mockPost).toHaveBeenCalledWith('/system/node_modules/mod-1/unmark_canary', {});
  });

  it('importManifest: POST /system/node_modules/:id/import_manifest with yaml + options', async () => {
    const importResult = {
      node_module: MODULE,
      node_module_version_id: 'ver-1',
      resolved_dependencies: [],
    };
    mockPost.mockResolvedValue(envelope(importResult));
    await systemApi.importManifest('mod-1', 'name: nginx\nversion: 1.0', {
      createVersion: true,
      changelog: 'initial',
    });
    expect(mockPost).toHaveBeenCalledWith('/system/node_modules/mod-1/import_manifest', {
      yaml: 'name: nginx\nversion: 1.0',
      create_version: true,
      changelog: 'initial',
    });
  });

  it('importManifest: defaults create_version to false when options omitted', async () => {
    mockPost.mockResolvedValue(envelope({
      node_module: MODULE,
      node_module_version_id: null,
      resolved_dependencies: [],
    }));
    await systemApi.importManifest('mod-1', 'name: nginx');
    expect(mockPost).toHaveBeenCalledWith('/system/node_modules/mod-1/import_manifest', {
      yaml: 'name: nginx',
      create_version: false,
      changelog: undefined,
    });
  });
});

describe('tasksApi delegation', () => {
  it('getTasks: GET /system/tasks with params', async () => {
    mockGet.mockResolvedValue(paginatedEnvelope({ tasks: [TASK] }));
    const result = await systemApi.getTasks({ status: 'running' });
    expect(mockGet).toHaveBeenCalledWith('/system/tasks', { params: { status: 'running' } });
    expect(result.tasks).toHaveLength(1);
    expect(result.tasks[0].id).toBe('task-1');
  });

  it('getTask: GET /system/tasks/:id', async () => {
    mockGet.mockResolvedValue(envelope({ task: TASK }));
    const result = await systemApi.getTask('task-1');
    expect(mockGet).toHaveBeenCalledWith('/system/tasks/task-1');
    expect(result.id).toBe('task-1');
  });

  it('createTask: POST /system/tasks with wrapped payload', async () => {
    mockPost.mockResolvedValue(envelope({ task: TASK }));
    await systemApi.createTask({ command: 'provision', description: 'boot node' });
    expect(mockPost).toHaveBeenCalledWith('/system/tasks', {
      task: { command: 'provision', description: 'boot node' },
    });
  });

  it('cancelTask: POST /system/tasks/:id/cancel with reason', async () => {
    mockPost.mockResolvedValue(envelope({ task: { ...TASK, status: 'aborted' } }));
    const result = await systemApi.cancelTask('task-1', 'user requested');
    expect(mockPost).toHaveBeenCalledWith('/system/tasks/task-1/cancel', { reason: 'user requested' });
    expect(result.status).toBe('aborted');
  });
});

describe('puppetApi delegation', () => {
  it('getPuppetModules: GET /system/puppet_modules with params, renames to puppetModules', async () => {
    mockGet.mockResolvedValue(paginatedEnvelope({ puppet_modules: [PUPPET_MODULE] }));
    const result = await systemApi.getPuppetModules({ page: 1 });
    expect(mockGet).toHaveBeenCalledWith('/system/puppet_modules', { params: { page: 1 } });
    expect(result.puppetModules).toHaveLength(1);
    expect(result.puppetModules[0].id).toBe('pup-1');
  });

  it('createPuppetModule: POST /system/puppet_modules with wrapped payload', async () => {
    mockPost.mockResolvedValue(envelope({ puppet_module: PUPPET_MODULE }));
    await systemApi.createPuppetModule({ name: 'apache' });
    expect(mockPost).toHaveBeenCalledWith('/system/puppet_modules', {
      puppet_module: { name: 'apache' },
    });
  });

  it('getPuppetResources: GET /system/puppet_modules/:id/puppet_resources', async () => {
    const res = { id: 'res-1', name: 'file-a', resource_type: 'file', enabled: true };
    mockGet.mockResolvedValue(envelope({ puppet_resources: [res] }));
    const result = await systemApi.getPuppetResources('pup-1');
    expect(mockGet).toHaveBeenCalledWith('/system/puppet_modules/pup-1/puppet_resources');
    expect(result).toHaveLength(1);
  });

  it('getPuppetResourceDsl: GET /system/puppet_modules/:id/puppet_resources/:rid/puppet_dsl', async () => {
    mockGet.mockResolvedValue(envelope({ puppet_dsl: 'file { "/etc/nginx.conf": }' }));
    const result = await systemApi.getPuppetResourceDsl('pup-1', 'res-1');
    expect(mockGet).toHaveBeenCalledWith(
      '/system/puppet_modules/pup-1/puppet_resources/res-1/puppet_dsl'
    );
    expect(result).toBe('file { "/etc/nginx.conf": }');
  });

  it('getPuppetModuleAssignments: GET /system/puppet_modules/:id/assignments', async () => {
    mockGet.mockResolvedValue(envelope({ assignments: [] }));
    await systemApi.getPuppetModuleAssignments('pup-1');
    expect(mockGet).toHaveBeenCalledWith('/system/puppet_modules/pup-1/assignments');
  });
});

describe('volumesApi delegation', () => {
  it('getVolumes: GET /system/provider_volumes with params', async () => {
    mockGet.mockResolvedValue(paginatedEnvelope({ volumes: [VOLUME] }));
    const result = await systemApi.getVolumes({ status: 'available' });
    expect(mockGet).toHaveBeenCalledWith('/system/provider_volumes', { params: { status: 'available' } });
    expect(result.volumes).toHaveLength(1);
    expect(result.volumes[0].id).toBe('vol-1');
  });

  it('createVolume: POST /system/provider_volumes with wrapped payload', async () => {
    mockPost.mockResolvedValue(envelope({ volume: VOLUME }));
    await systemApi.createVolume({ name: 'data-volume', size_gb: 20 });
    expect(mockPost).toHaveBeenCalledWith('/system/provider_volumes', {
      volume: { name: 'data-volume', size_gb: 20 },
    });
  });

  it('attachVolume: POST /system/provider_volumes/:id/attach with node_instance_id', async () => {
    mockPost.mockResolvedValue(envelope({ volume: { ...VOLUME, status: 'in-use' } }));
    await systemApi.attachVolume('vol-1', 'inst-1', '/dev/sdb');
    expect(mockPost).toHaveBeenCalledWith('/system/provider_volumes/vol-1/attach', {
      node_instance_id: 'inst-1',
      device_name: '/dev/sdb',
    });
  });

  it('detachVolume: POST /system/provider_volumes/:id/detach', async () => {
    mockPost.mockResolvedValue(envelope({ volume: VOLUME }));
    await systemApi.detachVolume('vol-1');
    expect(mockPost).toHaveBeenCalledWith('/system/provider_volumes/vol-1/detach');
  });

  it('createVolumeSnapshot: POST /system/provider_volumes/:id/snapshot with name and description', async () => {
    const snap = { id: 'snap-1', name: 'daily', status: 'pending', created_at: '2026-01-01T00:00:00Z' };
    mockPost.mockResolvedValue(envelope({ snapshot: snap }));
    const result = await systemApi.createVolumeSnapshot('vol-1', 'daily', 'nightly backup');
    expect(mockPost).toHaveBeenCalledWith('/system/provider_volumes/vol-1/snapshot', {
      name: 'daily',
      description: 'nightly backup',
    });
    expect(result.id).toBe('snap-1');
  });
});

describe('networksApi delegation', () => {
  it('getNetworks: GET /system/provider_networks with params', async () => {
    mockGet.mockResolvedValue(paginatedEnvelope({ networks: [NETWORK] }));
    const result = await systemApi.getNetworks({ search: 'prod' });
    expect(mockGet).toHaveBeenCalledWith('/system/provider_networks', { params: { search: 'prod' } });
    expect(result.networks).toHaveLength(1);
    expect(result.networks[0].id).toBe('net-1');
  });

  it('createNetwork: POST /system/provider_networks with wrapped payload', async () => {
    mockPost.mockResolvedValue(envelope({ network: NETWORK }));
    await systemApi.createNetwork({
      name: 'prod-net',
      provider_region_id: 'reg-1',
      cidr_block: '10.0.0.0/16',
    });
    expect(mockPost).toHaveBeenCalledWith('/system/provider_networks', {
      network: {
        name: 'prod-net',
        provider_region_id: 'reg-1',
        cidr_block: '10.0.0.0/16',
      },
    });
  });

  it('deleteNetwork: DELETE /system/provider_networks/:id', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });
    await systemApi.deleteNetwork('net-1');
    expect(mockDelete).toHaveBeenCalledWith('/system/provider_networks/net-1');
  });

  it('getNetworkSubnets: GET /system/provider_networks/:id/provider_network_subnets without az filter', async () => {
    mockGet.mockResolvedValue(envelope({ subnets: [] }));
    await systemApi.getNetworkSubnets('net-1');
    expect(mockGet).toHaveBeenCalledWith('/system/provider_networks/net-1/provider_network_subnets', { params: {} });
  });

  it('getNetworkSubnets: GET /system/provider_networks/:id/provider_network_subnets with az filter', async () => {
    mockGet.mockResolvedValue(envelope({ subnets: [] }));
    await systemApi.getNetworkSubnets('net-1', 'az-1');
    expect(mockGet).toHaveBeenCalledWith('/system/provider_networks/net-1/provider_network_subnets', {
      params: { availability_zone_id: 'az-1' },
    });
  });
});

describe('packageRepositoriesApi delegation (via systemApi.packageRepositories)', () => {
  it('list: GET /system/package_repositories with optional params', async () => {
    mockGet.mockResolvedValue(envelope({ package_repositories: [PACKAGE_REPO] }));
    const result = await systemApi.packageRepositories.list({ kind: 'apt' });
    expect(mockGet).toHaveBeenCalledWith('/system/package_repositories', { params: { kind: 'apt' } });
    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('repo-1');
  });

  it('get: GET /system/package_repositories/:id', async () => {
    mockGet.mockResolvedValue(envelope({ package_repository: PACKAGE_REPO }));
    const result = await systemApi.packageRepositories.get('repo-1');
    expect(mockGet).toHaveBeenCalledWith('/system/package_repositories/repo-1');
    expect(result.id).toBe('repo-1');
  });

  it('create: POST /system/package_repositories with wrapped payload', async () => {
    mockPost.mockResolvedValue(envelope({ package_repository: PACKAGE_REPO }));
    await systemApi.packageRepositories.create({
      name: 'ubuntu-noble',
      kind: 'apt',
      base_url: 'http://example.com',
    });
    expect(mockPost).toHaveBeenCalledWith('/system/package_repositories', {
      package_repository: {
        name: 'ubuntu-noble',
        kind: 'apt',
        base_url: 'http://example.com',
      },
    });
  });

  it('sync: POST /system/package_repositories/:id/sync', async () => {
    const syncResult = { ok: true, upserted: 50, obsoleted: 2, package_count: 500 };
    mockPost.mockResolvedValue(envelope(syncResult));
    const result = await systemApi.packageRepositories.sync('repo-1');
    expect(mockPost).toHaveBeenCalledWith('/system/package_repositories/repo-1/sync', {});
    expect(result.ok).toBe(true);
    expect(result.upserted).toBe(50);
  });

  it('linkPlatform: POST /system/package_repositories/:id/link_platform', async () => {
    const linkResult = { package_repository_id: 'repo-1', node_platform_id: 'plat-1', linked: true };
    mockPost.mockResolvedValue(envelope(linkResult));
    const result = await systemApi.packageRepositories.linkPlatform('repo-1', 'plat-1');
    expect(mockPost).toHaveBeenCalledWith('/system/package_repositories/repo-1/link_platform', {
      node_platform_id: 'plat-1',
    });
    expect(result.linked).toBe(true);
  });

  it('unlinkPlatform: DELETE /system/package_repositories/:id/unlink_platform with body', async () => {
    const unlinkResult = { package_repository_id: 'repo-1', node_platform_id: 'plat-1', linked: false };
    mockDelete.mockResolvedValue(envelope(unlinkResult));
    const result = await systemApi.packageRepositories.unlinkPlatform('repo-1', 'plat-1');
    expect(mockDelete).toHaveBeenCalledWith('/system/package_repositories/repo-1/unlink_platform', {
      data: { node_platform_id: 'plat-1' },
    });
    expect(result.linked).toBe(false);
  });

  it('delete: DELETE /system/package_repositories/:id', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });
    await systemApi.packageRepositories.delete('repo-1');
    expect(mockDelete).toHaveBeenCalledWith('/system/package_repositories/repo-1');
  });
});

describe('packagesApi delegation (via systemApi.packages)', () => {
  it('search: GET /system/packages with params, flattens meta into result', async () => {
    const responseData = {
      packages: [PACKAGE],
      meta: {
        total: 1,
        page: 1,
        per_page: 25,
        mode: 'lexical' as const,
        applied_filters: {},
      },
    };
    mockGet.mockResolvedValue(envelope(responseData));
    const result = await systemApi.packages.search({ q: 'nginx', mode: 'lexical' });
    expect(mockGet).toHaveBeenCalledWith('/system/packages', {
      params: { q: 'nginx', mode: 'lexical' },
    });
    expect(result.packages).toHaveLength(1);
    expect(result.total).toBe(1);
    expect(result.mode).toBe('lexical');
  });

  it('get: GET /system/packages/:id', async () => {
    mockGet.mockResolvedValue(envelope({ package: PACKAGE }));
    const result = await systemApi.packages.get('pkg-1');
    expect(mockGet).toHaveBeenCalledWith('/system/packages/pkg-1');
    expect(result.id).toBe('pkg-1');
  });

  it('discoverByIntent: POST /system/packages/discover with intent params', async () => {
    const discoverResult = {
      intent: 'reverse proxy',
      results: [],
      seed_count: 0,
      confidence: 'low' as const,
    };
    mockPost.mockResolvedValue(envelope(discoverResult));
    await systemApi.packages.discoverByIntent({ intent: 'reverse proxy', top_k: 10 });
    expect(mockPost).toHaveBeenCalledWith('/system/packages/discover', {
      intent: 'reverse proxy',
      top_k: 10,
    });
  });

  it('resolveDependencies: POST /system/packages/resolve_dependencies', async () => {
    const preview = {
      required_packages: [],
      required_edges: [],
      recommends_candidates: [],
      suggests_candidates: [],
      alternatives_chosen: {},
      warnings: [],
      errors: [],
    };
    mockPost.mockResolvedValue(envelope(preview));
    await systemApi.packages.resolveDependencies({
      repository_id: 'repo-1',
      package_name: 'nginx',
      architecture: 'amd64',
    });
    expect(mockPost).toHaveBeenCalledWith('/system/packages/resolve_dependencies', {
      repository_id: 'repo-1',
      package_name: 'nginx',
      architecture: 'amd64',
    });
  });

  it('createModuleFromPackage: POST /system/packages/create_module', async () => {
    const moduleResult = {
      top_level_module: { id: 'mod-new', name: 'nginx', auto_generated: true, public: false },
      dependency_modules: [],
      recommends_modules: [],
      dependencies_created: 0,
      build_dispatches: [],
      warnings: [],
    };
    mockPost.mockResolvedValue(envelope(moduleResult));
    await systemApi.packages.createModuleFromPackage({
      repository_id: 'repo-1',
      package_name: 'nginx',
      architectures: ['amd64'],
    });
    expect(mockPost).toHaveBeenCalledWith('/system/packages/create_module', {
      repository_id: 'repo-1',
      package_name: 'nginx',
      architectures: ['amd64'],
    });
  });

  it('suggestArchitectures: POST /system/packages/suggest_architectures', async () => {
    const suggestion = {
      repository_id: 'repo-1',
      suggested: ['amd64'],
      rationale: [],
      fallback: false,
      confidence: 'high' as const,
    };
    mockPost.mockResolvedValue(envelope(suggestion));
    const result = await systemApi.packages.suggestArchitectures({
      repository_id: 'repo-1',
      max_suggestions: 3,
    });
    expect(mockPost).toHaveBeenCalledWith('/system/packages/suggest_architectures', {
      repository_id: 'repo-1',
      max_suggestions: 3,
    });
    expect(result.suggested).toContain('amd64');
  });
});

describe('unclaimedDevicesApi delegation', () => {
  it('list: GET /system/unclaimed_devices with params, renames devices', async () => {
    mockGet.mockResolvedValue(paginatedEnvelope({ unclaimed_devices: [UNCLAIMED_DEVICE] }));
    const result = await unclaimedDevicesApi.list({ page: 1 });
    expect(mockGet).toHaveBeenCalledWith('/system/unclaimed_devices', { params: { page: 1 } });
    expect(result.devices).toHaveLength(1);
    expect(result.devices[0].id).toBe('dev-1');
  });

  it('claim: POST /system/unclaimed_devices/:id/claim with node_instance_id', async () => {
    const claimResp = {
      unclaimed_device: UNCLAIMED_DEVICE,
      node_instance_id: 'inst-1',
      node_instance_name: 'web-01-a',
    };
    mockPost.mockResolvedValue(envelope(claimResp));
    const result = await unclaimedDevicesApi.claim('dev-1', 'inst-1');
    expect(mockPost).toHaveBeenCalledWith('/system/unclaimed_devices/dev-1/claim', {
      node_instance_id: 'inst-1',
    });
    expect(result.node_instance_id).toBe('inst-1');
  });

  it('discard: DELETE /system/unclaimed_devices/:id', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });
    await unclaimedDevicesApi.discard('dev-1');
    expect(mockDelete).toHaveBeenCalledWith('/system/unclaimed_devices/dev-1');
  });
});

// =============================================================================
// 4. overviewApi getOverviewStats aggregates multiple parallel requests
// =============================================================================

describe('overviewApi.getOverviewStats', () => {
  it('fires parallel requests for all catalog endpoints and aggregates counts', async () => {
    // Nodes: 1 enabled, 0 disabled; 2 instances total, 1 running
    const nodeWithCounts = { ...NODE, enabled: true, instance_count: 2, running_instances_count: 1 };
    // Template: public
    const tpl = { ...TEMPLATE, public: true };
    // Platform: enabled
    const plat = { ...PLATFORM, enabled: true };
    // Provider: enabled, no regions
    const prov = { ...PROVIDER, enabled: true, region_count: 0 };
    // Module: enabled, instance variety
    const mod = { ...MODULE, enabled: true, variety: 'instance' as const };
    // Tasks: one running
    const task = { ...TASK, status: 'running' };
    // Puppet modules
    const pup = { ...PUPPET_MODULE, resource_count: 3, assigned_modules_count: 1 };

    mockGet
      .mockResolvedValueOnce(paginatedEnvelope({ nodes: [nodeWithCounts] }))           // /system/nodes
      .mockResolvedValueOnce(paginatedEnvelope({ node_templates: [tpl] }))              // /system/node_templates
      .mockResolvedValueOnce(envelope({ node_platforms: [plat] }))                     // /system/node_platforms
      .mockResolvedValueOnce(envelope({ providers: [prov] }))                          // /system/providers
      .mockResolvedValueOnce(paginatedEnvelope({ node_modules: [mod] }))               // /system/node_modules
      .mockResolvedValueOnce(paginatedEnvelope({ tasks: [task] }))                     // /system/tasks
      .mockResolvedValueOnce(paginatedEnvelope({ puppet_modules: [pup] }))             // /system/puppet_modules
      .mockResolvedValueOnce(paginatedEnvelope({ networks: [] }))                      // sdwan/networks
      .mockResolvedValueOnce(envelope({ host_bridges: [] }))                           // sdwan/host_bridges
      .mockResolvedValueOnce(envelope({ ovn_deployments: [] }))                        // sdwan/ovn_deployments
      .mockResolvedValueOnce(envelope({ ipfix_collectors: [] }));                      // sdwan/ipfix_collectors

    const stats = await systemApi.getOverviewStats();

    expect(stats.nodes.total).toBe(1);
    expect(stats.nodes.enabled).toBe(1);
    expect(stats.nodes.disabled).toBe(0);
    expect(stats.instances.total).toBe(2);
    expect(stats.instances.running).toBe(1);
    expect(stats.templates.total).toBe(1);
    expect(stats.templates.public).toBe(1);
    expect(stats.platforms.total).toBe(1);
    expect(stats.providers.total).toBe(1);
    expect(stats.modules.total).toBe(1);
    expect(stats.modules.by_variety.instance).toBe(1);
    expect(stats.operations.running).toBe(1);
    expect(stats.puppet.modules).toBe(1);
    expect(stats.sdwan.networks).toBe(0);
  });

  it('returns zero SDWAN counts when SDWAN endpoints reject (permission-gated)', async () => {
    mockGet
      .mockResolvedValueOnce(paginatedEnvelope({ nodes: [] }))
      .mockResolvedValueOnce(paginatedEnvelope({ node_templates: [] }))
      .mockResolvedValueOnce(envelope({ node_platforms: [] }))
      .mockResolvedValueOnce(envelope({ providers: [] }))
      .mockResolvedValueOnce(paginatedEnvelope({ node_modules: [] }))
      .mockResolvedValueOnce(paginatedEnvelope({ tasks: [] }))
      .mockResolvedValueOnce(paginatedEnvelope({ puppet_modules: [] }))
      .mockRejectedValueOnce(new Error('403 Forbidden'))   // sdwan/networks
      .mockRejectedValueOnce(new Error('403 Forbidden'))   // sdwan/host_bridges
      .mockRejectedValueOnce(new Error('403 Forbidden'))   // sdwan/ovn_deployments
      .mockRejectedValueOnce(new Error('403 Forbidden')); // sdwan/ipfix_collectors

    const stats = await systemApi.getOverviewStats();

    expect(stats.sdwan.networks).toBe(0);
    expect(stats.sdwan.host_bridges).toBe(0);
    expect(stats.sdwan.ovn_deployments).toBe(0);
    expect(stats.sdwan.ipfix_collectors).toBe(0);
  });
});

describe('overviewApi.getRecentActivity', () => {
  it('GET /system/tasks with per_page, maps tasks to activity records', async () => {
    const task = {
      id: 'task-1',
      command: 'provision',
      description: 'Provision web-01',
      status: 'complete',
      operable_type: 'SystemNode',
      operable_id: 'node-1',
      initiated_by_name: 'admin',
      created_at: '2026-01-01T00:00:00Z',
    };
    mockGet.mockResolvedValue(paginatedEnvelope({ tasks: [task] }));

    const activity = await systemApi.getRecentActivity(5);

    expect(mockGet).toHaveBeenCalledWith('/system/tasks', { params: { per_page: 5 } });
    expect(activity).toHaveLength(1);
    expect(activity[0].id).toBe('task-1');
    expect(activity[0].type).toBe('operation');
    expect(activity[0].action).toBe('provision');
    expect(activity[0].status).toBe('complete');
    expect(activity[0].entity_name).toBe('SystemNode');
  });

  it('defaults per_page to 10 when limit is omitted', async () => {
    mockGet.mockResolvedValue(paginatedEnvelope({ tasks: [] }));
    await systemApi.getRecentActivity();
    expect(mockGet).toHaveBeenCalledWith('/system/tasks', { params: { per_page: 10 } });
  });
});
