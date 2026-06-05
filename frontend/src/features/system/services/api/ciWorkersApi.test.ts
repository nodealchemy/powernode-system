// Behavioral tests for ciWorkersApi — pure request-shaping / response-
// extraction tests covering every exported function including edge cases.
//
// API double-envelope: apiClient.{get,post,delete} resolve to an AxiosResponse
// whose body is { success: true, data: <payload> }. A mocked resolve is
// therefore { data: { success: true, data: <payload> } } — the outer `data`
// key is the AxiosResponse body, and the inner `data` key is the API envelope.

import { ciWorkersApi } from './ciWorkersApi';
import type {
  SystemCiWorker,
  SystemCiWorkerCreatedResponse,
} from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const CI_WORKER_A: SystemCiWorker = {
  id: 'worker-aaa',
  account_id: 'account-1',
  name: 'ci-runner-main',
  description: 'Primary CI runner',
  status: 'active',
  last_seen_at: '2026-06-01T10:00:00Z',
  roles: ['ci_worker'],
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-06-01T10:00:00Z',
};

const CI_WORKER_B: SystemCiWorker = {
  id: 'worker-bbb',
  account_id: 'account-1',
  name: 'ci-runner-secondary',
  status: 'inactive',
  roles: ['ci_worker'],
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
};

const CREATED_RESPONSE: SystemCiWorkerCreatedResponse = {
  ci_worker: CI_WORKER_A,
  token_plaintext: 'pnt_plaintext_token_abc123',
  note: 'Store this token securely — it will not be shown again.',
};

const ROTATED_RESPONSE: SystemCiWorkerCreatedResponse = {
  ci_worker: { ...CI_WORKER_A, updated_at: '2026-06-05T12:00:00Z' },
  token_plaintext: 'pnt_rotated_token_xyz789',
  note: 'Old token revoked. Update POWERNODE_CI_WORKER_TOKEN in your CI secrets.',
};

/**
 * Build the double-envelope AxiosResponse mock value.
 * Outer `data` = AxiosResponse body; inner `data` = API envelope payload.
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Tests
// =============================================================================

describe('ciWorkersApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list()
  // ---------------------------------------------------------------------------

  describe('list()', () => {
    it('GET /system/ci_workers and returns the ci_workers array', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ ci_workers: [CI_WORKER_A, CI_WORKER_B] }),
      );

      const result = await ciWorkersApi.list();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/ci_workers');
      expect(result).toHaveLength(2);
      expect(result[0]).toEqual(CI_WORKER_A);
      expect(result[1]).toEqual(CI_WORKER_B);
    });

    it('returns an empty array when ci_workers key is absent from the payload', async () => {
      mockGet.mockResolvedValueOnce(envelope({}));

      const result = await ciWorkersApi.list();

      expect(result).toEqual([]);
    });

    it('returns an empty array when ci_workers is explicitly null/undefined', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ ci_workers: null }),
      );

      const result = await ciWorkersApi.list();

      expect(result).toEqual([]);
    });

    it('propagates API errors to the caller', async () => {
      const apiError = new Error('Network error');
      mockGet.mockRejectedValueOnce(apiError);

      await expect(ciWorkersApi.list()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // get(id)
  // ---------------------------------------------------------------------------

  describe('get(id)', () => {
    it('GET /system/ci_workers/:id and returns the ci_worker', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ ci_worker: CI_WORKER_A }),
      );

      const result = await ciWorkersApi.get('worker-aaa');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/ci_workers/worker-aaa');
      expect(result).toEqual(CI_WORKER_A);
    });

    it('interpolates the id correctly into the URL', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ ci_worker: CI_WORKER_B }),
      );

      await ciWorkersApi.get('worker-bbb');

      expect(mockGet).toHaveBeenCalledWith('/system/ci_workers/worker-bbb');
    });

    it('propagates API errors to the caller', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(ciWorkersApi.get('nonexistent')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // create(name, description?)
  // ---------------------------------------------------------------------------

  describe('create(name, description?)', () => {
    it('POST /system/ci_workers with name+description and returns the created response', async () => {
      mockPost.mockResolvedValueOnce(envelope(CREATED_RESPONSE));

      const result = await ciWorkersApi.create('ci-runner-main', 'Primary CI runner');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith('/system/ci_workers', {
        name: 'ci-runner-main',
        description: 'Primary CI runner',
      });
      expect(result).toEqual(CREATED_RESPONSE);
    });

    it('POST /system/ci_workers with only name when description is omitted', async () => {
      mockPost.mockResolvedValueOnce(envelope(CREATED_RESPONSE));

      await ciWorkersApi.create('ci-runner-main');

      expect(mockPost).toHaveBeenCalledWith('/system/ci_workers', {
        name: 'ci-runner-main',
        description: undefined,
      });
    });

    it('returns the token_plaintext in the response (only shown once)', async () => {
      mockPost.mockResolvedValueOnce(envelope(CREATED_RESPONSE));

      const result = await ciWorkersApi.create('ci-runner-main');

      expect(result.token_plaintext).toBe('pnt_plaintext_token_abc123');
      expect(result.ci_worker).toEqual(CI_WORKER_A);
      expect(result.note).toBeTruthy();
    });

    it('propagates API errors to the caller', async () => {
      mockPost.mockRejectedValueOnce(new Error('Validation failed'));

      await expect(ciWorkersApi.create('bad-name')).rejects.toThrow('Validation failed');
    });
  });

  // ---------------------------------------------------------------------------
  // destroy(id)
  // ---------------------------------------------------------------------------

  describe('destroy(id)', () => {
    it('DELETE /system/ci_workers/:id', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await ciWorkersApi.destroy('worker-aaa');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith('/system/ci_workers/worker-aaa');
    });

    it('interpolates the id correctly into the DELETE URL', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await ciWorkersApi.destroy('worker-bbb');

      expect(mockDelete).toHaveBeenCalledWith('/system/ci_workers/worker-bbb');
    });

    it('resolves to undefined (void) on success', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      const result = await ciWorkersApi.destroy('worker-aaa');

      expect(result).toBeUndefined();
    });

    it('propagates API errors to the caller', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Forbidden'));

      await expect(ciWorkersApi.destroy('worker-aaa')).rejects.toThrow('Forbidden');
    });
  });

  // ---------------------------------------------------------------------------
  // rotateToken(id)
  // ---------------------------------------------------------------------------

  describe('rotateToken(id)', () => {
    it('POST /system/ci_workers/:id/rotate_token with empty body', async () => {
      mockPost.mockResolvedValueOnce(envelope(ROTATED_RESPONSE));

      const result = await ciWorkersApi.rotateToken('worker-aaa');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        '/system/ci_workers/worker-aaa/rotate_token',
        {},
      );
      expect(result).toEqual(ROTATED_RESPONSE);
    });

    it('returns the new token_plaintext in the rotate response', async () => {
      mockPost.mockResolvedValueOnce(envelope(ROTATED_RESPONSE));

      const result = await ciWorkersApi.rotateToken('worker-aaa');

      expect(result.token_plaintext).toBe('pnt_rotated_token_xyz789');
      expect(result.ci_worker.id).toBe('worker-aaa');
    });

    it('interpolates the id correctly into the rotate URL', async () => {
      mockPost.mockResolvedValueOnce(envelope(ROTATED_RESPONSE));

      await ciWorkersApi.rotateToken('worker-bbb');

      expect(mockPost).toHaveBeenCalledWith(
        '/system/ci_workers/worker-bbb/rotate_token',
        {},
      );
    });

    it('propagates API errors to the caller', async () => {
      mockPost.mockRejectedValueOnce(new Error('Worker not found'));

      await expect(ciWorkersApi.rotateToken('nonexistent')).rejects.toThrow('Worker not found');
    });
  });
});
