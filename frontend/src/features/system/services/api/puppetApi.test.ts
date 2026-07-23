// Behavioral tests for puppetApi.
//
// Covers every exported method: exact URL, params, payload, envelope
// unwrapping, nested key extraction, and optional-argument edge cases.

import { puppetApi } from './puppetApi';

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
// Helpers
// =============================================================================

/** Build a double-envelope AxiosResponse body for a generic success. */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

/** Build a paginated envelope body (meta at the root, not inside data). */
function paginatedEnvelope<T>(payload: T, count = 1) {
  return {
    data: {
      success: true,
      data: payload,
      meta: {
        current_page: 1,
        per_page: 20,
        total_count: count,
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

const MODULE_A = {
  id: 'mod-1',
  name: 'apache',
  description: 'Apache HTTP server module',
  enabled: true,
  public: false,
  version: '3.6.0',
  author: 'puppetlabs',
  license: 'Apache-2.0',
  source_url: 'https://github.com/puppetlabs/puppetlabs-apache',
  project_url: 'https://forge.puppet.com/modules/puppetlabs/apache',
  forge_name: 'puppetlabs-apache',
  dependencies: [{ name: 'puppetlabs-concat', version_requirement: '>= 4.0.0' }],
  config: { timeout: 30 },
  metadata: { tags: ['web'] },
  resource_count: 2,
  resource_types: ['File', 'Service'],
  assigned_modules_count: 3,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const MODULE_B = {
  id: 'mod-2',
  name: 'nginx',
  description: 'Nginx module',
  enabled: false,
  public: true,
  version: '2.0.0',
  author: 'puppet',
  license: 'MIT',
  source_url: null,
  project_url: null,
  forge_name: 'puppet-nginx',
  dependencies: [],
  config: {},
  metadata: {},
  resource_count: 0,
  resource_types: [],
  assigned_modules_count: 0,
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
};

const RESOURCE_A = {
  id: 'res-1',
  name: 'apache_conf',
  description: 'Main apache config',
  resource_type: 'File',
  title: '/etc/apache2/apache2.conf',
  path: '/etc/apache2/apache2.conf',
  data: 'ServerRoot "/etc/apache2"',
  enabled: true,
  exported: false,
  parameters: { owner: 'root', mode: '0644' },
  config: {},
  puppet_module_id: 'mod-1',
  puppet_module_name: 'apache',
  resource_identifier: 'File[/etc/apache2/apache2.conf]',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const RESOURCE_B = {
  id: 'res-2',
  name: 'apache_service',
  description: 'Apache service',
  resource_type: 'Service',
  title: 'apache2',
  path: undefined,
  data: undefined,
  enabled: true,
  exported: true,
  parameters: { ensure: 'running', enable: true },
  config: {},
  puppet_module_id: 'mod-1',
  puppet_module_name: 'apache',
  resource_identifier: 'Service[apache2]',
  created_at: '2026-01-02T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const ASSIGNMENT_A = {
  id: 'asgn-1',
  puppet_module_id: 'mod-1',
  node_module_id: 'nm-10',
  node_id: 'node-abc',
  created_at: '2026-01-01T00:00:00Z',
};

const MODULES_BASE = '/system/puppet_modules';

// =============================================================================
// Tests
// =============================================================================

describe('puppetApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // getPuppetModules
  // ---------------------------------------------------------------------------

  describe('getPuppetModules()', () => {
    it('calls GET /system/puppet_modules with no params when called without args', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ puppet_modules: [MODULE_A] }, 1),
      );

      await puppetApi.getPuppetModules();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(MODULES_BASE, { params: undefined });
    });

    it('passes pagination params when provided', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ puppet_modules: [MODULE_A] }, 1),
      );

      await puppetApi.getPuppetModules({ page: 2, per_page: 10 });

      expect(mockGet).toHaveBeenCalledWith(MODULES_BASE, {
        params: { page: 2, per_page: 10 },
      });
    });

    it('returns the unwrapped puppet_modules array and meta', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ puppet_modules: [MODULE_A, MODULE_B] }, 2),
      );

      const result = await puppetApi.getPuppetModules();

      expect(result.puppetModules).toHaveLength(2);
      expect(result.puppetModules[0]).toEqual(MODULE_A);
      expect(result.puppetModules[1]).toEqual(MODULE_B);
      expect(result.meta.total_count).toBe(2);
      expect(result.meta.current_page).toBe(1);
    });

    it('returns an empty array when puppet_modules is absent from response', async () => {
      // Backend can return empty data object; guard against undefined
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ puppet_modules: undefined }, 0),
      );

      const result = await puppetApi.getPuppetModules();

      expect(result.puppetModules).toEqual([]);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(puppetApi.getPuppetModules()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // getPuppetModule
  // ---------------------------------------------------------------------------

  describe('getPuppetModule()', () => {
    it('calls GET /system/puppet_modules/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_module: MODULE_A }));

      await puppetApi.getPuppetModule('mod-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${MODULES_BASE}/mod-1`);
    });

    it('unwraps the nested .puppet_module from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_module: MODULE_A }));

      const result = await puppetApi.getPuppetModule('mod-1');

      expect(result).toEqual(MODULE_A);
      expect(result.name).toBe('apache');
      expect(result.version).toBe('3.6.0');
    });

    it('uses the supplied id in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_module: MODULE_B }));

      await puppetApi.getPuppetModule('mod-999');

      expect(mockGet).toHaveBeenCalledWith(`${MODULES_BASE}/mod-999`);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(puppetApi.getPuppetModule('missing')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // createPuppetModule
  // ---------------------------------------------------------------------------

  describe('createPuppetModule()', () => {
    const CREATE_DATA = {
      name: 'redis',
      description: 'Redis module',
      version: '6.0.0',
      author: 'puppet',
      license: 'MIT',
      source_url: 'https://github.com/puppet/puppetlabs-redis',
      project_url: 'https://forge.puppet.com/modules/puppet/redis',
      forge_name: 'puppet-redis',
      enabled: true,
      public: false,
      dependencies: [{ name: 'puppetlabs-stdlib', version_requirement: '>= 4.0.0' }],
      config: { max_memory: '256mb' },
      metadata: { tags: ['cache'] },
    };

    it('calls POST /system/puppet_modules with the module wrapped in puppet_module key', async () => {
      mockPost.mockResolvedValueOnce(envelope({ puppet_module: MODULE_A }));

      await puppetApi.createPuppetModule(CREATE_DATA);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(MODULES_BASE, {
        puppet_module: CREATE_DATA,
      });
    });

    it('returns the unwrapped puppet module', async () => {
      const createdModule = { ...MODULE_A, name: 'redis' };
      mockPost.mockResolvedValueOnce(envelope({ puppet_module: createdModule }));

      const result = await puppetApi.createPuppetModule(CREATE_DATA);

      expect(result).toEqual(createdModule);
      expect(result.name).toBe('redis');
    });

    it('works with only the required name field', async () => {
      mockPost.mockResolvedValueOnce(envelope({ puppet_module: MODULE_A }));

      await puppetApi.createPuppetModule({ name: 'minimal-mod' });

      expect(mockPost).toHaveBeenCalledWith(MODULES_BASE, {
        puppet_module: { name: 'minimal-mod' },
      });
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Validation failed'));

      await expect(puppetApi.createPuppetModule({ name: 'bad' })).rejects.toThrow(
        'Validation failed',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // updatePuppetModule
  // ---------------------------------------------------------------------------

  describe('updatePuppetModule()', () => {
    it('calls PUT /system/puppet_modules/:id with the patch wrapped in puppet_module key', async () => {
      const patch = { description: 'Updated description', enabled: false };
      mockPut.mockResolvedValueOnce(envelope({ puppet_module: MODULE_A }));

      await puppetApi.updatePuppetModule('mod-1', patch);

      expect(mockPut).toHaveBeenCalledTimes(1);
      expect(mockPut).toHaveBeenCalledWith(`${MODULES_BASE}/mod-1`, {
        puppet_module: patch,
      });
    });

    it('returns the updated puppet module', async () => {
      const updatedModule = { ...MODULE_A, description: 'Updated description' };
      mockPut.mockResolvedValueOnce(envelope({ puppet_module: updatedModule }));

      const result = await puppetApi.updatePuppetModule('mod-1', {
        description: 'Updated description',
      });

      expect(result).toEqual(updatedModule);
      expect(result.description).toBe('Updated description');
    });

    it('uses the supplied id in the URL', async () => {
      mockPut.mockResolvedValueOnce(envelope({ puppet_module: MODULE_B }));

      await puppetApi.updatePuppetModule('mod-xyz', { enabled: true });

      expect(mockPut).toHaveBeenCalledWith(`${MODULES_BASE}/mod-xyz`, {
        puppet_module: { enabled: true },
      });
    });

    it('propagates API errors', async () => {
      mockPut.mockRejectedValueOnce(new Error('Update failed'));

      await expect(
        puppetApi.updatePuppetModule('mod-1', { name: 'new-name' }),
      ).rejects.toThrow('Update failed');
    });
  });

  // ---------------------------------------------------------------------------
  // deletePuppetModule
  // ---------------------------------------------------------------------------

  describe('deletePuppetModule()', () => {
    it('calls DELETE /system/puppet_modules/:id', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await puppetApi.deletePuppetModule('mod-1');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(`${MODULES_BASE}/mod-1`);
    });

    it('resolves to void (returns undefined)', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      const result = await puppetApi.deletePuppetModule('mod-1');

      expect(result).toBeUndefined();
    });

    it('uses the supplied id in the URL', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await puppetApi.deletePuppetModule('mod-abc-999');

      expect(mockDelete).toHaveBeenCalledWith(`${MODULES_BASE}/mod-abc-999`);
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Delete failed'));

      await expect(puppetApi.deletePuppetModule('mod-1')).rejects.toThrow('Delete failed');
    });
  });

  // ---------------------------------------------------------------------------
  // getPuppetResources
  // ---------------------------------------------------------------------------

  describe('getPuppetResources()', () => {
    it('calls GET /system/puppet_modules/:moduleId/puppet_resources', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ puppet_resources: [RESOURCE_A, RESOURCE_B] }),
      );

      await puppetApi.getPuppetResources('mod-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${MODULES_BASE}/mod-1/puppet_resources`);
    });

    it('returns the unwrapped puppet_resources array', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ puppet_resources: [RESOURCE_A, RESOURCE_B] }),
      );

      const result = await puppetApi.getPuppetResources('mod-1');

      expect(result).toHaveLength(2);
      expect(result[0]).toEqual(RESOURCE_A);
      expect(result[1]).toEqual(RESOURCE_B);
    });

    it('returns an empty array when puppet_resources is absent', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_resources: undefined }));

      const result = await puppetApi.getPuppetResources('mod-1');

      expect(result).toEqual([]);
    });

    it('returns an empty array when puppet_resources is an empty list', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_resources: [] }));

      const result = await puppetApi.getPuppetResources('mod-1');

      expect(result).toEqual([]);
    });

    it('uses the supplied puppetModuleId in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_resources: [] }));

      await puppetApi.getPuppetResources('mod-xyz-999');

      expect(mockGet).toHaveBeenCalledWith(`${MODULES_BASE}/mod-xyz-999/puppet_resources`);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Forbidden'));

      await expect(puppetApi.getPuppetResources('mod-1')).rejects.toThrow('Forbidden');
    });
  });

  // ---------------------------------------------------------------------------
  // getPuppetResource
  // ---------------------------------------------------------------------------

  describe('getPuppetResource()', () => {
    it('calls GET /system/puppet_modules/:moduleId/puppet_resources/:resourceId', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_resource: RESOURCE_A }));

      await puppetApi.getPuppetResource('mod-1', 'res-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(
        `${MODULES_BASE}/mod-1/puppet_resources/res-1`,
      );
    });

    it('unwraps the nested .puppet_resource from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_resource: RESOURCE_A }));

      const result = await puppetApi.getPuppetResource('mod-1', 'res-1');

      expect(result).toEqual(RESOURCE_A);
      expect(result.resource_type).toBe('File');
      expect(result.title).toBe('/etc/apache2/apache2.conf');
    });

    it('uses both supplied ids in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_resource: RESOURCE_B }));

      await puppetApi.getPuppetResource('mod-99', 'res-77');

      expect(mockGet).toHaveBeenCalledWith(
        `${MODULES_BASE}/mod-99/puppet_resources/res-77`,
      );
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(puppetApi.getPuppetResource('mod-1', 'missing')).rejects.toThrow(
        'Not found',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // createPuppetResource
  // ---------------------------------------------------------------------------

  describe('createPuppetResource()', () => {
    const CREATE_RESOURCE_DATA = {
      name: 'new_conf',
      description: 'New config file',
      resource_type: 'File',
      title: '/etc/app/config.conf',
      path: '/etc/app/config.conf',
      data: '# config',
      enabled: true,
      exported: false,
      parameters: { owner: 'app', mode: '0640' },
      config: {},
    };

    it('calls POST /system/puppet_modules/:moduleId/puppet_resources with resource wrapped in puppet_resource key', async () => {
      mockPost.mockResolvedValueOnce(envelope({ puppet_resource: RESOURCE_A }));

      await puppetApi.createPuppetResource('mod-1', CREATE_RESOURCE_DATA);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        `${MODULES_BASE}/mod-1/puppet_resources`,
        { puppet_resource: CREATE_RESOURCE_DATA },
      );
    });

    it('returns the unwrapped puppet resource', async () => {
      mockPost.mockResolvedValueOnce(envelope({ puppet_resource: RESOURCE_A }));

      const result = await puppetApi.createPuppetResource('mod-1', CREATE_RESOURCE_DATA);

      expect(result).toEqual(RESOURCE_A);
      expect(result.resource_type).toBe('File');
    });

    it('uses the supplied puppetModuleId in the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope({ puppet_resource: RESOURCE_A }));

      await puppetApi.createPuppetResource('mod-xyz', CREATE_RESOURCE_DATA);

      expect(mockPost).toHaveBeenCalledWith(`${MODULES_BASE}/mod-xyz/puppet_resources`, {
        puppet_resource: CREATE_RESOURCE_DATA,
      });
    });

    it('works with only the two required fields', async () => {
      mockPost.mockResolvedValueOnce(envelope({ puppet_resource: RESOURCE_A }));

      await puppetApi.createPuppetResource('mod-1', {
        name: 'minimal',
        resource_type: 'Exec',
      });

      expect(mockPost).toHaveBeenCalledWith(`${MODULES_BASE}/mod-1/puppet_resources`, {
        puppet_resource: { name: 'minimal', resource_type: 'Exec' },
      });
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Validation failed'));

      await expect(
        puppetApi.createPuppetResource('mod-1', { name: 'bad', resource_type: 'File' }),
      ).rejects.toThrow('Validation failed');
    });
  });

  // ---------------------------------------------------------------------------
  // updatePuppetResource
  // ---------------------------------------------------------------------------

  describe('updatePuppetResource()', () => {
    it('calls PUT /system/puppet_modules/:moduleId/puppet_resources/:resourceId with patch wrapped in puppet_resource key', async () => {
      const patch = { description: 'Updated', enabled: false };
      mockPut.mockResolvedValueOnce(envelope({ puppet_resource: RESOURCE_A }));

      await puppetApi.updatePuppetResource('mod-1', 'res-1', patch);

      expect(mockPut).toHaveBeenCalledTimes(1);
      expect(mockPut).toHaveBeenCalledWith(
        `${MODULES_BASE}/mod-1/puppet_resources/res-1`,
        { puppet_resource: patch },
      );
    });

    it('returns the updated puppet resource', async () => {
      const updatedResource = { ...RESOURCE_A, description: 'Updated' };
      mockPut.mockResolvedValueOnce(envelope({ puppet_resource: updatedResource }));

      const result = await puppetApi.updatePuppetResource('mod-1', 'res-1', {
        description: 'Updated',
      });

      expect(result).toEqual(updatedResource);
      expect(result.description).toBe('Updated');
    });

    it('uses both supplied ids in the URL', async () => {
      mockPut.mockResolvedValueOnce(envelope({ puppet_resource: RESOURCE_B }));

      await puppetApi.updatePuppetResource('mod-99', 'res-77', { enabled: true });

      expect(mockPut).toHaveBeenCalledWith(
        `${MODULES_BASE}/mod-99/puppet_resources/res-77`,
        { puppet_resource: { enabled: true } },
      );
    });

    it('propagates API errors', async () => {
      mockPut.mockRejectedValueOnce(new Error('Update failed'));

      await expect(
        puppetApi.updatePuppetResource('mod-1', 'res-1', { name: 'new' }),
      ).rejects.toThrow('Update failed');
    });
  });

  // ---------------------------------------------------------------------------
  // deletePuppetResource
  // ---------------------------------------------------------------------------

  describe('deletePuppetResource()', () => {
    it('calls DELETE /system/puppet_modules/:moduleId/puppet_resources/:resourceId', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await puppetApi.deletePuppetResource('mod-1', 'res-1');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(
        `${MODULES_BASE}/mod-1/puppet_resources/res-1`,
      );
    });

    it('resolves to void (returns undefined)', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      const result = await puppetApi.deletePuppetResource('mod-1', 'res-1');

      expect(result).toBeUndefined();
    });

    it('uses both supplied ids in the URL', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await puppetApi.deletePuppetResource('mod-abc', 'res-xyz-999');

      expect(mockDelete).toHaveBeenCalledWith(
        `${MODULES_BASE}/mod-abc/puppet_resources/res-xyz-999`,
      );
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Delete failed'));

      await expect(puppetApi.deletePuppetResource('mod-1', 'res-1')).rejects.toThrow(
        'Delete failed',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // getPuppetResourceDsl
  // ---------------------------------------------------------------------------

  describe('getPuppetResourceDsl()', () => {
    const DSL_URL_SUFFIX = '/puppet_dsl';

    it('calls GET /system/puppet_modules/:moduleId/puppet_resources/:resourceId/puppet_dsl', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ puppet_dsl: 'file { "/etc/apache2/apache2.conf": ensure => present }' }),
      );

      await puppetApi.getPuppetResourceDsl('mod-1', 'res-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(
        `${MODULES_BASE}/mod-1/puppet_resources/res-1${DSL_URL_SUFFIX}`,
      );
    });

    it('returns the unwrapped puppet_dsl string', async () => {
      const dslContent = 'file { "/etc/apache2/apache2.conf": ensure => present }';
      mockGet.mockResolvedValueOnce(envelope({ puppet_dsl: dslContent }));

      const result = await puppetApi.getPuppetResourceDsl('mod-1', 'res-1');

      expect(result).toBe(dslContent);
    });

    it('returns an empty string when puppet_dsl is absent from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_dsl: undefined }));

      const result = await puppetApi.getPuppetResourceDsl('mod-1', 'res-1');

      expect(result).toBe('');
    });

    it('returns an empty string when puppet_dsl is null', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_dsl: null }));

      const result = await puppetApi.getPuppetResourceDsl('mod-1', 'res-1');

      expect(result).toBe('');
    });

    it('uses both supplied ids in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_dsl: 'service { "nginx": }' }));

      await puppetApi.getPuppetResourceDsl('mod-99', 'res-77');

      expect(mockGet).toHaveBeenCalledWith(
        `${MODULES_BASE}/mod-99/puppet_resources/res-77${DSL_URL_SUFFIX}`,
      );
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('DSL generation failed'));

      await expect(puppetApi.getPuppetResourceDsl('mod-1', 'res-1')).rejects.toThrow(
        'DSL generation failed',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // getPuppetModuleAssignments
  // ---------------------------------------------------------------------------

  describe('getPuppetModuleAssignments()', () => {
    // Backend only supports listing puppet-module assignments FOR a given
    // node module (ModulePuppetAssignmentsController#index is nested under
    // node_modules/:node_module_id, not puppet_modules/:puppet_module_id —
    // there is no route for the inverse direction). The id parameter here
    // is therefore a NodeModule id, even though the function name refers
    // to the type of record returned (puppet-module assignments).
    it('calls GET /system/node_modules/:nodeModuleId/module_puppet_assignments', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ puppet_assignments: [ASSIGNMENT_A] }),
      );

      await puppetApi.getPuppetModuleAssignments('nm-10');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/node_modules/nm-10/module_puppet_assignments');
    });

    it('returns the unwrapped puppet_assignments array', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ puppet_assignments: [ASSIGNMENT_A] }),
      );

      const result = await puppetApi.getPuppetModuleAssignments('nm-10');

      expect(result).toHaveLength(1);
      expect(result[0]).toEqual(ASSIGNMENT_A);
      expect(result[0].node_module_id).toBe('nm-10');
    });

    it('returns an empty array when puppet_assignments is absent', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_assignments: undefined }));

      const result = await puppetApi.getPuppetModuleAssignments('nm-10');

      expect(result).toEqual([]);
    });

    it('returns an empty array when there are no assignments', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_assignments: [] }));

      const result = await puppetApi.getPuppetModuleAssignments('nm-10');

      expect(result).toEqual([]);
    });

    it('uses the supplied nodeModuleId in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_assignments: [] }));

      await puppetApi.getPuppetModuleAssignments('nm-xyz-999');

      expect(mockGet).toHaveBeenCalledWith('/system/node_modules/nm-xyz-999/module_puppet_assignments');
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not authorized'));

      await expect(puppetApi.getPuppetModuleAssignments('nm-10')).rejects.toThrow(
        'Not authorized',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping', () => {
    it('getPuppetModule does not expose envelope keys in the returned object', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_module: MODULE_A }));

      const result = await puppetApi.getPuppetModule('mod-1');

      // Must NOT contain envelope wrapper keys
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
      expect((result as unknown as Record<string, unknown>)['puppet_module']).toBeUndefined();
    });

    it('getPuppetResource does not expose the { puppet_resource: ... } wrapper', async () => {
      mockGet.mockResolvedValueOnce(envelope({ puppet_resource: RESOURCE_A }));

      const result = await puppetApi.getPuppetResource('mod-1', 'res-1');

      expect((result as unknown as Record<string, unknown>)['puppet_resource']).toBeUndefined();
      expect(result.id).toBe('res-1');
    });

    it('getPuppetModules returns meta at the top level (not inside puppetModules)', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ puppet_modules: [MODULE_A] }, 1));

      const result = await puppetApi.getPuppetModules();

      // meta must live beside puppetModules, not nested inside an item
      expect(result.meta).toBeDefined();
      expect(result.meta.total_count).toBe(1);
      expect((result.puppetModules[0] as unknown as Record<string, unknown>)['meta']).toBeUndefined();
    });

    it('correctly handles the double-envelope for createPuppetModule', async () => {
      mockPost.mockResolvedValueOnce({
        data: { success: true, data: { puppet_module: MODULE_A } },
      });

      const result = await puppetApi.createPuppetModule({ name: 'test' });

      expect(result.id).toBe('mod-1');
      expect(result.name).toBe('apache');
    });
  });
});

// =============================================================================
// Puppet assignment writes (IMP-5dba18916d37) — nested under node_modules
// =============================================================================

describe('puppetApi.createPuppetAssignment', () => {
  it('POSTs the nested collection with the puppet_assignment envelope', async () => {
    const row = {
      id: 'mpa-1',
      node_module_id: 'mod-1',
      puppet_module_id: 'pm-1',
      puppet_module_name: 'profile_base',
      enabled: true,
      priority: 9,
      config: {},
      parameters: {},
    };
    mockPost.mockResolvedValue({
      data: { success: true, data: { puppet_assignment: row } },
    });

    const result = await puppetApi.createPuppetAssignment('mod-1', {
      puppet_module_id: 'pm-1',
      priority: 9,
    });

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-1/module_puppet_assignments',
      { puppet_assignment: { puppet_module_id: 'pm-1', priority: 9 } },
    );
    expect(result.id).toBe('mpa-1');
  });
});

describe('puppetApi.updatePuppetAssignment', () => {
  it('PUTs the nested member and unwraps the assignment', async () => {
    const row = { id: 'mpa-1', node_module_id: 'mod-1', puppet_module_id: 'pm-1', enabled: false, priority: 2 };
    mockPut.mockResolvedValue({
      data: { success: true, data: { puppet_assignment: row } },
    });

    const result = await puppetApi.updatePuppetAssignment('mod-1', 'mpa-1', { enabled: false, priority: 2 });

    expect(mockPut).toHaveBeenCalledWith(
      '/system/node_modules/mod-1/module_puppet_assignments/mpa-1',
      { puppet_assignment: { enabled: false, priority: 2 } },
    );
    expect(result.enabled).toBe(false);
  });
});

describe('puppetApi.deletePuppetAssignment', () => {
  it('DELETEs the nested member', async () => {
    mockDelete.mockResolvedValue({ data: { success: true, data: { message: 'ok' } } });

    await puppetApi.deletePuppetAssignment('mod-1', 'mpa-1');

    expect(mockDelete).toHaveBeenCalledWith(
      '/system/node_modules/mod-1/module_puppet_assignments/mpa-1',
    );
  });
});
