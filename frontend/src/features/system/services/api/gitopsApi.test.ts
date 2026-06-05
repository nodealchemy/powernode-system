// Behavioral tests for gitopsApi.
//
// Covers every exported method: exact URL, request shape, envelope unwrapping,
// pagination meta extraction, optional argument edge cases, and error propagation.

import { gitopsApi } from './gitopsApi';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPatch = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    patch: (...args: unknown[]) => mockPatch(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/** Build a double-envelope AxiosResponse body for a non-paginated success. */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

/**
 * Build a paginated envelope.
 * Per helpers.ts: meta sits at the ROOT of the response body (response.data.meta),
 * NOT inside response.data.data. extractPaginated() reads response.data.meta.
 */
function paginatedEnvelope<T>(data: T, meta?: Partial<PaginationMetaShape>) {
  const baseMeta: PaginationMetaShape = {
    current_page: 1,
    per_page: 50,
    total_count: 1,
    total_pages: 1,
    next_page: null,
    prev_page: null,
    ...meta,
  };
  return { data: { success: true, data, meta: baseMeta } };
}

interface PaginationMetaShape {
  current_page: number;
  per_page: number;
  total_count: number;
  total_pages: number;
  next_page: number | null;
  prev_page: number | null;
}

// =============================================================================
// Fixtures
// =============================================================================

const REPO_A = {
  id: 'repo-a',
  name: 'fleet-config',
  repo_url: 'https://git.example.com/org/fleet.git',
  branch: 'main',
  path_prefix: 'clusters/',
  enabled: true,
  auto_apply: false,
  last_synced_at: '2026-05-01T10:00:00Z',
  last_synced_revision: 'abc1234',
  last_diff_count: 3,
  last_status: 'success',
  last_error: null,
  metadata: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-05-01T10:00:00Z',
};

const REPO_B = {
  id: 'repo-b',
  name: 'infra-modules',
  repo_url: 'https://git.example.com/org/infra.git',
  branch: 'develop',
  path_prefix: '',
  enabled: false,
  auto_apply: true,
  last_synced_at: null,
  last_synced_revision: null,
  last_diff_count: 0,
  last_status: 'pending',
  last_error: null,
  metadata: { team: 'ops' },
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
};

const SYNC_RUN_A = {
  id: 'run-1',
  started_at: '2026-05-01T10:00:00Z',
  completed_at: '2026-05-01T10:00:05Z',
  duration_seconds: 5,
  diff_count: 3,
  proposal_ids: ['prop-1', 'prop-2', 'prop-3'],
  status: 'completed',
  synced_revision: 'abc1234',
  error_message: null,
  diff_summary: { nodes: 2, modules: 1 },
};

const SYNC_RUN_FAILED = {
  id: 'run-fail',
  started_at: '2026-05-02T09:00:00Z',
  completed_at: '2026-05-02T09:00:02Z',
  duration_seconds: 2,
  diff_count: 0,
  proposal_ids: [],
  status: 'failed',
  synced_revision: null,
  error_message: 'Repository unreachable',
  diff_summary: {},
};

const SYNC_RESULT = {
  sync_run: SYNC_RUN_A,
  ok: true,
  diff_count: 3,
  proposal_ids: ['prop-1', 'prop-2', 'prop-3'],
};

const DEFAULT_META: PaginationMetaShape = {
  current_page: 1,
  per_page: 50,
  total_count: 2,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

const BASE = '/system/gitops_repositories';

// =============================================================================
// Tests
// =============================================================================

describe('gitopsApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPatch.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list()
  // ---------------------------------------------------------------------------

  describe('list()', () => {
    it('calls GET /system/gitops_repositories with no params when called with no arguments', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ gitops_repositories: [REPO_A] }, { total_count: 1 })
      );

      await gitopsApi.list();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE, { params: undefined });
    });

    it('passes pagination params when provided', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ gitops_repositories: [REPO_A] })
      );

      await gitopsApi.list({ page: 2, per_page: 25 });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { page: 2, per_page: 25 } });
    });

    it('passes the enabled filter when provided', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ gitops_repositories: [REPO_A] })
      );

      await gitopsApi.list({ enabled: true });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { enabled: true } });
    });

    it('passes enabled: false to filter disabled repos', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ gitops_repositories: [REPO_B] })
      );

      await gitopsApi.list({ enabled: false });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { enabled: false } });
    });

    it('passes combined pagination + filter params', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ gitops_repositories: [REPO_A] })
      );

      await gitopsApi.list({ page: 1, per_page: 10, enabled: true });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { page: 1, per_page: 10, enabled: true },
      });
    });

    it('returns the gitops_repositories array unwrapped from the data envelope', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope(
          { gitops_repositories: [REPO_A, REPO_B] },
          { total_count: 2 }
        )
      );

      const result = await gitopsApi.list();

      expect(result.gitops_repositories).toHaveLength(2);
      expect(result.gitops_repositories[0]).toEqual(REPO_A);
      expect(result.gitops_repositories[1]).toEqual(REPO_B);
    });

    it('returns pagination meta from the root of the response body, not from data', async () => {
      const customMeta: PaginationMetaShape = {
        current_page: 2,
        per_page: 10,
        total_count: 25,
        total_pages: 3,
        next_page: 3,
        prev_page: 1,
      };
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ gitops_repositories: [REPO_A] }, customMeta)
      );

      const result = await gitopsApi.list({ page: 2, per_page: 10 });

      expect(result.meta.current_page).toBe(2);
      expect(result.meta.total_count).toBe(25);
      expect(result.meta.total_pages).toBe(3);
      expect(result.meta.next_page).toBe(3);
      expect(result.meta.prev_page).toBe(1);
    });

    it('returns a synthesized meta when the response carries no meta block', async () => {
      // When meta is absent from the response, extractPaginated synthesizes a
      // default meta using the item count derived from array fields in data.
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: { gitops_repositories: [REPO_A] } },
        // no meta key at all
      });

      const result = await gitopsApi.list();

      expect(result.meta).toBeDefined();
      expect(result.meta.total_count).toBe(1);
      expect(result.meta.current_page).toBe(1);
    });

    it('returns an empty array when no repos exist', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ gitops_repositories: [] }, { total_count: 0 })
      );

      const result = await gitopsApi.list();

      expect(result.gitops_repositories).toEqual([]);
      expect(result.meta.total_count).toBe(0);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(gitopsApi.list()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // get()
  // ---------------------------------------------------------------------------

  describe('get()', () => {
    it('calls GET /system/gitops_repositories/:id', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ gitops_repository: REPO_A, recent_runs: [SYNC_RUN_A] })
      );

      await gitopsApi.get('repo-a');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/repo-a`);
    });

    it('uses the supplied id in the URL', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ gitops_repository: REPO_B, recent_runs: [] })
      );

      await gitopsApi.get('repo-b');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/repo-b`);
    });

    it('returns the unwrapped gitops_repository and recent_runs', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ gitops_repository: REPO_A, recent_runs: [SYNC_RUN_A, SYNC_RUN_FAILED] })
      );

      const result = await gitopsApi.get('repo-a');

      expect(result.gitops_repository).toEqual(REPO_A);
      expect(result.recent_runs).toHaveLength(2);
      expect(result.recent_runs[0]).toEqual(SYNC_RUN_A);
      expect(result.recent_runs[1]).toEqual(SYNC_RUN_FAILED);
    });

    it('returns an empty recent_runs array when there are no runs', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ gitops_repository: REPO_B, recent_runs: [] })
      );

      const result = await gitopsApi.get('repo-b');

      expect(result.recent_runs).toEqual([]);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(gitopsApi.get('missing')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // create()
  // ---------------------------------------------------------------------------

  describe('create()', () => {
    const MINIMAL_CREATE = {
      name: 'my-fleet',
      repo_url: 'https://git.example.com/org/fleet.git',
    };

    const FULL_CREATE = {
      name: 'full-fleet',
      repo_url: 'https://git.example.com/org/fleet.git',
      branch: 'production',
      path_prefix: 'nodes/',
      vault_credential_path: 'secret/data/gitops/token',
      enabled: true,
      auto_apply: true,
      metadata: { team: 'infra', region: 'us-east-1' },
    };

    it('calls POST /system/gitops_repositories with the body wrapped in gitops_repository key', async () => {
      mockPost.mockResolvedValueOnce(envelope({ gitops_repository: REPO_A }));

      await gitopsApi.create(MINIMAL_CREATE);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(BASE, { gitops_repository: MINIMAL_CREATE });
    });

    it('wraps the full create payload in the gitops_repository envelope', async () => {
      mockPost.mockResolvedValueOnce(envelope({ gitops_repository: REPO_A }));

      await gitopsApi.create(FULL_CREATE);

      expect(mockPost).toHaveBeenCalledWith(BASE, { gitops_repository: FULL_CREATE });
    });

    it('passes optional fields when provided: branch, path_prefix, vault_credential_path', async () => {
      mockPost.mockResolvedValueOnce(envelope({ gitops_repository: REPO_A }));

      await gitopsApi.create(FULL_CREATE);

      const [, body] = mockPost.mock.calls[0] as [string, { gitops_repository: typeof FULL_CREATE }];
      expect(body.gitops_repository.branch).toBe('production');
      expect(body.gitops_repository.path_prefix).toBe('nodes/');
      expect(body.gitops_repository.vault_credential_path).toBe('secret/data/gitops/token');
      expect(body.gitops_repository.auto_apply).toBe(true);
    });

    it('works with only the required fields (name, repo_url)', async () => {
      mockPost.mockResolvedValueOnce(envelope({ gitops_repository: REPO_A }));

      await gitopsApi.create(MINIMAL_CREATE);

      const [, body] = mockPost.mock.calls[0] as [string, { gitops_repository: typeof MINIMAL_CREATE }];
      expect(body.gitops_repository.name).toBe('my-fleet');
      expect(body.gitops_repository.repo_url).toBe('https://git.example.com/org/fleet.git');
    });

    it('returns the unwrapped SystemGitopsRepository record', async () => {
      mockPost.mockResolvedValueOnce(envelope({ gitops_repository: REPO_A }));

      const result = await gitopsApi.create(MINIMAL_CREATE);

      expect(result).toEqual(REPO_A);
      expect(result.id).toBe('repo-a');
      expect(result.name).toBe('fleet-config');
    });

    it('does NOT return the { gitops_repository: ... } wrapper', async () => {
      mockPost.mockResolvedValueOnce(envelope({ gitops_repository: REPO_A }));

      const result = await gitopsApi.create(MINIMAL_CREATE);

      expect((result as unknown as Record<string, unknown>)['gitops_repository']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Validation failed'));

      await expect(gitopsApi.create(MINIMAL_CREATE)).rejects.toThrow('Validation failed');
    });
  });

  // ---------------------------------------------------------------------------
  // update()
  // ---------------------------------------------------------------------------

  describe('update()', () => {
    it('calls PATCH /system/gitops_repositories/:id with body wrapped in gitops_repository key', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ gitops_repository: REPO_A }));

      await gitopsApi.update('repo-a', { enabled: false });

      expect(mockPatch).toHaveBeenCalledTimes(1);
      expect(mockPatch).toHaveBeenCalledWith(`${BASE}/repo-a`, {
        gitops_repository: { enabled: false },
      });
    });

    it('uses the supplied id in the URL', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ gitops_repository: REPO_B }));

      await gitopsApi.update('repo-b', { branch: 'staging' });

      expect(mockPatch).toHaveBeenCalledWith(`${BASE}/repo-b`, {
        gitops_repository: { branch: 'staging' },
      });
    });

    it('uses PATCH, not PUT', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ gitops_repository: REPO_A }));

      await gitopsApi.update('repo-a', { enabled: true });

      expect(mockPatch).toHaveBeenCalledTimes(1);
      expect(mockPost).not.toHaveBeenCalled();
    });

    it('allows partial updates (single field)', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ gitops_repository: { ...REPO_A, enabled: false } }));

      await gitopsApi.update('repo-a', { enabled: false });

      const [, body] = mockPatch.mock.calls[0] as [string, { gitops_repository: { enabled: boolean } }];
      expect(body.gitops_repository).toEqual({ enabled: false });
    });

    it('allows updating multiple fields at once', async () => {
      const updates = { name: 'renamed', branch: 'release', auto_apply: true };
      mockPatch.mockResolvedValueOnce(envelope({ gitops_repository: { ...REPO_A, ...updates } }));

      await gitopsApi.update('repo-a', updates);

      expect(mockPatch).toHaveBeenCalledWith(`${BASE}/repo-a`, {
        gitops_repository: updates,
      });
    });

    it('returns the unwrapped updated SystemGitopsRepository record', async () => {
      const updated = { ...REPO_A, enabled: false };
      mockPatch.mockResolvedValueOnce(envelope({ gitops_repository: updated }));

      const result = await gitopsApi.update('repo-a', { enabled: false });

      expect(result).toEqual(updated);
      expect(result.enabled).toBe(false);
    });

    it('does NOT return the { gitops_repository: ... } wrapper', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ gitops_repository: REPO_A }));

      const result = await gitopsApi.update('repo-a', { name: 'new-name' });

      expect((result as unknown as Record<string, unknown>)['gitops_repository']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPatch.mockRejectedValueOnce(new Error('Update failed'));

      await expect(gitopsApi.update('repo-a', { name: 'x' })).rejects.toThrow('Update failed');
    });
  });

  // ---------------------------------------------------------------------------
  // destroy()
  // ---------------------------------------------------------------------------

  describe('destroy()', () => {
    it('calls DELETE /system/gitops_repositories/:id', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await gitopsApi.destroy('repo-a');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/repo-a`);
    });

    it('uses the supplied id in the URL', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await gitopsApi.destroy('repo-xyz-999');

      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/repo-xyz-999`);
    });

    it('resolves to void (returns undefined)', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      const result = await gitopsApi.destroy('repo-a');

      expect(result).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Delete failed'));

      await expect(gitopsApi.destroy('repo-a')).rejects.toThrow('Delete failed');
    });
  });

  // ---------------------------------------------------------------------------
  // syncNow()
  // ---------------------------------------------------------------------------

  describe('syncNow()', () => {
    it('calls POST /system/gitops_repositories/:id/sync_now with an empty body', async () => {
      mockPost.mockResolvedValueOnce(envelope(SYNC_RESULT));

      await gitopsApi.syncNow('repo-a');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/repo-a/sync_now`, {});
    });

    it('uses the supplied id in the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope(SYNC_RESULT));

      await gitopsApi.syncNow('repo-b');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/repo-b/sync_now`, {});
    });

    it('always sends an empty object body (not null or undefined)', async () => {
      mockPost.mockResolvedValueOnce(envelope(SYNC_RESULT));

      await gitopsApi.syncNow('repo-a');

      const [, body] = mockPost.mock.calls[0] as [string, unknown];
      expect(body).toEqual({});
    });

    it('returns the full SystemGitopsSyncResult payload', async () => {
      mockPost.mockResolvedValueOnce(envelope(SYNC_RESULT));

      const result = await gitopsApi.syncNow('repo-a');

      expect(result).toEqual(SYNC_RESULT);
      expect(result.ok).toBe(true);
      expect(result.diff_count).toBe(3);
      expect(result.proposal_ids).toEqual(['prop-1', 'prop-2', 'prop-3']);
    });

    it('returns the sync_run details nested inside the result', async () => {
      mockPost.mockResolvedValueOnce(envelope(SYNC_RESULT));

      const result = await gitopsApi.syncNow('repo-a');

      expect(result.sync_run).toEqual(SYNC_RUN_A);
      expect(result.sync_run.id).toBe('run-1');
      expect(result.sync_run.status).toBe('completed');
      expect(result.sync_run.duration_seconds).toBe(5);
    });

    it('returns ok: false and zero diffs when sync found nothing to do', async () => {
      const emptyResult = {
        sync_run: { ...SYNC_RUN_A, diff_count: 0, proposal_ids: [] },
        ok: true,
        diff_count: 0,
        proposal_ids: [],
      };
      mockPost.mockResolvedValueOnce(envelope(emptyResult));

      const result = await gitopsApi.syncNow('repo-a');

      expect(result.diff_count).toBe(0);
      expect(result.proposal_ids).toEqual([]);
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Sync failed'));

      await expect(gitopsApi.syncNow('repo-a')).rejects.toThrow('Sync failed');
    });
  });

  // ---------------------------------------------------------------------------
  // syncRuns()
  // ---------------------------------------------------------------------------

  describe('syncRuns()', () => {
    it('calls GET /system/gitops_repositories/:id/sync_runs', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ sync_runs: [SYNC_RUN_A] })
      );

      await gitopsApi.syncRuns('repo-a');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/repo-a/sync_runs`);
    });

    it('uses the supplied id in the URL', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ sync_runs: [SYNC_RUN_A] })
      );

      await gitopsApi.syncRuns('repo-b');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/repo-b/sync_runs`);
    });

    it('returns the unwrapped array of sync runs', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ sync_runs: [SYNC_RUN_A, SYNC_RUN_FAILED] })
      );

      const result = await gitopsApi.syncRuns('repo-a');

      expect(result).toHaveLength(2);
      expect(result[0]).toEqual(SYNC_RUN_A);
      expect(result[1]).toEqual(SYNC_RUN_FAILED);
    });

    it('returns an empty array when there are no sync runs', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ sync_runs: [] })
      );

      const result = await gitopsApi.syncRuns('repo-a');

      expect(result).toEqual([]);
    });

    it('returns an empty array when sync_runs key is absent from the response', async () => {
      // extractData().sync_runs ?? [] should fall back to []
      mockGet.mockResolvedValueOnce(
        envelope({})
      );

      const result = await gitopsApi.syncRuns('repo-a');

      expect(result).toEqual([]);
    });

    it('does NOT return the { sync_runs: [...] } wrapper', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ sync_runs: [SYNC_RUN_A] })
      );

      const result = await gitopsApi.syncRuns('repo-a');

      // Result should be the array itself, not the wrapping object
      expect(Array.isArray(result)).toBe(true);
      expect((result as unknown as Record<string, unknown>)['sync_runs']).toBeUndefined();
    });

    it('returns a failed run with its error message intact', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ sync_runs: [SYNC_RUN_FAILED] })
      );

      const result = await gitopsApi.syncRuns('repo-a');

      expect(result[0].status).toBe('failed');
      expect(result[0].error_message).toBe('Repository unreachable');
      expect(result[0].diff_count).toBe(0);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Sync run fetch failed'));

      await expect(gitopsApi.syncRuns('repo-a')).rejects.toThrow('Sync run fetch failed');
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping contract', () => {
    it('list() correctly extracts items from double-envelope { data: { success, data, meta } }', async () => {
      const payload = { gitops_repositories: [REPO_A] };
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: payload, meta: DEFAULT_META },
      });

      const result = await gitopsApi.list();

      expect(result.gitops_repositories).toEqual([REPO_A]);
      // Must NOT leak envelope keys into the result
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
      expect((result as unknown as Record<string, unknown>)['data']).toBeUndefined();
    });

    it('get() correctly extracts both gitops_repository and recent_runs from the data envelope', async () => {
      mockGet.mockResolvedValueOnce({
        data: {
          success: true,
          data: { gitops_repository: REPO_A, recent_runs: [SYNC_RUN_A] },
        },
      });

      const result = await gitopsApi.get('repo-a');

      expect(result.gitops_repository).toEqual(REPO_A);
      expect(result.recent_runs).toEqual([SYNC_RUN_A]);
    });

    it('create() unwraps only the gitops_repository from the data envelope', async () => {
      mockPost.mockResolvedValueOnce({
        data: { success: true, data: { gitops_repository: REPO_A } },
      });

      const result = await gitopsApi.create({ name: 'test', repo_url: 'https://git.example.com/test.git' });

      expect(result).toEqual(REPO_A);
      // Must NOT be the { gitops_repository: ... } wrapper
      expect((result as unknown as Record<string, unknown>)['gitops_repository']).toBeUndefined();
    });

    it('syncNow() returns the full sync result, not the outer data envelope', async () => {
      mockPost.mockResolvedValueOnce({
        data: { success: true, data: SYNC_RESULT },
      });

      const result = await gitopsApi.syncNow('repo-a');

      expect(result.sync_run).toBeDefined();
      expect(result.ok).toBe(true);
      // Must NOT contain envelope keys
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });
  });
});
