import { renderHook, waitFor, act } from '@testing-library/react';
import { usePlatformPeers } from './usePlatformPeers';
import type { PlatformPeerSummary, PeerListResponse } from '../types/peer.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...a: unknown[]) => mockGet(...a),
    post: (...a: unknown[]) => mockPost(...a),
    put: (...a: unknown[]) => mockPut(...a),
    delete: (...a: unknown[]) => mockDelete(...a),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const PEER_A: PlatformPeerSummary = {
  id: 'peer-a',
  remote_instance_url: 'https://node-a.example.com',
  remote_instance_id: 'inst-a',
  peer_kind: 'platform',
  spawn_role: 'parent',
  spawn_mode: 'managed_child',
  status: 'active',
  created_at: '2026-01-01T00:00:00Z',
  last_heartbeat_at: '2026-05-01T12:00:00Z',
  last_handshake_at: '2026-05-01T11:00:00Z',
  endpoints_count: 2,
  acceptance_pending: false,
  acceptance_expires_at: null,
};

const PEER_B: PlatformPeerSummary = {
  id: 'peer-b',
  remote_instance_url: 'https://node-b.example.com',
  remote_instance_id: null,
  peer_kind: 'sdwan_only',
  spawn_role: null,
  spawn_mode: null,
  status: 'proposed',
  created_at: '2026-02-01T00:00:00Z',
  last_heartbeat_at: null,
  last_handshake_at: null,
  endpoints_count: 0,
  acceptance_pending: true,
  acceptance_expires_at: '2026-06-10T00:00:00Z',
};

function peerListEnvelope(peers: PlatformPeerSummary[]): ReturnType<typeof envelope<PeerListResponse>> {
  return envelope<PeerListResponse>({ peers, count: peers.length });
}

// =============================================================================
// Tests
// =============================================================================

describe('usePlatformPeers', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Initial state + successful fetch
  // ---------------------------------------------------------------------------

  it('starts in loading state and resolves to the fetched peers', async () => {
    mockGet.mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    const { result } = renderHook(() => usePlatformPeers());

    // Immediately: loading is true, peers is empty, no error
    expect(result.current.loading).toBe(true);
    expect(result.current.peers).toEqual([]);
    expect(result.current.error).toBeNull();

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.peers).toHaveLength(2);
    expect(result.current.peers[0]).toEqual(PEER_A);
    expect(result.current.peers[1]).toEqual(PEER_B);
    expect(result.current.error).toBeNull();
  });

  it('calls the listPeers endpoint with no params when no filters given', async () => {
    mockGet.mockResolvedValueOnce(peerListEnvelope([PEER_A]));

    renderHook(() => usePlatformPeers());

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/platform/peers', { params: {} }),
    );
  });

  // ---------------------------------------------------------------------------
  // Filter serialization
  // ---------------------------------------------------------------------------

  it('passes status filter as a query param string', async () => {
    mockGet.mockResolvedValueOnce(peerListEnvelope([PEER_A]));

    renderHook(() => usePlatformPeers({ status: 'active' }));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/platform/peers', {
        params: { status: 'active' },
      }),
    );
  });

  it('joins array status filter values with commas', async () => {
    mockGet.mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    renderHook(() => usePlatformPeers({ status: ['active', 'degraded'] }));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/platform/peers', {
        params: { status: 'active,degraded' },
      }),
    );
  });

  it('passes spawn_mode filter as a query param string', async () => {
    mockGet.mockResolvedValueOnce(peerListEnvelope([PEER_A]));

    renderHook(() => usePlatformPeers({ spawn_mode: 'managed_child' }));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/platform/peers', {
        params: { spawn_mode: 'managed_child' },
      }),
    );
  });

  it('omits undefined/null filter values from the params', async () => {
    mockGet.mockResolvedValueOnce(peerListEnvelope([]));

    // spawn_mode is undefined, only status should appear
    renderHook(() => usePlatformPeers({ status: 'proposed' }));

    await waitFor(() => {
      const call = mockGet.mock.calls[0] as [string, { params: Record<string, string> }];
      expect(call[1].params).toEqual({ status: 'proposed' });
      expect(call[1].params).not.toHaveProperty('spawn_mode');
    });
  });

  it('omits empty-array status filter from the params', async () => {
    mockGet.mockResolvedValueOnce(peerListEnvelope([]));

    renderHook(() => usePlatformPeers({ status: [] as unknown as import('../types/peer.types').PeerStatus[] }));

    await waitFor(() => {
      const call = mockGet.mock.calls[0] as [string, { params: Record<string, string> }];
      expect(call[1].params).not.toHaveProperty('status');
    });
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  it('sets error state when the API call rejects with an Error instance', async () => {
    mockGet.mockRejectedValueOnce(new Error('Network timeout'));

    const { result } = renderHook(() => usePlatformPeers());

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.peers).toEqual([]);
    expect(result.current.error).toBe('Network timeout');
  });

  it('sets a fallback message when the rejection is not an Error instance', async () => {
    mockGet.mockRejectedValueOnce('raw string rejection');

    const { result } = renderHook(() => usePlatformPeers());

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.error).toBe('Failed to load peers');
  });

  it('clears the error and resets loading on each refetch', async () => {
    // First call fails
    mockGet.mockRejectedValueOnce(new Error('First failure'));

    const { result } = renderHook(() => usePlatformPeers());

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.error).toBe('First failure');

    // Second call succeeds
    mockGet.mockResolvedValueOnce(peerListEnvelope([PEER_A]));

    await act(async () => {
      await result.current.refetch();
    });

    expect(result.current.loading).toBe(false);
    expect(result.current.error).toBeNull();
    expect(result.current.peers).toHaveLength(1);
    expect(result.current.peers[0]).toEqual(PEER_A);
  });

  // ---------------------------------------------------------------------------
  // refetch
  // ---------------------------------------------------------------------------

  it('exposes a refetch function that re-calls the API', async () => {
    mockGet
      .mockResolvedValueOnce(peerListEnvelope([PEER_A]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    const { result } = renderHook(() => usePlatformPeers());

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.peers).toHaveLength(1);

    await act(async () => {
      await result.current.refetch();
    });

    expect(result.current.peers).toHaveLength(2);
    expect(mockGet).toHaveBeenCalledTimes(2);
  });

  it('sets loading true during refetch then false on completion', async () => {
    let resolveSecond!: (value: ReturnType<typeof peerListEnvelope>) => void;
    const secondCall = new Promise<ReturnType<typeof peerListEnvelope>>(
      (res) => { resolveSecond = res; }
    );

    mockGet
      .mockResolvedValueOnce(peerListEnvelope([PEER_A]))
      .mockReturnValueOnce(secondCall);

    const { result } = renderHook(() => usePlatformPeers());

    await waitFor(() => expect(result.current.loading).toBe(false));

    // Kick off refetch without awaiting — React will synchronously set loading=true
    // inside the async function before the first await, but we need to wait for the
    // state update to flush through the render cycle.
    const refetchPromise = result.current.refetch();
    await waitFor(() => expect(result.current.loading).toBe(true));

    resolveSecond(peerListEnvelope([PEER_B]));
    await act(async () => {
      await refetchPromise;
    });

    expect(result.current.loading).toBe(false);
    expect(result.current.peers[0]).toEqual(PEER_B);
  });

  // ---------------------------------------------------------------------------
  // Exposed state setters (used by consumers for live-update without refetch)
  // ---------------------------------------------------------------------------

  it('exposes setPeers so consumers can mutate rows in-place', async () => {
    mockGet.mockResolvedValueOnce(peerListEnvelope([PEER_A]));

    const { result } = renderHook(() => usePlatformPeers());

    await waitFor(() => expect(result.current.loading).toBe(false));

    const updated: PlatformPeerSummary = {
      ...PEER_A,
      last_heartbeat_at: '2026-06-05T00:00:00Z',
      status: 'degraded',
    };

    act(() => {
      result.current.setPeers([updated]);
    });

    expect(result.current.peers).toHaveLength(1);
    expect(result.current.peers[0].status).toBe('degraded');
    expect(result.current.peers[0].last_heartbeat_at).toBe('2026-06-05T00:00:00Z');
  });

  it('exposes setError so consumers can surface dismissible banners', async () => {
    mockGet.mockResolvedValueOnce(peerListEnvelope([PEER_A]));

    const { result } = renderHook(() => usePlatformPeers());

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.error).toBeNull();

    act(() => {
      result.current.setError('Custom banner message');
    });

    expect(result.current.error).toBe('Custom banner message');
  });

  // ---------------------------------------------------------------------------
  // Filter change triggers a new fetch
  // ---------------------------------------------------------------------------

  it('re-fetches when filter values change between renders', async () => {
    mockGet
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A]));

    const { result, rerender } = renderHook(
      ({ filters }: { filters?: import('../types/peer.types').PeerListFilters }) =>
        usePlatformPeers(filters),
      { initialProps: { filters: undefined } },
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.peers).toHaveLength(2);

    rerender({ filters: { status: 'active' } });

    await waitFor(() => expect(result.current.peers).toHaveLength(1));
    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(mockGet).toHaveBeenLastCalledWith('/system/platform/peers', {
      params: { status: 'active' },
    });
  });

  it('does NOT re-fetch when the filter object reference changes but values are identical', async () => {
    mockGet.mockResolvedValue(peerListEnvelope([PEER_A]));

    const { rerender } = renderHook(
      ({ filters }: { filters?: import('../types/peer.types').PeerListFilters }) =>
        usePlatformPeers(filters),
      { initialProps: { filters: { status: 'active' as const } } },
    );

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));

    // New object reference but same JSON representation → filterKey unchanged
    rerender({ filters: { status: 'active' as const } });

    // Give React a tick to process
    await new Promise((r) => setTimeout(r, 50));

    expect(mockGet).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Return shape completeness
  // ---------------------------------------------------------------------------

  it('returns all expected keys from the hook', async () => {
    mockGet.mockResolvedValueOnce(peerListEnvelope([]));

    const { result } = renderHook(() => usePlatformPeers());

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current).toMatchObject({
      peers: expect.any(Array) as PlatformPeerSummary[],
      loading: expect.any(Boolean) as boolean,
      error: null,
    });
    expect(typeof result.current.setPeers).toBe('function');
    expect(typeof result.current.setError).toBe('function');
    expect(typeof result.current.refetch).toBe('function');
  });
});
