// Behavioral tests for platformMigrationsApi.
//
// Covers every exported method: exact URL, params, payload, envelope
// unwrapping, paramsFromFilters edge cases, and error propagation.

import { platformMigrationsApi } from './platformMigrationsApi';
import type { MigrationListFilters, MigrationStatus } from '../../types/migration.types';

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

/** Build a double-envelope AxiosResponse body for a generic success. */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Fixtures
// =============================================================================

const BASE = '/system/platform/migrations';

const MIGRATION_SUMMARY = {
  id: 'mig-1',
  operation: 'migrate' as const,
  status: 'planned' as const,
  root_resource_kind: 'Node',
  root_resource_id: 'node-abc',
  dry_run: false,
  destination_peer_id: 'peer-1',
  step_count: 2,
  total_steps: 5,
  created_at: '2026-06-01T00:00:00Z',
  started_at: null,
  completed_at: null,
  failed_at: null,
  cancelled_at: null,
  terminal: false,
  error_message: null,
};

const MIGRATION_DETAIL = {
  ...MIGRATION_SUMMARY,
  plan_summary: { steps: 5 },
  conflict_log: [],
  audit_log: [],
  metadata: {},
  initiated_by_user_id: 'user-1',
};

const MIGRATION_SUMMARY_B = {
  id: 'mig-2',
  operation: 'duplicate' as const,
  status: 'completed' as const,
  root_resource_kind: 'AgentTeam',
  root_resource_id: 'team-xyz',
  dry_run: true,
  destination_peer_id: null,
  step_count: 5,
  total_steps: 5,
  created_at: '2026-06-02T00:00:00Z',
  started_at: '2026-06-02T01:00:00Z',
  completed_at: '2026-06-02T02:00:00Z',
  failed_at: null,
  cancelled_at: null,
  terminal: true,
  error_message: null,
};

const LIST_RESPONSE = {
  migrations: [MIGRATION_SUMMARY],
  count: 1,
};

// =============================================================================
// Tests
// =============================================================================

describe('platformMigrationsApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list()
  // ---------------------------------------------------------------------------

  describe('list()', () => {
    it('calls GET /system/platform/migrations with empty params when called with no arguments', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      await platformMigrationsApi.list();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
    });

    it('calls GET /system/platform/migrations with empty params when filters is undefined', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      await platformMigrationsApi.list(undefined);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
    });

    it('returns the unwrapped MigrationListResponse', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const result = await platformMigrationsApi.list();

      expect(result).toEqual(LIST_RESPONSE);
      expect(result.migrations).toHaveLength(1);
      expect(result.count).toBe(1);
    });

    it('returns multiple migrations in the list', async () => {
      const multiList = {
        migrations: [MIGRATION_SUMMARY, MIGRATION_SUMMARY_B],
        count: 2,
      };
      mockGet.mockResolvedValueOnce(envelope(multiList));

      const result = await platformMigrationsApi.list();

      expect(result.migrations).toHaveLength(2);
      expect(result.count).toBe(2);
    });

    it('returns an empty migrations array when the list is empty', async () => {
      const emptyList = { migrations: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(emptyList));

      const result = await platformMigrationsApi.list();

      expect(result.migrations).toEqual([]);
      expect(result.count).toBe(0);
    });

    it('passes a single status string filter as a query param', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const filters: MigrationListFilters = { status: 'planned' };
      await platformMigrationsApi.list(filters);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { status: 'planned' } });
    });

    it('passes an array of statuses joined by comma as a single query param', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const filters: MigrationListFilters = { status: ['planned', 'validating', 'transferring'] };
      await platformMigrationsApi.list(filters);

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { status: 'planned,validating,transferring' },
      });
    });

    it('passes the operation filter as a query param', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const filters: MigrationListFilters = { operation: 'duplicate' };
      await platformMigrationsApi.list(filters);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { operation: 'duplicate' } });
    });

    it('passes both status and operation filters together', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const filters: MigrationListFilters = { status: 'completed', operation: 'migrate' };
      await platformMigrationsApi.list(filters);

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { status: 'completed', operation: 'migrate' },
      });
    });

    it('passes status as array of two elements joined by comma', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const filters: MigrationListFilters = { status: ['failed', 'cancelled'] };
      await platformMigrationsApi.list(filters);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { status: 'failed,cancelled' } });
    });

    it('omits array filter when status array is empty', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      // An empty status array should produce no status param at all.
      const filters = { status: [] as MigrationStatus[] };
      await platformMigrationsApi.list(filters);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
    });

    it('omits filter keys whose value is null', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      // null values are stripped by paramsFromFilters.
      const filters = { status: null as unknown as MigrationStatus };
      await platformMigrationsApi.list(filters);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
    });

    it('omits filter keys whose value is undefined', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const filters: MigrationListFilters = { status: undefined, operation: undefined };
      await platformMigrationsApi.list(filters);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
    });

    it('does not include envelope wrapper keys in the returned data', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const result = await platformMigrationsApi.list();

      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('propagates API errors thrown by apiClient.get', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(platformMigrationsApi.list()).rejects.toThrow('Network error');
    });

    it('propagates 4xx errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Unauthorized'));

      await expect(platformMigrationsApi.list()).rejects.toThrow('Unauthorized');
    });
  });

  // ---------------------------------------------------------------------------
  // get()
  // ---------------------------------------------------------------------------

  describe('get()', () => {
    it('calls GET /system/platform/migrations/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ migration: MIGRATION_DETAIL }));

      await platformMigrationsApi.get('mig-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/mig-1`);
    });

    it('uses the supplied id in the URL path', async () => {
      mockGet.mockResolvedValueOnce(envelope({ migration: MIGRATION_DETAIL }));

      await platformMigrationsApi.get('mig-abc-99');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/mig-abc-99`);
    });

    it('unwraps the nested .migration from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ migration: MIGRATION_DETAIL }));

      const result = await platformMigrationsApi.get('mig-1');

      expect(result).toEqual(MIGRATION_DETAIL);
    });

    it('returns the MigrationDetail with extended fields', async () => {
      mockGet.mockResolvedValueOnce(envelope({ migration: MIGRATION_DETAIL }));

      const result = await platformMigrationsApi.get('mig-1');

      expect(result.plan_summary).toEqual({ steps: 5 });
      expect(result.conflict_log).toEqual([]);
      expect(result.audit_log).toEqual([]);
      expect(result.metadata).toEqual({});
      expect(result.initiated_by_user_id).toBe('user-1');
    });

    it('returns the base MigrationSummary fields correctly', async () => {
      mockGet.mockResolvedValueOnce(envelope({ migration: MIGRATION_DETAIL }));

      const result = await platformMigrationsApi.get('mig-1');

      expect(result.id).toBe('mig-1');
      expect(result.operation).toBe('migrate');
      expect(result.status).toBe('planned');
      expect(result.root_resource_kind).toBe('Node');
      expect(result.root_resource_id).toBe('node-abc');
      expect(result.dry_run).toBe(false);
      expect(result.destination_peer_id).toBe('peer-1');
      expect(result.step_count).toBe(2);
      expect(result.total_steps).toBe(5);
      expect(result.terminal).toBe(false);
      expect(result.error_message).toBeNull();
    });

    it('returns null for nullable timestamp fields when not set', async () => {
      mockGet.mockResolvedValueOnce(envelope({ migration: MIGRATION_DETAIL }));

      const result = await platformMigrationsApi.get('mig-1');

      expect(result.started_at).toBeNull();
      expect(result.completed_at).toBeNull();
      expect(result.failed_at).toBeNull();
      expect(result.cancelled_at).toBeNull();
    });

    it('correctly unwraps a completed migration with all timestamps set', async () => {
      const completedDetail = {
        ...MIGRATION_SUMMARY_B,
        plan_summary: {},
        conflict_log: [],
        audit_log: [{ at: '2026-06-02T01:30:00Z', event: 'step_completed', message: 'done' }],
        metadata: {},
        initiated_by_user_id: null,
      };
      mockGet.mockResolvedValueOnce(envelope({ migration: completedDetail }));

      const result = await platformMigrationsApi.get('mig-2');

      expect(result.id).toBe('mig-2');
      expect(result.status).toBe('completed');
      expect(result.terminal).toBe(true);
      expect(result.started_at).toBe('2026-06-02T01:00:00Z');
      expect(result.completed_at).toBe('2026-06-02T02:00:00Z');
      expect(result.initiated_by_user_id).toBeNull();
      expect(result.audit_log).toHaveLength(1);
      expect(result.audit_log[0].event).toBe('step_completed');
    });

    it('returns a migration with a non-empty conflict_log', async () => {
      const conflictDetail = {
        ...MIGRATION_DETAIL,
        status: 'conflict' as const,
        conflict_log: [
          {
            kind: 'resource_conflict',
            message: 'Duplicate node detected',
            resource_kind: 'Node',
            resource_id: 'node-abc',
            detected_at: '2026-06-01T01:00:00Z',
          },
        ],
      };
      mockGet.mockResolvedValueOnce(envelope({ migration: conflictDetail }));

      const result = await platformMigrationsApi.get('mig-conflict');

      expect(result.status).toBe('conflict');
      expect(result.conflict_log).toHaveLength(1);
      expect(result.conflict_log[0].kind).toBe('resource_conflict');
      expect(result.conflict_log[0].message).toBe('Duplicate node detected');
      expect(result.conflict_log[0].resource_kind).toBe('Node');
    });

    it('does not return envelope wrapper keys from get()', async () => {
      mockGet.mockResolvedValueOnce(envelope({ migration: MIGRATION_DETAIL }));

      const result = await platformMigrationsApi.get('mig-1');

      // Must NOT be the { migration: ... } wrapper
      expect((result as unknown as Record<string, unknown>)['migration']).toBeUndefined();
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('does not pass query params to the get endpoint', async () => {
      mockGet.mockResolvedValueOnce(envelope({ migration: MIGRATION_DETAIL }));

      await platformMigrationsApi.get('mig-1');

      // get() is called with only the URL, no options object
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/mig-1`);
      const [url, ...rest] = mockGet.mock.calls[0] as [string, ...unknown[]];
      expect(url).toBe(`${BASE}/mig-1`);
      expect(rest).toHaveLength(0);
    });

    it('propagates API errors thrown by apiClient.get', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(platformMigrationsApi.get('mig-missing')).rejects.toThrow('Not found');
    });

    it('propagates network errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network timeout'));

      await expect(platformMigrationsApi.get('mig-1')).rejects.toThrow('Network timeout');
    });
  });

  // ---------------------------------------------------------------------------
  // paramsFromFilters — indirectly tested via list()
  // ---------------------------------------------------------------------------

  describe('paramsFromFilters (via list())', () => {
    it('converts a boolean-like string value using String()', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      // operation is always a string, but test ensures non-array primitives
      // go through String() coercion correctly.
      await platformMigrationsApi.list({ operation: 'migrate' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { operation: 'migrate' } });
    });

    it('produces no params object keys when filters object is empty', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      await platformMigrationsApi.list({});

      const [, options] = mockGet.mock.calls[0] as [string, { params: Record<string, string> }];
      expect(Object.keys(options.params)).toHaveLength(0);
    });

    it('handles all 8 terminal status values as a joined array', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const allStatuses: MigrationStatus[] = [
        'planned',
        'validating',
        'transferring',
        'conflict',
        'applying',
        'completed',
        'failed',
        'cancelled',
      ];
      await platformMigrationsApi.list({ status: allStatuses });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: {
          status: 'planned,validating,transferring,conflict,applying,completed,failed,cancelled',
        },
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — explicit contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping', () => {
    it('list(): extracts data from double-envelope { data: { success, data: payload } }', async () => {
      const payload = { migrations: [], count: 0 };
      mockGet.mockResolvedValueOnce({ data: { success: true, data: payload } });

      const result = await platformMigrationsApi.list();

      expect(result).toEqual(payload);
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('get(): extracts nested .migration from double-envelope', async () => {
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: { migration: MIGRATION_DETAIL } },
      });

      const result = await platformMigrationsApi.get('mig-1');

      expect(result.id).toBe('mig-1');
      expect((result as unknown as Record<string, unknown>)['migration']).toBeUndefined();
    });
  });

  // ---------------------------------------------------------------------------
  // Concurrent calls
  // ---------------------------------------------------------------------------

  describe('concurrent calls', () => {
    it('each call uses its own mock resolved value independently', async () => {
      const listResp = { migrations: [MIGRATION_SUMMARY], count: 1 };
      mockGet
        .mockResolvedValueOnce(envelope(listResp))
        .mockResolvedValueOnce(envelope({ migration: MIGRATION_DETAIL }));

      const [list, detail] = await Promise.all([
        platformMigrationsApi.list(),
        platformMigrationsApi.get('mig-1'),
      ]);

      expect(list.migrations).toHaveLength(1);
      expect(detail.id).toBe('mig-1');
      expect(mockGet).toHaveBeenCalledTimes(2);
    });
  });
});
