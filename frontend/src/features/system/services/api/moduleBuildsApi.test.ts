// Behavioral tests for moduleBuildsApi.
//
// Covers both exported methods: exact URL, params, envelope unwrapping
// (paginated list vs. single-record show), filter combinations.
//
// Backend: Api::V1::System::ModuleBuildBatchesController (index/show,
// read-only). Auth scope: system.module_builds.read

import { moduleBuildsApi } from './moduleBuildsApi';
import type { PaginationMeta } from './types';
import type {
  SystemModuleBuildBatch,
  SystemModuleBuildBatchFull,
} from '@system/features/system/types/system.types';

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
 * Build a paginated double-envelope response. Meta sits at the root of the
 * body (NOT inside data) — matching the backend's
 * render_success(data: ..., meta: ...) contract.
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
  total_count: 1,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

const BATCH_A: SystemModuleBuildBatch = {
  id: 'batch-1',
  status: 'dispatched',
  trigger: 'push',
  shadow: false,
  base_sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  head_sha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  module_slugs: ['core-runtime', 'network-stack'],
  planned_count: 2,
  succeeded_count: 0,
  failed_count: 0,
  active: true,
  finished: false,
  package_context: null,
  created_at: '2026-06-01T00:00:00Z',
  updated_at: '2026-06-01T00:00:00Z',
};

const BATCH_PACKAGE: SystemModuleBuildBatch = {
  id: 'batch-2',
  status: 'complete',
  trigger: 'package',
  shadow: false,
  base_sha: 'snapshot-token-a',
  head_sha: 'snapshot-token-b',
  module_slugs: ['pkg-closure'],
  planned_count: 1,
  succeeded_count: 1,
  failed_count: 0,
  active: false,
  finished: true,
  package_context: {
    repository_id: 'repo-1',
    package_repo_kind: 'apt',
    architecture: 'amd64',
    snapshot: '2026-06-01',
    tag: 'stable',
  },
  created_at: '2026-06-01T01:00:00Z',
  updated_at: '2026-06-01T02:00:00Z',
};

const BATCH_FULL: SystemModuleBuildBatchFull = {
  ...BATCH_A,
  dispatched_at: '2026-06-01T00:01:00Z',
  awaiting_signature_at: null,
  publishing_at: null,
  completed_at: null,
  failed_at: null,
  error_message: null,
  modules: [
    {
      module: 'core-runtime',
      tag: 'bbbbbbb',
      state: 'dispatched',
      attempts: 1,
      error: null,
      task: {
        id: 'task-1',
        status: 'running',
        progress: 40,
        started_at: '2026-06-01T00:01:10Z',
        completed_at: null,
        error_message: null,
      },
      lease: {
        id: 'lease-1',
        status: 'busy',
        node_instance_id: 'ni-1',
        runner_name: 'builder-1',
      },
      artifact: null,
      parity: null,
    },
  ],
};

const BASE = '/system/module_build_batches';

// =============================================================================
// Tests
// =============================================================================

describe('moduleBuildsApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list()
  // ---------------------------------------------------------------------------

  describe('list()', () => {
    it('calls GET /system/module_build_batches with undefined params when called with no arguments', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ module_build_batches: [BATCH_A] }, META),
      );

      await moduleBuildsApi.list();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE, { params: undefined });
    });

    it('passes status filter as a query param', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ module_build_batches: [BATCH_A] }, META),
      );

      await moduleBuildsApi.list({ status: 'dispatched' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { status: 'dispatched' } });
    });

    it('passes trigger filter as a query param (including "package")', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ module_build_batches: [BATCH_PACKAGE] }, META),
      );

      await moduleBuildsApi.list({ trigger: 'package' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { trigger: 'package' } });
    });

    it('passes shadow filter as a query param', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ module_build_batches: [] }, { ...META, total_count: 0 }),
      );

      await moduleBuildsApi.list({ shadow: true });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { shadow: true } });
    });

    it('returns batches and meta unwrapped from the paginated envelope', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ module_build_batches: [BATCH_A, BATCH_PACKAGE] }, META),
      );

      const result = await moduleBuildsApi.list();

      expect(result.module_build_batches).toEqual([BATCH_A, BATCH_PACKAGE]);
      expect(result.meta).toEqual(META);
    });
  });

  // ---------------------------------------------------------------------------
  // get()
  // ---------------------------------------------------------------------------

  describe('get()', () => {
    it('calls GET /system/module_build_batches/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ module_build_batch: BATCH_FULL }));

      await moduleBuildsApi.get('batch-1');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/batch-1`);
    });

    it('returns the unwrapped full batch (with per-module rows)', async () => {
      mockGet.mockResolvedValueOnce(envelope({ module_build_batch: BATCH_FULL }));

      const result = await moduleBuildsApi.get('batch-1');

      expect(result).toEqual(BATCH_FULL);
      expect(result.modules).toHaveLength(1);
      expect(result.modules[0].module).toBe('core-runtime');
    });
  });
});
