// Behavioral tests for metricsApi.
//
// Covers the single exported method `dispatch()`: exact URL construction
// (with and without the optional `window` param), envelope unwrapping,
// edge cases (window=0, window=3600), and error propagation.

import { metricsApi } from './metricsApi';
import type {
  DispatchMetricsResponse,
  MetricStats,
  MetricBucket,
} from './metricsApi';

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

const BUCKET_A: MetricBucket = { ts: 1_700_000_000, count: 12 };
const BUCKET_B: MetricBucket = { ts: 1_700_000_060, count: 7 };

const STATS_PROVISION: MetricStats = {
  count: 19,
  rate_per_sec: 0.317,
  window_seconds: 60,
  buckets: [BUCKET_A, BUCKET_B],
};

const STATS_DEPLOY: MetricStats = {
  count: 4,
  rate_per_sec: 0.067,
  window_seconds: 60,
  buckets: [{ ts: 1_700_000_000, count: 4 }],
};

const DISPATCH_RESPONSE: DispatchMetricsResponse = {
  window_seconds: 60,
  metrics: {
    provision: STATS_PROVISION,
    deploy: STATS_DEPLOY,
  },
};

const EMPTY_RESPONSE: DispatchMetricsResponse = {
  window_seconds: 60,
  metrics: {},
};

const BASE_URL = '/system/metrics/dispatch';

// =============================================================================
// Tests
// =============================================================================

describe('metricsApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // dispatch() — URL construction
  // ---------------------------------------------------------------------------

  describe('dispatch()', () => {
    describe('URL construction', () => {
      it('calls GET /system/metrics/dispatch with no query string when called with no params', async () => {
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        await metricsApi.dispatch();

        expect(mockGet).toHaveBeenCalledTimes(1);
        expect(mockGet).toHaveBeenCalledWith(BASE_URL);
      });

      it('calls GET /system/metrics/dispatch with no query string when called with empty params object', async () => {
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        await metricsApi.dispatch({});

        expect(mockGet).toHaveBeenCalledTimes(1);
        expect(mockGet).toHaveBeenCalledWith(BASE_URL);
      });

      it('appends ?window=N when window is provided', async () => {
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        await metricsApi.dispatch({ window: 300 });

        expect(mockGet).toHaveBeenCalledWith(`${BASE_URL}?window=300`);
      });

      it('appends ?window=60 for a 60-second window', async () => {
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        await metricsApi.dispatch({ window: 60 });

        expect(mockGet).toHaveBeenCalledWith(`${BASE_URL}?window=60`);
      });

      it('appends ?window=3600 for the maximum allowed window', async () => {
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        await metricsApi.dispatch({ window: 3600 });

        expect(mockGet).toHaveBeenCalledWith(`${BASE_URL}?window=3600`);
      });

      it('uses String() coercion for the window value (no floating-point artifacts)', async () => {
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        await metricsApi.dispatch({ window: 120 });

        const [url] = mockGet.mock.calls[0] as [string];
        expect(url).toBe(`${BASE_URL}?window=120`);
      });

      it('does NOT append a query string when window is 0 (falsy)', async () => {
        // window: 0 is falsy — the source uses `if (params.window)` so 0 is
        // treated the same as omitted and no query param is appended.
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        await metricsApi.dispatch({ window: 0 });

        expect(mockGet).toHaveBeenCalledWith(BASE_URL);
      });

      it('does NOT include any /api/v1 prefix (the apiClient base URL already has it)', async () => {
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        await metricsApi.dispatch();

        const [url] = mockGet.mock.calls[0] as [string];
        expect(url).not.toContain('/api/v1');
        expect(url).toMatch(/^\/system\//);
      });
    });

    // -------------------------------------------------------------------------
    // dispatch() — return value / envelope unwrapping
    // -------------------------------------------------------------------------

    describe('return value', () => {
      it('returns the unwrapped DispatchMetricsResponse with window_seconds and metrics', async () => {
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        const result = await metricsApi.dispatch();

        expect(result).toEqual(DISPATCH_RESPONSE);
        expect(result.window_seconds).toBe(60);
        expect(result.metrics).toEqual(DISPATCH_RESPONSE.metrics);
      });

      it('returns metrics keyed by action name with correct MetricStats shape', async () => {
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        const result = await metricsApi.dispatch();

        expect(result.metrics['provision']).toEqual(STATS_PROVISION);
        expect(result.metrics['provision'].count).toBe(19);
        expect(result.metrics['provision'].rate_per_sec).toBe(0.317);
        expect(result.metrics['provision'].window_seconds).toBe(60);
        expect(result.metrics['provision'].buckets).toHaveLength(2);
      });

      it('returns buckets with ts and count fields', async () => {
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        const result = await metricsApi.dispatch();

        const buckets = result.metrics['provision'].buckets;
        expect(buckets[0]).toEqual(BUCKET_A);
        expect(buckets[1]).toEqual(BUCKET_B);
        expect(buckets[0].ts).toBe(1_700_000_000);
        expect(buckets[0].count).toBe(12);
      });

      it('returns multiple metric keys when the backend provides several', async () => {
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        const result = await metricsApi.dispatch();

        const keys = Object.keys(result.metrics);
        expect(keys).toContain('provision');
        expect(keys).toContain('deploy');
        expect(keys).toHaveLength(2);
      });

      it('returns an empty metrics record when the backend reports no dispatch metrics', async () => {
        mockGet.mockResolvedValueOnce(envelope(EMPTY_RESPONSE));

        const result = await metricsApi.dispatch();

        expect(result.metrics).toEqual({});
        expect(Object.keys(result.metrics)).toHaveLength(0);
      });

      it('does NOT include envelope wrapper keys in the returned value', async () => {
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        const result = await metricsApi.dispatch() as unknown as Record<string, unknown>;

        expect(result['success']).toBeUndefined();
        expect(result['data']).toBeUndefined();
      });

      it('returns the correct window_seconds from the response (not from the request param)', async () => {
        const response3600: DispatchMetricsResponse = {
          window_seconds: 3600,
          metrics: { provision: { ...STATS_PROVISION, window_seconds: 3600 } },
        };
        mockGet.mockResolvedValueOnce(envelope(response3600));

        const result = await metricsApi.dispatch({ window: 3600 });

        expect(result.window_seconds).toBe(3600);
        expect(result.metrics['provision'].window_seconds).toBe(3600);
      });
    });

    // -------------------------------------------------------------------------
    // dispatch() — envelope unwrapping contract
    // -------------------------------------------------------------------------

    describe('envelope unwrapping', () => {
      it('correctly extracts data from the double-envelope { data: { success, data: payload } } shape', async () => {
        // apiClient returns AxiosResponse<ApiEnvelope<T>> — body is
        // { success: true, data: <payload> }. extractData must reach the
        // inner data, not return the envelope wrapper itself.
        mockGet.mockResolvedValueOnce({
          data: { success: true, data: DISPATCH_RESPONSE },
        });

        const result = await metricsApi.dispatch();

        expect(result.window_seconds).toBe(60);
        expect(result.metrics['provision']).toBeDefined();
        // Must NOT expose envelope keys
        const raw = result as unknown as Record<string, unknown>;
        expect(raw['success']).toBeUndefined();
      });

      it('does not accidentally return the envelope wrapper as the payload', async () => {
        // If extractData were broken, dispatch() would return
        // { success: true, data: DISPATCH_RESPONSE } instead of DISPATCH_RESPONSE.
        mockGet.mockResolvedValueOnce(envelope(DISPATCH_RESPONSE));

        const result = await metricsApi.dispatch();

        // result.window_seconds must be a number, not undefined
        expect(typeof result.window_seconds).toBe('number');
        expect(typeof result.metrics).toBe('object');
      });
    });

    // -------------------------------------------------------------------------
    // dispatch() — error propagation
    // -------------------------------------------------------------------------

    describe('error propagation', () => {
      it('propagates network errors', async () => {
        mockGet.mockRejectedValueOnce(new Error('Network error'));

        await expect(metricsApi.dispatch()).rejects.toThrow('Network error');
      });

      it('propagates network errors when window param is supplied', async () => {
        mockGet.mockRejectedValueOnce(new Error('Timeout'));

        await expect(metricsApi.dispatch({ window: 300 })).rejects.toThrow('Timeout');
      });

      it('propagates non-Error rejections', async () => {
        mockGet.mockRejectedValueOnce({ status: 503, message: 'Service Unavailable' });

        await expect(metricsApi.dispatch()).rejects.toEqual({
          status: 503,
          message: 'Service Unavailable',
        });
      });

      it('propagates 404 errors from the API', async () => {
        mockGet.mockRejectedValueOnce(new Error('Not found'));

        await expect(metricsApi.dispatch()).rejects.toThrow('Not found');
      });
    });
  });
});
