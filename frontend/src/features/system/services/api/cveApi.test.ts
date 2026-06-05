// Behavioral tests for cveApi.
//
// Covers both exported methods: exact URL, params, payload shapes, envelope
// unwrapping (single-record vs. paginated), filter combinations, and error
// propagation.
//
// Backend: Api::V1::System::CveExposuresController (index/show, read-only)
// Auth scope: system.cve.read

import { cveApi } from './cveApi';
import type { PaginationMeta } from './types';

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

/** Build a double-envelope AxiosResponse body for a single-record success. */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

/**
 * Build a paginated double-envelope response.
 * Meta sits at the root of the body (NOT inside data) — matching the
 * backend's render_success(data: ..., meta: ...) contract.
 */
function paginatedEnvelope<T>(payload: T, meta: PaginationMeta) {
  return { data: { success: true, data: payload, meta } };
}

// =============================================================================
// Fixtures
// =============================================================================

const META: PaginationMeta = {
  current_page: 1,
  per_page: 25,
  total_count: 2,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

const CVE_DETAIL_A = {
  id: 'cve-det-1',
  cve_id: 'CVE-2024-12345',
  severity: 'critical',
  severity_weight: 9.8,
  summary: 'Critical buffer overflow in libfoo',
  reference_url: 'https://nvd.nist.gov/vuln/detail/CVE-2024-12345',
  published_at: '2024-01-15T00:00:00Z',
  feed_source: 'nvd',
};

const CVE_DETAIL_B = {
  id: 'cve-det-2',
  cve_id: 'CVE-2024-67890',
  severity: 'medium',
  severity_weight: 5.5,
  summary: null,
  reference_url: null,
  published_at: '2024-03-01T00:00:00Z',
  feed_source: 'osv',
};

const EXPOSURE_A = {
  id: 'exp-1',
  state: 'open' as const,
  package_name: 'libfoo',
  package_version: '1.2.3',
  detected_at: '2024-01-20T10:00:00Z',
  resolved_at: null,
  resolution_note: null,
  metadata: {},
  created_at: '2024-01-20T10:00:00Z',
  updated_at: '2024-01-20T10:00:00Z',
  cve: CVE_DETAIL_A,
  node_module_version: {
    id: 'nmv-1',
    version_number: '1.0.0',
    promotion_state: 'stable',
  },
  node_module: {
    id: 'nm-1',
    name: 'core-runtime',
  },
};

const EXPOSURE_B = {
  id: 'exp-2',
  state: 'remediating' as const,
  package_name: 'libbar',
  package_version: '2.0.0',
  detected_at: '2024-03-05T08:00:00Z',
  resolved_at: null,
  resolution_note: null,
  metadata: { ticket: 'SEC-42' },
  created_at: '2024-03-05T08:00:00Z',
  updated_at: '2024-03-06T12:00:00Z',
  cve: CVE_DETAIL_B,
  node_module_version: {
    id: 'nmv-2',
    version_number: '2.1.0',
    promotion_state: 'canary',
  },
  node_module: {
    id: 'nm-2',
    name: 'network-stack',
  },
};

const EXPOSURE_RESOLVED = {
  id: 'exp-3',
  state: 'resolved' as const,
  package_name: 'libfoo',
  package_version: '1.2.3',
  detected_at: '2024-01-20T10:00:00Z',
  resolved_at: '2024-02-01T09:00:00Z',
  resolution_note: 'Upgraded to 1.2.4',
  metadata: {},
  created_at: '2024-01-20T10:00:00Z',
  updated_at: '2024-02-01T09:00:00Z',
  cve: CVE_DETAIL_A,
  node_module_version: {
    id: 'nmv-1',
    version_number: '1.2.4',
    promotion_state: 'stable',
  },
  node_module: {
    id: 'nm-1',
    name: 'core-runtime',
  },
};

const EXPOSURE_WONT_FIX = {
  id: 'exp-4',
  state: 'wont_fix' as const,
  package_name: 'libbaz',
  package_version: null,
  detected_at: '2024-04-01T00:00:00Z',
  resolved_at: null,
  resolution_note: 'Not exploitable in our deployment profile',
  metadata: {},
  created_at: '2024-04-01T00:00:00Z',
  updated_at: '2024-04-01T00:00:00Z',
  cve: null,
  node_module_version: null,
  node_module: null,
};

const BASE = '/system/cve_exposures';

// =============================================================================
// Tests
// =============================================================================

describe('cveApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list()
  // ---------------------------------------------------------------------------

  describe('list()', () => {
    it('calls GET /system/cve_exposures with no params when called with no arguments', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [EXPOSURE_A, EXPOSURE_B] }, META),
      );

      await cveApi.list();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE, { params: undefined });
    });

    it('calls GET /system/cve_exposures with an empty params object when passed {}', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [] }, { ...META, total_count: 0 }),
      );

      await cveApi.list({});

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
    });

    it('passes severity filter as a query param', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [EXPOSURE_A] }, { ...META, total_count: 1 }),
      );

      await cveApi.list({ severity: 'critical' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { severity: 'critical' } });
    });

    it('passes high severity filter correctly', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [] }, { ...META, total_count: 0 }),
      );

      await cveApi.list({ severity: 'high' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { severity: 'high' } });
    });

    it('passes medium severity filter correctly', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [] }, { ...META, total_count: 0 }),
      );

      await cveApi.list({ severity: 'medium' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { severity: 'medium' } });
    });

    it('passes state filter as a query param', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [EXPOSURE_B] }, { ...META, total_count: 1 }),
      );

      await cveApi.list({ state: 'remediating' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { state: 'remediating' } });
    });

    it('passes open state filter correctly', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [EXPOSURE_A] }, { ...META, total_count: 1 }),
      );

      await cveApi.list({ state: 'open' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { state: 'open' } });
    });

    it('passes resolved state filter correctly', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [EXPOSURE_RESOLVED] }, { ...META, total_count: 1 }),
      );

      await cveApi.list({ state: 'resolved' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { state: 'resolved' } });
    });

    it('passes wont_fix state filter correctly', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [EXPOSURE_WONT_FIX] }, { ...META, total_count: 1 }),
      );

      await cveApi.list({ state: 'wont_fix' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { state: 'wont_fix' } });
    });

    it('passes combined severity + state filters', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [EXPOSURE_A] }, { ...META, total_count: 1 }),
      );

      await cveApi.list({ severity: 'critical', state: 'open' });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { severity: 'critical', state: 'open' },
      });
    });

    it('passes pagination params alongside filters', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [] }, { ...META, total_count: 0 }),
      );

      await cveApi.list({ page: 2, per_page: 10, severity: 'high' });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { page: 2, per_page: 10, severity: 'high' },
      });
    });

    it('passes page and per_page pagination params with no filter', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [EXPOSURE_A] }, { ...META, current_page: 3, per_page: 5 }),
      );

      await cveApi.list({ page: 3, per_page: 5 });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { page: 3, per_page: 5 } });
    });

    it('returns cve_exposures array and meta from the unwrapped envelope', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [EXPOSURE_A, EXPOSURE_B] }, META),
      );

      const result = await cveApi.list();

      expect(result.cve_exposures).toHaveLength(2);
      expect(result.cve_exposures[0]).toEqual(EXPOSURE_A);
      expect(result.cve_exposures[1]).toEqual(EXPOSURE_B);
      expect(result.meta).toEqual(META);
    });

    it('returns a correct empty list with meta when no exposures match', async () => {
      const emptyMeta: PaginationMeta = { ...META, total_count: 0, per_page: 25 };
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [] }, emptyMeta),
      );

      const result = await cveApi.list({ severity: 'critical' });

      expect(result.cve_exposures).toEqual([]);
      expect(result.meta.total_count).toBe(0);
    });

    it('returns meta at the result root (not nested inside cve_exposures)', async () => {
      // This guards the "meta sits at response root" contract — the known
      // M1 audit bug where meta was read from inside data instead.
      const customMeta: PaginationMeta = {
        current_page: 2,
        per_page: 10,
        total_count: 50,
        total_pages: 5,
        next_page: 3,
        prev_page: 1,
      };
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [EXPOSURE_A] }, customMeta),
      );

      const result = await cveApi.list();

      expect(result.meta.total_count).toBe(50);
      expect(result.meta.total_pages).toBe(5);
      expect(result.meta.next_page).toBe(3);
      expect(result.meta.prev_page).toBe(1);
      expect(result.meta.current_page).toBe(2);
    });

    it('preserves the full CveExposure shape including nested cve and module fields', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [EXPOSURE_A] }, META),
      );

      const result = await cveApi.list();
      const exp = result.cve_exposures[0];

      expect(exp.id).toBe('exp-1');
      expect(exp.state).toBe('open');
      expect(exp.package_name).toBe('libfoo');
      expect(exp.package_version).toBe('1.2.3');
      expect(exp.cve?.cve_id).toBe('CVE-2024-12345');
      expect(exp.cve?.severity).toBe('critical');
      expect(exp.node_module_version?.version_number).toBe('1.0.0');
      expect(exp.node_module?.name).toBe('core-runtime');
    });

    it('handles exposures with null cve and null module fields', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ cve_exposures: [EXPOSURE_WONT_FIX] }, META),
      );

      const result = await cveApi.list();
      const exp = result.cve_exposures[0];

      expect(exp.id).toBe('exp-4');
      expect(exp.state).toBe('wont_fix');
      expect(exp.cve).toBeNull();
      expect(exp.node_module_version).toBeNull();
      expect(exp.node_module).toBeNull();
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(cveApi.list()).rejects.toThrow('Network error');
    });

    it('propagates 403 authorization errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Forbidden'));

      await expect(cveApi.list()).rejects.toThrow('Forbidden');
    });
  });

  // ---------------------------------------------------------------------------
  // get()
  // ---------------------------------------------------------------------------

  describe('get()', () => {
    it('calls GET /system/cve_exposures/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ cve_exposure: EXPOSURE_A }));

      await cveApi.get('exp-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/exp-1`);
    });

    it('uses the supplied id in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ cve_exposure: EXPOSURE_B }));

      await cveApi.get('exp-2');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/exp-2`);
    });

    it('uses a different id in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ cve_exposure: EXPOSURE_RESOLVED }));

      await cveApi.get('exp-abc-999');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/exp-abc-999`);
    });

    it('does NOT pass query params (no second argument to apiClient.get)', async () => {
      mockGet.mockResolvedValueOnce(envelope({ cve_exposure: EXPOSURE_A }));

      await cveApi.get('exp-1');

      // get() should be called with exactly one argument (the URL)
      expect(mockGet.mock.calls[0]).toHaveLength(1);
    });

    it('unwraps the nested .cve_exposure from the envelope and returns it directly', async () => {
      mockGet.mockResolvedValueOnce(envelope({ cve_exposure: EXPOSURE_A }));

      const result = await cveApi.get('exp-1');

      expect(result).toEqual(EXPOSURE_A);
      // Must NOT be the wrapper object { cve_exposure: ... }
      expect((result as unknown as Record<string, unknown>)['cve_exposure']).toBeUndefined();
    });

    it('returns the full CveExposure shape with nested cve detail', async () => {
      mockGet.mockResolvedValueOnce(envelope({ cve_exposure: EXPOSURE_A }));

      const result = await cveApi.get('exp-1');

      expect(result.id).toBe('exp-1');
      expect(result.state).toBe('open');
      expect(result.package_name).toBe('libfoo');
      expect(result.package_version).toBe('1.2.3');
      expect(result.cve?.cve_id).toBe('CVE-2024-12345');
      expect(result.cve?.severity).toBe('critical');
      expect(result.cve?.severity_weight).toBe(9.8);
      expect(result.node_module?.name).toBe('core-runtime');
      expect(result.node_module_version?.version_number).toBe('1.0.0');
    });

    it('returns remediating state exposure correctly', async () => {
      mockGet.mockResolvedValueOnce(envelope({ cve_exposure: EXPOSURE_B }));

      const result = await cveApi.get('exp-2');

      expect(result.state).toBe('remediating');
      expect(result.metadata).toEqual({ ticket: 'SEC-42' });
    });

    it('returns resolved exposure with resolved_at and resolution_note populated', async () => {
      mockGet.mockResolvedValueOnce(envelope({ cve_exposure: EXPOSURE_RESOLVED }));

      const result = await cveApi.get('exp-3');

      expect(result.state).toBe('resolved');
      expect(result.resolved_at).toBe('2024-02-01T09:00:00Z');
      expect(result.resolution_note).toBe('Upgraded to 1.2.4');
    });

    it('returns wont_fix exposure with null cve and null module fields', async () => {
      mockGet.mockResolvedValueOnce(envelope({ cve_exposure: EXPOSURE_WONT_FIX }));

      const result = await cveApi.get('exp-4');

      expect(result.state).toBe('wont_fix');
      expect(result.cve).toBeNull();
      expect(result.node_module_version).toBeNull();
      expect(result.node_module).toBeNull();
      expect(result.package_version).toBeNull();
    });

    it('propagates 404 not-found errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(cveApi.get('missing-id')).rejects.toThrow('Not found');
    });

    it('propagates network errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(cveApi.get('exp-1')).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping contract', () => {
    it('list() correctly extracts cve_exposures from double-envelope { data: { success, data, meta } }', async () => {
      // The API client returns AxiosResponse<PaginatedEnvelope<T>>.
      // extractPaginated must merge data payload with root-level meta.
      const exposures = [EXPOSURE_A];
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: { cve_exposures: exposures }, meta: META },
      });

      const result = await cveApi.list();

      expect(result.cve_exposures).toEqual(exposures);
      expect(result.meta).toEqual(META);
      // Must NOT contain envelope wrapper keys on the result
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('get() correctly extracts cve_exposure from double-envelope { data: { success, data: { cve_exposure } } }', async () => {
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: { cve_exposure: EXPOSURE_A } },
      });

      const result = await cveApi.get('exp-1');

      expect(result).toEqual(EXPOSURE_A);
      // Must NOT be the { cve_exposure: ... } wrapper
      expect((result as unknown as Record<string, unknown>)['cve_exposure']).toBeUndefined();
    });

    it('list() meta is NOT nested inside cve_exposures (guards M1 audit bug)', async () => {
      // The M1 audit finding was that meta was read from inside data instead of
      // response root. Verify it comes from the correct location.
      const multiPageMeta: PaginationMeta = {
        current_page: 3,
        per_page: 5,
        total_count: 42,
        total_pages: 9,
        next_page: 4,
        prev_page: 2,
      };
      mockGet.mockResolvedValueOnce({
        data: {
          success: true,
          data: { cve_exposures: [EXPOSURE_A] },
          meta: multiPageMeta,
        },
      });

      const result = await cveApi.list();

      expect(result.meta.total_count).toBe(42);
      expect(result.meta.total_pages).toBe(9);
      expect(result.meta.next_page).toBe(4);
    });
  });
});
