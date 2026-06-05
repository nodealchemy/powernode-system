import { bootReplayApi } from './bootReplayApi';
import type { BootReplayResponse } from './bootReplayApi';

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

/** Wrap a payload in the double-envelope the backend produces. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

// =============================================================================
// Fixtures
// =============================================================================

const BOOT_REPLAY_RESPONSE: BootReplayResponse = {
  instance_id: 'inst-abc123',
  events: [
    {
      id: 'evt-001',
      kind: 'boot.start',
      severity: 'info',
      payload: { message: 'Boot sequence initiated' },
      emitted_at: '2026-06-05T10:00:00Z',
      correlation_id: 'corr-xyz',
      source: 'initramfs',
    },
    {
      id: 'evt-002',
      kind: 'boot.kernel',
      severity: 'info',
      payload: { kernel: '6.1.0' },
      emitted_at: '2026-06-05T10:00:01Z',
      correlation_id: null,
      source: null,
    },
    {
      id: 'evt-003',
      kind: 'boot.error',
      severity: 'error',
      payload: { code: 'DISK_TIMEOUT' },
      emitted_at: '2026-06-05T10:00:02Z',
    },
  ],
  phase_summary: {
    'boot.start': {
      first_at: '2026-06-05T10:00:00Z',
      last_at: '2026-06-05T10:00:00Z',
      count: 1,
    },
    'boot.kernel': {
      first_at: '2026-06-05T10:00:01Z',
      last_at: '2026-06-05T10:00:01Z',
      count: 1,
    },
    'boot.error': {
      first_at: '2026-06-05T10:00:02Z',
      last_at: '2026-06-05T10:00:02Z',
      count: 1,
    },
  },
};

// =============================================================================
// Tests
// =============================================================================

describe('bootReplayApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  describe('fetch', () => {
    it('calls the correct URL with only the required instance_id param', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      await bootReplayApi.fetch({ instance_id: 'inst-abc123' });

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(
        '/system/fleet/boot_replay?instance_id=inst-abc123',
      );
    });

    it('appends correlation_id to the query string when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      await bootReplayApi.fetch({
        instance_id: 'inst-abc123',
        correlation_id: 'corr-xyz',
      });

      expect(mockGet).toHaveBeenCalledWith(
        '/system/fleet/boot_replay?instance_id=inst-abc123&correlation_id=corr-xyz',
      );
    });

    it('appends limit to the query string when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      await bootReplayApi.fetch({
        instance_id: 'inst-abc123',
        limit: 50,
      });

      expect(mockGet).toHaveBeenCalledWith(
        '/system/fleet/boot_replay?instance_id=inst-abc123&limit=50',
      );
    });

    it('appends both correlation_id and limit when all params are provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      await bootReplayApi.fetch({
        instance_id: 'inst-abc123',
        correlation_id: 'corr-xyz',
        limit: 100,
      });

      expect(mockGet).toHaveBeenCalledWith(
        '/system/fleet/boot_replay?instance_id=inst-abc123&correlation_id=corr-xyz&limit=100',
      );
    });

    it('does not append correlation_id when it is undefined', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      await bootReplayApi.fetch({
        instance_id: 'inst-abc123',
        correlation_id: undefined,
      });

      const calledUrl: string = mockGet.mock.calls[0][0] as string;
      expect(calledUrl).not.toContain('correlation_id');
    });

    it('does not append limit when it is undefined', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      await bootReplayApi.fetch({
        instance_id: 'inst-abc123',
        limit: undefined,
      });

      const calledUrl: string = mockGet.mock.calls[0][0] as string;
      expect(calledUrl).not.toContain('limit');
    });

    it('does not append limit when it is 0 (falsy)', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      // limit: 0 is falsy, so the source's `if (params.limit)` guard skips it
      await bootReplayApi.fetch({
        instance_id: 'inst-abc123',
        limit: 0,
      });

      const calledUrl: string = mockGet.mock.calls[0][0] as string;
      expect(calledUrl).not.toContain('limit');
    });

    it('returns the unwrapped BootReplayResponse from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      const result = await bootReplayApi.fetch({ instance_id: 'inst-abc123' });

      expect(result).toEqual(BOOT_REPLAY_RESPONSE);
    });

    it('returns the correct instance_id from the response', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      const result = await bootReplayApi.fetch({ instance_id: 'inst-abc123' });

      expect(result.instance_id).toBe('inst-abc123');
    });

    it('returns the events array from the response', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      const result = await bootReplayApi.fetch({ instance_id: 'inst-abc123' });

      expect(result.events).toHaveLength(3);
      expect(result.events[0].id).toBe('evt-001');
      expect(result.events[0].kind).toBe('boot.start');
      expect(result.events[0].severity).toBe('info');
      expect(result.events[0].correlation_id).toBe('corr-xyz');
      expect(result.events[0].source).toBe('initramfs');
    });

    it('handles events with null optional fields', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      const result = await bootReplayApi.fetch({ instance_id: 'inst-abc123' });

      expect(result.events[1].correlation_id).toBeNull();
      expect(result.events[1].source).toBeNull();
    });

    it('handles events with absent optional fields', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      const result = await bootReplayApi.fetch({ instance_id: 'inst-abc123' });

      // evt-003 has no correlation_id or source keys at all
      expect(result.events[2].correlation_id).toBeUndefined();
      expect(result.events[2].source).toBeUndefined();
    });

    it('returns the phase_summary map from the response', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      const result = await bootReplayApi.fetch({ instance_id: 'inst-abc123' });

      expect('boot.start' in result.phase_summary).toBe(true);
      expect(result.phase_summary['boot.start'].count).toBe(1);
      expect(result.phase_summary['boot.error'].count).toBe(1);
    });

    it('returns an empty events array and empty phase_summary when the response contains no events', async () => {
      const emptyResponse: BootReplayResponse = {
        instance_id: 'inst-empty',
        events: [],
        phase_summary: {},
      };
      mockGet.mockResolvedValueOnce(envelope(emptyResponse));

      const result = await bootReplayApi.fetch({ instance_id: 'inst-empty' });

      expect(result.events).toEqual([]);
      expect(result.phase_summary).toEqual({});
    });

    it('propagates errors thrown by the API client', async () => {
      const networkError = new Error('Network Error');
      mockGet.mockRejectedValueOnce(networkError);

      await expect(
        bootReplayApi.fetch({ instance_id: 'inst-abc123' }),
      ).rejects.toThrow('Network Error');
    });

    it('propagates 404 errors from the API client', async () => {
      const notFoundError = Object.assign(new Error('Request failed with status code 404'), {
        response: { status: 404, data: { success: false, error: 'Instance not found' } },
      });
      mockGet.mockRejectedValueOnce(notFoundError);

      await expect(
        bootReplayApi.fetch({ instance_id: 'inst-not-found' }),
      ).rejects.toThrow('Request failed with status code 404');
    });

    it('URL-encodes special characters in instance_id', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      await bootReplayApi.fetch({ instance_id: 'inst/with spaces&special' });

      const calledUrl: string = mockGet.mock.calls[0][0] as string;
      expect(calledUrl).toContain('instance_id=inst%2Fwith+spaces%26special');
    });

    it('URL-encodes special characters in correlation_id', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      await bootReplayApi.fetch({
        instance_id: 'inst-abc123',
        correlation_id: 'corr/a&b=c',
      });

      const calledUrl: string = mockGet.mock.calls[0][0] as string;
      expect(calledUrl).toContain('correlation_id=corr%2Fa%26b%3Dc');
    });

    it('converts limit to a string in the query parameter', async () => {
      mockGet.mockResolvedValueOnce(envelope(BOOT_REPLAY_RESPONSE));

      await bootReplayApi.fetch({ instance_id: 'inst-abc123', limit: 25 });

      const calledUrl: string = mockGet.mock.calls[0][0] as string;
      expect(calledUrl).toContain('limit=25');
    });
  });
});
