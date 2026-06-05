// Behavioral tests for fleetApi.
//
// Covers every exported method: exact URL, payload, envelope unwrapping,
// optional-argument defaults, and error propagation.

import { fleetApi } from './fleetApi';
import type { FleetEvent, AttributionCandidate, AttributionResult } from './fleetApi';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    post: (...args: unknown[]) => mockPost(...args),
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

const EVENT_A: FleetEvent = {
  id: 'evt-1',
  account_id: 'acct-1',
  kind: 'module_drift_detected',
  severity: 'high',
  payload: { module: 'nginx', expected: '1.0', actual: '0.9' },
  correlation_id: 'corr-abc',
  source: 'fleet_sensor',
  emitted_at: '2026-05-01T10:00:00Z',
  node_id: 'node-1',
  node_instance_id: 'inst-1',
  node_module_id: 'mod-1',
  node_module_version_id: 'ver-1',
  certificate_id: null,
  cve_id: null,
};

const EVENT_B: FleetEvent = {
  id: 'evt-2',
  account_id: 'acct-1',
  kind: 'cert_expiring',
  severity: 'critical',
  payload: { cert: 'ca.crt', days_left: 3 },
  correlation_id: null,
  source: null,
  emitted_at: '2026-05-02T08:30:00Z',
  certificate_id: 'cert-1',
  cve_id: null,
};

const SIGNALS_RESPONSE = {
  events: [EVENT_A, EVENT_B],
  count: 2,
  channel: 'SystemFleetChannel',
};

const CANDIDATE_A: AttributionCandidate = {
  kind: 'promotion',
  module_id: 'mod-99',
  module_name: 'nginx-module',
  score: 0.92,
  reasons: ['promoted 2h before failure', 'CPU spike correlated'],
  changed_at: '2026-05-01T07:00:00Z',
  module_version_id: 'ver-99',
};

const CANDIDATE_B: AttributionCandidate = {
  kind: 'assignment_change',
  module_id: 'mod-55',
  module_name: null,
  score: 0.45,
  reasons: ['assigned 6h before failure'],
};

const ATTRIBUTION_RESULT: AttributionResult = {
  candidates: [CANDIDATE_A, CANDIDATE_B],
  top_candidate: CANDIDATE_A,
  confidence: 0.92,
  reasoning: 'nginx-module promotion tightly correlates with the observed crash window.',
};

const BASE_FLEET = '/system/fleet';

// =============================================================================
// Tests
// =============================================================================

describe('fleetApi', () => {
  beforeEach(() => {
    mockPost.mockReset();
  });

  // ---------------------------------------------------------------------------
  // recentSignals
  // ---------------------------------------------------------------------------

  describe('recentSignals()', () => {
    it('calls POST /system/fleet/signals with an empty body when no params provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(SIGNALS_RESPONSE));

      await fleetApi.recentSignals();

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE_FLEET}/signals`, {});
    });

    it('passes limit as part of the POST body when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(SIGNALS_RESPONSE));

      await fleetApi.recentSignals({ limit: 50 });

      expect(mockPost).toHaveBeenCalledWith(`${BASE_FLEET}/signals`, { limit: 50 });
    });

    it('passes kind as part of the POST body when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(SIGNALS_RESPONSE));

      await fleetApi.recentSignals({ kind: 'module_drift_detected' });

      expect(mockPost).toHaveBeenCalledWith(`${BASE_FLEET}/signals`, {
        kind: 'module_drift_detected',
      });
    });

    it('passes correlation_id as part of the POST body when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(SIGNALS_RESPONSE));

      await fleetApi.recentSignals({ correlation_id: 'corr-abc' });

      expect(mockPost).toHaveBeenCalledWith(`${BASE_FLEET}/signals`, {
        correlation_id: 'corr-abc',
      });
    });

    it('passes all params together when all are provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(SIGNALS_RESPONSE));

      await fleetApi.recentSignals({ limit: 100, kind: 'cert_expiring', correlation_id: 'corr-xyz' });

      expect(mockPost).toHaveBeenCalledWith(`${BASE_FLEET}/signals`, {
        limit: 100,
        kind: 'cert_expiring',
        correlation_id: 'corr-xyz',
      });
    });

    it('returns the unwrapped payload with events, count, and channel', async () => {
      mockPost.mockResolvedValueOnce(envelope(SIGNALS_RESPONSE));

      const result = await fleetApi.recentSignals();

      expect(result).toEqual(SIGNALS_RESPONSE);
      expect(result.events).toHaveLength(2);
      expect(result.count).toBe(2);
      expect(result.channel).toBe('SystemFleetChannel');
    });

    it('returns event fields verbatim including optional nullable properties', async () => {
      mockPost.mockResolvedValueOnce(envelope(SIGNALS_RESPONSE));

      const result = await fleetApi.recentSignals();

      expect(result.events[0]).toEqual(EVENT_A);
      expect(result.events[1].correlation_id).toBeNull();
      expect(result.events[1].source).toBeNull();
      expect(result.events[1].certificate_id).toBe('cert-1');
    });

    it('returns an empty events array when the backend returns no events', async () => {
      const emptyResponse = { events: [], count: 0, channel: 'SystemFleetChannel' };
      mockPost.mockResolvedValueOnce(envelope(emptyResponse));

      const result = await fleetApi.recentSignals();

      expect(result.events).toEqual([]);
      expect(result.count).toBe(0);
    });

    it('does NOT include envelope wrapper keys in the returned value', async () => {
      mockPost.mockResolvedValueOnce(envelope(SIGNALS_RESPONSE));

      const result = await fleetApi.recentSignals() as unknown as Record<string, unknown>;

      expect(result['success']).toBeUndefined();
      expect(result['data']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Network error'));

      await expect(fleetApi.recentSignals()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // attributeFailure
  // ---------------------------------------------------------------------------

  describe('attributeFailure()', () => {
    it('calls POST /system/fleet/attribute_failure with instance_id and default lookback_hours=24', async () => {
      mockPost.mockResolvedValueOnce(envelope(ATTRIBUTION_RESULT));

      await fleetApi.attributeFailure('inst-42');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE_FLEET}/attribute_failure`, {
        instance_id: 'inst-42',
        lookback_hours: 24,
      });
    });

    it('uses the supplied lookbackHours in the request body when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(ATTRIBUTION_RESULT));

      await fleetApi.attributeFailure('inst-99', 48);

      expect(mockPost).toHaveBeenCalledWith(`${BASE_FLEET}/attribute_failure`, {
        instance_id: 'inst-99',
        lookback_hours: 48,
      });
    });

    it('uses lookbackHours=0 correctly when explicitly passed', async () => {
      mockPost.mockResolvedValueOnce(envelope(ATTRIBUTION_RESULT));

      await fleetApi.attributeFailure('inst-7', 0);

      expect(mockPost).toHaveBeenCalledWith(`${BASE_FLEET}/attribute_failure`, {
        instance_id: 'inst-7',
        lookback_hours: 0,
      });
    });

    it('uses the supplied instance_id verbatim in the POST body', async () => {
      mockPost.mockResolvedValueOnce(envelope(ATTRIBUTION_RESULT));

      await fleetApi.attributeFailure('inst-abc-uuid-456');

      const [, body] = mockPost.mock.calls[0] as [string, { instance_id: string; lookback_hours: number }];
      expect(body.instance_id).toBe('inst-abc-uuid-456');
    });

    it('returns the unwrapped AttributionResult with candidates and top_candidate', async () => {
      mockPost.mockResolvedValueOnce(envelope(ATTRIBUTION_RESULT));

      const result = await fleetApi.attributeFailure('inst-42');

      expect(result).toEqual(ATTRIBUTION_RESULT);
      expect(result.candidates).toHaveLength(2);
      expect(result.top_candidate).toEqual(CANDIDATE_A);
      expect(result.confidence).toBe(0.92);
      expect(result.reasoning).toBe(
        'nginx-module promotion tightly correlates with the observed crash window.',
      );
    });

    it('returns a result with null top_candidate when confidence is low', async () => {
      const lowConfidenceResult: AttributionResult = {
        candidates: [],
        top_candidate: null,
        confidence: 0,
        reasoning: 'No correlated changes found in the lookback window.',
      };
      mockPost.mockResolvedValueOnce(envelope(lowConfidenceResult));

      const result = await fleetApi.attributeFailure('inst-unknown');

      expect(result.top_candidate).toBeNull();
      expect(result.candidates).toEqual([]);
      expect(result.confidence).toBe(0);
    });

    it('returns candidate with null module_name correctly', async () => {
      const resultWithNullName: AttributionResult = {
        candidates: [CANDIDATE_B],
        top_candidate: CANDIDATE_B,
        confidence: 0.45,
        reasoning: 'Assignment change detected.',
      };
      mockPost.mockResolvedValueOnce(envelope(resultWithNullName));

      const result = await fleetApi.attributeFailure('inst-42');

      expect(result.top_candidate?.module_name).toBeNull();
      expect(result.candidates[0].kind).toBe('assignment_change');
    });

    it('does NOT include envelope wrapper keys in the returned value', async () => {
      mockPost.mockResolvedValueOnce(envelope(ATTRIBUTION_RESULT));

      const result = await fleetApi.attributeFailure('inst-42') as unknown as Record<string, unknown>;

      expect(result['success']).toBeUndefined();
      expect(result['data']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Attribution service unavailable'));

      await expect(fleetApi.attributeFailure('inst-42')).rejects.toThrow(
        'Attribution service unavailable',
      );
    });

    it('propagates non-Error rejections', async () => {
      mockPost.mockRejectedValueOnce({ status: 503 });

      await expect(fleetApi.attributeFailure('inst-1')).rejects.toEqual({ status: 503 });
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping', () => {
    it('extracts data from the double-envelope { data: { success, data: payload } } shape', async () => {
      // apiClient returns AxiosResponse whose .data is the backend body
      // { success: true, data: <payload> }. extractData must reach the inner data.
      mockPost.mockResolvedValueOnce({
        data: { success: true, data: SIGNALS_RESPONSE },
      });

      const result = await fleetApi.recentSignals();

      expect(result.events).toHaveLength(2);
      // Must NOT contain envelope-level keys
      const raw = result as unknown as Record<string, unknown>;
      expect(raw['success']).toBeUndefined();
    });

    it('does not accidentally return the envelope wrapper as the payload', async () => {
      // If extractData were broken, calling recentSignals() would return
      // { success: true, data: SIGNALS_RESPONSE } instead of SIGNALS_RESPONSE.
      mockPost.mockResolvedValueOnce(envelope(SIGNALS_RESPONSE));

      const result = await fleetApi.recentSignals();

      // The result must have FleetEvent[] under .events, not a boolean .success
      expect(Array.isArray(result.events)).toBe(true);
    });
  });
});
