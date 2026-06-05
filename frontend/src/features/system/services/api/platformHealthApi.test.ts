import { platformHealthApi } from './platformHealthApi';
import type { PlatformHealth } from '../../types/platform-health.types';

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

/**
 * Build a double-envelope AxiosResponse for a non-paginated endpoint.
 * The body shape is: { success: true, data: <payload> }
 * and `response.data` is the body, so the full mock return is
 * { data: { success: true, data: <payload> } }.
 */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

// =============================================================================
// Fixtures
// =============================================================================

const HEALTH_OK: PlatformHealth = {
  rails: {
    status: 'ok',
    uptime_seconds: 86400,
    uptime_human: '1 day',
    db_connected: true,
    rails_env: 'production',
    ruby_version: '3.3.0',
  },
  worker: {
    status: 'ok',
    stats: {
      processed: 10000,
      failed: 3,
      enqueued: 2,
      scheduled: 5,
      retry_size: 1,
      dead_size: 0,
      processes: 4,
      default_queue_latency: 0.12,
    },
    last_seen_at: '2026-06-05T10:00:00Z',
  },
  redis: {
    status: 'ok',
    cache_store: 'redis_cache_store',
    probe_at: '2026-06-05T10:00:00Z',
  },
  postgres: {
    status: 'ok',
    database: 'powernode_production',
    size_bytes: 524288000,
    size_human: '500 MB',
    active_connections: 12,
  },
  acme: {
    status: 'ok',
    count: 4,
    by_status: { valid: 3, pending: 1 },
    expiring_within_30d: 1,
    expiring_within_7d: 0,
    failed_count: 0,
    nearest_expiry_at: '2026-07-05T00:00:00Z',
  },
  sdwan: {
    status: 'ok',
    networks_count: 3,
    virtual_ips: { count: 5, assigned: 4 },
    bgp: { total: 2, established: 2 },
  },
  federation: {
    status: 'ok',
    total: 2,
    active: 2,
    degraded: 0,
    suspended: 0,
    heartbeat_stale: 0,
    last_handshake_at: '2026-06-05T09:59:00Z',
  },
  generated_at: '2026-06-05T10:00:01Z',
};

const HEALTH_DEGRADED: PlatformHealth = {
  rails: { status: 'ok' },
  worker: {
    status: 'degraded',
    stats: {
      processed: 5000,
      failed: 120,
      enqueued: 50,
      retry_size: 20,
      dead_size: 5,
    },
    last_seen_at: '2026-06-05T09:00:00Z',
    error: 'high failure rate',
  },
  redis: {
    status: 'degraded',
    error: 'connection slow',
  },
  postgres: {
    status: 'ok',
    database: 'powernode_production',
    active_connections: 95,
  },
  acme: {
    status: 'degraded',
    count: 2,
    expiring_within_7d: 1,
    failed_count: 1,
    error: '1 cert expired',
  },
  sdwan: {
    status: 'degraded',
    networks_count: 2,
    virtual_ips: { count: 3, assigned: 1 },
    bgp: { total: 2, established: 1 },
    error: 'BGP session down',
  },
  federation: {
    status: 'degraded',
    total: 3,
    active: 1,
    degraded: 2,
    suspended: 0,
    heartbeat_stale: 1,
    last_handshake_at: null,
    error: '2 peers unreachable',
  },
  generated_at: '2026-06-05T10:00:02Z',
};

const HEALTH_MINIMAL: PlatformHealth = {
  rails: { status: 'unknown' },
  worker: { status: 'down', stats: {}, error: 'unreachable' },
  redis: { status: 'down', error: 'ECONNREFUSED' },
  postgres: { status: 'down', error: 'pg connection failed' },
  acme: { status: 'unknown' },
  sdwan: { status: 'unknown' },
  federation: { status: 'unknown' },
  generated_at: '2026-06-05T10:00:03Z',
};

// =============================================================================
// Tests
// =============================================================================

describe('platformHealthApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // show — URL correctness
  // ---------------------------------------------------------------------------

  describe('show — URL', () => {
    it('calls GET /system/platform/health with no extra params', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_OK }));

      await platformHealthApi.show();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/platform/health');
    });

    it('does not add any query parameters to the request', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_OK }));

      await platformHealthApi.show();

      // Verify only the URL argument was passed — no second argument (params)
      const [url, secondArg] = mockGet.mock.calls[0] as [string, unknown];
      expect(url).toBe('/system/platform/health');
      expect(secondArg).toBeUndefined();
    });
  });

  // ---------------------------------------------------------------------------
  // show — happy-path payload extraction
  // ---------------------------------------------------------------------------

  describe('show — full health snapshot', () => {
    it('returns the health object extracted from inside the data envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_OK }));

      const result = await platformHealthApi.show();

      expect(result).toEqual(HEALTH_OK);
    });

    it('returns the exact generated_at timestamp from the payload', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_OK }));

      const result = await platformHealthApi.show();

      expect(result.generated_at).toBe('2026-06-05T10:00:01Z');
    });

    it('preserves deeply-nested rails subsystem fields', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_OK }));

      const result = await platformHealthApi.show();

      expect(result.rails.status).toBe('ok');
      expect(result.rails.uptime_seconds).toBe(86400);
      expect(result.rails.db_connected).toBe(true);
      expect(result.rails.ruby_version).toBe('3.3.0');
    });

    it('preserves worker stats sub-object', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_OK }));

      const result = await platformHealthApi.show();

      expect(result.worker.status).toBe('ok');
      expect(result.worker.stats.processed).toBe(10000);
      expect(result.worker.stats.failed).toBe(3);
      expect(result.worker.stats.processes).toBe(4);
      expect(result.worker.last_seen_at).toBe('2026-06-05T10:00:00Z');
    });

    it('preserves redis subsystem fields', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_OK }));

      const result = await platformHealthApi.show();

      expect(result.redis.status).toBe('ok');
      expect(result.redis.cache_store).toBe('redis_cache_store');
      expect(result.redis.probe_at).toBe('2026-06-05T10:00:00Z');
    });

    it('preserves postgres subsystem fields including size_bytes and active_connections', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_OK }));

      const result = await platformHealthApi.show();

      expect(result.postgres.status).toBe('ok');
      expect(result.postgres.database).toBe('powernode_production');
      expect(result.postgres.size_bytes).toBe(524288000);
      expect(result.postgres.size_human).toBe('500 MB');
      expect(result.postgres.active_connections).toBe(12);
    });

    it('preserves ACME subsystem fields including by_status map and expiry counts', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_OK }));

      const result = await platformHealthApi.show();

      expect(result.acme.status).toBe('ok');
      expect(result.acme.count).toBe(4);
      expect(result.acme.by_status).toEqual({ valid: 3, pending: 1 });
      expect(result.acme.expiring_within_30d).toBe(1);
      expect(result.acme.expiring_within_7d).toBe(0);
      expect(result.acme.failed_count).toBe(0);
      expect(result.acme.nearest_expiry_at).toBe('2026-07-05T00:00:00Z');
    });

    it('preserves SDWAN subsystem fields including nested virtual_ips and bgp objects', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_OK }));

      const result = await platformHealthApi.show();

      expect(result.sdwan.status).toBe('ok');
      expect(result.sdwan.networks_count).toBe(3);
      expect(result.sdwan.virtual_ips).toEqual({ count: 5, assigned: 4 });
      expect(result.sdwan.bgp).toEqual({ total: 2, established: 2 });
    });

    it('preserves federation subsystem fields including peer counts', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_OK }));

      const result = await platformHealthApi.show();

      expect(result.federation.status).toBe('ok');
      expect(result.federation.total).toBe(2);
      expect(result.federation.active).toBe(2);
      expect(result.federation.degraded).toBe(0);
      expect(result.federation.heartbeat_stale).toBe(0);
      expect(result.federation.last_handshake_at).toBe('2026-06-05T09:59:00Z');
    });
  });

  // ---------------------------------------------------------------------------
  // show — degraded/error states
  // ---------------------------------------------------------------------------

  describe('show — degraded health snapshot', () => {
    it('returns degraded statuses for all impaired subsystems', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_DEGRADED }));

      const result = await platformHealthApi.show();

      expect(result.worker.status).toBe('degraded');
      expect(result.redis.status).toBe('degraded');
      expect(result.acme.status).toBe('degraded');
      expect(result.sdwan.status).toBe('degraded');
      expect(result.federation.status).toBe('degraded');
    });

    it('exposes error messages on subsystems that carry them', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_DEGRADED }));

      const result = await platformHealthApi.show();

      expect(result.worker.error).toBe('high failure rate');
      expect(result.redis.error).toBe('connection slow');
      expect(result.acme.error).toBe('1 cert expired');
      expect(result.sdwan.error).toBe('BGP session down');
      expect(result.federation.error).toBe('2 peers unreachable');
    });

    it('surfaces null last_handshake_at when federation peers are unreachable', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_DEGRADED }));

      const result = await platformHealthApi.show();

      expect(result.federation.last_handshake_at).toBeNull();
    });

    it('returns elevated heartbeat_stale count in degraded federation', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_DEGRADED }));

      const result = await platformHealthApi.show();

      expect(result.federation.heartbeat_stale).toBe(1);
      expect(result.federation.degraded).toBe(2);
    });
  });

  // ---------------------------------------------------------------------------
  // show — minimal / down snapshot
  // ---------------------------------------------------------------------------

  describe('show — minimal / down snapshot', () => {
    it('handles subsystems with only status and error (all optional fields absent)', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_MINIMAL }));

      const result = await platformHealthApi.show();

      expect(result.rails.status).toBe('unknown');
      expect(result.worker.status).toBe('down');
      expect(result.worker.error).toBe('unreachable');
      expect(result.redis.status).toBe('down');
      expect(result.redis.error).toBe('ECONNREFUSED');
      expect(result.postgres.status).toBe('down');
      expect(result.postgres.error).toBe('pg connection failed');
      expect(result.acme.status).toBe('unknown');
      expect(result.sdwan.status).toBe('unknown');
      expect(result.federation.status).toBe('unknown');
    });

    it('returns an empty stats object on the worker when stats is {}', async () => {
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_MINIMAL }));

      const result = await platformHealthApi.show();

      expect(result.worker.stats).toEqual({});
    });
  });

  // ---------------------------------------------------------------------------
  // show — envelope extraction correctness
  // ---------------------------------------------------------------------------

  describe('show — envelope extraction', () => {
    it('extracts health from inside data.health, not the raw response root', async () => {
      // Double-envelope: response.data = { success: true, data: { health: ... } }
      // The function must reach through: response → .data → .data → .health
      mockGet.mockResolvedValueOnce(envelope({ health: HEALTH_OK }));

      const result = await platformHealthApi.show();

      // Confirm we got the actual PlatformHealth object, not the wrapper
      expect(result).not.toHaveProperty('success');
      expect(result).not.toHaveProperty('data');
      expect(result).toHaveProperty('rails');
      expect(result).toHaveProperty('worker');
      expect(result).toHaveProperty('redis');
      expect(result).toHaveProperty('postgres');
      expect(result).toHaveProperty('acme');
      expect(result).toHaveProperty('sdwan');
      expect(result).toHaveProperty('federation');
      expect(result).toHaveProperty('generated_at');
    });

    it('resolves to a fresh PlatformHealth object on each call', async () => {
      mockGet
        .mockResolvedValueOnce(envelope({ health: HEALTH_OK }))
        .mockResolvedValueOnce(envelope({ health: HEALTH_DEGRADED }));

      const first = await platformHealthApi.show();
      const second = await platformHealthApi.show();

      expect(first.rails.status).toBe('ok');
      expect(second.worker.status).toBe('degraded');
      expect(mockGet).toHaveBeenCalledTimes(2);
    });
  });

  // ---------------------------------------------------------------------------
  // show — error propagation
  // ---------------------------------------------------------------------------

  describe('show — error propagation', () => {
    it('rejects with a network error when apiClient.get throws', async () => {
      const networkError = new Error('Network Error');
      mockGet.mockRejectedValueOnce(networkError);

      await expect(platformHealthApi.show()).rejects.toThrow('Network Error');
    });

    it('rejects with a 401 Unauthorized error when the response is 401', async () => {
      const authError = Object.assign(new Error('Unauthorized'), {
        response: { status: 401, data: { success: false, error: 'Unauthorized' } },
      });
      mockGet.mockRejectedValueOnce(authError);

      await expect(platformHealthApi.show()).rejects.toMatchObject({
        message: 'Unauthorized',
      });
    });

    it('rejects with a 503 Service Unavailable when the backend is down', async () => {
      const serverError = Object.assign(new Error('Service Unavailable'), {
        response: { status: 503, data: { success: false, error: 'Service Unavailable' } },
      });
      mockGet.mockRejectedValueOnce(serverError);

      await expect(platformHealthApi.show()).rejects.toMatchObject({
        message: 'Service Unavailable',
      });
    });

    it('does not catch or swallow API errors — they propagate to the caller', async () => {
      const err = new Error('timeout');
      mockGet.mockRejectedValueOnce(err);

      let thrown: Error | null = null;
      try {
        await platformHealthApi.show();
      } catch (e) {
        thrown = e as Error;
      }

      expect(thrown).toBe(err);
    });
  });
});
