import { storageMigrationsApi } from './storageMigrationsApi';
import type {
  StorageMigrationDetail,
  StorageMigrationListResponse,
  StorageMigrationSummary,
} from '../../types/storageMigration.types';

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

/**
 * Wrap a payload in the double-envelope shape that AxiosResponse<ApiEnvelope<T>>
 * resolves to:  { data: { success: true, data: <payload> } }
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

const BASE = '/system/platform/storage_migrations';

// =============================================================================
// Fixtures
// =============================================================================

const SUMMARY_A: StorageMigrationSummary = {
  id: 'migration-a',
  status: 'planned',
  role: 'database',
  node_instance_id: 'ni-1',
  source_volume_id: 'vol-src-1',
  target_volume_id: 'vol-tgt-1',
  source_subpath: null,
  target_subpath: null,
  bytes_copied: null,
  bytes_total: null,
  terminal: false,
  error_message: null,
  created_at: '2026-06-01T10:00:00Z',
  approved_at: null,
  started_at: null,
  completed_at: null,
  failed_at: null,
  cancelled_at: null,
};

const SUMMARY_B: StorageMigrationSummary = {
  id: 'migration-b',
  status: 'syncing',
  role: 'cache',
  node_instance_id: 'ni-2',
  source_volume_id: 'vol-src-2',
  target_volume_id: 'vol-tgt-2',
  source_subpath: '/data',
  target_subpath: '/mnt/data',
  bytes_copied: 512000,
  bytes_total: 1024000,
  terminal: false,
  error_message: null,
  created_at: '2026-06-02T08:00:00Z',
  approved_at: '2026-06-02T08:30:00Z',
  started_at: '2026-06-02T09:00:00Z',
  completed_at: null,
  failed_at: null,
  cancelled_at: null,
};

const DETAIL_A: StorageMigrationDetail = {
  ...SUMMARY_A,
  plan: { steps: ['prepare', 'sync', 'cutover'] },
  audit_log: [
    { at: '2026-06-01T10:00:00Z', message: 'Migration created', status_before: null, status_after: 'planned' },
  ],
  metadata: { initiated_by: 'operator' },
  snapshot_subpath: null,
  initiated_by_user_id: 'user-42',
  bytes_verified: null,
};

const LIST_RESPONSE: StorageMigrationListResponse = {
  storage_migrations: [SUMMARY_A, SUMMARY_B],
  count: 2,
};

// =============================================================================
// Tests
// =============================================================================

describe('storageMigrationsApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list
  // ---------------------------------------------------------------------------

  describe('list', () => {
    it('calls GET /system/platform/storage_migrations with no params when no filters given', async () => {
      mockGet.mockResolvedValue(envelope(LIST_RESPONSE));

      const result = await storageMigrationsApi.list();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
      expect(result.storage_migrations).toHaveLength(2);
      expect(result.count).toBe(2);
    });

    it('passes status string filter as a query param', async () => {
      mockGet.mockResolvedValue(envelope(LIST_RESPONSE));

      await storageMigrationsApi.list({ status: 'planned' });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { status: 'planned' },
      });
    });

    it('joins status array filter into a comma-separated string', async () => {
      mockGet.mockResolvedValue(envelope(LIST_RESPONSE));

      await storageMigrationsApi.list({ status: ['planned', 'approved'] });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { status: 'planned,approved' },
      });
    });

    it('passes node_instance_id filter', async () => {
      mockGet.mockResolvedValue(envelope(LIST_RESPONSE));

      await storageMigrationsApi.list({ node_instance_id: 'ni-1' });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { node_instance_id: 'ni-1' },
      });
    });

    it('passes active_only boolean filter as the string "true"', async () => {
      mockGet.mockResolvedValue(envelope(LIST_RESPONSE));

      await storageMigrationsApi.list({ active_only: true });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { active_only: 'true' },
      });
    });

    it('passes active_only false as the string "false"', async () => {
      mockGet.mockResolvedValue(envelope(LIST_RESPONSE));

      await storageMigrationsApi.list({ active_only: false });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { active_only: 'false' },
      });
    });

    it('omits undefined filter values from params', async () => {
      mockGet.mockResolvedValue(envelope(LIST_RESPONSE));

      await storageMigrationsApi.list({ status: undefined, node_instance_id: 'ni-1' });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { node_instance_id: 'ni-1' },
      });
    });

    it('omits null filter values from params', async () => {
      mockGet.mockResolvedValue(envelope(LIST_RESPONSE));

      // Cast to exercise the null branch in paramsFromFilters
      await storageMigrationsApi.list({ node_instance_id: null as unknown as string });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
    });

    it('omits empty-array filter values from params', async () => {
      mockGet.mockResolvedValue(envelope(LIST_RESPONSE));

      await storageMigrationsApi.list({ status: [] as unknown as never });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
    });

    it('combines multiple filters together', async () => {
      mockGet.mockResolvedValue(envelope({ storage_migrations: [], count: 0 }));

      await storageMigrationsApi.list({ status: 'syncing', node_instance_id: 'ni-2', active_only: true });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { status: 'syncing', node_instance_id: 'ni-2', active_only: 'true' },
      });
    });

    it('returns the unwrapped StorageMigrationListResponse', async () => {
      mockGet.mockResolvedValue(envelope(LIST_RESPONSE));

      const result = await storageMigrationsApi.list();

      expect(result).toEqual(LIST_RESPONSE);
    });

    it('propagates API errors', async () => {
      const error = new Error('Network error');
      mockGet.mockRejectedValue(error);

      await expect(storageMigrationsApi.list()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // get
  // ---------------------------------------------------------------------------

  describe('get', () => {
    it('calls GET /system/platform/storage_migrations/:id', async () => {
      mockGet.mockResolvedValue(envelope({ storage_migration: DETAIL_A }));

      await storageMigrationsApi.get('migration-a');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/migration-a`);
    });

    it('returns the unwrapped StorageMigrationDetail (extracts .storage_migration)', async () => {
      mockGet.mockResolvedValue(envelope({ storage_migration: DETAIL_A }));

      const result = await storageMigrationsApi.get('migration-a');

      expect(result).toEqual(DETAIL_A);
      expect(result.plan).toBeDefined();
      expect(result.audit_log).toHaveLength(1);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValue(new Error('Not found'));

      await expect(storageMigrationsApi.get('migration-a')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // create
  // ---------------------------------------------------------------------------

  describe('create', () => {
    const CREATE_PARAMS = {
      node_instance_id: 'ni-1',
      source_volume_id: 'vol-src-1',
      target_volume_id: 'vol-tgt-1',
      role: 'database',
    };

    it('calls POST /system/platform/storage_migrations with the given params', async () => {
      mockPost.mockResolvedValue(envelope({ storage_migration: SUMMARY_A }));

      await storageMigrationsApi.create(CREATE_PARAMS);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(BASE, CREATE_PARAMS);
    });

    it('returns the unwrapped StorageMigrationSummary (extracts .storage_migration)', async () => {
      mockPost.mockResolvedValue(envelope({ storage_migration: SUMMARY_A }));

      const result = await storageMigrationsApi.create(CREATE_PARAMS);

      expect(result).toEqual(SUMMARY_A);
      expect(result.id).toBe('migration-a');
      expect(result.status).toBe('planned');
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValue(new Error('Unprocessable Entity'));

      await expect(storageMigrationsApi.create(CREATE_PARAMS)).rejects.toThrow('Unprocessable Entity');
    });
  });

  // ---------------------------------------------------------------------------
  // approve
  // ---------------------------------------------------------------------------

  describe('approve', () => {
    const APPROVED_DETAIL: StorageMigrationDetail = {
      ...DETAIL_A,
      status: 'approved',
      approved_at: '2026-06-01T11:00:00Z',
    };

    it('calls POST /system/platform/storage_migrations/:id/approve with an empty body', async () => {
      mockPost.mockResolvedValue(envelope({ storage_migration: APPROVED_DETAIL }));

      await storageMigrationsApi.approve('migration-a');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/migration-a/approve`, {});
    });

    it('returns the unwrapped StorageMigrationDetail after approval', async () => {
      mockPost.mockResolvedValue(envelope({ storage_migration: APPROVED_DETAIL }));

      const result = await storageMigrationsApi.approve('migration-a');

      expect(result.status).toBe('approved');
      expect(result.approved_at).toBe('2026-06-01T11:00:00Z');
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValue(new Error('Forbidden'));

      await expect(storageMigrationsApi.approve('migration-a')).rejects.toThrow('Forbidden');
    });
  });

  // ---------------------------------------------------------------------------
  // cancel
  // ---------------------------------------------------------------------------

  describe('cancel', () => {
    const CANCELLED_DETAIL: StorageMigrationDetail = {
      ...DETAIL_A,
      status: 'cancelled',
      cancelled_at: '2026-06-01T12:00:00Z',
      terminal: true,
    };

    it('calls POST /system/platform/storage_migrations/:id/cancel with a reason', async () => {
      mockPost.mockResolvedValue(envelope({ storage_migration: CANCELLED_DETAIL }));

      await storageMigrationsApi.cancel('migration-a', 'Operator requested');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/migration-a/cancel`, {
        reason: 'Operator requested',
      });
    });

    it('calls POST with reason: undefined when no reason is provided', async () => {
      mockPost.mockResolvedValue(envelope({ storage_migration: CANCELLED_DETAIL }));

      await storageMigrationsApi.cancel('migration-a');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/migration-a/cancel`, {
        reason: undefined,
      });
    });

    it('returns the unwrapped StorageMigrationDetail after cancellation', async () => {
      mockPost.mockResolvedValue(envelope({ storage_migration: CANCELLED_DETAIL }));

      const result = await storageMigrationsApi.cancel('migration-a', 'Operator requested');

      expect(result.status).toBe('cancelled');
      expect(result.terminal).toBe(true);
      expect(result.cancelled_at).toBe('2026-06-01T12:00:00Z');
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValue(new Error('Conflict'));

      await expect(storageMigrationsApi.cancel('migration-a')).rejects.toThrow('Conflict');
    });
  });

  // ---------------------------------------------------------------------------
  // paramsFromFilters edge cases (tested via list())
  // ---------------------------------------------------------------------------

  describe('paramsFromFilters edge cases', () => {
    it('converts numeric-like string values to strings without modification', async () => {
      mockGet.mockResolvedValue(envelope({ storage_migrations: [], count: 0 }));

      // node_instance_id is always a string; this exercises the default String(value) branch
      await storageMigrationsApi.list({ node_instance_id: '12345' });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { node_instance_id: '12345' },
      });
    });

    it('handles an empty filters object (all keys stripped) with no params', async () => {
      mockGet.mockResolvedValue(envelope({ storage_migrations: [], count: 0 }));

      await storageMigrationsApi.list({});

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
    });
  });
});
