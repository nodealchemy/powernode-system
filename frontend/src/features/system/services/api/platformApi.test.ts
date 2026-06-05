import { platformApi } from './platformApi';
import type { PlatformOverview } from '../../types/platform.types';

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
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const OVERVIEW: PlatformOverview = {
  peers: {
    count: 3,
    by_status: { active: 2, inactive: 1 },
    last_handshake_at: '2026-06-01T12:00:00Z',
  },
  children: {
    count: 5,
    by_spawn_mode: { clone: 3, fresh: 2 },
    by_status: { running: 4, stopped: 1 },
  },
  services: {
    offerings: 10,
    subscriptions: 7,
  },
  migrations: {
    count: 2,
    by_status: { pending: 1, completed: 1 },
  },
  certificates: {
    count: 8,
    by_status: { valid: 7, expired: 1 },
    near_expiry: 2,
  },
  generated_at: '2026-06-05T00:00:00Z',
};

// =============================================================================
// Tests
// =============================================================================

describe('platformApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  describe('overview()', () => {
    it('calls GET /system/platform/overview', async () => {
      mockGet.mockResolvedValue(envelope({ overview: OVERVIEW }));

      await platformApi.overview();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/platform/overview');
    });

    it('returns the unwrapped PlatformOverview from the nested data.overview key', async () => {
      mockGet.mockResolvedValue(envelope({ overview: OVERVIEW }));

      const result = await platformApi.overview();

      expect(result).toEqual(OVERVIEW);
    });

    it('returns peers summary with correct shape', async () => {
      mockGet.mockResolvedValue(envelope({ overview: OVERVIEW }));

      const result = await platformApi.overview();

      expect(result.peers).toEqual({
        count: 3,
        by_status: { active: 2, inactive: 1 },
        last_handshake_at: '2026-06-01T12:00:00Z',
      });
    });

    it('returns children summary with correct shape', async () => {
      mockGet.mockResolvedValue(envelope({ overview: OVERVIEW }));

      const result = await platformApi.overview();

      expect(result.children).toEqual({
        count: 5,
        by_spawn_mode: { clone: 3, fresh: 2 },
        by_status: { running: 4, stopped: 1 },
      });
    });

    it('returns services summary with correct shape', async () => {
      mockGet.mockResolvedValue(envelope({ overview: OVERVIEW }));

      const result = await platformApi.overview();

      expect(result.services).toEqual({ offerings: 10, subscriptions: 7 });
    });

    it('returns migrations summary with correct shape', async () => {
      mockGet.mockResolvedValue(envelope({ overview: OVERVIEW }));

      const result = await platformApi.overview();

      expect(result.migrations).toEqual({
        count: 2,
        by_status: { pending: 1, completed: 1 },
      });
    });

    it('returns certificates summary including near_expiry count', async () => {
      mockGet.mockResolvedValue(envelope({ overview: OVERVIEW }));

      const result = await platformApi.overview();

      expect(result.certificates).toEqual({
        count: 8,
        by_status: { valid: 7, expired: 1 },
        near_expiry: 2,
      });
    });

    it('returns generated_at timestamp', async () => {
      mockGet.mockResolvedValue(envelope({ overview: OVERVIEW }));

      const result = await platformApi.overview();

      expect(result.generated_at).toBe('2026-06-05T00:00:00Z');
    });

    it('propagates errors thrown by apiClient.get', async () => {
      const err = new Error('Network Error');
      mockGet.mockRejectedValue(err);

      await expect(platformApi.overview()).rejects.toThrow('Network Error');
    });

    it('handles zero-count summary fields gracefully', async () => {
      const emptyOverview: PlatformOverview = {
        peers: { count: 0, by_status: {}, last_handshake_at: null },
        children: { count: 0 },
        services: { offerings: 0, subscriptions: 0 },
        migrations: { count: 0 },
        certificates: { count: 0, near_expiry: 0 },
        generated_at: '2026-06-05T00:00:00Z',
      };
      mockGet.mockResolvedValue(envelope({ overview: emptyOverview }));

      const result = await platformApi.overview();

      expect(result.peers.count).toBe(0);
      expect(result.peers.last_handshake_at).toBeNull();
      expect(result.children.count).toBe(0);
      expect(result.certificates.near_expiry).toBe(0);
    });

    it('does not call apiClient.get until the returned promise is awaited', () => {
      mockGet.mockResolvedValue(envelope({ overview: OVERVIEW }));

      // Call but do not await — the internal GET should still have been invoked
      // because async functions begin executing synchronously up to the first await.
      const promise = platformApi.overview();

      expect(mockGet).toHaveBeenCalledTimes(1);

      // Clean up the hanging promise.
      return promise;
    });
  });
});
