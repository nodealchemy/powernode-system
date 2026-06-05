// Behavioral tests for packageRepositoriesApi and packagesApi.
//
// Covers every exported method: exact URL, params, payload shape, nested
// envelope unwrapping, optional-argument edge cases, and error propagation.

import {
  packageRepositoriesApi,
  packagesApi,
} from './packageRepositoriesApi';
import type {
  SystemPackageRepository,
  SystemPackage,
  PackageRepositoryCreate,
  PackagesSearchResult,
  PackageDiscoverResult,
  ResolveDependenciesPreview,
  CreateModuleResult,
  SuggestArchitecturesResult,
} from './packageRepositoriesApi';

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

// =============================================================================
// Fixtures
// =============================================================================

const REPO_A: SystemPackageRepository = {
  id: 'repo-1',
  name: 'ubuntu-noble',
  description: 'Ubuntu Noble main',
  kind: 'apt',
  visibility: 'shared',
  base_url: 'https://archive.ubuntu.com/ubuntu',
  architectures: ['amd64', 'arm64'],
  priority: 100,
  enabled: true,
  sync_status: 'idle',
  last_synced_at: '2026-05-01T00:00:00Z',
  last_sync_error: undefined,
  package_count: 5000,
  shared: true,
  embedding_pending_count: 12,
  node_platform_ids: ['plat-1', 'plat-2'],
  node_platforms: [
    { id: 'plat-1', name: 'x86-generic' },
    { id: 'plat-2', name: 'arm-generic' },
  ],
  apt_config: { suite: 'noble', components: ['main', 'universe'] },
  has_signing_key: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-05-01T00:00:00Z',
};

const REPO_B: SystemPackageRepository = {
  id: 'repo-2',
  name: 'centos-stream-9',
  kind: 'rpm',
  visibility: 'account',
  base_url: 'https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/',
  architectures: ['x86_64'],
  priority: 50,
  enabled: false,
  sync_status: 'failed',
  package_count: 1200,
  shared: false,
  node_platform_ids: [],
  rpm_config: { releasever: '9', gpgcheck: true },
  has_signing_key: false,
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-04-01T00:00:00Z',
};

const PACKAGE_A: SystemPackage = {
  id: 'pkg-1',
  name: 'nginx',
  version: '1.24.0-1ubuntu3',
  architecture: 'amd64',
  section: 'httpd',
  summary: 'High-performance HTTP server',
  description: 'Full-featured HTTP reverse proxy server.',
  installed_size_bytes: 1_048_576,
  download_size_bytes: 512_000,
  repository_id: 'repo-1',
  homepage: 'https://nginx.org',
  license: 'BSD-2-Clause',
  provides_names: ['httpd', 'nginx'],
  similarity: 0.97,
  package_repository_id: 'repo-1',
  depends: [[{ name: 'libpcre3', op: '>=', version: '1.0' }]],
  recommends: [[{ name: 'libnginx-mod-http-lua' }]],
  provides: [[{ name: 'httpd' }, { name: 'nginx' }]],
};

const PACKAGE_B: SystemPackage = {
  id: 'pkg-2',
  name: 'curl',
  version: '8.5.0',
  architecture: 'arm64',
  package_repository_id: 'repo-1',
};

const SEARCH_RESULT: PackagesSearchResult = {
  packages: [PACKAGE_A, PACKAGE_B],
  total: 42,
  page: 1,
  per_page: 20,
  mode: 'hybrid',
  applied_filters: { kind: 'apt', section: 'httpd' },
};

const DISCOVER_RESULT: PackageDiscoverResult = {
  intent: 'reverse proxy with TLS termination',
  results: [
    {
      ...PACKAGE_A,
      package_id: 'pkg-1',
      similarity: 0.97,
      reason: 'Nginx is the canonical reverse proxy with TLS support',
    },
  ],
  seed_count: 3,
  confidence: 'high',
};

const RESOLVE_RESULT: ResolveDependenciesPreview = {
  required_packages: [
    { name: 'libpcre3', version: '1.0', architecture: 'amd64', summary: 'Perl regex library', installed_size_bytes: 256_000 },
  ],
  required_edges: [{ from: 'nginx', to: 'libpcre3', type: 'depends', constraint: '>=1.0' }],
  recommends_candidates: [
    {
      from: 'nginx',
      to: 'libnginx-mod-http-lua',
      summary: 'Lua scripting module',
      installed_size_bytes: 128_000,
      transitive_required_if_chosen: ['liblua5.1-0'],
    },
  ],
  suggests_candidates: [{ from: 'nginx', to: 'nginx-doc', summary: 'Nginx documentation' }],
  alternatives_chosen: {},
  warnings: ['Recommends libnginx-mod-http-lua not available in this repo'],
  conflicts: [],
  errors: [],
};

const CREATE_MODULE_RESULT: CreateModuleResult = {
  top_level_module: { id: 'mod-1', name: 'nginx', auto_generated: true, public: false },
  dependency_modules: [{ id: 'mod-2', name: 'libpcre3' }],
  recommends_modules: [],
  dependencies_created: 1,
  build_dispatches: [{ dispatch_id: 'disp-1', architecture: 'amd64', ok: true }],
  warnings: [],
};

const SUGGEST_ARCHITECTURES_RESULT: SuggestArchitecturesResult = {
  repository_id: 'repo-1',
  suggested: ['amd64', 'arm64'],
  rationale: [
    { arch: 'amd64', node_platforms: 5, packages: 4800, reason: 'Covers 80% of fleet nodes' },
    { arch: 'arm64', node_platforms: 2, packages: 3100, reason: 'Covers ARM edge nodes' },
  ],
  fallback: false,
  confidence: 'high',
};

const CREATE_PAYLOAD: PackageRepositoryCreate = {
  name: 'my-apt-repo',
  kind: 'apt',
  base_url: 'https://deb.example.com/ubuntu',
  description: 'Custom APT repo',
  visibility: 'account',
  architectures: ['amd64'],
  apt_config: { suite: 'jammy', components: ['main'] },
  signing_key_armor: '-----BEGIN PGP PUBLIC KEY BLOCK-----',
  node_platform_ids: ['plat-1'],
  priority: 75,
  enabled: true,
};

const BASE = '/system/package_repositories';
const PKG_BASE = '/system/packages';

// =============================================================================
// packageRepositoriesApi tests
// =============================================================================

describe('packageRepositoriesApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list()
  // ---------------------------------------------------------------------------

  describe('list()', () => {
    it('calls GET /system/package_repositories with no params when called with no arguments', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package_repositories: [REPO_A, REPO_B] }));

      await packageRepositoriesApi.list();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE, { params: undefined });
    });

    it('passes kind as a query param when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package_repositories: [REPO_A] }));

      await packageRepositoriesApi.list({ kind: 'apt' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { kind: 'apt' } });
    });

    it('passes node_platform_ids as a query param when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package_repositories: [REPO_A] }));

      await packageRepositoriesApi.list({ node_platform_ids: ['plat-1', 'plat-2'] });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { node_platform_ids: ['plat-1', 'plat-2'] },
      });
    });

    it('passes both kind and node_platform_ids together when both are provided', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package_repositories: [REPO_A] }));

      await packageRepositoriesApi.list({ kind: 'rpm', node_platform_ids: ['plat-3'] });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { kind: 'rpm', node_platform_ids: ['plat-3'] },
      });
    });

    it('returns the unwrapped array of repositories', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package_repositories: [REPO_A, REPO_B] }));

      const result = await packageRepositoriesApi.list();

      expect(result).toHaveLength(2);
      expect(result[0]).toEqual(REPO_A);
      expect(result[1]).toEqual(REPO_B);
    });

    it('returns an empty array when the backend returns no repositories', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package_repositories: [] }));

      const result = await packageRepositoriesApi.list();

      expect(result).toEqual([]);
    });

    it('does NOT include envelope wrapper keys in the returned value', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package_repositories: [REPO_A] }));

      const result = await packageRepositoriesApi.list() as unknown as Record<string, unknown>;

      expect(result['success']).toBeUndefined();
      expect(result['data']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(packageRepositoriesApi.list()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // get()
  // ---------------------------------------------------------------------------

  describe('get()', () => {
    it('calls GET /system/package_repositories/:id with the correct id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package_repository: REPO_A }));

      await packageRepositoriesApi.get('repo-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/repo-1`);
    });

    it('uses the supplied id verbatim in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package_repository: REPO_B }));

      await packageRepositoriesApi.get('repo-uuid-abc-999');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/repo-uuid-abc-999`);
    });

    it('returns the unwrapped repository detail', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package_repository: REPO_A }));

      const result = await packageRepositoriesApi.get('repo-1');

      expect(result).toEqual(REPO_A);
      expect(result.name).toBe('ubuntu-noble');
      expect(result.node_platforms).toHaveLength(2);
    });

    it('correctly extracts the nested .package_repository key from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package_repository: REPO_B }));

      const result = await packageRepositoriesApi.get('repo-2');

      // Must NOT be the wrapper { package_repository: ... }
      expect((result as unknown as Record<string, unknown>)['package_repository']).toBeUndefined();
      expect(result.id).toBe('repo-2');
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(packageRepositoriesApi.get('missing')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // create()
  // ---------------------------------------------------------------------------

  describe('create()', () => {
    it('calls POST /system/package_repositories with the wrapped payload', async () => {
      mockPost.mockResolvedValueOnce(envelope({ package_repository: REPO_A }));

      await packageRepositoriesApi.create(CREATE_PAYLOAD);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(BASE, { package_repository: CREATE_PAYLOAD });
    });

    it('wraps the request body in a { package_repository: ... } key', async () => {
      mockPost.mockResolvedValueOnce(envelope({ package_repository: REPO_A }));

      await packageRepositoriesApi.create(CREATE_PAYLOAD);

      const [, body] = mockPost.mock.calls[0] as [string, { package_repository: PackageRepositoryCreate }];
      expect(body.package_repository).toEqual(CREATE_PAYLOAD);
    });

    it('returns the unwrapped created repository', async () => {
      mockPost.mockResolvedValueOnce(envelope({ package_repository: REPO_A }));

      const result = await packageRepositoriesApi.create(CREATE_PAYLOAD);

      expect(result).toEqual(REPO_A);
      expect(result.id).toBe('repo-1');
    });

    it('works with a minimal payload (only required fields)', async () => {
      const minimal: PackageRepositoryCreate = {
        name: 'minimal-repo',
        kind: 'apt',
        base_url: 'https://deb.minimal.com',
      };
      mockPost.mockResolvedValueOnce(envelope({ package_repository: REPO_B }));

      await packageRepositoriesApi.create(minimal);

      expect(mockPost).toHaveBeenCalledWith(BASE, { package_repository: minimal });
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Validation failed'));

      await expect(packageRepositoriesApi.create(CREATE_PAYLOAD)).rejects.toThrow('Validation failed');
    });
  });

  // ---------------------------------------------------------------------------
  // update()
  // ---------------------------------------------------------------------------

  describe('update()', () => {
    it('calls PUT /system/package_repositories/:id with the wrapped partial payload', async () => {
      mockPut.mockResolvedValueOnce(envelope({ package_repository: REPO_A }));

      await packageRepositoriesApi.update('repo-1', { enabled: false, priority: 50 });

      expect(mockPut).toHaveBeenCalledTimes(1);
      expect(mockPut).toHaveBeenCalledWith(
        `${BASE}/repo-1`,
        { package_repository: { enabled: false, priority: 50 } },
      );
    });

    it('uses the supplied id in the URL', async () => {
      mockPut.mockResolvedValueOnce(envelope({ package_repository: REPO_B }));

      await packageRepositoriesApi.update('repo-xyz-456', { name: 'renamed' });

      expect(mockPut).toHaveBeenCalledWith(
        `${BASE}/repo-xyz-456`,
        { package_repository: { name: 'renamed' } },
      );
    });

    it('wraps the partial update data in a { package_repository: ... } key', async () => {
      mockPut.mockResolvedValueOnce(envelope({ package_repository: REPO_A }));

      const patch = { description: 'Updated description', enabled: true };
      await packageRepositoriesApi.update('repo-1', patch);

      const [, body] = mockPut.mock.calls[0] as [string, { package_repository: typeof patch }];
      expect(body.package_repository).toEqual(patch);
    });

    it('returns the unwrapped updated repository', async () => {
      mockPut.mockResolvedValueOnce(envelope({ package_repository: REPO_A }));

      const result = await packageRepositoriesApi.update('repo-1', { enabled: true });

      expect(result).toEqual(REPO_A);
      expect(result.id).toBe('repo-1');
    });

    it('propagates API errors', async () => {
      mockPut.mockRejectedValueOnce(new Error('Conflict'));

      await expect(packageRepositoriesApi.update('repo-1', {})).rejects.toThrow('Conflict');
    });
  });

  // ---------------------------------------------------------------------------
  // delete()
  // ---------------------------------------------------------------------------

  describe('delete()', () => {
    it('calls DELETE /system/package_repositories/:id', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await packageRepositoriesApi.delete('repo-1');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/repo-1`);
    });

    it('uses the supplied id in the URL', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await packageRepositoriesApi.delete('repo-uuid-999');

      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/repo-uuid-999`);
    });

    it('resolves to void (returns undefined)', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      const result = await packageRepositoriesApi.delete('repo-1');

      expect(result).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Not found'));

      await expect(packageRepositoriesApi.delete('repo-1')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // sync()
  // ---------------------------------------------------------------------------

  describe('sync()', () => {
    const SYNC_RESPONSE = { ok: true, upserted: 150, obsoleted: 3, package_count: 5000 };

    it('calls POST /system/package_repositories/:id/sync with an empty body', async () => {
      mockPost.mockResolvedValueOnce(envelope(SYNC_RESPONSE));

      await packageRepositoriesApi.sync('repo-1');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/repo-1/sync`, {});
    });

    it('uses the supplied id in the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope(SYNC_RESPONSE));

      await packageRepositoriesApi.sync('repo-abc-99');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/repo-abc-99/sync`, {});
    });

    it('returns the unwrapped sync result with upserted/obsoleted counts', async () => {
      mockPost.mockResolvedValueOnce(envelope(SYNC_RESPONSE));

      const result = await packageRepositoriesApi.sync('repo-1');

      expect(result.ok).toBe(true);
      expect(result.upserted).toBe(150);
      expect(result.obsoleted).toBe(3);
      expect(result.package_count).toBe(5000);
    });

    it('returns the error field when sync fails at the application level', async () => {
      const failedSync = { ok: false, upserted: 0, obsoleted: 0, package_count: 4500, error: 'GPG key verification failed' };
      mockPost.mockResolvedValueOnce(envelope(failedSync));

      const result = await packageRepositoriesApi.sync('repo-1');

      expect(result.ok).toBe(false);
      expect(result.error).toBe('GPG key verification failed');
    });

    it('propagates transport errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Timeout'));

      await expect(packageRepositoriesApi.sync('repo-1')).rejects.toThrow('Timeout');
    });
  });

  // ---------------------------------------------------------------------------
  // linkPlatform()
  // ---------------------------------------------------------------------------

  describe('linkPlatform()', () => {
    const LINK_RESPONSE = { package_repository_id: 'repo-1', node_platform_id: 'plat-1', linked: true };

    it('calls POST /system/package_repositories/:id/link_platform with the node_platform_id', async () => {
      mockPost.mockResolvedValueOnce(envelope(LINK_RESPONSE));

      await packageRepositoriesApi.linkPlatform('repo-1', 'plat-1');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        `${BASE}/repo-1/link_platform`,
        { node_platform_id: 'plat-1' },
      );
    });

    it('uses the correct repo id and platform id in URL and body', async () => {
      mockPost.mockResolvedValueOnce(envelope(LINK_RESPONSE));

      await packageRepositoriesApi.linkPlatform('repo-xyz', 'plat-abc');

      expect(mockPost).toHaveBeenCalledWith(
        `${BASE}/repo-xyz/link_platform`,
        { node_platform_id: 'plat-abc' },
      );
    });

    it('returns the unwrapped link result with linked: true', async () => {
      mockPost.mockResolvedValueOnce(envelope(LINK_RESPONSE));

      const result = await packageRepositoriesApi.linkPlatform('repo-1', 'plat-1');

      expect(result.linked).toBe(true);
      expect(result.package_repository_id).toBe('repo-1');
      expect(result.node_platform_id).toBe('plat-1');
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Cross-account violation'));

      await expect(packageRepositoriesApi.linkPlatform('repo-1', 'plat-other')).rejects.toThrow(
        'Cross-account violation',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // unlinkPlatform()
  // ---------------------------------------------------------------------------

  describe('unlinkPlatform()', () => {
    const UNLINK_RESPONSE = { package_repository_id: 'repo-1', node_platform_id: 'plat-1', linked: false };

    it('calls DELETE /system/package_repositories/:id/unlink_platform with node_platform_id in data', async () => {
      mockDelete.mockResolvedValueOnce(envelope(UNLINK_RESPONSE));

      await packageRepositoriesApi.unlinkPlatform('repo-1', 'plat-1');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(
        `${BASE}/repo-1/unlink_platform`,
        { data: { node_platform_id: 'plat-1' } },
      );
    });

    it('uses the correct repo id in the URL', async () => {
      mockDelete.mockResolvedValueOnce(envelope(UNLINK_RESPONSE));

      await packageRepositoriesApi.unlinkPlatform('repo-999', 'plat-2');

      expect(mockDelete).toHaveBeenCalledWith(
        `${BASE}/repo-999/unlink_platform`,
        { data: { node_platform_id: 'plat-2' } },
      );
    });

    it('returns the unwrapped unlink result with linked: false', async () => {
      mockDelete.mockResolvedValueOnce(envelope(UNLINK_RESPONSE));

      const result = await packageRepositoriesApi.unlinkPlatform('repo-1', 'plat-1');

      expect(result.linked).toBe(false);
      expect(result.package_repository_id).toBe('repo-1');
      expect(result.node_platform_id).toBe('plat-1');
    });

    it('sends the platform id in the DELETE request body data (not as a query param)', async () => {
      mockDelete.mockResolvedValueOnce(envelope(UNLINK_RESPONSE));

      await packageRepositoriesApi.unlinkPlatform('repo-1', 'plat-1');

      const [, options] = mockDelete.mock.calls[0] as [string, { data: { node_platform_id: string } }];
      expect(options.data.node_platform_id).toBe('plat-1');
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Not found'));

      await expect(packageRepositoriesApi.unlinkPlatform('repo-1', 'plat-missing')).rejects.toThrow(
        'Not found',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping', () => {
    it('correctly extracts the data payload from the double-envelope { data: { success, data: payload } }', async () => {
      const payload = { package_repositories: [REPO_A] };
      mockGet.mockResolvedValueOnce({ data: { success: true, data: payload } });

      const result = await packageRepositoriesApi.list();

      expect(result).toEqual([REPO_A]);
      // Must NOT contain envelope keys
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('correctly unwraps the nested .package_repository from get() response', async () => {
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: { package_repository: REPO_A } },
      });

      const result = await packageRepositoriesApi.get('repo-1');

      expect(result.id).toBe('repo-1');
      // Must NOT be the { package_repository: ... } wrapper
      expect((result as unknown as Record<string, unknown>)['package_repository']).toBeUndefined();
    });
  });
});

// =============================================================================
// packagesApi tests
// =============================================================================

describe('packagesApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // search()
  // ---------------------------------------------------------------------------

  describe('search()', () => {
    const SEARCH_API_RESPONSE = {
      packages: [PACKAGE_A, PACKAGE_B],
      meta: {
        total: 42,
        page: 1,
        per_page: 20,
        mode: 'hybrid' as const,
        applied_filters: { kind: 'apt', section: 'httpd' },
      },
    };

    it('calls GET /system/packages with the provided params', async () => {
      mockGet.mockResolvedValueOnce(envelope(SEARCH_API_RESPONSE));

      await packagesApi.search({ q: 'nginx', mode: 'hybrid', page: 1, per_page: 20 });

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(PKG_BASE, {
        params: { q: 'nginx', mode: 'hybrid', page: 1, per_page: 20 },
      });
    });

    it('passes kind filter when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(SEARCH_API_RESPONSE));

      await packagesApi.search({ kind: 'apt' });

      expect(mockGet).toHaveBeenCalledWith(PKG_BASE, { params: { kind: 'apt' } });
    });

    it('passes repository_ids array filter when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(SEARCH_API_RESPONSE));

      await packagesApi.search({ repository_ids: ['repo-1', 'repo-2'] });

      expect(mockGet).toHaveBeenCalledWith(PKG_BASE, {
        params: { repository_ids: ['repo-1', 'repo-2'] },
      });
    });

    it('passes legacy singular repository_id when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(SEARCH_API_RESPONSE));

      await packagesApi.search({ repository_id: 'repo-1' });

      expect(mockGet).toHaveBeenCalledWith(PKG_BASE, { params: { repository_id: 'repo-1' } });
    });

    it('passes architectures array filter when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(SEARCH_API_RESPONSE));

      await packagesApi.search({ architectures: ['amd64', 'arm64'] });

      expect(mockGet).toHaveBeenCalledWith(PKG_BASE, {
        params: { architectures: ['amd64', 'arm64'] },
      });
    });

    it('passes sections array filter when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(SEARCH_API_RESPONSE));

      await packagesApi.search({ sections: ['net', 'httpd'] });

      expect(mockGet).toHaveBeenCalledWith(PKG_BASE, { params: { sections: ['net', 'httpd'] } });
    });

    it('flattens the nested meta into the returned PackagesSearchResult', async () => {
      mockGet.mockResolvedValueOnce(envelope(SEARCH_API_RESPONSE));

      const result = await packagesApi.search({ q: 'nginx' });

      // The meta fields must be flattened onto the result, not nested under .meta
      expect(result.packages).toHaveLength(2);
      expect(result.total).toBe(42);
      expect(result.page).toBe(1);
      expect(result.per_page).toBe(20);
      expect(result.mode).toBe('hybrid');
      expect(result.applied_filters).toEqual({ kind: 'apt', section: 'httpd' });
    });

    it('flattens total: null correctly (semantic/hybrid mode without exact count)', async () => {
      const semanticResponse = {
        packages: [PACKAGE_A],
        meta: {
          total: null,
          page: 1,
          per_page: 20,
          mode: 'semantic' as const,
          applied_filters: {},
        },
      };
      mockGet.mockResolvedValueOnce(envelope(semanticResponse));

      const result = await packagesApi.search({ q: 'web server', mode: 'semantic' });

      expect(result.total).toBeNull();
      expect(result.mode).toBe('semantic');
    });

    it('does NOT nest meta under a .meta key in the result', async () => {
      mockGet.mockResolvedValueOnce(envelope(SEARCH_API_RESPONSE));

      const result = await packagesApi.search({});

      expect((result as unknown as Record<string, unknown>)['meta']).toBeUndefined();
    });

    it('returns all package fields verbatim including optional fields', async () => {
      mockGet.mockResolvedValueOnce(envelope(SEARCH_API_RESPONSE));

      const result = await packagesApi.search({ q: 'nginx' });

      expect(result.packages[0]).toEqual(PACKAGE_A);
      expect(result.packages[0].provides_names).toEqual(['httpd', 'nginx']);
      expect(result.packages[0].similarity).toBe(0.97);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Service unavailable'));

      await expect(packagesApi.search({ q: 'nginx' })).rejects.toThrow('Service unavailable');
    });
  });

  // ---------------------------------------------------------------------------
  // discoverByIntent()
  // ---------------------------------------------------------------------------

  describe('discoverByIntent()', () => {
    it('calls POST /system/packages/discover with the intent and optional params', async () => {
      mockPost.mockResolvedValueOnce(envelope(DISCOVER_RESULT));

      await packagesApi.discoverByIntent({
        intent: 'reverse proxy with TLS termination',
        repository_ids: ['repo-1'],
        kind: 'apt',
        architectures: ['amd64'],
        top_k: 5,
      });

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${PKG_BASE}/discover`, {
        intent: 'reverse proxy with TLS termination',
        repository_ids: ['repo-1'],
        kind: 'apt',
        architectures: ['amd64'],
        top_k: 5,
      });
    });

    it('calls POST /system/packages/discover with only the intent when no optional params', async () => {
      mockPost.mockResolvedValueOnce(envelope(DISCOVER_RESULT));

      await packagesApi.discoverByIntent({ intent: 'distributed cache' });

      expect(mockPost).toHaveBeenCalledWith(`${PKG_BASE}/discover`, {
        intent: 'distributed cache',
      });
    });

    it('passes license filter when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(DISCOVER_RESULT));

      await packagesApi.discoverByIntent({ intent: 'database', license: 'MIT' });

      expect(mockPost).toHaveBeenCalledWith(`${PKG_BASE}/discover`, {
        intent: 'database',
        license: 'MIT',
      });
    });

    it('returns the unwrapped discover result with intent, results, seed_count, and confidence', async () => {
      mockPost.mockResolvedValueOnce(envelope(DISCOVER_RESULT));

      const result = await packagesApi.discoverByIntent({ intent: 'reverse proxy with TLS termination' });

      expect(result).toEqual(DISCOVER_RESULT);
      expect(result.intent).toBe('reverse proxy with TLS termination');
      expect(result.results).toHaveLength(1);
      expect(result.seed_count).toBe(3);
      expect(result.confidence).toBe('high');
    });

    it('returns result entries with package_id, similarity, and reason alongside package fields', async () => {
      mockPost.mockResolvedValueOnce(envelope(DISCOVER_RESULT));

      const result = await packagesApi.discoverByIntent({ intent: 'reverse proxy' });

      const entry = result.results[0];
      expect(entry.package_id).toBe('pkg-1');
      expect(entry.similarity).toBe(0.97);
      expect(entry.reason).toBe('Nginx is the canonical reverse proxy with TLS support');
      expect(entry.name).toBe('nginx');
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Embedding service down'));

      await expect(packagesApi.discoverByIntent({ intent: 'anything' })).rejects.toThrow(
        'Embedding service down',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // get()
  // ---------------------------------------------------------------------------

  describe('get()', () => {
    it('calls GET /system/packages/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package: PACKAGE_A }));

      await packagesApi.get('pkg-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${PKG_BASE}/pkg-1`);
    });

    it('uses the supplied id verbatim in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package: PACKAGE_B }));

      await packagesApi.get('pkg-uuid-abc-999');

      expect(mockGet).toHaveBeenCalledWith(`${PKG_BASE}/pkg-uuid-abc-999`);
    });

    it('returns the unwrapped package detail', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package: PACKAGE_A }));

      const result = await packagesApi.get('pkg-1');

      expect(result).toEqual(PACKAGE_A);
      expect(result.name).toBe('nginx');
      expect(result.depends).toHaveLength(1);
    });

    it('correctly extracts the nested .package key from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ package: PACKAGE_A }));

      const result = await packagesApi.get('pkg-1');

      // Must NOT be the { package: ... } wrapper
      expect((result as unknown as Record<string, unknown>)['package']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(packagesApi.get('missing')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // resolveDependencies()
  // ---------------------------------------------------------------------------

  describe('resolveDependencies()', () => {
    const PARAMS = {
      repository_id: 'repo-1',
      package_name: 'nginx',
      architecture: 'amd64',
    };

    it('calls POST /system/packages/resolve_dependencies with the correct params', async () => {
      mockPost.mockResolvedValueOnce(envelope(RESOLVE_RESULT));

      await packagesApi.resolveDependencies(PARAMS);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${PKG_BASE}/resolve_dependencies`, PARAMS);
    });

    it('sends all three required fields verbatim in the request body', async () => {
      mockPost.mockResolvedValueOnce(envelope(RESOLVE_RESULT));

      await packagesApi.resolveDependencies(PARAMS);

      const [, body] = mockPost.mock.calls[0] as [string, typeof PARAMS];
      expect(body.repository_id).toBe('repo-1');
      expect(body.package_name).toBe('nginx');
      expect(body.architecture).toBe('amd64');
    });

    it('returns the full unwrapped ResolveDependenciesPreview', async () => {
      mockPost.mockResolvedValueOnce(envelope(RESOLVE_RESULT));

      const result = await packagesApi.resolveDependencies(PARAMS);

      expect(result).toEqual(RESOLVE_RESULT);
      expect(result.required_packages).toHaveLength(1);
      expect(result.required_edges).toHaveLength(1);
      expect(result.recommends_candidates).toHaveLength(1);
      expect(result.suggests_candidates).toHaveLength(1);
      expect(result.warnings).toHaveLength(1);
      expect(result.errors).toHaveLength(0);
    });

    it('returns an empty conflicts array when no conflicts exist', async () => {
      mockPost.mockResolvedValueOnce(envelope(RESOLVE_RESULT));

      const result = await packagesApi.resolveDependencies(PARAMS);

      expect(result.conflicts).toEqual([]);
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Package not found'));

      await expect(packagesApi.resolveDependencies(PARAMS)).rejects.toThrow('Package not found');
    });
  });

  // ---------------------------------------------------------------------------
  // createModuleFromPackage()
  // ---------------------------------------------------------------------------

  describe('createModuleFromPackage()', () => {
    const PARAMS = {
      repository_id: 'repo-1',
      package_name: 'nginx',
      architectures: ['amd64', 'arm64'],
      recommends_selected: ['libnginx-mod-http-lua'],
      category_id: 'cat-web',
      dispatch_build: true,
    };

    it('calls POST /system/packages/create_module with the full params', async () => {
      mockPost.mockResolvedValueOnce(envelope(CREATE_MODULE_RESULT));

      await packagesApi.createModuleFromPackage(PARAMS);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${PKG_BASE}/create_module`, PARAMS);
    });

    it('sends all params verbatim in the request body', async () => {
      mockPost.mockResolvedValueOnce(envelope(CREATE_MODULE_RESULT));

      await packagesApi.createModuleFromPackage(PARAMS);

      const [, body] = mockPost.mock.calls[0] as [string, typeof PARAMS];
      expect(body.repository_id).toBe('repo-1');
      expect(body.architectures).toEqual(['amd64', 'arm64']);
      expect(body.dispatch_build).toBe(true);
    });

    it('works without optional params (recommends_selected, category_id, dispatch_build)', async () => {
      const minimal = {
        repository_id: 'repo-1',
        package_name: 'curl',
        architectures: ['amd64'],
      };
      mockPost.mockResolvedValueOnce(envelope(CREATE_MODULE_RESULT));

      await packagesApi.createModuleFromPackage(minimal);

      expect(mockPost).toHaveBeenCalledWith(`${PKG_BASE}/create_module`, minimal);
    });

    it('returns the full unwrapped CreateModuleResult', async () => {
      mockPost.mockResolvedValueOnce(envelope(CREATE_MODULE_RESULT));

      const result = await packagesApi.createModuleFromPackage(PARAMS);

      expect(result).toEqual(CREATE_MODULE_RESULT);
      expect(result.top_level_module.name).toBe('nginx');
      expect(result.dependency_modules).toHaveLength(1);
      expect(result.dependencies_created).toBe(1);
      expect(result.build_dispatches).toHaveLength(1);
      expect(result.build_dispatches[0].ok).toBe(true);
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Module already exists'));

      await expect(packagesApi.createModuleFromPackage(PARAMS)).rejects.toThrow('Module already exists');
    });
  });

  // ---------------------------------------------------------------------------
  // suggestArchitectures()
  // ---------------------------------------------------------------------------

  describe('suggestArchitectures()', () => {
    it('calls POST /system/packages/suggest_architectures with repository_id', async () => {
      mockPost.mockResolvedValueOnce(envelope(SUGGEST_ARCHITECTURES_RESULT));

      await packagesApi.suggestArchitectures({ repository_id: 'repo-1' });

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${PKG_BASE}/suggest_architectures`, {
        repository_id: 'repo-1',
      });
    });

    it('includes max_suggestions when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(SUGGEST_ARCHITECTURES_RESULT));

      await packagesApi.suggestArchitectures({ repository_id: 'repo-1', max_suggestions: 3 });

      expect(mockPost).toHaveBeenCalledWith(`${PKG_BASE}/suggest_architectures`, {
        repository_id: 'repo-1',
        max_suggestions: 3,
      });
    });

    it('does NOT include max_suggestions when not provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(SUGGEST_ARCHITECTURES_RESULT));

      await packagesApi.suggestArchitectures({ repository_id: 'repo-2' });

      const [, body] = mockPost.mock.calls[0] as [string, { repository_id: string; max_suggestions?: number }];
      expect(body.max_suggestions).toBeUndefined();
    });

    it('returns the full unwrapped SuggestArchitecturesResult', async () => {
      mockPost.mockResolvedValueOnce(envelope(SUGGEST_ARCHITECTURES_RESULT));

      const result = await packagesApi.suggestArchitectures({ repository_id: 'repo-1' });

      expect(result).toEqual(SUGGEST_ARCHITECTURES_RESULT);
      expect(result.repository_id).toBe('repo-1');
      expect(result.suggested).toEqual(['amd64', 'arm64']);
      expect(result.rationale).toHaveLength(2);
      expect(result.fallback).toBe(false);
      expect(result.confidence).toBe('high');
    });

    it('returns fallback: true with low confidence when fleet data is insufficient', async () => {
      const fallbackResult: SuggestArchitecturesResult = {
        repository_id: 'repo-1',
        suggested: ['amd64'],
        rationale: [{ reason: 'No fleet nodes found; defaulting to most common arch' }],
        fallback: true,
        confidence: 'low',
      };
      mockPost.mockResolvedValueOnce(envelope(fallbackResult));

      const result = await packagesApi.suggestArchitectures({ repository_id: 'repo-1' });

      expect(result.fallback).toBe(true);
      expect(result.confidence).toBe('low');
      expect(result.suggested).toEqual(['amd64']);
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Repository not found'));

      await expect(packagesApi.suggestArchitectures({ repository_id: 'missing' })).rejects.toThrow(
        'Repository not found',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract for packagesApi
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping', () => {
    it('correctly flattens search() meta into the result shape (not nested under .meta)', async () => {
      const apiResponse = {
        packages: [PACKAGE_A],
        meta: { total: 1, page: 1, per_page: 20, mode: 'lexical' as const, applied_filters: {} },
      };
      mockGet.mockResolvedValueOnce({ data: { success: true, data: apiResponse } });

      const result = await packagesApi.search({ q: 'nginx' });

      // Flattened result shape
      expect(result.total).toBe(1);
      expect(result.mode).toBe('lexical');
      expect(result.packages).toHaveLength(1);
      // meta must NOT be a nested key
      expect((result as unknown as Record<string, unknown>)['meta']).toBeUndefined();
    });

    it('correctly extracts the nested .package key from get() envelope', async () => {
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: { package: PACKAGE_A } },
      });

      const result = await packagesApi.get('pkg-1');

      expect(result.name).toBe('nginx');
      // Must NOT be the { package: ... } wrapper
      expect((result as unknown as Record<string, unknown>)['package']).toBeUndefined();
    });

    it('does not include envelope wrapper keys in discoverByIntent() result', async () => {
      mockPost.mockResolvedValueOnce(envelope(DISCOVER_RESULT));

      const result = await packagesApi.discoverByIntent({ intent: 'cache' }) as unknown as Record<string, unknown>;

      expect(result['success']).toBeUndefined();
      expect(result['data']).toBeUndefined();
    });
  });
});
