// Behavioral tests for marketplaceApi.
//
// Covers every exported method: exact URL, params (including filtering,
// pagination, and empty-value omission), payload, envelope unwrapping via
// extractData / extractPaginated, and error propagation.

import { marketplaceApi } from './marketplaceApi';

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

/** Build a double-envelope AxiosResponse body for a non-paginated success. */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

/** Build a paginated envelope (meta at the body root, not inside data). */
function paginatedEnvelope<T>(payload: T, meta: Record<string, unknown> = {}) {
  return {
    data: {
      success: true,
      data: payload,
      meta: {
        current_page: 1,
        per_page: 20,
        total_count: 1,
        total_pages: 1,
        next_page: null,
        prev_page: null,
        ...meta,
      },
    },
  };
}

// =============================================================================
// Fixtures
// =============================================================================

const MODULE_CARD_A = {
  id: 'mod-a',
  name: 'nginx-proxy',
  description: 'Reverse proxy module',
  variety: 'service',
  priority: 10,
  trust_tier: 'verified-publisher' as const,
  category: 'networking',
  platform: 'linux',
  current_version_number: 3,
  assignment_count: 42,
  updated_at: '2026-05-01T10:00:00Z',
};

const MODULE_CARD_B = {
  id: 'mod-b',
  name: 'postgres-db',
  description: 'PostgreSQL database module',
  variety: 'database',
  priority: 20,
  trust_tier: 'internal' as const,
  category: 'data',
  platform: 'linux',
  current_version_number: 1,
  assignment_count: 7,
  updated_at: '2026-04-15T08:00:00Z',
};

const MODULE_DETAIL = {
  ...MODULE_CARD_A,
  manifest_yaml: { version: '1.0', services: {} },
  file_spec: null,
  mask: null,
  package_spec: null,
  dependency_spec: null,
  protected_spec: null,
  consent_budget_per_day: 100,
  cosign_identity_regexp: null,
  cosign_issuer_regexp: null,
  gitea_repo_full_name: 'org/nginx-proxy',
};

const VERSION_1 = {
  id: 'ver-1',
  version_number: 3,
  changelog: 'Bugfix: improved TLS handling',
  created_at: '2026-05-01T10:00:00Z',
};

const DEPENDENCY_1 = {
  id: 'dep-1',
  required_module_id: 'mod-core',
  required_module_name: 'core-runtime',
  required_version: '>=2.0',
};

const BASE_URL = '/system/marketplace';

// =============================================================================
// Tests
// =============================================================================

describe('marketplaceApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list()
  // ---------------------------------------------------------------------------

  describe('list()', () => {
    it('calls GET /system/marketplace with no query params when called with no filters', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ modules: [MODULE_CARD_A] }),
      );

      await marketplaceApi.list();

      expect(mockGet).toHaveBeenCalledTimes(1);
      // No filters → URLSearchParams is empty → URL is "/system/marketplace?"
      expect(mockGet).toHaveBeenCalledWith(`${BASE_URL}?`);
    });

    it('calls GET /system/marketplace with no query params when called with empty object', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ modules: [MODULE_CARD_A] }),
      );

      await marketplaceApi.list({});

      expect(mockGet).toHaveBeenCalledWith(`${BASE_URL}?`);
    });

    it('appends trust_tier filter to the URL', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ modules: [MODULE_CARD_A] }),
      );

      await marketplaceApi.list({ trust_tier: 'verified-publisher' });

      expect(mockGet).toHaveBeenCalledWith(
        `${BASE_URL}?trust_tier=verified-publisher`,
      );
    });

    it('appends category_id filter to the URL', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ modules: [] }));

      await marketplaceApi.list({ category_id: 'cat-net' });

      expect(mockGet).toHaveBeenCalledWith(`${BASE_URL}?category_id=cat-net`);
    });

    it('appends search filter to the URL', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ modules: [] }));

      await marketplaceApi.list({ search: 'nginx' });

      expect(mockGet).toHaveBeenCalledWith(`${BASE_URL}?search=nginx`);
    });

    it('appends pagination params page and per_page to the URL', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ modules: [] }));

      await marketplaceApi.list({ page: 2, per_page: 10 });

      const call = mockGet.mock.calls[0][0] as string;
      const params = new URLSearchParams(call.split('?')[1]);
      expect(params.get('page')).toBe('2');
      expect(params.get('per_page')).toBe('10');
    });

    it('appends all filters together in the URL', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ modules: [] }));

      await marketplaceApi.list({
        trust_tier: 'community',
        category_id: 'cat-sec',
        search: 'firewall',
        page: 3,
        per_page: 5,
      });

      const call = mockGet.mock.calls[0][0] as string;
      const params = new URLSearchParams(call.split('?')[1]);
      expect(params.get('trust_tier')).toBe('community');
      expect(params.get('category_id')).toBe('cat-sec');
      expect(params.get('search')).toBe('firewall');
      expect(params.get('page')).toBe('3');
      expect(params.get('per_page')).toBe('5');
    });

    it('omits filter keys whose value is undefined', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ modules: [] }));

      await marketplaceApi.list({ trust_tier: undefined, search: 'redis' });

      const call = mockGet.mock.calls[0][0] as string;
      const params = new URLSearchParams(call.split('?')[1]);
      expect(params.has('trust_tier')).toBe(false);
      expect(params.get('search')).toBe('redis');
    });

    it('omits filter keys whose value is null', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ modules: [] }));

      // TypeScript does not allow null for category_id but the runtime guard
      // is explicit — verify it by casting.
      await marketplaceApi.list({
        category_id: null as unknown as string,
        search: 'db',
      });

      const call = mockGet.mock.calls[0][0] as string;
      const params = new URLSearchParams(call.split('?')[1]);
      expect(params.has('category_id')).toBe(false);
      expect(params.get('search')).toBe('db');
    });

    it('omits filter keys whose value is an empty string', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ modules: [] }));

      await marketplaceApi.list({ trust_tier: '', search: 'cache' });

      const call = mockGet.mock.calls[0][0] as string;
      const params = new URLSearchParams(call.split('?')[1]);
      expect(params.has('trust_tier')).toBe(false);
      expect(params.get('search')).toBe('cache');
    });

    it('returns the unwrapped modules array', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ modules: [MODULE_CARD_A, MODULE_CARD_B] }),
      );

      const result = await marketplaceApi.list();

      expect(result.modules).toHaveLength(2);
      expect(result.modules[0]).toEqual(MODULE_CARD_A);
      expect(result.modules[1]).toEqual(MODULE_CARD_B);
    });

    it('returns an empty modules array when the backend returns none', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ modules: [] }));

      const result = await marketplaceApi.list();

      expect(result.modules).toEqual([]);
    });

    it('includes the pagination meta from the response root', async () => {
      const meta = {
        current_page: 2,
        per_page: 10,
        total_count: 35,
        total_pages: 4,
        next_page: 3,
        prev_page: 1,
      };
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ modules: [MODULE_CARD_A] }, meta),
      );

      const result = await marketplaceApi.list({ page: 2, per_page: 10 });

      expect(result.meta.total_count).toBe(35);
      expect(result.meta.total_pages).toBe(4);
      expect(result.meta.current_page).toBe(2);
      expect(result.meta.per_page).toBe(10);
      expect(result.meta.next_page).toBe(3);
      expect(result.meta.prev_page).toBe(1);
    });

    it('synthesizes a defaultMeta when the backend omits meta', async () => {
      // Some environments may return no meta block; extractPaginated synthesizes one.
      mockGet.mockResolvedValueOnce({
        data: {
          success: true,
          data: { modules: [MODULE_CARD_A, MODULE_CARD_B] },
          // no meta key
        },
      });

      const result = await marketplaceApi.list();

      expect(result.meta.total_count).toBe(2);
      expect(result.meta.total_pages).toBe(1);
      expect(result.meta.current_page).toBe(1);
      expect(result.meta.next_page).toBeNull();
      expect(result.meta.prev_page).toBeNull();
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(marketplaceApi.list()).rejects.toThrow('Network error');
    });

    it('does NOT call apiClient.post/put/delete', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ modules: [] }));

      await marketplaceApi.list();

      // Only GET is mocked; confirming no unexpected method was called
      expect(mockGet).toHaveBeenCalledTimes(1);
    });
  });

  // ---------------------------------------------------------------------------
  // get()
  // ---------------------------------------------------------------------------

  describe('get()', () => {
    const DETAIL_PAYLOAD = {
      module: MODULE_DETAIL,
      recent_versions: [VERSION_1],
      dependencies: [DEPENDENCY_1],
    };

    it('calls GET /system/marketplace/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope(DETAIL_PAYLOAD));

      await marketplaceApi.get('mod-a');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE_URL}/mod-a`);
    });

    it('uses the supplied id in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope(DETAIL_PAYLOAD));

      await marketplaceApi.get('mod-xyz-999');

      expect(mockGet).toHaveBeenCalledWith(`${BASE_URL}/mod-xyz-999`);
    });

    it('returns the unwrapped detail payload containing module, recent_versions, and dependencies', async () => {
      mockGet.mockResolvedValueOnce(envelope(DETAIL_PAYLOAD));

      const result = await marketplaceApi.get('mod-a');

      expect(result.module).toEqual(MODULE_DETAIL);
      expect(result.recent_versions).toHaveLength(1);
      expect(result.recent_versions[0]).toEqual(VERSION_1);
      expect(result.dependencies).toHaveLength(1);
      expect(result.dependencies[0]).toEqual(DEPENDENCY_1);
    });

    it('returns the full module detail fields including optional extended props', async () => {
      mockGet.mockResolvedValueOnce(envelope(DETAIL_PAYLOAD));

      const result = await marketplaceApi.get('mod-a');

      expect(result.module.id).toBe('mod-a');
      expect(result.module.name).toBe('nginx-proxy');
      expect(result.module.trust_tier).toBe('verified-publisher');
      expect(result.module.current_version_number).toBe(3);
      expect(result.module.assignment_count).toBe(42);
      expect(result.module.manifest_yaml).toEqual({ version: '1.0', services: {} });
      expect(result.module.gitea_repo_full_name).toBe('org/nginx-proxy');
      expect(result.module.consent_budget_per_day).toBe(100);
    });

    it('handles a module with null optional fields', async () => {
      const minimalDetail = {
        ...MODULE_CARD_A,
        manifest_yaml: null,
        file_spec: null,
        mask: null,
        package_spec: null,
        dependency_spec: null,
        protected_spec: null,
        consent_budget_per_day: null,
        cosign_identity_regexp: null,
        cosign_issuer_regexp: null,
        gitea_repo_full_name: null,
      };
      mockGet.mockResolvedValueOnce(
        envelope({ module: minimalDetail, recent_versions: [], dependencies: [] }),
      );

      const result = await marketplaceApi.get('mod-a');

      expect(result.module.manifest_yaml).toBeNull();
      expect(result.module.gitea_repo_full_name).toBeNull();
      expect(result.module.consent_budget_per_day).toBeNull();
      expect(result.recent_versions).toEqual([]);
      expect(result.dependencies).toEqual([]);
    });

    it('handles multiple recent_versions in the response', async () => {
      const version2 = {
        id: 'ver-2',
        version_number: 2,
        changelog: 'Initial release',
        created_at: '2026-03-01T00:00:00Z',
      };
      mockGet.mockResolvedValueOnce(
        envelope({
          module: MODULE_DETAIL,
          recent_versions: [VERSION_1, version2],
          dependencies: [],
        }),
      );

      const result = await marketplaceApi.get('mod-a');

      expect(result.recent_versions).toHaveLength(2);
      expect(result.recent_versions[0].version_number).toBe(3);
      expect(result.recent_versions[1].version_number).toBe(2);
    });

    it('handles multiple dependencies in the response', async () => {
      const dep2 = {
        id: 'dep-2',
        required_module_id: 'mod-utils',
        required_module_name: null,
        required_version: null,
      };
      mockGet.mockResolvedValueOnce(
        envelope({
          module: MODULE_DETAIL,
          recent_versions: [],
          dependencies: [DEPENDENCY_1, dep2],
        }),
      );

      const result = await marketplaceApi.get('mod-a');

      expect(result.dependencies).toHaveLength(2);
      expect(result.dependencies[1].required_module_id).toBe('mod-utils');
      expect(result.dependencies[1].required_module_name).toBeNull();
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(marketplaceApi.get('missing')).rejects.toThrow('Not found');
    });

    it('propagates 404 errors', async () => {
      const notFoundError = Object.assign(new Error('Request failed with status code 404'), {
        response: { status: 404 },
      });
      mockGet.mockRejectedValueOnce(notFoundError);

      await expect(marketplaceApi.get('no-such-module')).rejects.toThrow(
        'Request failed with status code 404',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping', () => {
    it('list() correctly extracts modules from the double-envelope paginated response', async () => {
      const payload = { modules: [MODULE_CARD_A] };
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: payload, meta: null },
      });

      const result = await marketplaceApi.list();

      expect(result.modules).toEqual([MODULE_CARD_A]);
      // Must NOT expose envelope keys
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
      expect((result as unknown as Record<string, unknown>)['data']).toBeUndefined();
    });

    it('get() correctly extracts data from the double-envelope response', async () => {
      const payload = {
        module: MODULE_DETAIL,
        recent_versions: [VERSION_1],
        dependencies: [],
      };
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: payload },
      });

      const result = await marketplaceApi.get('mod-a');

      expect(result.module.id).toBe('mod-a');
      // Must NOT contain envelope keys
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
      expect((result as unknown as Record<string, unknown>)['data']).toBeUndefined();
    });

    it('list() meta is at the response root, not inside data', async () => {
      // Regression guard: meta must come from response.data.meta (root),
      // not from response.data.data.meta (would always be undefined).
      mockGet.mockResolvedValueOnce({
        data: {
          success: true,
          data: { modules: [MODULE_CARD_A] },
          meta: {
            current_page: 3,
            per_page: 5,
            total_count: 100,
            total_pages: 20,
            next_page: 4,
            prev_page: 2,
          },
        },
      });

      const result = await marketplaceApi.list({ page: 3, per_page: 5 });

      // meta.total_pages must be 20 (from root), not 1 (synthesized default)
      expect(result.meta.total_pages).toBe(20);
      expect(result.meta.total_count).toBe(100);
      expect(result.meta.current_page).toBe(3);
    });
  });

  // ---------------------------------------------------------------------------
  // MarketplaceModuleCard interface — field coverage
  // ---------------------------------------------------------------------------

  describe('MarketplaceModuleCard fields', () => {
    it('preserves all core card fields on list items', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ modules: [MODULE_CARD_A] }),
      );

      const result = await marketplaceApi.list();
      const card = result.modules[0];

      expect(card.id).toBe('mod-a');
      expect(card.name).toBe('nginx-proxy');
      expect(card.description).toBe('Reverse proxy module');
      expect(card.variety).toBe('service');
      expect(card.priority).toBe(10);
      expect(card.trust_tier).toBe('verified-publisher');
      expect(card.category).toBe('networking');
      expect(card.platform).toBe('linux');
      expect(card.current_version_number).toBe(3);
      expect(card.assignment_count).toBe(42);
      expect(card.updated_at).toBe('2026-05-01T10:00:00Z');
    });

    it('handles a card with unknown trust_tier string (open union)', async () => {
      const unknownTierCard = { ...MODULE_CARD_A, trust_tier: 'partner' };
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ modules: [unknownTierCard] }),
      );

      const result = await marketplaceApi.list({ trust_tier: 'partner' });

      expect(result.modules[0].trust_tier).toBe('partner');
    });

    it('handles a card where optional fields description, category, and platform are absent', async () => {
      const bareCard = {
        id: 'mod-bare',
        name: 'bare-module',
        variety: 'util',
        priority: 1,
        trust_tier: 'community',
        current_version_number: 1,
        assignment_count: 0,
        updated_at: '2026-01-01T00:00:00Z',
      };
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ modules: [bareCard] }));

      const result = await marketplaceApi.list();

      expect(result.modules[0].description).toBeUndefined();
      expect(result.modules[0].category).toBeUndefined();
      expect(result.modules[0].platform).toBeUndefined();
    });
  });
});
