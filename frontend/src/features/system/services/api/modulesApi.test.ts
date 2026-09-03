/**
 * Behavioral tests for modulesApi.
 *
 * Covers every exported function: request shaping (exact URLs, payloads,
 * query params), response unwrapping via extractData / extractPaginated,
 * filter serialization, edge cases (null/undefined filters, empty-collection
 * fallback, void delete), dependency management, manifest import, and
 * honeypot-canary toggle.
 */

import { modulesApi } from './modulesApi';
import type {
  ModuleFilters,
  ModuleCreate,
  ModuleCategoryCreate,
  ModuleDependencyOptions,
  NodeModuleScopedFilters,
} from './modulesApi';
import type { SystemNodeModule, SystemNodeModuleCategory } from '../../types/system.types';
import type { PaginationMeta } from './types';

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
// Helpers & Fixtures
// =============================================================================

/**
 * Wrap a payload in the double-envelope shape:
 *   AxiosResponse.data = { success: true, data: <payload> }
 *
 * This mimics what apiClient.get/post/put/delete resolves to for a
 * non-paginated (ApiEnvelope) response.
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

/**
 * Wrap a payload in the paginated double-envelope shape.
 * Pagination metadata sits at the RESPONSE ROOT — NOT inside data.
 *   AxiosResponse.data = { success: true, data: <payload>, meta: <PaginationMeta> }
 */
function paginatedEnvelope<T>(payload: T, meta?: Partial<PaginationMeta>) {
  const defaultMeta: PaginationMeta = {
    current_page: 1,
    per_page: 20,
    total_count: 1,
    total_pages: 1,
    next_page: null,
    prev_page: null,
    ...meta,
  };
  return { data: { success: true, data: payload, meta: defaultMeta } };
}

function makeModule(overrides: Partial<SystemNodeModule> = {}): SystemNodeModule {
  return {
    id: 'mod-1',
    name: 'base-config',
    variety: 'config',
    enabled: true,
    public: true,
    priority: 100,
    mask: [],
    file_spec: [],
    config: {},
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    ...overrides,
  };
}

function makeCategory(overrides: Partial<SystemNodeModuleCategory> = {}): SystemNodeModuleCategory {
  return {
    id: 'cat-1',
    name: 'networking',
    depth: 0,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    ...overrides,
  };
}

const defaultMeta: PaginationMeta = {
  current_page: 1,
  per_page: 20,
  total_count: 2,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

const MODULE_A = makeModule({ id: 'mod-a', name: 'net-base', variety: 'config' });
const MODULE_B = makeModule({ id: 'mod-b', name: 'ssh-daemon', variety: 'instance' });

const CAT_A = makeCategory({ id: 'cat-a', name: 'networking', depth: 0 });
const CAT_B = makeCategory({ id: 'cat-b', name: 'security', depth: 0, parent_id: 'cat-a' });

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
// getModules — paginated list with filters
// =============================================================================

describe('modulesApi.getModules', () => {
  it('calls GET /system/node_modules with no params when called without filters', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ node_modules: [MODULE_A, MODULE_B] }, defaultMeta)
    );

    const result = await modulesApi.getModules();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/node_modules', { params: undefined });
    expect(result.modules).toEqual([MODULE_A, MODULE_B]);
    expect(result.meta.total_count).toBe(2);
  });

  it('calls GET /system/node_modules with filters when provided', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ node_modules: [MODULE_A] }, { total_count: 1 })
    );

    const filters: ModuleFilters = { variety: 'config', enabled: true, page: 2, per_page: 10 };
    await modulesApi.getModules(filters);

    expect(mockGet).toHaveBeenCalledWith('/system/node_modules', { params: filters });
  });

  it('returns modules from the node_modules collection key', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ node_modules: [MODULE_A] }, { total_count: 1 })
    );

    const result = await modulesApi.getModules();

    expect(result.modules).toHaveLength(1);
    expect(result.modules[0]).toEqual(MODULE_A);
  });

  it('returns an empty array when node_modules is absent from the response', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({} as { node_modules: SystemNodeModule[] }, { total_count: 0 })
    );

    const result = await modulesApi.getModules();

    expect(result.modules).toEqual([]);
  });

  it('returns pagination meta from the response root (not from inside data)', async () => {
    const meta: PaginationMeta = {
      current_page: 2,
      per_page: 10,
      total_count: 25,
      total_pages: 3,
      next_page: 3,
      prev_page: 1,
    };
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ node_modules: [MODULE_A] }, meta)
    );

    const result = await modulesApi.getModules({ page: 2, per_page: 10 });

    expect(result.meta.current_page).toBe(2);
    expect(result.meta.total_count).toBe(25);
    expect(result.meta.total_pages).toBe(3);
    expect(result.meta.next_page).toBe(3);
    expect(result.meta.prev_page).toBe(1);
  });

  it('passes variety=instance filter through to query params', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ node_modules: [MODULE_B] }, { total_count: 1 })
    );

    await modulesApi.getModules({ variety: 'instance' });

    expect(mockGet).toHaveBeenCalledWith('/system/node_modules', {
      params: { variety: 'instance' },
    });
  });

  it('passes variety=subscription filter through to query params', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ node_modules: [] }, { total_count: 0 })
    );

    await modulesApi.getModules({ variety: 'subscription' });

    expect(mockGet).toHaveBeenCalledWith('/system/node_modules', {
      params: { variety: 'subscription' },
    });
  });

  it('passes enabled=false filter through to query params', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ node_modules: [] }, { total_count: 0 })
    );

    await modulesApi.getModules({ enabled: false });

    expect(mockGet).toHaveBeenCalledWith('/system/node_modules', {
      params: { enabled: false },
    });
  });
});

// =============================================================================
// getNodeModules — non-paginated list scoped by node_id
// =============================================================================

describe('modulesApi.getNodeModules', () => {
  it('calls GET /system/node_modules with no params when called without filters', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_modules: [MODULE_A, MODULE_B] })
    );

    const result = await modulesApi.getNodeModules();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/node_modules', { params: undefined });
    expect(result.node_modules).toEqual([MODULE_A, MODULE_B]);
  });

  it('passes node_id filter to query params', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_modules: [MODULE_A] })
    );

    const filters: NodeModuleScopedFilters = { node_id: 'node-123' };
    await modulesApi.getNodeModules(filters);

    expect(mockGet).toHaveBeenCalledWith('/system/node_modules', {
      params: { node_id: 'node-123' },
    });
  });

  it('returns an empty array when node_modules is absent from the response', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({} as { node_modules: SystemNodeModule[] })
    );

    const result = await modulesApi.getNodeModules();

    expect(result.node_modules).toEqual([]);
  });

  it('unwraps the node_modules array from the non-paginated envelope', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_modules: [MODULE_A, MODULE_B] })
    );

    const result = await modulesApi.getNodeModules({ node_id: 'node-xyz' });

    expect(result.node_modules).toHaveLength(2);
    expect(result.node_modules[0].id).toBe('mod-a');
    expect(result.node_modules[1].id).toBe('mod-b');
  });
});

// =============================================================================
// getModule — single module
// =============================================================================

describe('modulesApi.getModule', () => {
  it('calls GET /system/node_modules/:id', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_module: MODULE_A })
    );

    const result = await modulesApi.getModule('mod-a');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/node_modules/mod-a');
    expect(result).toEqual(MODULE_A);
  });

  it('interpolates arbitrary IDs correctly', async () => {
    const mod = makeModule({ id: 'some-uuid-9876' });
    mockGet.mockResolvedValueOnce(
      envelope({ node_module: mod })
    );

    const result = await modulesApi.getModule('some-uuid-9876');

    expect(mockGet).toHaveBeenCalledWith('/system/node_modules/some-uuid-9876');
    expect(result.id).toBe('some-uuid-9876');
  });

  it('unwraps the node_module field from the envelope', async () => {
    const mod = makeModule({
      id: 'mod-full',
      name: 'full-module',
      variety: 'instance',
      priority: 50,
      mask: ['b64-line-1'],
      file_spec: ['b64-line-2'],
    });
    mockGet.mockResolvedValueOnce(
      envelope({ node_module: mod })
    );

    const result = await modulesApi.getModule('mod-full');

    expect(result.id).toBe('mod-full');
    expect(result.variety).toBe('instance');
    expect(result.priority).toBe(50);
    expect(result.mask).toEqual(['b64-line-1']);
  });
});

// =============================================================================
// createModule
// =============================================================================

describe('modulesApi.createModule', () => {
  it('calls POST /system/node_modules with data wrapped in node_module key', async () => {
    const created = makeModule({ id: 'new-mod', name: 'my-module', variety: 'config' });
    mockPost.mockResolvedValueOnce(
      envelope({ node_module: created })
    );

    const payload: ModuleCreate = {
      name: 'my-module',
      variety: 'config',
    };

    const result = await modulesApi.createModule(payload);

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules',
      { node_module: payload }
    );
    expect(result).toEqual(created);
  });

  it('wraps the full optional payload inside node_module key', async () => {
    const fullPayload: ModuleCreate = {
      name: 'full-module',
      description: 'A full module with all fields',
      variety: 'instance',
      node_platform_id: 'plat-1',
      category_id: 'cat-1',
      priority: 200,
      enabled: true,
      public: false,
      consent_budget_per_day: 100,
      mask: 'glob/pattern/**\nanother/glob/**',
      file_spec: '/etc/config/**',
      package_spec: 'nginx,curl',
      dependency_spec: 'dep-module-1',
      protected_spec: '/etc/shadow',
      lock_spec: true,
      init_start: '/etc/init.d/nginx start',
      init_stop: '/etc/init.d/nginx stop',
      init_restart: '/etc/init.d/nginx restart',
      reboot_required: false,
      config: { key: 'value' },
    };

    const created = makeModule({ id: 'full-id', ...fullPayload, mask: [], file_spec: [] });
    mockPost.mockResolvedValueOnce(
      envelope({ node_module: created })
    );

    await modulesApi.createModule(fullPayload);

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules',
      { node_module: fullPayload }
    );
  });

  it('accepts consent_budget_per_day as null to disable enforcement', async () => {
    const payload: ModuleCreate = {
      name: 'no-budget-module',
      variety: 'config',
      consent_budget_per_day: null,
    };
    const created = makeModule({ id: 'no-budget-id', name: 'no-budget-module' });
    mockPost.mockResolvedValueOnce(envelope({ node_module: created }));

    await modulesApi.createModule(payload);

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules',
      { node_module: { name: 'no-budget-module', variety: 'config', consent_budget_per_day: null } }
    );
  });

  it('accepts spec fields as string arrays (already-encoded wire shape)', async () => {
    const payload: ModuleCreate = {
      name: 'array-spec-module',
      variety: 'subscription',
      mask: ['b64chunk1==', 'b64chunk2=='],
      file_spec: ['b64file1=='],
    };
    const created = makeModule({ id: 'arr-id', ...payload });
    mockPost.mockResolvedValueOnce(envelope({ node_module: created }));

    await modulesApi.createModule(payload);

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules',
      { node_module: payload }
    );
  });

  it('returns the unwrapped created module', async () => {
    const created = makeModule({ id: 'created-id', name: 'z-module', variety: 'subscription' });
    mockPost.mockResolvedValueOnce(envelope({ node_module: created }));

    const result = await modulesApi.createModule({ name: 'z-module', variety: 'subscription' });

    expect(result.id).toBe('created-id');
    expect(result.name).toBe('z-module');
    expect(result.variety).toBe('subscription');
  });
});

// =============================================================================
// updateModule
// =============================================================================

describe('modulesApi.updateModule', () => {
  it('calls PUT /system/node_modules/:id with partial data wrapped in node_module key', async () => {
    const updated = makeModule({ id: 'mod-a', name: 'updated-name' });
    mockPut.mockResolvedValueOnce(
      envelope({ node_module: updated })
    );

    const patch: Partial<ModuleCreate> = { name: 'updated-name', enabled: false };

    const result = await modulesApi.updateModule('mod-a', patch);

    expect(mockPut).toHaveBeenCalledTimes(1);
    expect(mockPut).toHaveBeenCalledWith(
      '/system/node_modules/mod-a',
      { node_module: patch }
    );
    expect(result).toEqual(updated);
  });

  it('interpolates the id into the URL', async () => {
    const updated = makeModule({ id: 'target-uuid' });
    mockPut.mockResolvedValueOnce(envelope({ node_module: updated }));

    await modulesApi.updateModule('target-uuid', { description: 'Updated desc' });

    expect(mockPut).toHaveBeenCalledWith(
      '/system/node_modules/target-uuid',
      { node_module: { description: 'Updated desc' } }
    );
  });

  it('accepts an empty patch object', async () => {
    const mod = makeModule({ id: 'mod-a' });
    mockPut.mockResolvedValueOnce(envelope({ node_module: mod }));

    const result = await modulesApi.updateModule('mod-a', {});

    expect(mockPut).toHaveBeenCalledWith(
      '/system/node_modules/mod-a',
      { node_module: {} }
    );
    expect(result).toEqual(mod);
  });

  it('returns the unwrapped updated module', async () => {
    const updated = makeModule({ id: 'mod-b', enabled: false, priority: 999 });
    mockPut.mockResolvedValueOnce(envelope({ node_module: updated }));

    const result = await modulesApi.updateModule('mod-b', { enabled: false, priority: 999 });

    expect(result.enabled).toBe(false);
    expect(result.priority).toBe(999);
  });
});

// =============================================================================
// deleteModule
// =============================================================================

describe('modulesApi.deleteModule', () => {
  it('calls DELETE /system/node_modules/:id', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await modulesApi.deleteModule('mod-a');

    expect(mockDelete).toHaveBeenCalledTimes(1);
    expect(mockDelete).toHaveBeenCalledWith('/system/node_modules/mod-a');
  });

  it('interpolates arbitrary IDs into the delete URL', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await modulesApi.deleteModule('some-other-uuid');

    expect(mockDelete).toHaveBeenCalledWith('/system/node_modules/some-other-uuid');
  });

  it('resolves to void (returns undefined)', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    const result = await modulesApi.deleteModule('mod-a');

    expect(result).toBeUndefined();
  });
});

// =============================================================================
// getModuleCategories
// =============================================================================

describe('modulesApi.getModuleCategories', () => {
  it('calls GET /system/node_module_categories', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_module_categories: [CAT_A, CAT_B] })
    );

    const result = await modulesApi.getModuleCategories();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/node_module_categories');
    expect(result).toEqual([CAT_A, CAT_B]);
  });

  it('returns an empty array when node_module_categories is absent from the response', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({} as { node_module_categories: SystemNodeModuleCategory[] })
    );

    const result = await modulesApi.getModuleCategories();

    expect(result).toEqual([]);
  });

  it('returns an empty array when node_module_categories is an empty list', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_module_categories: [] })
    );

    const result = await modulesApi.getModuleCategories();

    expect(result).toEqual([]);
  });

  it('unwraps the full category objects returned by the backend', async () => {
    const cat = makeCategory({
      id: 'cat-full',
      name: 'full-cat',
      description: 'A category with all fields',
      parent_id: 'cat-root',
      parent_name: 'root',
      depth: 2,
      children_count: 3,
      module_count: 10,
    });
    mockGet.mockResolvedValueOnce(
      envelope({ node_module_categories: [cat] })
    );

    const result = await modulesApi.getModuleCategories();

    expect(result).toHaveLength(1);
    expect(result[0]).toEqual(cat);
  });
});

// =============================================================================
// getModuleCategory — single category
// =============================================================================

describe('modulesApi.getModuleCategory', () => {
  it('calls GET /system/node_module_categories/:id', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_module_category: CAT_A })
    );

    const result = await modulesApi.getModuleCategory('cat-a');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/node_module_categories/cat-a');
    expect(result).toEqual(CAT_A);
  });

  it('interpolates arbitrary IDs correctly', async () => {
    const cat = makeCategory({ id: 'some-cat-uuid' });
    mockGet.mockResolvedValueOnce(
      envelope({ node_module_category: cat })
    );

    await modulesApi.getModuleCategory('some-cat-uuid');

    expect(mockGet).toHaveBeenCalledWith('/system/node_module_categories/some-cat-uuid');
  });

  it('unwraps the node_module_category field from the envelope', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_module_category: CAT_B })
    );

    const result = await modulesApi.getModuleCategory('cat-b');

    expect(result.id).toBe('cat-b');
    expect(result.name).toBe('security');
    expect(result.parent_id).toBe('cat-a');
  });
});

// =============================================================================
// createModuleCategory
// =============================================================================

describe('modulesApi.createModuleCategory', () => {
  it('calls POST /system/node_module_categories with data wrapped in node_module_category key', async () => {
    const created = makeCategory({ id: 'new-cat', name: 'storage' });
    mockPost.mockResolvedValueOnce(
      envelope({ node_module_category: created })
    );

    const payload: ModuleCategoryCreate = { name: 'storage' };

    const result = await modulesApi.createModuleCategory(payload);

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_module_categories',
      { node_module_category: payload }
    );
    expect(result).toEqual(created);
  });

  it('wraps the full optional payload including parent_id', async () => {
    const fullPayload: ModuleCategoryCreate = {
      name: 'child-category',
      description: 'A nested category',
      parent_id: 'cat-parent',
      enabled: true,
    };

    const created = makeCategory({ id: 'child-cat', ...fullPayload });
    mockPost.mockResolvedValueOnce(envelope({ node_module_category: created }));

    await modulesApi.createModuleCategory(fullPayload);

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_module_categories',
      { node_module_category: fullPayload }
    );
  });

  it('returns the unwrapped created category', async () => {
    const created = makeCategory({ id: 'created-cat', name: 'runtime', depth: 1 });
    mockPost.mockResolvedValueOnce(envelope({ node_module_category: created }));

    const result = await modulesApi.createModuleCategory({ name: 'runtime' });

    expect(result.id).toBe('created-cat');
    expect(result.name).toBe('runtime');
    expect(result.depth).toBe(1);
  });
});

// =============================================================================
// updateModuleCategory
// =============================================================================

describe('modulesApi.updateModuleCategory', () => {
  it('calls PUT /system/node_module_categories/:id with partial data wrapped in node_module_category key', async () => {
    const updated = makeCategory({ id: 'cat-a', name: 'updated-networking' });
    mockPut.mockResolvedValueOnce(
      envelope({ node_module_category: updated })
    );

    const patch: Partial<ModuleCategoryCreate> = { name: 'updated-networking' };

    const result = await modulesApi.updateModuleCategory('cat-a', patch);

    expect(mockPut).toHaveBeenCalledTimes(1);
    expect(mockPut).toHaveBeenCalledWith(
      '/system/node_module_categories/cat-a',
      { node_module_category: patch }
    );
    expect(result).toEqual(updated);
  });

  it('interpolates the id into the URL', async () => {
    const updated = makeCategory({ id: 'target-cat-uuid' });
    mockPut.mockResolvedValueOnce(envelope({ node_module_category: updated }));

    await modulesApi.updateModuleCategory('target-cat-uuid', { description: 'Updated' });

    expect(mockPut).toHaveBeenCalledWith(
      '/system/node_module_categories/target-cat-uuid',
      { node_module_category: { description: 'Updated' } }
    );
  });

  it('accepts an empty patch object', async () => {
    const cat = makeCategory({ id: 'cat-a' });
    mockPut.mockResolvedValueOnce(envelope({ node_module_category: cat }));

    const result = await modulesApi.updateModuleCategory('cat-a', {});

    expect(mockPut).toHaveBeenCalledWith(
      '/system/node_module_categories/cat-a',
      { node_module_category: {} }
    );
    expect(result).toEqual(cat);
  });

  it('returns the unwrapped updated category', async () => {
    const updated = makeCategory({ id: 'cat-b', name: 'infra', parent_id: undefined });
    mockPut.mockResolvedValueOnce(envelope({ node_module_category: updated }));

    const result = await modulesApi.updateModuleCategory('cat-b', { name: 'infra' });

    expect(result.name).toBe('infra');
    expect(result.id).toBe('cat-b');
  });
});

// =============================================================================
// deleteModuleCategory
// =============================================================================

describe('modulesApi.deleteModuleCategory', () => {
  it('calls DELETE /system/node_module_categories/:id', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await modulesApi.deleteModuleCategory('cat-a');

    expect(mockDelete).toHaveBeenCalledTimes(1);
    expect(mockDelete).toHaveBeenCalledWith('/system/node_module_categories/cat-a');
  });

  it('interpolates arbitrary IDs into the delete URL', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await modulesApi.deleteModuleCategory('some-cat-uuid');

    expect(mockDelete).toHaveBeenCalledWith('/system/node_module_categories/some-cat-uuid');
  });

  it('resolves to void (returns undefined)', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    const result = await modulesApi.deleteModuleCategory('cat-a');

    expect(result).toBeUndefined();
  });
});

// =============================================================================
// getModuleDependencies
// =============================================================================

describe('modulesApi.getModuleDependencies', () => {
  it('calls GET /system/node_modules/:moduleId/dependencies', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ dependencies: [MODULE_A, MODULE_B] })
    );

    const result = await modulesApi.getModuleDependencies('mod-parent');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/node_modules/mod-parent/dependencies');
    expect(result).toEqual([MODULE_A, MODULE_B]);
  });

  it('returns an empty array when dependencies is absent from the response', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({} as { dependencies: SystemNodeModule[] })
    );

    const result = await modulesApi.getModuleDependencies('mod-no-deps');

    expect(result).toEqual([]);
  });

  it('returns an empty array when dependencies is an empty list', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ dependencies: [] })
    );

    const result = await modulesApi.getModuleDependencies('mod-empty');

    expect(result).toEqual([]);
  });

  it('interpolates the moduleId into the URL', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ dependencies: [MODULE_A] })
    );

    await modulesApi.getModuleDependencies('specific-module-uuid');

    expect(mockGet).toHaveBeenCalledWith(
      '/system/node_modules/specific-module-uuid/dependencies'
    );
  });

  it('unwraps the full dependency module objects', async () => {
    const dep = makeModule({ id: 'dep-1', name: 'dep-module', variety: 'config' });
    mockGet.mockResolvedValueOnce(envelope({ dependencies: [dep] }));

    const result = await modulesApi.getModuleDependencies('mod-parent');

    expect(result).toHaveLength(1);
    expect(result[0]).toEqual(dep);
  });
});

// =============================================================================
// addModuleDependency
// =============================================================================

describe('modulesApi.addModuleDependency', () => {
  it('calls POST /system/node_modules/:moduleId/module_dependencies with dependency_id', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true } });

    await modulesApi.addModuleDependency('mod-parent', 'dep-mod-id');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-parent/module_dependencies',
      { dependency: { dependency_id: 'dep-mod-id' } }
    );
  });

  it('merges dependency options into the dependency body', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true } });

    const opts: ModuleDependencyOptions = {
      dependency_type: 'runtime',
      required: true,
      version_constraint: '>= 1.0.0',
    };

    await modulesApi.addModuleDependency('mod-parent', 'dep-mod-id', opts);

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-parent/module_dependencies',
      {
        dependency: {
          dependency_id: 'dep-mod-id',
          dependency_type: 'runtime',
          required: true,
          version_constraint: '>= 1.0.0',
        },
      }
    );
  });

  it('sends only dependency_id when no options are provided', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true } });

    await modulesApi.addModuleDependency('mod-a', 'dep-b');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-a/module_dependencies',
      { dependency: { dependency_id: 'dep-b' } }
    );
  });

  it('sends only dependency_id when options is undefined', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true } });

    await modulesApi.addModuleDependency('mod-a', 'dep-b', undefined);

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-a/module_dependencies',
      { dependency: { dependency_id: 'dep-b' } }
    );
  });

  it('resolves to void (returns undefined)', async () => {
    mockPost.mockResolvedValueOnce({ data: { success: true } });

    const result = await modulesApi.addModuleDependency('mod-a', 'dep-b');

    expect(result).toBeUndefined();
  });
});

// =============================================================================
// removeModuleDependency
// =============================================================================

describe('modulesApi.removeModuleDependency', () => {
  it('calls DELETE /system/node_modules/:moduleId/module_dependencies/:dependencyId', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await modulesApi.removeModuleDependency('mod-parent', 'dep-mod-id');

    expect(mockDelete).toHaveBeenCalledTimes(1);
    expect(mockDelete).toHaveBeenCalledWith(
      '/system/node_modules/mod-parent/module_dependencies/dep-mod-id'
    );
  });

  it('interpolates both IDs into the URL', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await modulesApi.removeModuleDependency('module-uuid-abc', 'dep-uuid-xyz');

    expect(mockDelete).toHaveBeenCalledWith(
      '/system/node_modules/module-uuid-abc/module_dependencies/dep-uuid-xyz'
    );
  });

  it('resolves to void (returns undefined)', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    const result = await modulesApi.removeModuleDependency('mod-a', 'dep-b');

    expect(result).toBeUndefined();
  });
});

// =============================================================================
// importManifest
// =============================================================================

describe('modulesApi.importManifest', () => {
  const YAML_CONTENT = 'name: net-base\nvariety: config\nfile_spec:\n  - /etc/**';

  it('calls POST /system/node_modules/:id/import_manifest with yaml and create_version=false by default', async () => {
    const responsePayload = {
      node_module: MODULE_A,
      node_module_version_id: null,
      resolved_dependencies: [],
    };
    mockPost.mockResolvedValueOnce(envelope(responsePayload));

    const result = await modulesApi.importManifest('mod-a', YAML_CONTENT);

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-a/import_manifest',
      {
        yaml: YAML_CONTENT,
        create_version: false,
        changelog: undefined,
      }
    );
    expect(result.node_module).toEqual(MODULE_A);
    expect(result.node_module_version_id).toBeNull();
    expect(result.resolved_dependencies).toEqual([]);
  });

  it('passes create_version=true and changelog when provided', async () => {
    const responsePayload = {
      node_module: MODULE_A,
      node_module_version_id: 'ver-123',
      resolved_dependencies: [
        { repo: 'dep-repo', constraint: '>= 1.0', status: 'resolved' },
      ],
    };
    mockPost.mockResolvedValueOnce(envelope(responsePayload));

    const result = await modulesApi.importManifest('mod-a', YAML_CONTENT, {
      createVersion: true,
      changelog: 'Added networking support',
    });

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-a/import_manifest',
      {
        yaml: YAML_CONTENT,
        create_version: true,
        changelog: 'Added networking support',
      }
    );
    expect(result.node_module_version_id).toBe('ver-123');
    expect(result.resolved_dependencies).toHaveLength(1);
    expect(result.resolved_dependencies[0].repo).toBe('dep-repo');
    expect(result.resolved_dependencies[0].status).toBe('resolved');
  });

  it('defaults create_version to false when options is an empty object', async () => {
    mockPost.mockResolvedValueOnce(
      envelope({ node_module: MODULE_A, node_module_version_id: null, resolved_dependencies: [] })
    );

    await modulesApi.importManifest('mod-a', YAML_CONTENT, {});

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-a/import_manifest',
      {
        yaml: YAML_CONTENT,
        create_version: false,
        changelog: undefined,
      }
    );
  });

  it('defaults create_version to false when options is omitted entirely', async () => {
    mockPost.mockResolvedValueOnce(
      envelope({ node_module: MODULE_A, node_module_version_id: null, resolved_dependencies: [] })
    );

    await modulesApi.importManifest('mod-a', YAML_CONTENT);

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-a/import_manifest',
      {
        yaml: YAML_CONTENT,
        create_version: false,
        changelog: undefined,
      }
    );
  });

  it('interpolates the moduleId into the URL', async () => {
    mockPost.mockResolvedValueOnce(
      envelope({ node_module: MODULE_B, node_module_version_id: null, resolved_dependencies: [] })
    );

    await modulesApi.importManifest('some-module-uuid', YAML_CONTENT);

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/some-module-uuid/import_manifest',
      expect.any(Object)
    );
  });

  it('returns the full response payload including resolved_dependencies', async () => {
    const deps = [
      { repo: 'repo-a', constraint: '^2.0', status: 'resolved' },
      { repo: 'repo-b', status: 'not_found' },
    ];
    mockPost.mockResolvedValueOnce(
      envelope({
        node_module: MODULE_A,
        node_module_version_id: 'ver-456',
        resolved_dependencies: deps,
      })
    );

    const result = await modulesApi.importManifest('mod-a', YAML_CONTENT, { createVersion: true });

    expect(result.resolved_dependencies).toHaveLength(2);
    expect(result.resolved_dependencies[0]).toEqual({ repo: 'repo-a', constraint: '^2.0', status: 'resolved' });
    expect(result.resolved_dependencies[1]).toEqual({ repo: 'repo-b', status: 'not_found' });
  });
});

// =============================================================================
// markModuleAsCanary (honeypot canary toggle)
// =============================================================================

describe('modulesApi.markModuleAsCanary', () => {
  it('calls POST /system/node_modules/:id/mark_canary with empty body when no lureKind provided', async () => {
    const canaryMod = makeModule({ id: 'mod-a' });
    mockPost.mockResolvedValueOnce(envelope({ node_module: canaryMod }));

    const result = await modulesApi.markModuleAsCanary('mod-a');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-a/mark_canary',
      {}
    );
    expect(result).toEqual(canaryMod);
  });

  it('includes lure_kind in the body when provided', async () => {
    const canaryMod = makeModule({ id: 'mod-a' });
    mockPost.mockResolvedValueOnce(envelope({ node_module: canaryMod }));

    await modulesApi.markModuleAsCanary('mod-a', 'credentials');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-a/mark_canary',
      { lure_kind: 'credentials' }
    );
  });

  it('sends empty body when lureKind is undefined', async () => {
    const canaryMod = makeModule({ id: 'mod-b' });
    mockPost.mockResolvedValueOnce(envelope({ node_module: canaryMod }));

    await modulesApi.markModuleAsCanary('mod-b', undefined);

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-b/mark_canary',
      {}
    );
  });

  it('interpolates the moduleId into the URL', async () => {
    const canaryMod = makeModule({ id: 'target-uuid' });
    mockPost.mockResolvedValueOnce(envelope({ node_module: canaryMod }));

    await modulesApi.markModuleAsCanary('target-uuid', 'config');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/target-uuid/mark_canary',
      { lure_kind: 'config' }
    );
  });

  it('returns the unwrapped updated module', async () => {
    const canaryMod = makeModule({ id: 'mod-a', name: 'canary-module' });
    mockPost.mockResolvedValueOnce(envelope({ node_module: canaryMod }));

    const result = await modulesApi.markModuleAsCanary('mod-a');

    expect(result.id).toBe('mod-a');
    expect(result.name).toBe('canary-module');
  });
});

// =============================================================================
// unmarkModuleAsCanary (honeypot canary toggle)
// =============================================================================

describe('modulesApi.unmarkModuleAsCanary', () => {
  it('calls POST /system/node_modules/:id/unmark_canary with empty body', async () => {
    const uncanaryMod = makeModule({ id: 'mod-a' });
    mockPost.mockResolvedValueOnce(envelope({ node_module: uncanaryMod }));

    const result = await modulesApi.unmarkModuleAsCanary('mod-a');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/mod-a/unmark_canary',
      {}
    );
    expect(result).toEqual(uncanaryMod);
  });

  it('interpolates the moduleId into the URL', async () => {
    const mod = makeModule({ id: 'some-module-uuid' });
    mockPost.mockResolvedValueOnce(envelope({ node_module: mod }));

    await modulesApi.unmarkModuleAsCanary('some-module-uuid');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_modules/some-module-uuid/unmark_canary',
      {}
    );
  });

  it('always sends an empty body (no options parameter)', async () => {
    const mod = makeModule({ id: 'mod-b' });
    mockPost.mockResolvedValueOnce(envelope({ node_module: mod }));

    await modulesApi.unmarkModuleAsCanary('mod-b');

    const [, body] = mockPost.mock.calls[0];
    expect(body).toEqual({});
  });

  it('returns the unwrapped updated module', async () => {
    const mod = makeModule({ id: 'mod-a', name: 'regular-module' });
    mockPost.mockResolvedValueOnce(envelope({ node_module: mod }));

    const result = await modulesApi.unmarkModuleAsCanary('mod-a');

    expect(result.id).toBe('mod-a');
    expect(result.name).toBe('regular-module');
  });
});

// =============================================================================
// Version lifecycle (IMP-c4235dad3779)
// =============================================================================

describe('modulesApi.getModuleVersions', () => {
  it('GETs /system/node_modules/:id/versions and unwraps versions + current pointer', async () => {
    const versionRow = {
      id: 'ver-2',
      node_module_id: 'mod-a',
      version_number: 2,
      promotion_state: 'built',
      changelog: 'second cut',
      oci_digest: 'sha256:abc',
      staging_baked_at: null,
      blessed_at: null,
      live_at: null,
      retired_at: null,
      created_at: '2026-07-01T00:00:00Z',
    };
    mockGet.mockResolvedValue({
      data: {
        success: true,
        data: {
          versions: [versionRow],
          current_version_id: 'ver-1',
          current_version_number: 1,
        },
      },
    });

    const result = await modulesApi.getModuleVersions('mod-a');

    expect(mockGet).toHaveBeenCalledWith('/system/node_modules/mod-a/versions');
    expect(result.versions).toEqual([versionRow]);
    expect(result.current_version_id).toBe('ver-1');
    expect(result.current_version_number).toBe(1);
  });

  it('defaults to empty versions when the module has none', async () => {
    mockGet.mockResolvedValue({
      data: {
        success: true,
        data: { versions: [], current_version_id: null, current_version_number: null },
      },
    });

    const result = await modulesApi.getModuleVersions('mod-bare');

    expect(result.versions).toEqual([]);
    expect(result.current_version_id).toBeNull();
  });
});

describe('modulesApi.promoteModuleVersion', () => {
  it('POSTs /system/node_module_versions/:id/promote with target_state', async () => {
    const promoted = {
      id: 'ver-2',
      node_module_id: 'mod-a',
      version_number: 2,
      promotion_state: 'staging',
      changelog: null,
      staging_baked_at: '2026-07-23T00:00:00Z',
      blessed_at: null,
      live_at: null,
      retired_at: null,
      created_at: '2026-07-01T00:00:00Z',
    };
    mockPost.mockResolvedValue({
      data: { success: true, data: { node_module_version: promoted } },
    });

    const result = await modulesApi.promoteModuleVersion('ver-2', 'staging');

    expect(mockPost).toHaveBeenCalledWith('/system/node_module_versions/ver-2/promote', {
      target_state: 'staging',
    });
    expect(result.node_module_version.promotion_state).toBe('staging');
    // An ungated target carries no verdict at all — the shape stays untouched.
    expect(result.promotion_criteria).toBeUndefined();
    expect(result.promotion_criteria_warning).toBeUndefined();
  });

  // IMP-bdb650b82c65 — the backend (IMP-d6826c872d88) consults PromotionCriteria
  // on a gated promote and WARNS, never refuses (operator ruling D17): the
  // envelope carries `promotion_criteria` and, when unmet,
  // `promotion_criteria_warning`. Returning only node_module_version dropped
  // both on the floor, so the panel could never show the warning.
  it('returns the promotion_criteria verdict and warning alongside the version', async () => {
    const blessed = {
      id: 'ver-2',
      node_module_id: 'mod-a',
      version_number: 2,
      promotion_state: 'blessed',
      changelog: null,
      staging_baked_at: '2026-07-23T00:00:00Z',
      blessed_at: '2026-07-24T00:00:00Z',
      live_at: null,
      retired_at: null,
      created_at: '2026-07-01T00:00:00Z',
    };
    const criteria = {
      eligible: false,
      reason: 'running_count 0 < required 3',
      running_count: 0,
      required_count: 3,
    };
    const warning = 'promoted to blessed despite unmet promotion criteria: running_count 0 < required 3';
    mockPost.mockResolvedValue({
      data: {
        success: true,
        data: {
          node_module_version: blessed,
          promotion_criteria: criteria,
          promotion_criteria_warning: warning,
        },
      },
    });

    const result = await modulesApi.promoteModuleVersion('ver-2', 'blessed');

    expect(result.node_module_version.promotion_state).toBe('blessed');
    expect(result.promotion_criteria).toEqual(criteria);
    expect(result.promotion_criteria_warning).toBe(warning);
  });
});

describe('modulesApi.rollbackModule', () => {
  it('POSTs /system/node_modules/:id/rollback with target_version_id + changelog', async () => {
    const payload = {
      node_module: { id: 'mod-a', name: 'regular-module' },
      new_version: { id: 'ver-3', version_number: 3, changelog: 'rollback to v1' },
    };
    mockPost.mockResolvedValue({ data: { success: true, data: payload } });

    const result = await modulesApi.rollbackModule('mod-a', {
      targetVersionId: 'ver-1',
      changelog: 'rollback to v1',
    });

    expect(mockPost).toHaveBeenCalledWith('/system/node_modules/mod-a/rollback', {
      target_version_id: 'ver-1',
      changelog: 'rollback to v1',
    });
    expect(result.new_version.version_number).toBe(3);
  });

  it('sends an empty body to roll back to the previous version', async () => {
    mockPost.mockResolvedValue({
      data: {
        success: true,
        data: {
          node_module: { id: 'mod-a' },
          new_version: { id: 'ver-4', version_number: 4, changelog: null },
        },
      },
    });

    await modulesApi.rollbackModule('mod-a');

    expect(mockPost).toHaveBeenCalledWith('/system/node_modules/mod-a/rollback', {});
  });
});

// =============================================================================
// Per-node assignment toggle (IMP-3e9620967632)
// =============================================================================

describe('modulesApi.enableModuleAssignment', () => {
  it('POSTs /system/node_module_assignments/:id/enable and unwraps the assignment', async () => {
    const row = {
      id: 'nma-1',
      node_id: 'node-1',
      node_module_id: 'mod-a',
      enabled: true,
      priority: 5,
      config: null,
      created_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-07-01T00:00:00Z',
    };
    mockPost.mockResolvedValue({
      data: { success: true, data: { node_module_assignment: row }, message: 'Assignment enabled' },
    });

    const result = await modulesApi.enableModuleAssignment('nma-1');

    expect(mockPost).toHaveBeenCalledWith('/system/node_module_assignments/nma-1/enable', {});
    expect(result).toEqual(row);
  });
});

describe('modulesApi.disableModuleAssignment', () => {
  it('POSTs /system/node_module_assignments/:id/disable and unwraps the assignment', async () => {
    const row = {
      id: 'nma-1',
      node_id: 'node-1',
      node_module_id: 'mod-a',
      enabled: false,
      priority: 5,
      config: null,
      created_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-07-01T00:00:00Z',
    };
    mockPost.mockResolvedValue({
      data: { success: true, data: { node_module_assignment: row }, message: 'Assignment disabled' },
    });

    const result = await modulesApi.disableModuleAssignment('nma-1');

    expect(mockPost).toHaveBeenCalledWith('/system/node_module_assignments/nma-1/disable', {});
    expect(result.enabled).toBe(false);
  });
});
