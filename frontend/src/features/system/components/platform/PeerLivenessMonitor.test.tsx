import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PeerLivenessMonitor } from './PeerLivenessMonitor';
import type { PlatformPeerSummary } from '../../types/peer.types';

// =============================================================================
// Mocks
//
// PeerLivenessMonitor composes:
//   - usePlatformPeers (which calls platformPeersApi.listPeers → apiClient.get)
//   - useWebSocket   (subscribe to SystemFleetChannel live events)
//   - useAuth        (currentUser.account.id for the WS channel params)
//   - PeerDetailDrawer (child component — stubbed to avoid its own API calls)
//   - PeerTable + PeerUrlCell + PeerStatusCell + PeerHeartbeatCell (passthrough)
// =============================================================================

const mockGet = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: jest.fn(),
    put: jest.fn(),
    delete: jest.fn(),
  },
}));

// ── WebSocket ─────────────────────────────────────────────────────────────────
// We capture the subscribe handler so tests can push synthetic fleet events.
let capturedOnMessage: ((raw: unknown) => void) | null = null;
let capturedOnError: ((err: string) => void) | null = null;
const mockSubscribe = jest.fn(
  (sub: { onMessage?: (raw: unknown) => void; onError?: (err: string) => void }) => {
    capturedOnMessage = sub.onMessage ?? null;
    capturedOnError = sub.onError ?? null;
    return jest.fn(); // unsub function
  },
);

// mockUseWebSocket is accessed by the factory via closure (jest hoists the
// mock() call but the variable declaration is evaluated first because Jest
// allows `mock`-prefixed identifiers to be used inside factory functions).
const mockUseWebSocket = jest.fn(() => ({
  subscribe: mockSubscribe,
  isConnected: true as boolean,
}));

jest.mock('@/shared/hooks/useWebSocket', () => ({
  useWebSocket: (...args: unknown[]) => mockUseWebSocket(...args),
}));

// ── Auth ─────────────────────────────────────────────────────────────────────
jest.mock('@/shared/hooks/useAuth', () => ({
  useAuth: () => ({
    currentUser: { account: { id: 'account-test-1' } },
    isAuthenticated: true,
    isLoading: false,
    permissions: [],
  }),
}));

// ── BreadcrumbContext ─────────────────────────────────────────────────────────
jest.mock('@/shared/hooks/BreadcrumbContext', () => ({
  __esModule: true,
  BreadcrumbProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
  useBreadcrumb: () => ({
    breadcrumbs: [],
    setBreadcrumbs: jest.fn(),
    getCurrentBreadcrumbs: () => [],
    setCurrentPage: jest.fn(),
  }),
}));

// ── PeerDetailDrawer — stub to avoid getPeer API call bleeding in ─────────────
jest.mock('./PeerDetailDrawer', () => ({
  PeerDetailDrawer: ({
    peerId,
    onClose,
  }: {
    peerId: string | null;
    onClose: () => void;
  }) =>
    peerId ? (
      <div data-testid="peer-detail-drawer" data-peer-id={peerId}>
        <button onClick={onClose} data-testid="detail-drawer-close">
          Close
        </button>
      </div>
    ) : null,
}));

// ── Logger — suppress warnings in test output ─────────────────────────────────
jest.mock('@/shared/utils/logger', () => ({
  logger: { warn: jest.fn(), info: jest.fn(), error: jest.fn(), debug: jest.fn() },
}));

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const PEER_ACTIVE: PlatformPeerSummary = {
  id: 'peer-active-1',
  remote_instance_url: 'https://remote-a.example.com',
  remote_instance_id: 'rid-001',
  peer_kind: 'platform',
  spawn_role: 'symmetric',
  spawn_mode: 'out_of_band',
  status: 'active',
  created_at: '2026-01-01T00:00:00Z',
  last_heartbeat_at: new Date(Date.now() - 10_000).toISOString(), // 10 s ago — fresh
  last_handshake_at: '2026-05-01T12:00:00Z',
  endpoints_count: 2,
  acceptance_pending: false,
  acceptance_expires_at: null,
};

const PEER_DEGRADED: PlatformPeerSummary = {
  id: 'peer-degraded-2',
  remote_instance_url: 'https://remote-b.example.com',
  remote_instance_id: 'rid-002',
  peer_kind: 'platform',
  spawn_role: null,
  spawn_mode: null,
  status: 'degraded',
  created_at: '2026-01-01T00:00:00Z',
  last_heartbeat_at: null,
  last_handshake_at: null,
  endpoints_count: 0,
  acceptance_pending: false,
  acceptance_expires_at: null,
};

const PEER_STALE: PlatformPeerSummary = {
  id: 'peer-stale-3',
  remote_instance_url: 'https://remote-c.example.com',
  remote_instance_id: 'rid-003',
  peer_kind: 'platform',
  spawn_role: 'parent',
  spawn_mode: 'managed_child',
  status: 'enrolled',
  created_at: '2026-01-01T00:00:00Z',
  // Heartbeat is 120 s old — exceeds the 90 s threshold
  last_heartbeat_at: new Date(Date.now() - 120_000).toISOString(),
  last_handshake_at: null,
  endpoints_count: 1,
  acceptance_pending: false,
  acceptance_expires_at: null,
};

function peersListEnvelope(peers: PlatformPeerSummary[]) {
  return envelope({ peers, count: peers.length });
}

// =============================================================================
// Render helper
// =============================================================================

function renderMonitor(props: Partial<React.ComponentProps<typeof PeerLivenessMonitor>> = {}) {
  return render(
    <BrowserRouter>
      <PeerLivenessMonitor {...props} />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('PeerLivenessMonitor', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockSubscribe.mockClear();
    mockUseWebSocket.mockClear();
    capturedOnMessage = null;
    capturedOnError = null;
    // Default: WebSocket is connected. Individual tests override via mockReturnValue.
    mockSubscribe.mockImplementation(
      (sub: { onMessage?: (raw: unknown) => void; onError?: (err: string) => void }) => {
        capturedOnMessage = sub.onMessage ?? null;
        capturedOnError = sub.onError ?? null;
        return jest.fn();
      },
    );
    mockUseWebSocket.mockReturnValue({ subscribe: mockSubscribe, isConnected: true });
  });

  // ---------------------------------------------------------------------------
  // Container render
  // ---------------------------------------------------------------------------

  describe('container render', () => {
    it('renders the monitor container', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([]));

      renderMonitor();

      expect(screen.getByTestId('peer-liveness-monitor')).toBeInTheDocument();
    });

    it('renders the "Peer Liveness" heading', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([]));

      renderMonitor();

      expect(screen.getByText('Peer Liveness')).toBeInTheDocument();
    });

    it('shows "live" connection indicator when WebSocket is connected', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([]));

      renderMonitor();

      expect(screen.getByText('live')).toBeInTheDocument();
    });

    it('shows "offline" connection indicator when WebSocket is disconnected', async () => {
      mockUseWebSocket.mockReturnValue({ subscribe: mockSubscribe, isConnected: false });
      mockGet.mockResolvedValue(peersListEnvelope([]));

      renderMonitor();

      expect(screen.getByText('offline')).toBeInTheDocument();
    });

    it('renders the summary stats bar (active/degraded/stale)', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([]));

      renderMonitor();

      expect(screen.getByText('active')).toBeInTheDocument();
      expect(screen.getByText('degraded')).toBeInTheDocument();
      expect(screen.getByText('stale heartbeat')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  describe('loading state', () => {
    it('shows "loading…" in the header while the API is in flight', () => {
      mockGet.mockReturnValue(new Promise(() => {}));

      renderMonitor();

      expect(screen.getByText('loading…')).toBeInTheDocument();
    });

    it('shows the peer count once the API resolves', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE, PEER_DEGRADED]));

      renderMonitor();

      await waitFor(() => {
        expect(screen.getByText('2 peers')).toBeInTheDocument();
      });
    });

    it('uses singular "peer" for a list of 1', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() => {
        expect(screen.getByText('1 peer')).toBeInTheDocument();
      });
    });
  });

  // ---------------------------------------------------------------------------
  // API calls
  // ---------------------------------------------------------------------------

  describe('API calls', () => {
    it('calls GET /system/platform/peers on mount', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([]));

      renderMonitor();

      await waitFor(() => {
        expect(mockGet).toHaveBeenCalledWith(
          '/system/platform/peers',
          expect.objectContaining({ params: {} }),
        );
      });
    });

    it('refetches when the Refresh button is clicked', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([]));

      renderMonitor();

      // The component calls refetch twice on mount: once from usePlatformPeers'
      // own effect and once from the refreshKey effect (fires even on initial
      // mount when refreshKey is undefined).
      const initialCallCount = await waitFor(() => {
        expect(mockGet).toHaveBeenCalled();
        return mockGet.mock.calls.length;
      });

      fireEvent.click(screen.getByTitle('Refresh'));

      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(initialCallCount + 1));
    });

    it('disables the Refresh button while loading is in flight', () => {
      mockGet.mockReturnValue(new Promise(() => {}));

      renderMonitor();

      expect(screen.getByTitle('Refresh')).toBeDisabled();
    });

    it('refetches when the refreshKey prop changes', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([]));

      const { rerender } = renderMonitor({ refreshKey: 0 });

      // Wait for initial fetch(es) to settle
      const initialCallCount = await waitFor(() => {
        expect(mockGet).toHaveBeenCalled();
        return mockGet.mock.calls.length;
      });

      rerender(
        <BrowserRouter>
          <PeerLivenessMonitor refreshKey={1} />
        </BrowserRouter>,
      );

      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(initialCallCount + 1));
    });
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  describe('error state', () => {
    it('shows an error banner when the API call fails', async () => {
      mockGet.mockRejectedValue(new Error('Failed to load peers'));

      renderMonitor();

      await waitFor(() => {
        expect(screen.getByText('Failed to load peers')).toBeInTheDocument();
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  describe('empty state', () => {
    it('shows the empty-state message when there are no peers', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([]));

      renderMonitor();

      await waitFor(() => {
        expect(
          screen.getByText(/No federation peers yet\. Use the Control tab to propose one\./),
        ).toBeInTheDocument();
      });
    });

    it('does not show the empty-state message when peers exist', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );
      expect(
        screen.queryByText(/No federation peers yet/),
      ).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Peer rows
  // ---------------------------------------------------------------------------

  describe('peer rows', () => {
    it('renders a row for each peer with the correct testid', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE, PEER_DEGRADED]));

      renderMonitor();

      await waitFor(() => {
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument();
        expect(screen.getByTestId('liveness-row-peer-degraded-2')).toBeInTheDocument();
      });
    });

    it('renders column headers: Remote URL, Status, Endpoints, Last Heartbeat', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );
      expect(screen.getByText('Remote URL')).toBeInTheDocument();
      expect(screen.getByText('Status')).toBeInTheDocument();
      expect(screen.getByText('Endpoints')).toBeInTheDocument();
      expect(screen.getByText('Last Heartbeat')).toBeInTheDocument();
    });

    it('displays the peer remote_instance_url in the row', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() => {
        expect(screen.getByText('https://remote-a.example.com')).toBeInTheDocument();
      });
    });

    it('displays the endpoints_count for the peer', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );
      // endpoints_count for PEER_ACTIVE is 2
      expect(screen.getByTestId('liveness-row-peer-active-1').textContent).toContain('2');
    });

    it('shows "never" for a peer with no last_heartbeat_at', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_DEGRADED]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-degraded-2')).toBeInTheDocument(),
      );
      expect(screen.getByText('never')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Summary statistics
  // ---------------------------------------------------------------------------

  describe('summary statistics', () => {
    it('counts active peers correctly in the stats bar', async () => {
      // 2 active, 1 degraded
      mockGet.mockResolvedValue(
        peersListEnvelope([
          PEER_ACTIVE,
          { ...PEER_ACTIVE, id: 'peer-active-2', remote_instance_url: 'https://a2.example.com' },
          PEER_DEGRADED,
        ]),
      );

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      // The stats bar is structured as:
      //   <span>active <span class="font-mono ...">2</span></span>
      // We query the mono number sibling to the "active" label text node.
      // Both the label and pill contain "active" — use the parent span text.
      const allActiveSpans = screen.getAllByText(/^active\s*\d*$|^active$/);
      // The stats bar outer span has combined text "active 2" or similar
      const statsBarActiveSpan = allActiveSpans.find((el) =>
        el.closest('[data-testid="peer-liveness-monitor"]') !== null &&
        el.tagName === 'SPAN' &&
        el.textContent?.includes('active'),
      );
      expect(statsBarActiveSpan).toBeDefined();
      // Get the mono number that is a direct child of this span
      const monoNum = statsBarActiveSpan?.querySelector('.font-mono');
      expect(monoNum?.textContent).toBe('2');
    });

    it('counts degraded+suspended peers in the degraded tally', async () => {
      const suspendedPeer: PlatformPeerSummary = {
        ...PEER_DEGRADED,
        id: 'peer-suspended-4',
        status: 'suspended',
        remote_instance_url: 'https://suspended.example.com',
      };

      mockGet.mockResolvedValue(peersListEnvelope([PEER_DEGRADED, suspendedPeer]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-degraded-2')).toBeInTheDocument(),
      );

      // Degraded stats bar span — search among all "degraded" occurrences for the parent span
      const allDegradedEls = screen.getAllByText(/degraded/);
      const statsBarDegradedSpan = allDegradedEls.find(
        (el) => el.tagName === 'SPAN' && el.querySelector('.font-mono') !== null,
      );
      expect(statsBarDegradedSpan).toBeDefined();
      const monoNum = statsBarDegradedSpan?.querySelector('.font-mono');
      expect(monoNum?.textContent).toBe('2');
    });

    it('flags a peer with stale heartbeat (>90s ago) in the stale tally', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_STALE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-stale-3')).toBeInTheDocument(),
      );

      const staleStats = screen.getByText('stale heartbeat').closest('span');
      expect(staleStats?.textContent).toContain('1');
    });

    it('flags an active peer with no heartbeat as stale', async () => {
      const noHeartbeatActive: PlatformPeerSummary = {
        ...PEER_ACTIVE,
        id: 'peer-no-hb',
        remote_instance_url: 'https://no-hb.example.com',
        last_heartbeat_at: null,
      };

      mockGet.mockResolvedValue(peersListEnvelope([noHeartbeatActive]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-no-hb')).toBeInTheDocument(),
      );

      const staleStats = screen.getByText('stale heartbeat').closest('span');
      expect(staleStats?.textContent).toContain('1');
    });
  });

  // ---------------------------------------------------------------------------
  // Row click → PeerDetailDrawer
  // ---------------------------------------------------------------------------

  describe('row click opens PeerDetailDrawer', () => {
    it('opens the PeerDetailDrawer with the correct peerId when a row is clicked', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      const row = await waitFor(() => screen.getByTestId('liveness-row-peer-active-1'));
      fireEvent.click(row);

      const drawer = screen.getByTestId('peer-detail-drawer');
      expect(drawer).toBeInTheDocument();
      expect(drawer).toHaveAttribute('data-peer-id', 'peer-active-1');
    });

    it('closes the PeerDetailDrawer when onClose is triggered', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      const row = await waitFor(() => screen.getByTestId('liveness-row-peer-active-1'));
      fireEvent.click(row);

      expect(screen.getByTestId('peer-detail-drawer')).toBeInTheDocument();

      fireEvent.click(screen.getByTestId('detail-drawer-close'));

      expect(screen.queryByTestId('peer-detail-drawer')).not.toBeInTheDocument();
    });

    it('opens the correct peer detail when a second peer row is clicked', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE, PEER_DEGRADED]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-degraded-2')).toBeInTheDocument(),
      );
      fireEvent.click(screen.getByTestId('liveness-row-peer-degraded-2'));

      const drawer = screen.getByTestId('peer-detail-drawer');
      expect(drawer).toHaveAttribute('data-peer-id', 'peer-degraded-2');
    });
  });

  // ---------------------------------------------------------------------------
  // WebSocket subscription
  // ---------------------------------------------------------------------------

  describe('WebSocket subscription', () => {
    it('subscribes to SystemFleetChannel with the account_id when connected', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      expect(mockSubscribe).toHaveBeenCalledWith(
        expect.objectContaining({
          channel: 'SystemFleetChannel',
          params: expect.objectContaining({ account_id: 'account-test-1' }),
        }),
      );
    });

    it('does not subscribe when WebSocket is disconnected', async () => {
      mockUseWebSocket.mockReturnValue({ subscribe: mockSubscribe, isConnected: false });
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      expect(mockSubscribe).not.toHaveBeenCalled();
    });

    it('ignores connection_established system messages', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      act(() => {
        capturedOnMessage?.({ type: 'connection_established' });
      });

      // Row still exists and peer count unchanged
      expect(screen.getByText('1 peer')).toBeInTheDocument();
    });

    it('ignores pong messages', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      act(() => {
        capturedOnMessage?.({ type: 'pong' });
      });

      expect(screen.getByText('1 peer')).toBeInTheDocument();
    });

    it('ignores fleet events with non-peer kinds', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      // The live-pulse dot should NOT appear before any event
      expect(screen.queryByTitle('Live event received this session')).not.toBeInTheDocument();

      act(() => {
        capturedOnMessage?.({
          kind: 'system.node.heartbeat',
          payload: { federation_peer_id: 'peer-active-1' },
          emitted_at: new Date().toISOString(),
        });
      });

      // Should still not show the pulse — the kind didn't match
      expect(screen.queryByTitle('Live event received this session')).not.toBeInTheDocument();
    });

    it('bumps last_heartbeat_at and marks row live on a federation event matched by federation_peer_id', async () => {
      const now = new Date().toISOString();
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      act(() => {
        capturedOnMessage?.({
          kind: 'system.federation.heartbeat',
          payload: { federation_peer_id: 'peer-active-1' },
          emitted_at: now,
        });
      });

      // Live-pulse dot should now appear
      await waitFor(() => {
        expect(screen.getByTitle('Live event received this session')).toBeInTheDocument();
      });
    });

    it('matches federation event by remote_instance_url when no federation_peer_id is present', async () => {
      const now = new Date().toISOString();
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      act(() => {
        capturedOnMessage?.({
          kind: 'system.federation.heartbeat',
          payload: { remote_instance_url: 'https://remote-a.example.com' },
          emitted_at: now,
        });
      });

      await waitFor(() => {
        expect(screen.getByTitle('Live event received this session')).toBeInTheDocument();
      });
    });

    it('updates peer status from federation event payload', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      // Before the event: status pill says "active"
      expect(screen.getAllByText('active').length).toBeGreaterThan(0);

      act(() => {
        capturedOnMessage?.({
          kind: 'system.federation.status_change',
          payload: { federation_peer_id: 'peer-active-1', status: 'degraded' },
          emitted_at: new Date().toISOString(),
        });
      });

      // After the event: a "degraded" text should appear (status pill or tally)
      await waitFor(() => {
        expect(screen.getAllByText('degraded').length).toBeGreaterThan(0);
      });
      // And the "active" pill should be gone (replaced by degraded)
      // The stats bar "active" label still exists, but the STATUS PILL text
      // should now show "degraded" not "active".
      const row = screen.getByTestId('liveness-row-peer-active-1');
      expect(row.textContent).toContain('degraded');
    });

    it('does not mark a non-existent peer as live', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      act(() => {
        capturedOnMessage?.({
          kind: 'system.federation.heartbeat',
          payload: { federation_peer_id: 'peer-unknown-999' },
          emitted_at: new Date().toISOString(),
        });
      });

      // Pulse dot should NOT appear — no matching peer
      expect(screen.queryByTitle('Live event received this session')).not.toBeInTheDocument();
    });

    it('accepts events with any federation-containing kind', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      act(() => {
        capturedOnMessage?.({
          kind: 'decision.federation.approved',
          payload: { federation_peer_id: 'peer-active-1' },
          emitted_at: new Date().toISOString(),
        });
      });

      await waitFor(() => {
        expect(screen.getByTitle('Live event received this session')).toBeInTheDocument();
      });
    });

    // ── Current broadcast contract ────────────────────────────────────────────
    // System::FederationPeer#broadcast_peer_state! (server/app/models/system/
    // federation_peer.rb) stamps `federation_peer_id` — NOT platform_peer_id /
    // peer_id / remote_instance_url — plus peer_kind/status/previous_status/
    // last_heartbeat_at/reason, under kind "federation.peer.<status|heartbeat>".
    // These payloads mirror that emitter literally; the legacy-key tests above
    // are the positive twins proving older payload shapes still attribute.

    it('attributes a HEAD-shaped broadcast_peer_state! status event (federation_peer_id) to the right row', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      act(() => {
        capturedOnMessage?.({
          kind: 'federation.peer.degraded',
          payload: {
            federation_peer_id: 'peer-active-1',
            peer_kind: 'platform',
            status: 'degraded',
            previous_status: 'active',
            last_heartbeat_at: new Date(Date.now() - 5_000).toISOString(),
          },
          emitted_at: new Date().toISOString(),
        });
      });

      // Row is attributed: live pulse appears AND the status pill flips.
      await waitFor(() => {
        expect(screen.getByTitle('Live event received this session')).toBeInTheDocument();
      });
      expect(screen.getByTestId('liveness-row-peer-active-1').textContent).toContain('degraded');
    });

    it('bumps the row live on a HEAD-shaped federation.peer.heartbeat event (federation_peer_id)', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      act(() => {
        capturedOnMessage?.({
          kind: 'federation.peer.heartbeat',
          payload: {
            federation_peer_id: 'peer-active-1',
            peer_kind: 'platform',
            status: 'active',
            last_heartbeat_at: new Date().toISOString(),
          },
          emitted_at: new Date().toISOString(),
        });
      });

      await waitFor(() => {
        expect(screen.getByTitle('Live event received this session')).toBeInTheDocument();
      });
    });

    it('does not attribute a federation_peer_id event to a non-matching row', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      act(() => {
        capturedOnMessage?.({
          kind: 'federation.peer.revoked',
          payload: {
            federation_peer_id: 'peer-unknown-999',
            peer_kind: 'platform',
            status: 'revoked',
            reason: 'operator revoked',
          },
          emitted_at: new Date().toISOString(),
        });
      });

      expect(screen.queryByTitle('Live event received this session')).not.toBeInTheDocument();
    });

    it('accepts events with a "peer" substring in the kind', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      act(() => {
        capturedOnMessage?.({
          kind: 'system.peer.check',
          payload: { federation_peer_id: 'peer-active-1' },
          emitted_at: new Date().toISOString(),
        });
      });

      await waitFor(() => {
        expect(screen.getByTitle('Live event received this session')).toBeInTheDocument();
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Stale heartbeat rendering
  // ---------------------------------------------------------------------------

  describe('stale heartbeat rendering', () => {
    it('renders "stale" text for a peer whose heartbeat is older than 90 s', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_STALE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-stale-3')).toBeInTheDocument(),
      );

      expect(screen.getByText('stale')).toBeInTheDocument();
    });

    it('does not render "stale" text for a peer with a fresh heartbeat', async () => {
      mockGet.mockResolvedValue(peersListEnvelope([PEER_ACTIVE]));

      renderMonitor();

      await waitFor(() =>
        expect(screen.getByTestId('liveness-row-peer-active-1')).toBeInTheDocument(),
      );

      expect(screen.queryByText('stale')).not.toBeInTheDocument();
    });
  });
});
