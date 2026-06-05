import { act, renderHook, waitFor } from '@testing-library/react';
import { useBootReplay } from './useBootReplay';
import type { BootReplayResponse } from '../../../services/api/bootReplayApi';

// =============================================================================
// Mocks
// =============================================================================

const mockFetch = jest.fn();

jest.mock('../../../services/api/bootReplayApi', () => ({
  bootReplayApi: {
    fetch: (...args: unknown[]) => mockFetch(...args),
  },
}));

jest.mock('@/shared/utils/logger', () => ({
  logger: {
    error: jest.fn(),
    warn: jest.fn(),
    info: jest.fn(),
    debug: jest.fn(),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const INSTANCE_ID = 'inst-abc123';
const CORRELATION_ID = 'corr-xyz789';

const BOOT_RESPONSE: BootReplayResponse = {
  instance_id: INSTANCE_ID,
  events: [
    {
      id: 'evt-1',
      kind: 'kernel.boot',
      severity: 'low',
      payload: { kernel_version: '6.1.0' },
      emitted_at: '2026-06-01T10:00:00Z',
      correlation_id: CORRELATION_ID,
      source: 'agent',
    },
    {
      id: 'evt-2',
      kind: 'enrollment.token_seen',
      severity: 'medium',
      payload: {},
      emitted_at: '2026-06-01T10:00:05Z',
      correlation_id: null,
      source: null,
    },
  ],
  phase_summary: {
    kernel: { first_at: '2026-06-01T10:00:00Z', last_at: '2026-06-01T10:00:30Z', count: 1 },
    enrollment: { first_at: '2026-06-01T10:00:05Z', last_at: '2026-06-01T10:00:10Z', count: 1 },
  },
};

// =============================================================================
// Tests
// =============================================================================

describe('useBootReplay', () => {
  beforeEach(() => {
    mockFetch.mockReset();
  });

  // ── Idle: null instanceId ────────────────────────────────────────────────────

  it('does not fetch when instanceId is null', () => {
    renderHook(() => useBootReplay(null));
    expect(mockFetch).not.toHaveBeenCalled();
  });

  it('returns loading=false, data=null, error=null when instanceId is null', () => {
    const { result } = renderHook(() => useBootReplay(null));
    expect(result.current.loading).toBe(false);
    expect(result.current.data).toBeNull();
    expect(result.current.error).toBeNull();
  });

  // ── Success path ─────────────────────────────────────────────────────────────

  it('sets loading=true while the fetch is in flight', async () => {
    // Use a promise that never resolves so we can inspect intermediate state.
    let resolveHold!: (v: BootReplayResponse) => void;
    const held = new Promise<BootReplayResponse>(res => { resolveHold = res; });
    mockFetch.mockReturnValueOnce(held);

    const { result } = renderHook(() => useBootReplay(INSTANCE_ID));

    // Flush the microtask queue so the effect fires but the promise hasn't resolved.
    await act(async () => { await Promise.resolve(); });

    expect(result.current.loading).toBe(true);
    expect(result.current.data).toBeNull();

    // Unblock the promise so the hook can clean up properly.
    act(() => { resolveHold(BOOT_RESPONSE); });
    await waitFor(() => expect(result.current.loading).toBe(false));
  });

  it('populates data and clears loading/error on successful fetch', async () => {
    mockFetch.mockResolvedValueOnce(BOOT_RESPONSE);

    const { result } = renderHook(() => useBootReplay(INSTANCE_ID));

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.data).toEqual(BOOT_RESPONSE);
    expect(result.current.error).toBeNull();
  });

  it('calls bootReplayApi.fetch with instance_id only when correlationId is absent', async () => {
    mockFetch.mockResolvedValueOnce(BOOT_RESPONSE);

    renderHook(() => useBootReplay(INSTANCE_ID));

    await waitFor(() => expect(mockFetch).toHaveBeenCalledTimes(1));
    expect(mockFetch).toHaveBeenCalledWith({ instance_id: INSTANCE_ID, correlation_id: undefined });
  });

  it('calls bootReplayApi.fetch with both instance_id and correlation_id when provided', async () => {
    mockFetch.mockResolvedValueOnce(BOOT_RESPONSE);

    renderHook(() => useBootReplay(INSTANCE_ID, CORRELATION_ID));

    await waitFor(() => expect(mockFetch).toHaveBeenCalledTimes(1));
    expect(mockFetch).toHaveBeenCalledWith({ instance_id: INSTANCE_ID, correlation_id: CORRELATION_ID });
  });

  // ── Error path ───────────────────────────────────────────────────────────────

  it('sets error from the thrown Error message and clears loading on failure', async () => {
    mockFetch.mockRejectedValueOnce(new Error('network timeout'));

    const { result } = renderHook(() => useBootReplay(INSTANCE_ID));

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.error).toBe('network timeout');
    expect(result.current.data).toBeNull();
  });

  it('falls back to a generic message when a non-Error is thrown', async () => {
    mockFetch.mockRejectedValueOnce('raw string error');

    const { result } = renderHook(() => useBootReplay(INSTANCE_ID));

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.error).toBe('Failed to load boot replay');
    expect(result.current.data).toBeNull();
  });

  it('clears a previous error on the next successful fetch', async () => {
    // First fetch fails.
    mockFetch.mockRejectedValueOnce(new Error('temporary failure'));

    const { result } = renderHook(() => useBootReplay(INSTANCE_ID));
    await waitFor(() => expect(result.current.error).toBe('temporary failure'));

    // Manual refresh resolves successfully.
    mockFetch.mockResolvedValueOnce(BOOT_RESPONSE);

    act(() => { result.current.refresh(); });

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.error).toBeNull();
    expect(result.current.data).toEqual(BOOT_RESPONSE);
  });

  // ── refresh() ────────────────────────────────────────────────────────────────

  it('refresh() triggers a second fetch and updates data', async () => {
    const SECOND_RESPONSE: BootReplayResponse = {
      ...BOOT_RESPONSE,
      events: [],
      phase_summary: {},
    };

    mockFetch.mockResolvedValueOnce(BOOT_RESPONSE);
    const { result } = renderHook(() => useBootReplay(INSTANCE_ID));
    await waitFor(() => expect(result.current.loading).toBe(false));

    mockFetch.mockResolvedValueOnce(SECOND_RESPONSE);
    act(() => { result.current.refresh(); });

    await waitFor(() => expect(result.current.data).toEqual(SECOND_RESPONSE));
    expect(mockFetch).toHaveBeenCalledTimes(2);
  });

  it('refresh() is a no-op when instanceId is null', async () => {
    const { result } = renderHook(() => useBootReplay(null));

    act(() => { result.current.refresh(); });

    await act(async () => { await Promise.resolve(); });

    expect(mockFetch).not.toHaveBeenCalled();
  });

  it('refresh() sets loading=true then false around its fetch', async () => {
    mockFetch.mockResolvedValue(BOOT_RESPONSE);
    const { result } = renderHook(() => useBootReplay(INSTANCE_ID));
    await waitFor(() => expect(result.current.loading).toBe(false));

    let resolveRefresh!: (v: BootReplayResponse) => void;
    const held = new Promise<BootReplayResponse>(res => { resolveRefresh = res; });
    mockFetch.mockReturnValueOnce(held);

    act(() => { result.current.refresh(); });

    await act(async () => { await Promise.resolve(); });
    expect(result.current.loading).toBe(true);

    act(() => { resolveRefresh(BOOT_RESPONSE); });
    await waitFor(() => expect(result.current.loading).toBe(false));
  });

  // ── Reactivity: instanceId change ────────────────────────────────────────────

  it('re-fetches when instanceId changes', async () => {
    mockFetch.mockResolvedValue(BOOT_RESPONSE);

    const { result, rerender } = renderHook(
      ({ id }: { id: string | null }) => useBootReplay(id),
      { initialProps: { id: INSTANCE_ID } },
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(mockFetch).toHaveBeenCalledTimes(1);
    expect(mockFetch).toHaveBeenLastCalledWith({ instance_id: INSTANCE_ID, correlation_id: undefined });

    const OTHER_ID = 'inst-other999';
    const OTHER_RESPONSE: BootReplayResponse = { ...BOOT_RESPONSE, instance_id: OTHER_ID };
    mockFetch.mockResolvedValueOnce(OTHER_RESPONSE);

    rerender({ id: OTHER_ID });

    await waitFor(() => expect(result.current.data?.instance_id).toBe(OTHER_ID));
    expect(mockFetch).toHaveBeenCalledTimes(2);
    expect(mockFetch).toHaveBeenLastCalledWith({ instance_id: OTHER_ID, correlation_id: undefined });
  });

  it('re-fetches when correlationId changes', async () => {
    mockFetch.mockResolvedValue(BOOT_RESPONSE);

    const { rerender } = renderHook(
      ({ cid }: { cid?: string }) => useBootReplay(INSTANCE_ID, cid),
      { initialProps: { cid: undefined as string | undefined } },
    );

    await waitFor(() => expect(mockFetch).toHaveBeenCalledTimes(1));

    mockFetch.mockResolvedValueOnce(BOOT_RESPONSE);
    rerender({ cid: CORRELATION_ID });

    await waitFor(() => expect(mockFetch).toHaveBeenCalledTimes(2));
    expect(mockFetch).toHaveBeenLastCalledWith({ instance_id: INSTANCE_ID, correlation_id: CORRELATION_ID });
  });

  it('does not fetch again when instanceId changes to null', async () => {
    mockFetch.mockResolvedValueOnce(BOOT_RESPONSE);

    const { result, rerender } = renderHook(
      ({ id }: { id: string | null }) => useBootReplay(id),
      { initialProps: { id: INSTANCE_ID } },
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(mockFetch).toHaveBeenCalledTimes(1);

    rerender({ id: null });

    await act(async () => { await Promise.resolve(); });
    expect(mockFetch).toHaveBeenCalledTimes(1);
  });

  // ── Return value shape ────────────────────────────────────────────────────────

  it('exposes a stable refresh function reference while inputs are unchanged', async () => {
    mockFetch.mockResolvedValue(BOOT_RESPONSE);

    const { result, rerender } = renderHook(() => useBootReplay(INSTANCE_ID));
    await waitFor(() => expect(result.current.loading).toBe(false));

    const refreshRef = result.current.refresh;
    rerender();

    expect(result.current.refresh).toBe(refreshRef);
  });

  it('returns the correct shape: { loading, data, error, refresh }', async () => {
    mockFetch.mockResolvedValueOnce(BOOT_RESPONSE);

    const { result } = renderHook(() => useBootReplay(INSTANCE_ID));
    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(typeof result.current.loading).toBe('boolean');
    expect(typeof result.current.error === 'string' || result.current.error === null).toBe(true);
    expect(typeof result.current.refresh).toBe('function');
    expect(result.current.data).not.toBeNull();
  });
});
