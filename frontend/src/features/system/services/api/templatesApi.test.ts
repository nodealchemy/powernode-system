/**
 * Behavioral tests for templatesApi.
 *
 * Covers every exported function: request shaping (exact URLs, payloads,
 * query params), response unwrapping via extractData / extractPaginated,
 * the collection-key rename (node_templates → templates), edge cases
 * (empty collection fallback, optional fields, void deletes), the
 * exportTemplate browser-download side-effect, and composePreview's
 * pass-through data extraction.
 */

import {
  templatesApi,
  type TemplateCreate,
  type TemplateModuleAssignment,
  type TemplateComposePreview,
} from './templatesApi';
import type { SystemNodeTemplate, SystemNodeModule } from '../../types/system.types';
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
// Fixtures & helpers
// =============================================================================

/**
 * Double-envelope helper for non-paginated (ApiEnvelope) responses.
 *   AxiosResponse.data = { success: true, data: <payload> }
 */
function envelope<T>(payload: T) {
  return { data: { success: true as const, data: payload } };
}

/**
 * Double-envelope helper for paginated (PaginatedEnvelope) responses.
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
  return { data: { success: true as const, data: payload, meta: defaultMeta } };
}

function makeTemplate(overrides: Partial<SystemNodeTemplate> = {}): SystemNodeTemplate {
  return {
    id: 'tpl-1',
    name: 'ubuntu-base',
    description: 'Ubuntu 22.04 base template',
    enabled: true,
    public: true,
    admin_user: 'root',
    config: {},
    node_platform_id: 'plat-1',
    node_platform_name: 'ubuntu-22-x86',
    node_count: 3,
    module_count: 2,
    modules: [],
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    ...overrides,
  };
}

function makeModule(overrides: Partial<SystemNodeModule> = {}): SystemNodeModule {
  return {
    id: 'mod-1',
    name: 'net-base',
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

function makeAssignment(overrides: Partial<TemplateModuleAssignment> = {}): TemplateModuleAssignment {
  return {
    id: 'assign-1',
    node_template_id: 'tpl-1',
    node_module_id: 'mod-1',
    enabled: true,
    priority: 100,
    ...overrides,
  };
}

const DEFAULT_META: PaginationMeta = {
  current_page: 1,
  per_page: 20,
  total_count: 2,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

const TPL_A = makeTemplate({ id: 'tpl-a', name: 'ubuntu-base' });
const TPL_B = makeTemplate({ id: 'tpl-b', name: 'debian-12' });

const MOD_A = makeModule({ id: 'mod-a', name: 'net-base' });
const MOD_B = makeModule({ id: 'mod-b', name: 'ssh-daemon', variety: 'instance' });

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
// getTemplates — paginated list with collection-key rename
// =============================================================================

describe('templatesApi.getTemplates', () => {
  it('calls GET /system/node_templates with no params when called without arguments', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ node_templates: [TPL_A, TPL_B] }, DEFAULT_META)
    );

    await templatesApi.getTemplates();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/node_templates', { params: undefined });
  });

  it('passes pagination params to the query string when provided', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ node_templates: [TPL_A] }, { total_count: 1 })
    );

    await templatesApi.getTemplates({ page: 2, per_page: 10 });

    expect(mockGet).toHaveBeenCalledWith('/system/node_templates', {
      params: { page: 2, per_page: 10 },
    });
  });

  it('renames node_templates → templates in the returned object', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ node_templates: [TPL_A, TPL_B] }, DEFAULT_META)
    );

    const result = await templatesApi.getTemplates();

    expect(result.templates).toEqual([TPL_A, TPL_B]);
  });

  it('returns pagination meta from the response root (not from inside data)', async () => {
    const meta: PaginationMeta = {
      current_page: 3,
      per_page: 5,
      total_count: 15,
      total_pages: 3,
      next_page: null,
      prev_page: 2,
    };
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ node_templates: [TPL_A] }, meta)
    );

    const result = await templatesApi.getTemplates();

    expect(result.meta.current_page).toBe(3);
    expect(result.meta.total_count).toBe(15);
    expect(result.meta.total_pages).toBe(3);
    expect(result.meta.prev_page).toBe(2);
  });

  it('returns an empty templates array when node_templates is absent from the response', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({} as { node_templates: SystemNodeTemplate[] }, { total_count: 0 })
    );

    const result = await templatesApi.getTemplates();

    expect(result.templates).toEqual([]);
  });

  it('propagates API errors without swallowing them', async () => {
    const err = new Error('Network error');
    mockGet.mockRejectedValueOnce(err);

    await expect(templatesApi.getTemplates()).rejects.toThrow('Network error');
  });
});

// =============================================================================
// getTemplate — single record fetch
// =============================================================================

describe('templatesApi.getTemplate', () => {
  it('calls GET /system/node_templates/:id with the correct id', async () => {
    mockGet.mockResolvedValueOnce(envelope({ node_template: TPL_A }));

    await templatesApi.getTemplate('tpl-a');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/node_templates/tpl-a');
  });

  it('returns the node_template record unwrapped from the envelope', async () => {
    mockGet.mockResolvedValueOnce(envelope({ node_template: TPL_A }));

    const result = await templatesApi.getTemplate('tpl-a');

    expect(result).toEqual(TPL_A);
  });

  it('preserves all fields including optional ones', async () => {
    const rich = makeTemplate({
      id: 'tpl-rich',
      description: 'A fully populated template',
      admin_user: 'ubuntu',
      node_platform_id: 'plat-x',
      node_platform_name: 'custom-platform',
      node_count: 7,
      module_count: 3,
    });
    mockGet.mockResolvedValueOnce(envelope({ node_template: rich }));

    const result = await templatesApi.getTemplate('tpl-rich');

    expect(result.description).toBe('A fully populated template');
    expect(result.admin_user).toBe('ubuntu');
    expect(result.node_count).toBe(7);
    expect(result.module_count).toBe(3);
  });

  it('propagates API errors', async () => {
    mockGet.mockRejectedValueOnce(new Error('Not found'));

    await expect(templatesApi.getTemplate('bad-id')).rejects.toThrow('Not found');
  });
});

// =============================================================================
// createTemplate — POST with node_template wrapper
// =============================================================================

describe('templatesApi.createTemplate', () => {
  const CREATE_DATA: TemplateCreate = {
    name: 'new-template',
    description: 'Test template',
    node_platform_id: 'plat-1',
    admin_user: 'root',
    enabled: true,
    public: false,
    config: { key: 'value' },
  };

  it('calls POST /system/node_templates with payload wrapped in node_template key', async () => {
    mockPost.mockResolvedValueOnce(envelope({ node_template: TPL_A }));

    await templatesApi.createTemplate(CREATE_DATA);

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith('/system/node_templates', {
      node_template: CREATE_DATA,
    });
  });

  it('returns the newly created template unwrapped from the envelope', async () => {
    const created = makeTemplate({ id: 'tpl-new', name: 'new-template' });
    mockPost.mockResolvedValueOnce(envelope({ node_template: created }));

    const result = await templatesApi.createTemplate(CREATE_DATA);

    expect(result).toEqual(created);
    expect(result.id).toBe('tpl-new');
  });

  it('sends only required fields when optional fields are omitted', async () => {
    mockPost.mockResolvedValueOnce(envelope({ node_template: TPL_A }));

    await templatesApi.createTemplate({ name: 'minimal' });

    expect(mockPost).toHaveBeenCalledWith('/system/node_templates', {
      node_template: { name: 'minimal' },
    });
  });

  it('propagates API errors', async () => {
    mockPost.mockRejectedValueOnce(new Error('Validation failed'));

    await expect(templatesApi.createTemplate({ name: 'bad' })).rejects.toThrow(
      'Validation failed'
    );
  });
});

// =============================================================================
// updateTemplate — PUT with partial node_template wrapper
// =============================================================================

describe('templatesApi.updateTemplate', () => {
  it('calls PUT /system/node_templates/:id with the partial payload wrapped in node_template key', async () => {
    mockPut.mockResolvedValueOnce(envelope({ node_template: TPL_A }));

    await templatesApi.updateTemplate('tpl-a', { name: 'renamed', enabled: false });

    expect(mockPut).toHaveBeenCalledTimes(1);
    expect(mockPut).toHaveBeenCalledWith('/system/node_templates/tpl-a', {
      node_template: { name: 'renamed', enabled: false },
    });
  });

  it('returns the updated template unwrapped from the envelope', async () => {
    const updated = makeTemplate({ id: 'tpl-a', name: 'renamed', enabled: false });
    mockPut.mockResolvedValueOnce(envelope({ node_template: updated }));

    const result = await templatesApi.updateTemplate('tpl-a', { name: 'renamed', enabled: false });

    expect(result.name).toBe('renamed');
    expect(result.enabled).toBe(false);
  });

  it('accepts a partial update with only a single field', async () => {
    mockPut.mockResolvedValueOnce(envelope({ node_template: TPL_A }));

    await templatesApi.updateTemplate('tpl-a', { public: true });

    expect(mockPut).toHaveBeenCalledWith('/system/node_templates/tpl-a', {
      node_template: { public: true },
    });
  });

  it('propagates API errors', async () => {
    mockPut.mockRejectedValueOnce(new Error('Conflict'));

    await expect(
      templatesApi.updateTemplate('tpl-a', { name: 'x' })
    ).rejects.toThrow('Conflict');
  });
});

// =============================================================================
// deleteTemplate — DELETE returns void
// =============================================================================

describe('templatesApi.deleteTemplate', () => {
  it('calls DELETE /system/node_templates/:id', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await templatesApi.deleteTemplate('tpl-a');

    expect(mockDelete).toHaveBeenCalledTimes(1);
    expect(mockDelete).toHaveBeenCalledWith('/system/node_templates/tpl-a');
  });

  it('returns void (undefined) on success', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    const result = await templatesApi.deleteTemplate('tpl-a');

    expect(result).toBeUndefined();
  });

  it('propagates API errors', async () => {
    mockDelete.mockRejectedValueOnce(new Error('Forbidden'));

    await expect(templatesApi.deleteTemplate('tpl-a')).rejects.toThrow('Forbidden');
  });
});

// =============================================================================
// exportTemplate — GET with responseType: 'blob', then browser download side-effect
// =============================================================================

// jsdom does not implement URL.createObjectURL or URL.revokeObjectURL.
// Install module-level stubs before the describe block so they survive
// beforeEach/afterEach cycles without using jest.spyOn (which requires the
// property to already exist on the object).
const mockCreateObjectURL = jest.fn(() => 'blob:mock-url');
const mockRevokeObjectURL = jest.fn();
(URL as unknown as Record<string, unknown>).createObjectURL = mockCreateObjectURL;
(URL as unknown as Record<string, unknown>).revokeObjectURL = mockRevokeObjectURL;

describe('templatesApi.exportTemplate', () => {
  let appendChildSpy: jest.SpyInstance;
  let removeChildSpy: jest.SpyInstance;
  let clickSpy: jest.Mock;

  beforeEach(() => {
    mockCreateObjectURL.mockClear();
    mockRevokeObjectURL.mockClear();
    clickSpy = jest.fn();

    appendChildSpy = jest
      .spyOn(document.body, 'appendChild')
      .mockImplementation((node) => node as Node);
    removeChildSpy = jest
      .spyOn(document.body, 'removeChild')
      .mockImplementation((node) => node as Node);

    // Intercept createElement so we can capture the link element and attach our click mock
    const origCreate = document.createElement.bind(document);
    jest.spyOn(document, 'createElement').mockImplementation((tag: string) => {
      const el = origCreate(tag);
      if (tag === 'a') {
        el.click = clickSpy;
      }
      return el;
    });
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('calls GET /system/node_templates/:id/export with responseType blob', async () => {
    const blob = new Blob(['{}'], { type: 'application/json' });
    mockGet.mockResolvedValueOnce({
      data: blob,
      headers: { 'content-disposition': 'attachment; filename="template-export.json"' },
    });

    await templatesApi.exportTemplate('tpl-a');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/node_templates/tpl-a/export', {
      responseType: 'blob',
    });
  });

  it('extracts filename from Content-Disposition header and uses it as the download attribute', async () => {
    const blob = new Blob(['{}'], { type: 'application/json' });
    mockGet.mockResolvedValueOnce({
      data: blob,
      headers: { 'content-disposition': 'attachment; filename="my-custom-template.json"' },
    });

    await templatesApi.exportTemplate('tpl-a');

    const appendedEl = appendChildSpy.mock.calls[0][0] as HTMLAnchorElement;
    expect(appendedEl.download).toBe('my-custom-template.json');
  });

  it('falls back to system-template-<id>.json when Content-Disposition header is missing', async () => {
    const blob = new Blob(['{}'], { type: 'application/json' });
    mockGet.mockResolvedValueOnce({
      data: blob,
      headers: {},
    });

    await templatesApi.exportTemplate('tpl-xyz');

    const appendedEl = appendChildSpy.mock.calls[0][0] as HTMLAnchorElement;
    expect(appendedEl.download).toBe('system-template-tpl-xyz.json');
  });

  it('falls back to system-template-<id>.json when headers object is absent', async () => {
    const blob = new Blob(['{}'], { type: 'application/json' });
    mockGet.mockResolvedValueOnce({ data: blob });

    await templatesApi.exportTemplate('tpl-abc');

    const appendedEl = appendChildSpy.mock.calls[0][0] as HTMLAnchorElement;
    expect(appendedEl.download).toBe('system-template-tpl-abc.json');
  });

  it('creates an object URL, triggers a click, then revokes the URL', async () => {
    const blob = new Blob(['{}'], { type: 'application/json' });
    mockGet.mockResolvedValueOnce({
      data: blob,
      headers: { 'content-disposition': '' },
    });

    await templatesApi.exportTemplate('tpl-a');

    expect(mockCreateObjectURL).toHaveBeenCalledTimes(1);
    expect(clickSpy).toHaveBeenCalledTimes(1);
    // revokeObjectURL is called with whatever createObjectURL returned
    const createdUrl = mockCreateObjectURL.mock.results[0].value as string;
    expect(mockRevokeObjectURL).toHaveBeenCalledWith(createdUrl);
  });

  it('appends then removes the anchor link from document.body', async () => {
    const blob = new Blob(['{}'], { type: 'application/json' });
    mockGet.mockResolvedValueOnce({
      data: blob,
      headers: {},
    });

    await templatesApi.exportTemplate('tpl-a');

    expect(appendChildSpy).toHaveBeenCalledTimes(1);
    expect(removeChildSpy).toHaveBeenCalledTimes(1);
  });

  it('wraps non-Blob response data in a JSON Blob before creating the object URL', async () => {
    const jsonPayload = { id: 'tpl-1', name: 'ubuntu-base' };
    mockGet.mockResolvedValueOnce({
      data: jsonPayload,
      headers: {},
    });

    await templatesApi.exportTemplate('tpl-json');

    // createObjectURL should still be called — the fallback Blob path triggers it
    expect(mockCreateObjectURL).toHaveBeenCalledTimes(1);
    const blobArg = mockCreateObjectURL.mock.calls[0][0] as Blob;
    expect(blobArg).toBeInstanceOf(Blob);
    expect(blobArg.type).toBe('application/json');
  });

  it('returns void (undefined) on success', async () => {
    const blob = new Blob(['{}'], { type: 'application/json' });
    mockGet.mockResolvedValueOnce({ data: blob, headers: {} });

    const result = await templatesApi.exportTemplate('tpl-a');

    expect(result).toBeUndefined();
  });
});

// =============================================================================
// getTemplateModules — fetch modules attached to a template
// =============================================================================

describe('templatesApi.getTemplateModules', () => {
  it('calls GET /system/node_templates/:templateId/modules', async () => {
    mockGet.mockResolvedValueOnce(envelope({ node_modules: [MOD_A, MOD_B] }));

    await templatesApi.getTemplateModules('tpl-a');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/node_templates/tpl-a/modules');
  });

  it('returns modules array under the modules key', async () => {
    mockGet.mockResolvedValueOnce(envelope({ node_modules: [MOD_A, MOD_B] }));

    const result = await templatesApi.getTemplateModules('tpl-a');

    expect(result.modules).toEqual([MOD_A, MOD_B]);
    expect(result.modules).toHaveLength(2);
  });

  it('returns an empty modules array when node_modules is absent from the response', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({} as { node_modules: SystemNodeModule[] })
    );

    const result = await templatesApi.getTemplateModules('tpl-a');

    expect(result.modules).toEqual([]);
  });

  it('propagates API errors', async () => {
    mockGet.mockRejectedValueOnce(new Error('Not found'));

    await expect(templatesApi.getTemplateModules('bad-id')).rejects.toThrow('Not found');
  });
});

// =============================================================================
// assignModuleToTemplate — POST to /modules endpoint
// =============================================================================

describe('templatesApi.assignModuleToTemplate', () => {
  it('calls POST /system/node_templates/:templateId/modules with node_module_id payload', async () => {
    const assignment = makeAssignment({ node_template_id: 'tpl-a', node_module_id: 'mod-a' });
    mockPost.mockResolvedValueOnce(envelope({ template_module: assignment }));

    await templatesApi.assignModuleToTemplate('tpl-a', 'mod-a');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_templates/tpl-a/modules',
      { node_module_id: 'mod-a' }
    );
  });

  it('returns the TemplateModuleAssignment record unwrapped from the envelope', async () => {
    const assignment = makeAssignment({
      id: 'assign-99',
      node_template_id: 'tpl-a',
      node_module_id: 'mod-a',
      enabled: true,
      priority: 200,
    });
    mockPost.mockResolvedValueOnce(envelope({ template_module: assignment }));

    const result = await templatesApi.assignModuleToTemplate('tpl-a', 'mod-a');

    expect(result).toEqual(assignment);
    expect(result.id).toBe('assign-99');
    expect(result.node_template_id).toBe('tpl-a');
    expect(result.node_module_id).toBe('mod-a');
    expect(result.priority).toBe(200);
  });

  it('propagates API errors', async () => {
    mockPost.mockRejectedValueOnce(new Error('Already assigned'));

    await expect(
      templatesApi.assignModuleToTemplate('tpl-a', 'mod-a')
    ).rejects.toThrow('Already assigned');
  });
});

// =============================================================================
// unassignModuleFromTemplate — DELETE returns void
// =============================================================================

describe('templatesApi.unassignModuleFromTemplate', () => {
  it('calls DELETE /system/node_templates/:templateId/modules/:moduleId', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await templatesApi.unassignModuleFromTemplate('tpl-a', 'mod-a');

    expect(mockDelete).toHaveBeenCalledTimes(1);
    expect(mockDelete).toHaveBeenCalledWith(
      '/system/node_templates/tpl-a/modules/mod-a'
    );
  });

  it('returns void (undefined) on success', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    const result = await templatesApi.unassignModuleFromTemplate('tpl-a', 'mod-a');

    expect(result).toBeUndefined();
  });

  it('propagates API errors', async () => {
    mockDelete.mockRejectedValueOnce(new Error('Not found'));

    await expect(
      templatesApi.unassignModuleFromTemplate('tpl-a', 'mod-z')
    ).rejects.toThrow('Not found');
  });
});

// =============================================================================
// composePreview — POST with module_ids, returns TemplateComposePreview
// =============================================================================

describe('templatesApi.composePreview', () => {
  const PREVIEW: TemplateComposePreview = {
    modules: [
      {
        id: 'mod-a',
        name: 'net-base',
        variety: 'config',
        priority: 100,
        effective_priority: 100,
        category_id: 'cat-1',
        current_version: { id: 'ver-1', version_number: 1, oci_digest: 'sha256:abc' },
      },
    ],
    conflicts: [],
    footprint: {
      module_count: 1,
      estimated_package_count: 5,
      architectures: ['x86_64'],
    },
    dependency_graph: {
      nodes: [{ id: 'mod-a', name: 'net-base', variety: 'config' }],
      edges: [],
    },
  };

  it('calls POST /system/node_templates/compose_preview with module_ids payload', async () => {
    mockPost.mockResolvedValueOnce(envelope(PREVIEW));

    await templatesApi.composePreview(['mod-a', 'mod-b']);

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_templates/compose_preview',
      { module_ids: ['mod-a', 'mod-b'] }
    );
  });

  it('returns the full TemplateComposePreview object unwrapped from the envelope', async () => {
    mockPost.mockResolvedValueOnce(envelope(PREVIEW));

    const result = await templatesApi.composePreview(['mod-a']);

    expect(result).toEqual(PREVIEW);
    expect(result.footprint.module_count).toBe(1);
    expect(result.footprint.architectures).toEqual(['x86_64']);
    expect(result.dependency_graph.nodes).toHaveLength(1);
    expect(result.dependency_graph.edges).toHaveLength(0);
  });

  it('returns an empty conflicts array when no conflicts exist', async () => {
    mockPost.mockResolvedValueOnce(envelope({ ...PREVIEW, conflicts: [] }));

    const result = await templatesApi.composePreview(['mod-a']);

    expect(result.conflicts).toEqual([]);
  });

  it('surfaces conflict details when conflicts are present', async () => {
    const withConflicts: TemplateComposePreview = {
      ...PREVIEW,
      conflicts: [
        {
          kind: 'instance_variety_collision',
          category_id: 'cat-1',
          module_ids: ['mod-a', 'mod-b'],
          detail: 'Two instance-variety modules share the same category.',
        },
        {
          kind: 'mount_path_collision',
          path: '/etc/resolv.conf',
          detail: 'Two modules claim /etc/resolv.conf.',
        },
      ],
    };
    mockPost.mockResolvedValueOnce(envelope(withConflicts));

    const result = await templatesApi.composePreview(['mod-a', 'mod-b']);

    expect(result.conflicts).toHaveLength(2);
    expect(result.conflicts[0].kind).toBe('instance_variety_collision');
    expect(result.conflicts[0].module_ids).toEqual(['mod-a', 'mod-b']);
    expect(result.conflicts[1].kind).toBe('mount_path_collision');
    expect(result.conflicts[1].path).toBe('/etc/resolv.conf');
  });

  it('handles an empty module_ids array', async () => {
    const emptyPreview: TemplateComposePreview = {
      modules: [],
      conflicts: [],
      footprint: { module_count: 0, estimated_package_count: 0, architectures: [] },
      dependency_graph: { nodes: [], edges: [] },
    };
    mockPost.mockResolvedValueOnce(envelope(emptyPreview));

    const result = await templatesApi.composePreview([]);

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_templates/compose_preview',
      { module_ids: [] }
    );
    expect(result.modules).toEqual([]);
  });

  it('handles modules with null current_version', async () => {
    const previewNullVersion: TemplateComposePreview = {
      ...PREVIEW,
      modules: [
        {
          id: 'mod-new',
          name: 'unpublished',
          variety: 'config',
          priority: 50,
          effective_priority: 50,
          category_id: null,
          current_version: null,
        },
      ],
    };
    mockPost.mockResolvedValueOnce(envelope(previewNullVersion));

    const result = await templatesApi.composePreview(['mod-new']);

    expect(result.modules[0].current_version).toBeNull();
    expect(result.modules[0].category_id).toBeNull();
  });

  it('propagates API errors', async () => {
    mockPost.mockRejectedValueOnce(new Error('Service unavailable'));

    await expect(templatesApi.composePreview(['mod-a'])).rejects.toThrow(
      'Service unavailable'
    );
  });
});
