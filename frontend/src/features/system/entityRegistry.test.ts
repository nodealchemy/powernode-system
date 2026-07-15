// Unit tests for entityRegistry.ts
// Covers: registerSystemEntities() registration shape, mode classification,
// fetchById delegates, composite id validation; resolveOperableType() mapping.

// =============================================================================
// Mock all component imports — they are React FCs; we only care that they are
// passed through as-is (or cast). Use jest.fn() so instanceof checks pass.
// =============================================================================

jest.mock('@system/features/system/components/nodes/NodeDetailModal', () => ({
  NodeDetailModal: jest.fn(),
}));
jest.mock('@system/features/system/components/templates/TemplateDetailModal', () => ({
  TemplateDetailModal: jest.fn(),
}));
jest.mock('@system/features/system/components/modules/ModuleDetailModal', () => ({
  ModuleDetailModal: jest.fn(),
}));
// Provider NetworkDetailModal (different from SDWAN one)
jest.mock('@system/features/system/components/networks/NetworkDetailModal', () => ({
  NetworkDetailModal: jest.fn(),
}));
jest.mock('@system/features/system/components/volumes/VolumeDetailModal', () => ({
  VolumeDetailModal: jest.fn(),
}));
jest.mock('@system/features/system/components/operations/OperationDetailModal', () => ({
  OperationDetailModal: jest.fn(),
}));
// SDWAN NetworkDetailModal — different module path
jest.mock('@system/features/system/components/sdwan/NetworkDetailModal', () => ({
  NetworkDetailModal: jest.fn(),
}));

// =============================================================================
// Mock all API service clients
// =============================================================================

const mockNodesApiGetNodeInstance = jest.fn();
const mockPlatformsApiGetPlatform = jest.fn();
const mockArchitecturesApiGetArchitecture = jest.fn();
const mockModulesApiGetModuleCategory = jest.fn();
const mockProvidersApiGetProvider = jest.fn();
const mockSdwanApiGetNetwork = jest.fn();
const mockSdwanApiGetHostBridge = jest.fn();
const mockSdwanApiGetOvnDeployment = jest.fn();
const mockSdwanApiGetIpfixCollector = jest.fn();
const mockSdwanApiGetVirtualIp = jest.fn();
const mockSdwanApiGetRoutePolicy = jest.fn();
const mockAcmeCertificatesApiGet = jest.fn();
const mockAcmeDnsCredentialsApiGet = jest.fn();
const mockCiWorkersApiGet = jest.fn();
const mockCveApiGet = jest.fn();
const mockGitopsApiGet = jest.fn();
const mockStorageMigrationsApiGet = jest.fn();
const mockPlatformPeersApiGetPeer = jest.fn();
const mockModuleBuildsApiGet = jest.fn();

jest.mock('@system/features/system/services/api/nodesApi', () => ({
  nodesApi: { getNodeInstance: (...a: unknown[]) => mockNodesApiGetNodeInstance(...a) },
}));
jest.mock('@system/features/system/services/api/platformsApi', () => ({
  platformsApi: { getPlatform: (...a: unknown[]) => mockPlatformsApiGetPlatform(...a) },
}));
jest.mock('@system/features/system/services/api/architecturesApi', () => ({
  architecturesApi: { getArchitecture: (...a: unknown[]) => mockArchitecturesApiGetArchitecture(...a) },
}));
jest.mock('@system/features/system/services/api/modulesApi', () => ({
  modulesApi: { getModuleCategory: (...a: unknown[]) => mockModulesApiGetModuleCategory(...a) },
}));
jest.mock('@system/features/system/services/api/providersApi', () => ({
  providersApi: { getProvider: (...a: unknown[]) => mockProvidersApiGetProvider(...a) },
}));
jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    getNetwork: (...a: unknown[]) => mockSdwanApiGetNetwork(...a),
    getHostBridge: (...a: unknown[]) => mockSdwanApiGetHostBridge(...a),
    getOvnDeployment: (...a: unknown[]) => mockSdwanApiGetOvnDeployment(...a),
    getIpfixCollector: (...a: unknown[]) => mockSdwanApiGetIpfixCollector(...a),
    getVirtualIp: (...a: unknown[]) => mockSdwanApiGetVirtualIp(...a),
    getRoutePolicy: (...a: unknown[]) => mockSdwanApiGetRoutePolicy(...a),
  },
}));
jest.mock('@system/features/system/services/api/acmeCertificatesApi', () => ({
  acmeCertificatesApi: { get: (...a: unknown[]) => mockAcmeCertificatesApiGet(...a) },
}));
jest.mock('@system/features/system/services/api/acmeDnsCredentialsApi', () => ({
  acmeDnsCredentialsApi: { get: (...a: unknown[]) => mockAcmeDnsCredentialsApiGet(...a) },
}));
jest.mock('@system/features/system/services/api/ciWorkersApi', () => ({
  ciWorkersApi: { get: (...a: unknown[]) => mockCiWorkersApiGet(...a) },
}));
jest.mock('@system/features/system/services/api/cveApi', () => ({
  cveApi: { get: (...a: unknown[]) => mockCveApiGet(...a) },
}));
jest.mock('@system/features/system/services/api/gitopsApi', () => ({
  gitopsApi: { get: (...a: unknown[]) => mockGitopsApiGet(...a) },
}));
jest.mock('@system/features/system/services/api/storageMigrationsApi', () => ({
  storageMigrationsApi: { get: (...a: unknown[]) => mockStorageMigrationsApiGet(...a) },
}));
jest.mock('@system/features/system/services/api/platformPeersApi', () => ({
  platformPeersApi: { getPeer: (...a: unknown[]) => mockPlatformPeersApiGetPeer(...a) },
}));
jest.mock('@system/features/system/services/api/moduleBuildsApi', () => ({
  moduleBuildsApi: { get: (...a: unknown[]) => mockModuleBuildsApiGet(...a) },
}));

// =============================================================================
// Import subjects under test — AFTER mocks are declared
// =============================================================================

import { entityRegistry } from '@/shared/services/entityRegistry';
import { registerSystemEntities, resolveOperableType } from './entityRegistry';

// =============================================================================
// Helpers
// =============================================================================

/** Run once, clear registry before each test to prevent cross-test leakage. */
beforeEach(() => {
  entityRegistry.clear();

  mockNodesApiGetNodeInstance.mockReset();
  mockPlatformsApiGetPlatform.mockReset();
  mockArchitecturesApiGetArchitecture.mockReset();
  mockModulesApiGetModuleCategory.mockReset();
  mockProvidersApiGetProvider.mockReset();
  mockSdwanApiGetNetwork.mockReset();
  mockSdwanApiGetHostBridge.mockReset();
  mockSdwanApiGetOvnDeployment.mockReset();
  mockSdwanApiGetIpfixCollector.mockReset();
  mockSdwanApiGetVirtualIp.mockReset();
  mockSdwanApiGetRoutePolicy.mockReset();
  mockAcmeCertificatesApiGet.mockReset();
  mockAcmeDnsCredentialsApiGet.mockReset();
  mockCiWorkersApiGet.mockReset();
  mockCveApiGet.mockReset();
  mockGitopsApiGet.mockReset();
  mockStorageMigrationsApiGet.mockReset();
  mockPlatformPeersApiGetPeer.mockReset();
  mockModuleBuildsApiGet.mockReset();
});

// =============================================================================
// registerSystemEntities — registration shape
// =============================================================================

describe('registerSystemEntities()', () => {
  describe('registration', () => {
    beforeEach(() => {
      registerSystemEntities();
    });

    it('registers entities under the "system" owner', () => {
      expect(entityRegistry.getRegisteredOwners()).toContain('system');
    });

    it('registers all expected entity types', () => {
      const expectedTypes = [
        'node',
        'node_template',
        'node_module',
        'provider_network',
        'provider_volume',
        'system_task',
        'sdwan_network',
        'node_platform',
        'node_architecture',
        'node_module_category',
        'provider',
        'node_instance',
        'acme_certificate',
        'acme_dns_credential',
        'ci_worker',
        'cve',
        'gitops_repository',
        'storage_migration',
        'platform_peer',
        'sdwan_host_bridge',
        'sdwan_ovn_deployment',
        'sdwan_ipfix_collector',
        'sdwan_virtual_ip',
        'sdwan_route_policy',
        'module_build_batch',
      ];
      for (const type of expectedTypes) {
        expect(entityRegistry.hasEntity(type)).toBe(true);
      }
    });

    it('exposes 25 total registered types', () => {
      expect(entityRegistry.getEntities('system')).toHaveLength(25);
    });

    it('is idempotent — calling twice does not corrupt the registry (last write wins)', () => {
      registerSystemEntities();
      // The "system" owner list will have 50 entries (2 × 25) but the byType
      // map still holds exactly 25 unique keys.
      expect(entityRegistry.getEntities().length).toBe(25);
    });
  });

  // --- Mode 1: id-prop modals (bespoke, self-fetching) ---------------------

  describe('mode 1 — id-prop modal entities', () => {
    const idPropCases: Array<{ type: string; idProp: string; permission: string; icon: string }> = [
      { type: 'node', idProp: 'nodeId', permission: 'system.nodes.read', icon: 'Server' },
      { type: 'node_template', idProp: 'templateId', permission: 'system.templates.read', icon: 'LayoutTemplate' },
      { type: 'node_module', idProp: 'moduleId', permission: 'system.modules.read', icon: 'Package' },
      { type: 'provider_network', idProp: 'networkId', permission: 'system.networks.read', icon: 'Network' },
      { type: 'provider_volume', idProp: 'volumeId', permission: 'system.volumes.read', icon: 'HardDrive' },
      { type: 'system_task', idProp: 'operationId', permission: 'system.infra_tasks.read', icon: 'Activity' },
    ];

    beforeEach(() => {
      registerSystemEntities();
    });

    it.each(idPropCases)(
      '$type has correct idProp, permission, icon, and a component',
      ({ type, idProp, permission, icon }) => {
        const def = entityRegistry.getEntity(type);
        expect(def).toBeDefined();
        expect(def!.idProp).toBe(idProp);
        expect(def!.permission).toBe(permission);
        expect(def!.icon).toBe(icon);
        expect(def!.component).toBeDefined();
        // Mode 1: component + idProp; no fetchById or objectProp
        expect(def!.fetchById).toBeUndefined();
        expect(def!.objectProp).toBeUndefined();
      },
    );
  });

  // --- Mode 2: object-prop modal (host fetches, passes object) -------------

  describe('mode 2 — object-prop modal: sdwan_network', () => {
    beforeEach(() => {
      registerSystemEntities();
    });

    it('registers sdwan_network with objectProp="network" and a component', () => {
      const def = entityRegistry.getEntity('sdwan_network');
      expect(def).toBeDefined();
      expect(def!.objectProp).toBe('network');
      expect(def!.component).toBeDefined();
      expect(def!.idProp).toBeUndefined();
    });

    it('sdwan_network.fetchById delegates to sdwanApi.getNetwork', async () => {
      const network = { id: 'net-1', name: 'test-net' };
      mockSdwanApiGetNetwork.mockResolvedValue(network);

      const def = entityRegistry.getEntity('sdwan_network');
      const result = await def!.fetchById!('net-1');

      expect(mockSdwanApiGetNetwork).toHaveBeenCalledWith('net-1');
      expect(result).toEqual(network);
    });

    it('sdwan_network has correct permission and icon', () => {
      const def = entityRegistry.getEntity('sdwan_network');
      expect(def!.permission).toBe('system.sdwan.networks.read');
      expect(def!.icon).toBe('ShieldCheck');
    });
  });

  // --- Mode 3: generic modal (fetchById only) -------------------------------

  describe('mode 3 — generic field-driven entities', () => {
    beforeEach(() => {
      registerSystemEntities();
    });

    it('node_platform delegates fetchById to platformsApi.getPlatform', async () => {
      const platform = { id: 'plat-1', name: 'Ubuntu 22.04' };
      mockPlatformsApiGetPlatform.mockResolvedValue(platform);

      const def = entityRegistry.getEntity('node_platform');
      expect(def!.labelField).toBe('name');
      expect(def!.component).toBeUndefined();

      const result = await def!.fetchById!('plat-1');
      expect(mockPlatformsApiGetPlatform).toHaveBeenCalledWith('plat-1');
      expect(result).toEqual(platform);
    });

    it('node_architecture delegates fetchById to architecturesApi.getArchitecture', async () => {
      const arch = { id: 'arch-1', name: 'x86_64' };
      mockArchitecturesApiGetArchitecture.mockResolvedValue(arch);

      const def = entityRegistry.getEntity('node_architecture');
      expect(def!.labelField).toBe('name');

      const result = await def!.fetchById!('arch-1');
      expect(mockArchitecturesApiGetArchitecture).toHaveBeenCalledWith('arch-1');
      expect(result).toEqual(arch);
    });

    it('node_module_category delegates fetchById to modulesApi.getModuleCategory', async () => {
      const cat = { id: 'cat-1', name: 'networking' };
      mockModulesApiGetModuleCategory.mockResolvedValue(cat);

      const def = entityRegistry.getEntity('node_module_category');
      expect(def!.labelField).toBe('name');

      const result = await def!.fetchById!('cat-1');
      expect(mockModulesApiGetModuleCategory).toHaveBeenCalledWith('cat-1');
      expect(result).toEqual(cat);
    });

    it('provider delegates fetchById to providersApi.getProvider', async () => {
      const provider = { id: 'prov-1', name: 'QEMU Local' };
      mockProvidersApiGetProvider.mockResolvedValue(provider);

      const def = entityRegistry.getEntity('provider');
      expect(def!.labelField).toBe('name');

      const result = await def!.fetchById!('prov-1');
      expect(mockProvidersApiGetProvider).toHaveBeenCalledWith('prov-1');
      expect(result).toEqual(provider);
    });

    it('acme_certificate delegates fetchById to acmeCertificatesApi.get', async () => {
      const cert = { id: 'cert-1', common_name: 'example.com' };
      mockAcmeCertificatesApiGet.mockResolvedValue(cert);

      const def = entityRegistry.getEntity('acme_certificate');
      expect(def!.labelField).toBe('common_name');
      expect(def!.permission).toBeUndefined();

      const result = await def!.fetchById!('cert-1');
      expect(mockAcmeCertificatesApiGet).toHaveBeenCalledWith('cert-1');
      expect(result).toEqual(cert);
    });

    it('acme_dns_credential delegates fetchById to acmeDnsCredentialsApi.get', async () => {
      const cred = { id: 'cred-1', name: 'cloudflare-dns' };
      mockAcmeDnsCredentialsApiGet.mockResolvedValue(cred);

      const def = entityRegistry.getEntity('acme_dns_credential');
      expect(def!.labelField).toBe('name');
      expect(def!.permission).toBeUndefined();

      const result = await def!.fetchById!('cred-1');
      expect(mockAcmeDnsCredentialsApiGet).toHaveBeenCalledWith('cred-1');
      expect(result).toEqual(cred);
    });

    it('ci_worker delegates fetchById to ciWorkersApi.get', async () => {
      const worker = { id: 'w-1', name: 'runner-01' };
      mockCiWorkersApiGet.mockResolvedValue(worker);

      const def = entityRegistry.getEntity('ci_worker');
      expect(def!.labelField).toBe('name');
      expect(def!.permission).toBe('system.ci_workers.read');

      const result = await def!.fetchById!('w-1');
      expect(mockCiWorkersApiGet).toHaveBeenCalledWith('w-1');
      expect(result).toEqual(worker);
    });

    it('cve uses labelField="package_name" and delegates to cveApi.get', async () => {
      const exposure = { id: 'cve-1', package_name: 'openssl' };
      mockCveApiGet.mockResolvedValue(exposure);

      const def = entityRegistry.getEntity('cve');
      expect(def!.labelField).toBe('package_name');
      expect(def!.permission).toBe('system.cve.read');

      const result = await def!.fetchById!('cve-1');
      expect(mockCveApiGet).toHaveBeenCalledWith('cve-1');
      expect(result).toEqual(exposure);
    });

    it('gitops_repository unwraps the nested gitops_repository from gitopsApi.get', async () => {
      const repo = { id: 'gr-1', name: 'fleet-config' };
      const apiResponse = { gitops_repository: repo, recent_runs: [] };
      mockGitopsApiGet.mockResolvedValue(apiResponse);

      const def = entityRegistry.getEntity('gitops_repository');
      expect(def!.labelField).toBe('name');
      expect(def!.permission).toBe('system.gitops.read');

      const result = await def!.fetchById!('gr-1');
      expect(mockGitopsApiGet).toHaveBeenCalledWith('gr-1');
      // The fetchById unwraps to just the repository row (not the full envelope)
      expect(result).toEqual(repo);
    });

    it('storage_migration uses labelField="role" and has no permission', async () => {
      const migration = { id: 'sm-1', role: 'primary' };
      mockStorageMigrationsApiGet.mockResolvedValue(migration);

      const def = entityRegistry.getEntity('storage_migration');
      expect(def!.labelField).toBe('role');
      expect(def!.permission).toBeUndefined();

      const result = await def!.fetchById!('sm-1');
      expect(mockStorageMigrationsApiGet).toHaveBeenCalledWith('sm-1');
      expect(result).toEqual(migration);
    });

    it('platform_peer uses labelField="remote_instance_url" and delegates to platformPeersApi.getPeer', async () => {
      const peer = { id: 'peer-1', remote_instance_url: 'https://peer.example.com' };
      mockPlatformPeersApiGetPeer.mockResolvedValue(peer);

      const def = entityRegistry.getEntity('platform_peer');
      expect(def!.labelField).toBe('remote_instance_url');
      expect(def!.permission).toBe('system.peers.read');

      const result = await def!.fetchById!('peer-1');
      expect(mockPlatformPeersApiGetPeer).toHaveBeenCalledWith('peer-1');
      expect(result).toEqual(peer);
    });

    it('module_build_batch uses labelField="trigger" and delegates to moduleBuildsApi.get', async () => {
      const batch = { id: 'batch-1', trigger: 'push' };
      mockModuleBuildsApiGet.mockResolvedValue(batch);

      const def = entityRegistry.getEntity('module_build_batch');
      expect(def!.labelField).toBe('trigger');
      expect(def!.permission).toBe('system.module_builds.read');

      const result = await def!.fetchById!('batch-1');
      expect(mockModuleBuildsApiGet).toHaveBeenCalledWith('batch-1');
      expect(result).toEqual(batch);
    });
  });

  // --- SDWAN sub-resources --------------------------------------------------

  describe('SDWAN sub-resource entities', () => {
    beforeEach(() => {
      registerSystemEntities();
    });

    it('sdwan_host_bridge delegates to sdwanApi.getHostBridge', async () => {
      const bridge = { id: 'hb-1', bridge_name: 'br0' };
      mockSdwanApiGetHostBridge.mockResolvedValue(bridge);

      const def = entityRegistry.getEntity('sdwan_host_bridge');
      expect(def!.labelField).toBe('bridge_name');
      expect(def!.permission).toBe('system.sdwan.host_bridges.read');

      const result = await def!.fetchById!('hb-1');
      expect(mockSdwanApiGetHostBridge).toHaveBeenCalledWith('hb-1');
      expect(result).toEqual(bridge);
    });

    it('sdwan_ovn_deployment unwraps the deployment object from getOvnDeployment', async () => {
      const deployment = { id: 'ovn-1', status: 'active' };
      const apiResponse = { deployment, compiled_plan: {} };
      mockSdwanApiGetOvnDeployment.mockResolvedValue(apiResponse);

      const def = entityRegistry.getEntity('sdwan_ovn_deployment');
      expect(def!.labelField).toBe('status');
      expect(def!.permission).toBe('system.sdwan.ovn.read');

      const result = await def!.fetchById!('ovn-1');
      expect(mockSdwanApiGetOvnDeployment).toHaveBeenCalledWith('ovn-1');
      expect(result).toEqual(deployment);
    });

    it('sdwan_ipfix_collector delegates to sdwanApi.getIpfixCollector', async () => {
      const collector = { id: 'col-1', name: 'main-collector' };
      mockSdwanApiGetIpfixCollector.mockResolvedValue(collector);

      const def = entityRegistry.getEntity('sdwan_ipfix_collector');
      expect(def!.labelField).toBe('name');
      expect(def!.permission).toBe('system.sdwan.ipfix.read');

      const result = await def!.fetchById!('col-1');
      expect(mockSdwanApiGetIpfixCollector).toHaveBeenCalledWith('col-1');
      expect(result).toEqual(collector);
    });

    it('sdwan_route_policy delegates to sdwanApi.getRoutePolicy with a single id', async () => {
      const policy = { id: 'rp-1', name: 'prefer-local' };
      mockSdwanApiGetRoutePolicy.mockResolvedValue(policy);

      const def = entityRegistry.getEntity('sdwan_route_policy');
      expect(def!.labelField).toBe('name');
      expect(def!.permission).toBe('system.sdwan.route_policies.read');

      const result = await def!.fetchById!('rp-1');
      expect(mockSdwanApiGetRoutePolicy).toHaveBeenCalledWith('rp-1');
      expect(result).toEqual(policy);
    });
  });

  // --- Composite id entities ------------------------------------------------

  describe('composite id entities', () => {
    beforeEach(() => {
      registerSystemEntities();
    });

    describe('node_instance — composite "nodeId:instanceId"', () => {
      it('splits the composite id and calls nodesApi.getNodeInstance with both parts', async () => {
        const instance = { id: 'inst-1', name: 'web-01' };
        mockNodesApiGetNodeInstance.mockResolvedValue(instance);

        const def = entityRegistry.getEntity('node_instance');
        expect(def!.labelField).toBe('name');
        expect(def!.permission).toBe('system.node_instances.read');
        expect(def!.component).toBeUndefined();

        const result = await def!.fetchById!('node-abc:inst-1');
        expect(mockNodesApiGetNodeInstance).toHaveBeenCalledWith('node-abc', 'inst-1');
        expect(result).toEqual(instance);
      });

      it('rejects with a descriptive error when the id has only one segment', async () => {
        const def = entityRegistry.getEntity('node_instance');
        await expect(def!.fetchById!('only-one-segment')).rejects.toThrow(
          'node_instance id must be "nodeId:instanceId" (got "only-one-segment")',
        );
        expect(mockNodesApiGetNodeInstance).not.toHaveBeenCalled();
      });

      it('rejects when the id has three or more segments', async () => {
        const def = entityRegistry.getEntity('node_instance');
        await expect(def!.fetchById!('a:b:c')).rejects.toThrow(
          'node_instance id must be "nodeId:instanceId" (got "a:b:c")',
        );
      });

      it('rejects when any segment is empty (e.g. ":inst-1")', async () => {
        const def = entityRegistry.getEntity('node_instance');
        await expect(def!.fetchById!(':inst-1')).rejects.toThrow(
          'node_instance id must be "nodeId:instanceId" (got ":inst-1")',
        );
      });

      it('rejects when the trailing segment is empty (e.g. "node-abc:")', async () => {
        const def = entityRegistry.getEntity('node_instance');
        await expect(def!.fetchById!('node-abc:')).rejects.toThrow(
          'node_instance id must be "nodeId:instanceId" (got "node-abc:")',
        );
      });
    });

    describe('sdwan_virtual_ip — composite "networkId:vipId"', () => {
      it('splits the composite id and calls sdwanApi.getVirtualIp with both parts', async () => {
        const vip = { id: 'vip-1', name: 'lb-vip' };
        mockSdwanApiGetVirtualIp.mockResolvedValue(vip);

        const def = entityRegistry.getEntity('sdwan_virtual_ip');
        expect(def!.labelField).toBe('name');
        expect(def!.permission).toBe('system.sdwan.vips.read');

        const result = await def!.fetchById!('net-xyz:vip-1');
        expect(mockSdwanApiGetVirtualIp).toHaveBeenCalledWith('net-xyz', 'vip-1');
        expect(result).toEqual(vip);
      });

      it('rejects with a descriptive error when the id has only one segment', async () => {
        const def = entityRegistry.getEntity('sdwan_virtual_ip');
        await expect(def!.fetchById!('only-one-part')).rejects.toThrow(
          'sdwan_virtual_ip id must be "networkId:vipId" (got "only-one-part")',
        );
        expect(mockSdwanApiGetVirtualIp).not.toHaveBeenCalled();
      });

      it('rejects when the id has three segments', async () => {
        const def = entityRegistry.getEntity('sdwan_virtual_ip');
        await expect(def!.fetchById!('a:b:c')).rejects.toThrow(
          'sdwan_virtual_ip id must be "networkId:vipId" (got "a:b:c")',
        );
      });

      it('rejects when a segment is empty', async () => {
        const def = entityRegistry.getEntity('sdwan_virtual_ip');
        await expect(def!.fetchById!(':vip-1')).rejects.toThrow(
          'sdwan_virtual_ip id must be "networkId:vipId" (got ":vip-1")',
        );
      });
    });
  });
});

// =============================================================================
// resolveOperableType — mapping coverage
// =============================================================================

describe('resolveOperableType()', () => {
  // Short-form keys that already match the registry (no class normalization)
  const shortFormMap: Array<[string, string]> = [
    ['node', 'node'],
    ['node_module', 'node_module'],
    ['module', 'node_module'],
    ['node_template', 'node_template'],
    ['template', 'node_template'],
    ['node_platform', 'node_platform'],
    ['platform', 'node_platform'],
    ['node_architecture', 'node_architecture'],
    ['architecture', 'node_architecture'],
    ['provider', 'provider'],
    ['provider_network', 'provider_network'],
    ['network', 'provider_network'],
    ['provider_volume', 'provider_volume'],
    ['volume', 'provider_volume'],
    ['task', 'system_task'],
    ['system_task', 'system_task'],
    ['sdwan_network', 'sdwan_network'],
    ['sdwan_host_bridge', 'sdwan_host_bridge'],
    ['host_bridge', 'sdwan_host_bridge'],
    ['sdwan_ovn_deployment', 'sdwan_ovn_deployment'],
    ['ovn_deployment', 'sdwan_ovn_deployment'],
    ['sdwan_ipfix_collector', 'sdwan_ipfix_collector'],
    ['ipfix_collector', 'sdwan_ipfix_collector'],
    ['sdwan_route_policy', 'sdwan_route_policy'],
    ['route_policy', 'sdwan_route_policy'],
  ];

  it.each(shortFormMap)('"%s" → "%s"', (input, expected) => {
    expect(resolveOperableType(input)).toBe(expected);
  });

  // Rails class-name forms (CamelCase namespace with ::)
  const railsClassMap: Array<[string, string]> = [
    ['System::Node', 'node'],
    ['System::NodeModule', 'node_module'],
    ['System::NodeTemplate', 'node_template'],
    ['System::NodePlatform', 'node_platform'],
    ['System::NodeArchitecture', 'node_architecture'],
    ['System::Provider', 'provider'],
    ['System::ProviderNetwork', 'provider_network'],
    ['System::ProviderVolume', 'provider_volume'],
    ['System::Task', 'system_task'],
    ['Sdwan::HostBridge', 'sdwan_host_bridge'],
    ['Sdwan::OvnDeployment', 'sdwan_ovn_deployment'],
    ['Sdwan::IpfixCollector', 'sdwan_ipfix_collector'],
    ['Sdwan::RoutePolicy', 'sdwan_route_policy'],
  ];

  it.each(railsClassMap)('Rails class "%s" normalizes to "%s"', (input, expected) => {
    expect(resolveOperableType(input)).toBe(expected);
  });

  // Types intentionally absent (composite id or no getById)
  const omittedTypes = [
    'node_instance',
    'System::NodeInstance',
    'sdwan_virtual_ip',
    'Sdwan::VirtualIp',
  ];

  it.each(omittedTypes)('intentionally omitted "%s" returns undefined', (input) => {
    expect(resolveOperableType(input)).toBeUndefined();
  });

  it('returns undefined for completely unknown types', () => {
    expect(resolveOperableType('something_unknown')).toBeUndefined();
  });

  it('returns undefined for an empty string', () => {
    expect(resolveOperableType('')).toBeUndefined();
  });

  it('handles a single-word Rails class name (no namespace separator)', () => {
    // "Node" → snake → "node" → registry key "node"
    expect(resolveOperableType('Node')).toBe('node');
  });

  it('normalizes "Network" (last segment) to "network" which maps to provider_network', () => {
    // 'Sdwan::Network' last segment is 'Network' → 'network' → maps to 'provider_network'
    // This is the documented collision: SDWAN networks are keyed explicitly (sdwan_network),
    // so 'Sdwan::Network' (normalized to 'network') maps to provider_network in the MAP.
    expect(resolveOperableType('Sdwan::Network')).toBe('provider_network');
  });

  // CamelCase snake_case normalization edge cases
  it('normalizes "OVNDeployment" style uppercase runs correctly', () => {
    // The regex: ([A-Z]+)([A-Z][a-z]) handles e.g. "OVNDeployment" → "OVN_Deployment"
    // then lowercased → "ovn_deployment"
    expect(resolveOperableType('OvnDeployment')).toBe('sdwan_ovn_deployment');
  });
});
