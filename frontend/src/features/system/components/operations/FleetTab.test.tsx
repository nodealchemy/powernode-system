import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { FleetTab } from './FleetTab';
import { FleetDashboardPage } from '@system/features/system/components/fleet/FleetDashboardPage';

// =============================================================================
// Shared mock fns
// =============================================================================

const mockPost = jest.fn();
const mockGet = jest.fn();
const mockAddNotification = jest.fn();

// hasPermission is reconfigured per-test for the FleetTab gate tests.
let mockHasPermission = jest.fn(() => true);

// wsManager.subscribe — capture the onMessage/onError callbacks so tests
// can push synthetic fleet events and error signals.
let capturedOnMessage: ((data: unknown) => void) | null = null;
let capturedOnError: ((err: string) => void) | null = null;

// Use jest.fn() with a persistent implementation so mockClear() doesn't
// wipe it. The implementation captures callbacks and always returns a
// function so React's cleanup doesn't throw.
const mockWsSubscribe = jest.fn();
const wsSubscribeImpl = (sub: { onMessage?: (data: unknown) => void; onError?: (err: string) => void }) => {
  capturedOnMessage = sub.onMessage ?? null;
  capturedOnError = sub.onError ?? null;
  return () => undefined; // unsubscribe function — must be a function, not a jest.fn() that may be cleared
};

// =============================================================================
// Module mocks
// =============================================================================

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: jest.fn(),
    delete: jest.fn(),
  },
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: (...args: unknown[]) => mockHasPermission(...args) }),
}));

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

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

jest.mock('@/shared/hooks/useAuth', () => ({
  useAuth: () => ({ currentUser: { account: { id: 'acct-test' } } }),
}));

jest.mock('@/shared/services/WebSocketManager', () => ({
  wsManager: {
    subscribe: (...args: unknown[]) => mockWsSubscribe(...args),
  },
}));

// Child tiles — stub them to prevent their own API calls from interfering.
jest.mock('@system/features/system/components/fleet/HoneypotCanaryTile', () => ({
  HoneypotCanaryTile: () => <div data-testid="honeypot-tile">HoneypotCanaryTile</div>,
}));

jest.mock('@system/features/system/components/fleet/DispatchLatencyTile', () => ({
  DispatchLatencyTile: () => <div data-testid="dispatch-tile">DispatchLatencyTile</div>,
}));

jest.mock('@system/features/system/components/fleet/AttributionFeedbackButton', () => ({
  AttributionFeedbackButton: () => <div data-testid="attribution-btn">AttributionFeedbackButton</div>,
}));

jest.mock('@system/features/system/components/fleet/boot-replay/BootReplayModal', () => ({
  BootReplayModal: ({ instanceId, onClose }: { instanceId: string | null; onClose: () => void }) =>
    instanceId ? (
      <div data-testid="boot-replay-modal">
        Boot Replay Modal — {instanceId}
        <button onClick={onClose}>close</button>
      </div>
    ) : null,
}));

// =============================================================================
// Fixtures + helpers
// =============================================================================

/** Wrap an API payload in the double-envelope AxiosResponse shape. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function makeEvent(overrides: Partial<{
  id: string;
  kind: string;
  severity: 'low' | 'medium' | 'high' | 'critical';
  emitted_at: string;
  source: string | null;
  correlation_id: string | null;
  node_id: string | null;
  node_instance_id: string | null;
  node_module_id: string | null;
  payload: Record<string, unknown>;
}> = {}) {
  return {
    id: overrides.id ?? 'evt-1',
    account_id: 'acct-test',
    kind: overrides.kind ?? 'system.test_event',
    severity: overrides.severity ?? 'low',
    payload: overrides.payload ?? {},
    correlation_id: overrides.correlation_id ?? null,
    source: overrides.source ?? null,
    emitted_at: overrides.emitted_at ?? new Date().toISOString(),
    node_id: overrides.node_id ?? null,
    node_instance_id: overrides.node_instance_id ?? null,
    node_module_id: overrides.node_module_id ?? null,
  };
}

function signalsResponse(events: ReturnType<typeof makeEvent>[]) {
  return envelope({ events, count: events.length, channel: 'SystemFleetChannel' });
}

const renderFleetTab = () =>
  render(
    <BrowserRouter>
      <FleetTab />
    </BrowserRouter>,
  );

const renderDashboard = () =>
  render(
    <BrowserRouter>
      <FleetDashboardPage />
    </BrowserRouter>,
  );

// =============================================================================
// FleetTab — permission gate
// =============================================================================

describe('FleetTab', () => {
  beforeEach(() => {
    mockHasPermission = jest.fn(() => true);
    mockPost.mockReset();
    mockGet.mockReset();
    mockAddNotification.mockReset();
    capturedOnMessage = null;
    capturedOnError = null;
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
    // Default: backlog returns empty events so FleetDashboardPage renders without noise.
    mockPost.mockResolvedValue(signalsResponse([]));
  });

  it('renders the permission-denied message when system.fleet.autonomy is absent', () => {
    mockHasPermission = jest.fn(() => false);
    renderFleetTab();

    expect(
      screen.getByText(/You don.t have permission to view the fleet dashboard/),
    ).toBeInTheDocument();
    expect(screen.getByText('system.fleet.autonomy')).toBeInTheDocument();
  });

  it('does NOT render the denied message when the permission is present', async () => {
    mockHasPermission = jest.fn(() => true);
    renderFleetTab();

    expect(
      screen.queryByText(/You don.t have permission to view the fleet dashboard/),
    ).not.toBeInTheDocument();
  });

  it('gates on the exact permission string "system.fleet.autonomy"', () => {
    mockHasPermission = jest.fn((perm: string) => perm === 'system.fleet.autonomy');
    renderFleetTab();
    // FleetDashboardPage header should render (not the denied message)
    expect(
      screen.queryByText(/You don.t have permission to view the fleet dashboard/),
    ).not.toBeInTheDocument();
    expect(mockHasPermission).toHaveBeenCalledWith('system.fleet.autonomy');
  });
});

// =============================================================================
// FleetDashboardPage — initial load + loading / error states
// =============================================================================

describe('FleetDashboardPage — initial render', () => {
  beforeEach(() => {
    mockHasPermission = jest.fn(() => true);
    mockPost.mockReset();
    mockGet.mockReset();
    mockAddNotification.mockReset();
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
    capturedOnMessage = null;
    capturedOnError = null;
  });

  it('renders the Fleet Dashboard heading', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    expect(screen.getByText('Fleet Dashboard')).toBeInTheDocument();
  });

  it('fetches the initial backlog from POST /system/fleet/signals', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/fleet/signals', { limit: 100, kind: undefined }),
    );
  });

  it('shows "No events yet." when the backlog is empty', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('No events yet.')).toBeInTheDocument());
  });

  it('renders events returned from the backlog fetch', async () => {
    const ev = makeEvent({ id: 'e-1', kind: 'system.module_published', severity: 'medium', source: 'fleet-auto' });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.module_published')).toBeInTheDocument());
    expect(screen.getByText('source: fleet-auto')).toBeInTheDocument();
  });

  it('adds an error notification when the backlog fetch fails', async () => {
    mockPost.mockRejectedValue(new Error('network error'));
    renderDashboard();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load fleet events',
      }),
    );
  });

  it('subscribes to SystemFleetChannel after mount', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() => {
      expect(mockWsSubscribe).toHaveBeenCalledWith(
        expect.objectContaining({
          channel: 'SystemFleetChannel',
          params: { account_id: 'acct-test' },
        }),
      );
    });
  });
});

// =============================================================================
// FleetDashboardPage — live WebSocket events
// =============================================================================

describe('FleetDashboardPage — WebSocket live events', () => {
  beforeEach(() => {
    mockPost.mockResolvedValue(signalsResponse([]));
    mockAddNotification.mockReset();
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
    capturedOnMessage = null;
    capturedOnError = null;
  });

  it('prepends a live event to the feed when the WS channel pushes it', async () => {
    renderDashboard();

    // Wait for subscription to be set up
    await waitFor(() => expect(capturedOnMessage).not.toBeNull());

    const liveEvent = makeEvent({ id: 'live-1', kind: 'system.drift_detected', severity: 'high' });

    act(() => {
      capturedOnMessage!(liveEvent);
    });

    await waitFor(() => expect(screen.getByText('system.drift_detected')).toBeInTheDocument());
  });

  it('ignores WS messages with type "connection_established"', async () => {
    renderDashboard();
    await waitFor(() => expect(capturedOnMessage).not.toBeNull());

    act(() => {
      capturedOnMessage!({ type: 'connection_established' });
    });

    // Only the "No events yet" placeholder should be present; no extra rows
    await waitFor(() => expect(screen.getByText('No events yet.')).toBeInTheDocument());
  });

  it('ignores WS messages with type "pong"', async () => {
    renderDashboard();
    await waitFor(() => expect(capturedOnMessage).not.toBeNull());

    act(() => {
      capturedOnMessage!({ type: 'pong' });
    });

    await waitFor(() => expect(screen.getByText('No events yet.')).toBeInTheDocument());
  });

  it('ignores WS messages that are missing required fields', async () => {
    renderDashboard();
    await waitFor(() => expect(capturedOnMessage).not.toBeNull());

    // Missing 'severity'
    act(() => {
      capturedOnMessage!({ id: 'x', kind: 'system.something' });
    });

    await waitFor(() => expect(screen.getByText('No events yet.')).toBeInTheDocument());
  });

  it('shows a warning notification when the WS channel reports an error', async () => {
    renderDashboard();
    await waitFor(() => expect(capturedOnError).not.toBeNull());

    act(() => {
      capturedOnError!('disconnected');
    });

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'warning',
        message: 'Fleet channel error: disconnected',
      }),
    );
  });
});

// =============================================================================
// FleetDashboardPage — filter chips
// =============================================================================

describe('FleetDashboardPage — filter chips', () => {
  const EVENTS = [
    makeEvent({ id: 'e-decision', kind: 'decision.autonomy_approved', severity: 'low' }),
    makeEvent({ id: 'e-module', kind: 'system.module_publish_started', severity: 'medium' }),
    makeEvent({ id: 'e-pressure', kind: 'system.pressure_detected', severity: 'high' }),
    makeEvent({ id: 'e-honeypot', kind: 'honeypot.triggered', severity: 'critical' }),
  ];

  beforeEach(() => {
    mockPost.mockResolvedValue(signalsResponse(EVENTS));
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
  });

  it('renders all quick-kind filter chips', async () => {
    renderDashboard();
    await waitFor(() => expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument());

    expect(screen.getByRole('button', { name: 'All' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Module publish' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Honeypot' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Capacity / pressure' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Decisions' })).toBeInTheDocument();
  });

  it('clicking a kind chip filters the event list', async () => {
    renderDashboard();
    await waitFor(() => expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Decisions' }));

    await waitFor(() => expect(screen.queryByText('system.module_publish_started')).not.toBeInTheDocument());
    expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument();
  });

  it('clicking "All" chip shows all events again after a filter', async () => {
    renderDashboard();
    await waitFor(() => expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Decisions' }));
    await waitFor(() => expect(screen.queryByText('system.module_publish_started')).not.toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'All' }));
    await waitFor(() => expect(screen.getByText('system.module_publish_started')).toBeInTheDocument());
  });

  it('renders severity filter chips (all, low, medium, high, critical)', async () => {
    renderDashboard();
    await waitFor(() => expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument());

    for (const sev of ['all', 'low', 'medium', 'high', 'critical']) {
      expect(screen.getByRole('button', { name: sev })).toBeInTheDocument();
    }
  });

  it('clicking a min-severity chip hides events below the threshold', async () => {
    renderDashboard();
    await waitFor(() => expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument());

    // Set min severity to "critical" → only the honeypot event qualifies
    fireEvent.click(screen.getByRole('button', { name: 'critical' }));

    await waitFor(() => expect(screen.queryByText('decision.autonomy_approved')).not.toBeInTheDocument());
    await waitFor(() => expect(screen.queryByText('system.module_publish_started')).not.toBeInTheDocument());
    await waitFor(() => expect(screen.queryByText('system.pressure_detected')).not.toBeInTheDocument());
    expect(screen.getByText('honeypot.triggered')).toBeInTheDocument();
  });

  it('free-text kind input filters events by substring', async () => {
    renderDashboard();
    await waitFor(() => expect(screen.getByText('honeypot.triggered')).toBeInTheDocument());

    const input = screen.getByPlaceholderText('Filter kind…');
    fireEvent.change(input, { target: { value: 'pressure' } });

    await waitFor(() => expect(screen.queryByText('decision.autonomy_approved')).not.toBeInTheDocument());
    expect(screen.getByText('system.pressure_detected')).toBeInTheDocument();
  });

  it('Refresh button re-fetches the backlog', async () => {
    mockPost.mockResolvedValueOnce(signalsResponse(EVENTS));
    mockPost.mockResolvedValueOnce(signalsResponse([]));

    renderDashboard();
    await waitFor(() => expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));

    await waitFor(() => expect(screen.getByText('No events yet.')).toBeInTheDocument());
    expect(mockPost).toHaveBeenCalledTimes(2);
  });
});

// =============================================================================
// FleetDashboardPage — counter tiles
// =============================================================================

describe('FleetDashboardPage — counter tiles', () => {
  beforeEach(() => {
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
  });

  it('renders counter labels', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('Signals (5m)')).toBeInTheDocument());
    expect(screen.getByText('Decisions (5m)')).toBeInTheDocument();
    expect(screen.getByText('High/Critical (5m)')).toBeInTheDocument();
    expect(screen.getByText(/Buffer/)).toBeInTheDocument();
  });

  it('shows buffer size as events/MAX in the counter', async () => {
    const events = [makeEvent({ id: 'e-1', kind: 'system.x' })];
    mockPost.mockResolvedValue(signalsResponse(events));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('1/200')).toBeInTheDocument());
  });

  it('renders the HoneypotCanaryTile stub', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();
    await waitFor(() => expect(screen.getByTestId('honeypot-tile')).toBeInTheDocument());
  });

  it('renders the DispatchLatencyTile stub', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();
    await waitFor(() => expect(screen.getByTestId('dispatch-tile')).toBeInTheDocument());
  });
});

// =============================================================================
// FleetDashboardPage — event detail panel
// =============================================================================

describe('FleetDashboardPage — event detail panel', () => {
  beforeEach(() => {
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
  });

  it('shows the prompt message when no event is selected', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() =>
      expect(
        screen.getByText('Click an event to view its details + correlation chain.'),
      ).toBeInTheDocument(),
    );
  });

  it('shows event detail when an event row is clicked', async () => {
    const ev = makeEvent({
      id: 'evt-detail',
      kind: 'system.cert_rotated',
      severity: 'low',
      source: 'cert-service',
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.cert_rotated')).toBeInTheDocument());

    // Click the event row — the list renders one item with the kind text
    fireEvent.click(screen.getByText('system.cert_rotated'));

    await waitFor(() =>
      // Detail panel should now show event fields — "source: cert-service" appears in
      // both the event list row (span) and detail panel (div), so use getAllByText
      expect(screen.getAllByText('source: cert-service').length).toBeGreaterThanOrEqual(1),
    );
  });

  it('shows event id and emitted_at in the detail panel', async () => {
    const ev = makeEvent({
      id: 'evt-abc123',
      kind: 'decision.approve',
      severity: 'medium',
      emitted_at: '2026-06-01T10:00:00.000Z',
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('decision.approve')).toBeInTheDocument());
    fireEvent.click(screen.getByText('decision.approve'));

    await waitFor(() => expect(screen.getByText('evt-abc123')).toBeInTheDocument());
  });

  it('shows the "clear" button after selecting an event and clears on click', async () => {
    const ev = makeEvent({ id: 'e-clear', kind: 'system.clear_test' });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.clear_test')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.clear_test'));

    await waitFor(() => expect(screen.getByText('clear')).toBeInTheDocument());

    fireEvent.click(screen.getByText('clear'));

    await waitFor(() =>
      expect(
        screen.getByText('Click an event to view its details + correlation chain.'),
      ).toBeInTheDocument(),
    );
  });

  it('shows payload as JSON in a details element when non-empty', async () => {
    const ev = makeEvent({
      id: 'e-payload',
      kind: 'system.payload_event',
      payload: { module: 'nginx', version: '1.25' },
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.payload_event')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.payload_event'));

    await waitFor(() => expect(screen.getByText(/"module": "nginx"/)).toBeInTheDocument());
  });

  it('shows correlation_id in the detail panel when present', async () => {
    const ev = makeEvent({
      id: 'e-corr',
      kind: 'decision.route',
      correlation_id: 'corr-xyz-789',
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('decision.route')).toBeInTheDocument());
    fireEvent.click(screen.getByText('decision.route'));

    await waitFor(() => expect(screen.getByText('corr-xyz-789')).toBeInTheDocument());
  });

  it('renders the AttributionFeedbackButton stub when event has node_instance_id and node_module_id', async () => {
    const ev = makeEvent({
      id: 'e-attr',
      kind: 'system.attribution_event',
      node_instance_id: 'inst-1',
      node_module_id: 'mod-1',
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.attribution_event')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.attribution_event'));

    await waitFor(() => expect(screen.getByTestId('attribution-btn')).toBeInTheDocument());
  });
});

// =============================================================================
// FleetDashboardPage — Boot Replay modal
// =============================================================================

describe('FleetDashboardPage — Boot Replay modal', () => {
  beforeEach(() => {
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
  });

  it('opens the BootReplayModal when "Boot Replay" is clicked on an event with node_instance_id', async () => {
    const ev = makeEvent({
      id: 'e-replay',
      kind: 'system.boot_complete',
      node_instance_id: 'inst-boot-123',
      correlation_id: 'corr-replay-456',
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.boot_complete')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.boot_complete'));

    await waitFor(() => expect(screen.getByText('Boot Replay')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Boot Replay'));

    await waitFor(() =>
      expect(screen.getByTestId('boot-replay-modal')).toBeInTheDocument(),
    );
    // inst-boot-123 appears in the detail panel code element AND the modal text
    expect(screen.getAllByText(/inst-boot-123/).length).toBeGreaterThanOrEqual(1);
  });

  it('does NOT show the Boot Replay button for events without node_instance_id', async () => {
    const ev = makeEvent({
      id: 'e-no-replay',
      kind: 'system.no_instance',
      node_instance_id: null,
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.no_instance')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.no_instance'));

    await waitFor(() => expect(screen.getByText('clear')).toBeInTheDocument());
    expect(screen.queryByText('Boot Replay')).not.toBeInTheDocument();
  });

  it('closes the modal when the close button is clicked', async () => {
    const ev = makeEvent({
      id: 'e-close',
      kind: 'system.boot_event',
      node_instance_id: 'inst-close-789',
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.boot_event')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.boot_event'));
    await waitFor(() => expect(screen.getByText('Boot Replay')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Boot Replay'));
    await waitFor(() => expect(screen.getByTestId('boot-replay-modal')).toBeInTheDocument());

    fireEvent.click(screen.getByText('close'));
    await waitFor(() => expect(screen.queryByTestId('boot-replay-modal')).not.toBeInTheDocument());
  });
});

// =============================================================================
// FleetDashboardPage — correlation chain panel
// =============================================================================

describe('FleetDashboardPage — correlation chain panel', () => {
  beforeEach(() => {
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
  });

  it('shows the correlation chain section when a correlated event is selected', async () => {
    const events = [
      makeEvent({ id: 'e-a', kind: 'decision.start', severity: 'low', correlation_id: 'corr-111', emitted_at: '2026-06-01T10:00:00Z' }),
      makeEvent({ id: 'e-b', kind: 'decision.end', severity: 'medium', correlation_id: 'corr-111', emitted_at: '2026-06-01T10:00:05Z' }),
      makeEvent({ id: 'e-c', kind: 'system.unrelated', severity: 'low', correlation_id: null }),
    ];
    mockPost.mockResolvedValue(signalsResponse(events));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('decision.start')).toBeInTheDocument());
    fireEvent.click(screen.getByText('decision.start'));

    await waitFor(() => expect(screen.getByText(/Correlation Chain/)).toBeInTheDocument());
    // decision.end appears in both the event feed list AND the correlation chain list
    expect(screen.getAllByText('decision.end').length).toBeGreaterThanOrEqual(1);
  });

  it('does NOT show correlation chain section when selected event has no correlation_id', async () => {
    const ev = makeEvent({ id: 'e-nocorr', kind: 'system.no_corr', correlation_id: null });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.no_corr')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.no_corr'));

    await waitFor(() => expect(screen.getByText('clear')).toBeInTheDocument());
    expect(screen.queryByText(/Correlation Chain/)).not.toBeInTheDocument();
  });

  it('shows correlation chain header with count even when only the selected event is in the chain', async () => {
    // A solo event with a correlation_id: the chain contains just itself (count=1).
    // The component shows "Correlation Chain (1)" — NOT the "No other events" message,
    // because correlationEvents always includes the selected event itself.
    const ev = makeEvent({ id: 'e-solo', kind: 'decision.solo', correlation_id: 'corr-solo' });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('decision.solo')).toBeInTheDocument());
    fireEvent.click(screen.getByText('decision.solo'));

    await waitFor(() => expect(screen.getByText(/Correlation Chain \(1\)/)).toBeInTheDocument());
  });
});

// =============================================================================
// FleetDashboardPage — module link rendering
// =============================================================================

describe('FleetDashboardPage — module links', () => {
  beforeEach(() => {
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
  });

  it('renders a module link when event has node_module_id', async () => {
    const ev = makeEvent({
      id: 'e-mod',
      kind: 'system.module_published',
      node_module_id: 'mod-abc',
      payload: { module_name: 'nginx-module' },
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('nginx-module')).toBeInTheDocument());
    const link = screen.getByRole('link', { name: /nginx-module/ });
    expect(link).toHaveAttribute('href', '/app/system/modules?module_id=mod-abc');
  });

  it('falls back to "view module" text when payload has no module_name', async () => {
    const ev = makeEvent({
      id: 'e-mod-fallback',
      kind: 'system.module_published',
      node_module_id: 'mod-xyz',
      payload: {},
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByRole('link', { name: /view module/ })).toBeInTheDocument());
  });
});
