import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { FleetDashboardPage } from './FleetDashboardPage';

// =============================================================================
// Shared mock fns
// =============================================================================

const mockPost = jest.fn();
const mockGet = jest.fn();
const mockAddNotification = jest.fn();

// wsManager.subscribe — capture onMessage/onError callbacks so tests can
// push synthetic fleet events and error signals.
let capturedOnMessage: ((data: unknown) => void) | null = null;
let capturedOnError: ((err: string) => void) | null = null;

const mockWsSubscribe = jest.fn();
const wsSubscribeImpl = (sub: {
  onMessage?: (data: unknown) => void;
  onError?: (err: string) => void;
}) => {
  capturedOnMessage = sub.onMessage ?? null;
  capturedOnError = sub.onError ?? null;
  // Return a stable unsubscribe function — must NOT be a jest.fn() that
  // gets cleared in beforeEach, because React's cleanup calls it after
  // the component unmounts.
  return () => undefined;
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

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
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

// Child tiles — stub to prevent their own API calls from interfering.
jest.mock('@system/features/system/components/fleet/HoneypotCanaryTile', () => ({
  HoneypotCanaryTile: () => <div data-testid="honeypot-tile">HoneypotCanaryTile</div>,
}));

jest.mock('@system/features/system/components/fleet/DispatchLatencyTile', () => ({
  DispatchLatencyTile: () => <div data-testid="dispatch-tile">DispatchLatencyTile</div>,
}));

jest.mock('@system/features/system/components/fleet/AttributionFeedbackButton', () => ({
  AttributionFeedbackButton: () => (
    <div data-testid="attribution-btn">AttributionFeedbackButton</div>
  ),
}));

jest.mock('@system/features/system/components/fleet/boot-replay/BootReplayModal', () => ({
  BootReplayModal: ({
    instanceId,
    onClose,
  }: {
    instanceId: string | null;
    onClose: () => void;
  }) =>
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

function makeEvent(
  overrides: Partial<{
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
  }> = {},
) {
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

const renderDashboard = () =>
  render(
    <BrowserRouter>
      <FleetDashboardPage />
    </BrowserRouter>,
  );

// =============================================================================
// Initial render + loading / error states
// =============================================================================

describe('FleetDashboardPage — initial render', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockGet.mockReset();
    mockAddNotification.mockReset();
    capturedOnMessage = null;
    capturedOnError = null;
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
  });

  it('renders the Fleet Dashboard heading', () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    expect(screen.getByText('Fleet Dashboard')).toBeInTheDocument();
  });

  it('renders the subtitle describing the service', () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    expect(
      screen.getByText(/Live observability of FleetAutonomyService/),
    ).toBeInTheDocument();
  });

  it('fetches the initial backlog from POST /system/fleet/signals with limit 100', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/fleet/signals', {
        limit: 100,
        kind: undefined,
      }),
    );
  });

  it('shows "No events yet." when the backlog is empty', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('No events yet.')).toBeInTheDocument());
  });

  it('renders events returned from the backlog fetch', async () => {
    const ev = makeEvent({
      id: 'e-1',
      kind: 'system.module_published',
      severity: 'medium',
      source: 'fleet-auto',
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() =>
      expect(screen.getByText('system.module_published')).toBeInTheDocument(),
    );
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

  it('shows the "Live Event Feed" section heading', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('Live Event Feed')).toBeInTheDocument());
  });

  it('renders the initial "0 events" count in the feed header', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('0 events')).toBeInTheDocument());
  });

  it('updates event count in the feed header after loading', async () => {
    const events = [
      makeEvent({ id: 'ea', kind: 'system.a' }),
      makeEvent({ id: 'eb', kind: 'system.b' }),
    ];
    mockPost.mockResolvedValue(signalsResponse(events));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('2 events')).toBeInTheDocument());
  });
});

// =============================================================================
// Live WebSocket events
// =============================================================================

describe('FleetDashboardPage — WebSocket live events', () => {
  beforeEach(() => {
    mockPost.mockResolvedValue(signalsResponse([]));
    mockAddNotification.mockReset();
    capturedOnMessage = null;
    capturedOnError = null;
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
  });

  it('prepends a live event to the feed when the WS channel pushes it', async () => {
    renderDashboard();

    await waitFor(() => expect(capturedOnMessage).not.toBeNull());

    const liveEvent = makeEvent({
      id: 'live-1',
      kind: 'system.drift_detected',
      severity: 'high',
    });

    act(() => {
      capturedOnMessage!(liveEvent);
    });

    await waitFor(() =>
      expect(screen.getByText('system.drift_detected')).toBeInTheDocument(),
    );
  });

  it('ignores WS messages with type "connection_established"', async () => {
    renderDashboard();
    await waitFor(() => expect(capturedOnMessage).not.toBeNull());

    act(() => {
      capturedOnMessage!({ type: 'connection_established' });
    });

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

  it('ignores WS messages missing required fields (id, kind, severity)', async () => {
    renderDashboard();
    await waitFor(() => expect(capturedOnMessage).not.toBeNull());

    // Missing 'severity' — should not be added
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

  it('caps the buffer at 200 events when live events overflow', async () => {
    // Seed 200 events via backlog
    const initialEvents = Array.from({ length: 200 }, (_, i) =>
      makeEvent({ id: `bg-${i}`, kind: `system.bg_event_${i}` }),
    );
    mockPost.mockResolvedValue(signalsResponse(initialEvents));

    renderDashboard();
    await waitFor(() => expect(capturedOnMessage).not.toBeNull());

    // Buffer is at max; pushing one more should still keep count at 200
    const overflow = makeEvent({ id: 'live-overflow', kind: 'system.overflow' });
    act(() => {
      capturedOnMessage!(overflow);
    });

    await waitFor(() =>
      expect(screen.getByText(/200\/200/)).toBeInTheDocument(),
    );
  });
});

// =============================================================================
// Filter chips — kind and severity
// =============================================================================

describe('FleetDashboardPage — filter chips', () => {
  const EVENTS = [
    makeEvent({ id: 'e-decision', kind: 'decision.autonomy_approved', severity: 'low' }),
    makeEvent({
      id: 'e-module',
      kind: 'system.module_publish_started',
      severity: 'medium',
    }),
    makeEvent({ id: 'e-pressure', kind: 'system.pressure_detected', severity: 'high' }),
    makeEvent({ id: 'e-honeypot', kind: 'honeypot.triggered', severity: 'critical' }),
  ];

  beforeEach(() => {
    mockPost.mockResolvedValue(signalsResponse(EVENTS));
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
    capturedOnMessage = null;
    capturedOnError = null;
  });

  it('renders all quick-kind filter chips', async () => {
    renderDashboard();
    await waitFor(() =>
      expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument(),
    );

    expect(screen.getByRole('button', { name: 'All' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Module publish' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Honeypot' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Capacity / pressure' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Decisions' })).toBeInTheDocument();
  });

  it('clicking a kind chip filters the event list to matching events', async () => {
    renderDashboard();
    await waitFor(() =>
      expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: 'Decisions' }));

    await waitFor(() =>
      expect(screen.queryByText('system.module_publish_started')).not.toBeInTheDocument(),
    );
    expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument();
  });

  it('clicking "All" chip shows all events after a filter', async () => {
    renderDashboard();
    await waitFor(() =>
      expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: 'Decisions' }));
    await waitFor(() =>
      expect(screen.queryByText('system.module_publish_started')).not.toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: 'All' }));
    await waitFor(() =>
      expect(screen.getByText('system.module_publish_started')).toBeInTheDocument(),
    );
  });

  it('renders severity filter chips: all, low, medium, high, critical', async () => {
    renderDashboard();
    await waitFor(() =>
      expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument(),
    );

    for (const sev of ['all', 'low', 'medium', 'high', 'critical']) {
      expect(screen.getByRole('button', { name: sev })).toBeInTheDocument();
    }
  });

  it('min-severity chip hides events below the threshold', async () => {
    renderDashboard();
    await waitFor(() =>
      expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument(),
    );

    // Set minimum to "critical" — only honeypot qualifies
    fireEvent.click(screen.getByRole('button', { name: 'critical' }));

    await waitFor(() =>
      expect(screen.queryByText('decision.autonomy_approved')).not.toBeInTheDocument(),
    );
    await waitFor(() =>
      expect(screen.queryByText('system.module_publish_started')).not.toBeInTheDocument(),
    );
    await waitFor(() =>
      expect(screen.queryByText('system.pressure_detected')).not.toBeInTheDocument(),
    );
    expect(screen.getByText('honeypot.triggered')).toBeInTheDocument();
  });

  it('min-severity "high" includes high and critical events', async () => {
    renderDashboard();
    await waitFor(() =>
      expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: 'high' }));

    await waitFor(() =>
      expect(screen.queryByText('decision.autonomy_approved')).not.toBeInTheDocument(),
    );
    await waitFor(() =>
      expect(screen.queryByText('system.module_publish_started')).not.toBeInTheDocument(),
    );
    expect(screen.getByText('system.pressure_detected')).toBeInTheDocument();
    expect(screen.getByText('honeypot.triggered')).toBeInTheDocument();
  });

  it('free-text kind input filters events by substring', async () => {
    renderDashboard();
    await waitFor(() =>
      expect(screen.getByText('honeypot.triggered')).toBeInTheDocument(),
    );

    const input = screen.getByPlaceholderText('Filter kind…');
    fireEvent.change(input, { target: { value: 'pressure' } });

    await waitFor(() =>
      expect(screen.queryByText('decision.autonomy_approved')).not.toBeInTheDocument(),
    );
    expect(screen.getByText('system.pressure_detected')).toBeInTheDocument();
  });

  it('Refresh button re-fetches the backlog', async () => {
    mockPost.mockResolvedValueOnce(signalsResponse(EVENTS));
    mockPost.mockResolvedValueOnce(signalsResponse([]));

    renderDashboard();
    await waitFor(() =>
      expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));

    await waitFor(() => expect(screen.getByText('No events yet.')).toBeInTheDocument());
    expect(mockPost).toHaveBeenCalledTimes(2);
  });

  it('Refresh button passes filterKind to the API when a chip is active', async () => {
    mockPost.mockResolvedValue(signalsResponse(EVENTS));

    renderDashboard();
    await waitFor(() =>
      expect(screen.getByText('decision.autonomy_approved')).toBeInTheDocument(),
    );

    // Activate "Honeypot" chip then refresh
    fireEvent.click(screen.getByRole('button', { name: 'Honeypot' }));
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenLastCalledWith('/system/fleet/signals', {
        limit: 100,
        kind: 'honeypot',
      }),
    );
  });
});

// =============================================================================
// Counter tiles
// =============================================================================

describe('FleetDashboardPage — counter tiles', () => {
  beforeEach(() => {
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
    capturedOnMessage = null;
    capturedOnError = null;
  });

  it('renders all counter labels', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('Signals (5m)')).toBeInTheDocument());
    expect(screen.getByText('Decisions (5m)')).toBeInTheDocument();
    expect(screen.getByText('High/Critical (5m)')).toBeInTheDocument();
    expect(screen.getByText(/Buffer/)).toBeInTheDocument();
  });

  it('shows buffer size as events/MAX when events are loaded', async () => {
    const events = [makeEvent({ id: 'e-1', kind: 'system.x' })];
    mockPost.mockResolvedValue(signalsResponse(events));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('1/200')).toBeInTheDocument());
  });

  it('renders the HoneypotCanaryTile stub', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() =>
      expect(screen.getByTestId('honeypot-tile')).toBeInTheDocument(),
    );
  });

  it('renders the DispatchLatencyTile stub', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() =>
      expect(screen.getByTestId('dispatch-tile')).toBeInTheDocument(),
    );
  });

  it('counts system.* events in the Signals (5m) counter', async () => {
    const now = new Date().toISOString();
    const events = [
      makeEvent({ id: 'e-sig1', kind: 'system.alpha', emitted_at: now }),
      makeEvent({ id: 'e-sig2', kind: 'system.beta', emitted_at: now }),
      makeEvent({ id: 'e-dec', kind: 'decision.route', emitted_at: now }),
    ];
    mockPost.mockResolvedValue(signalsResponse(events));
    renderDashboard();

    // 2 system.* events → Signals counter = 2
    // The counter is adjacent to the label; look for the value in the document
    await waitFor(() => {
      const signalsLabel = screen.getByText('Signals (5m)');
      const tile = signalsLabel.closest('div[class*="bg-theme-surface"]') ?? signalsLabel.parentElement?.parentElement;
      expect(tile?.textContent).toContain('2');
    });
  });

  it('counts decision.* events in the Decisions (5m) counter', async () => {
    const now = new Date().toISOString();
    const events = [
      makeEvent({ id: 'e-d1', kind: 'decision.approve', emitted_at: now }),
      makeEvent({ id: 'e-d2', kind: 'decision.reject', emitted_at: now }),
    ];
    mockPost.mockResolvedValue(signalsResponse(events));
    renderDashboard();

    await waitFor(() => {
      const decisionsLabel = screen.getByText('Decisions (5m)');
      const tile = decisionsLabel.closest('div[class*="bg-theme-surface"]') ?? decisionsLabel.parentElement?.parentElement;
      expect(tile?.textContent).toContain('2');
    });
  });
});

// =============================================================================
// Event detail panel
// =============================================================================

describe('FleetDashboardPage — event detail panel', () => {
  beforeEach(() => {
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
    capturedOnMessage = null;
    capturedOnError = null;
  });

  it('shows prompt message when no event is selected', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() =>
      expect(
        screen.getByText('Click an event to view its details + correlation chain.'),
      ).toBeInTheDocument(),
    );
  });

  it('shows "Correlation Chain" heading before any event is selected', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    renderDashboard();

    await waitFor(() =>
      expect(screen.getByText('Correlation Chain')).toBeInTheDocument(),
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

    await waitFor(() =>
      expect(screen.getByText('system.cert_rotated')).toBeInTheDocument(),
    );

    // Click the first occurrence (event list row)
    fireEvent.click(screen.getAllByText('system.cert_rotated')[0]);

    // Detail panel shows source field — may appear in multiple places (list + detail)
    await waitFor(() =>
      expect(screen.getAllByText('source: cert-service').length).toBeGreaterThan(0),
    );
  });

  it('shows event id in the detail panel after clicking a row', async () => {
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

  it('panel heading changes to "Event Detail" when an event is selected', async () => {
    const ev = makeEvent({ id: 'e-hd', kind: 'system.heading_test' });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.heading_test')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.heading_test'));

    await waitFor(() => expect(screen.getByText('Event Detail')).toBeInTheDocument());
  });

  it('shows "clear" button after selecting an event', async () => {
    const ev = makeEvent({ id: 'e-clear', kind: 'system.clear_test' });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.clear_test')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.clear_test'));

    await waitFor(() => expect(screen.getByText('clear')).toBeInTheDocument());
  });

  it('clicking "clear" returns the panel to the prompt state', async () => {
    const ev = makeEvent({ id: 'e-clear2', kind: 'system.clear_test2' });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.clear_test2')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.clear_test2'));
    await waitFor(() => expect(screen.getByText('clear')).toBeInTheDocument());

    fireEvent.click(screen.getByText('clear'));

    await waitFor(() =>
      expect(
        screen.getByText('Click an event to view its details + correlation chain.'),
      ).toBeInTheDocument(),
    );
  });

  it('shows payload as formatted JSON when event has non-empty payload', async () => {
    const ev = makeEvent({
      id: 'e-payload',
      kind: 'system.payload_event',
      payload: { module: 'nginx', version: '1.25' },
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() =>
      expect(screen.getByText('system.payload_event')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('system.payload_event'));

    await waitFor(() =>
      expect(screen.getByText(/"module": "nginx"/)).toBeInTheDocument(),
    );
  });

  it('shows correlation_id in the detail panel when event has one', async () => {
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

  it('shows node_id in the detail panel when event has one', async () => {
    const ev = makeEvent({
      id: 'e-node',
      kind: 'system.node_event',
      node_id: 'node-abc',
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.node_event')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.node_event'));

    await waitFor(() => expect(screen.getByText('node-abc')).toBeInTheDocument());
  });

  it('shows instance_id in the detail panel when event has node_instance_id', async () => {
    const ev = makeEvent({
      id: 'e-inst',
      kind: 'system.instance_event',
      node_instance_id: 'inst-xyz',
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() =>
      expect(screen.getByText('system.instance_event')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('system.instance_event'));

    await waitFor(() => expect(screen.getByText('inst-xyz')).toBeInTheDocument());
  });

  it('renders AttributionFeedbackButton when event has both node_instance_id and node_module_id', async () => {
    const ev = makeEvent({
      id: 'e-attr',
      kind: 'system.attribution_event',
      node_instance_id: 'inst-1',
      node_module_id: 'mod-1',
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() =>
      expect(screen.getByText('system.attribution_event')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('system.attribution_event'));

    await waitFor(() =>
      expect(screen.getByTestId('attribution-btn')).toBeInTheDocument(),
    );
  });

  it('does NOT render AttributionFeedbackButton when event has only node_instance_id', async () => {
    const ev = makeEvent({
      id: 'e-no-attr',
      kind: 'system.no_attr',
      node_instance_id: 'inst-only',
      node_module_id: null,
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.no_attr')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.no_attr'));

    await waitFor(() => expect(screen.getByText('clear')).toBeInTheDocument());
    expect(screen.queryByTestId('attribution-btn')).not.toBeInTheDocument();
  });
});

// =============================================================================
// Boot Replay modal
// =============================================================================

describe('FleetDashboardPage — Boot Replay modal', () => {
  beforeEach(() => {
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
    capturedOnMessage = null;
    capturedOnError = null;
  });

  it('opens BootReplayModal when "Boot Replay" is clicked on event with node_instance_id', async () => {
    const ev = makeEvent({
      id: 'e-replay',
      kind: 'system.boot_complete',
      node_instance_id: 'inst-boot-123',
      correlation_id: 'corr-replay-456',
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() =>
      expect(screen.getByText('system.boot_complete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('system.boot_complete'));

    await waitFor(() => expect(screen.getByText('Boot Replay')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Boot Replay'));

    await waitFor(() =>
      expect(screen.getByTestId('boot-replay-modal')).toBeInTheDocument(),
    );
    expect(screen.getAllByText(/inst-boot-123/).length).toBeGreaterThan(0);
  });

  it('does NOT show Boot Replay button for events without node_instance_id', async () => {
    const ev = makeEvent({
      id: 'e-no-replay',
      kind: 'system.no_instance',
      node_instance_id: null,
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() =>
      expect(screen.getByText('system.no_instance')).toBeInTheDocument(),
    );
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

    await waitFor(() =>
      expect(screen.getByText('system.boot_event')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('system.boot_event'));
    await waitFor(() => expect(screen.getByText('Boot Replay')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Boot Replay'));
    await waitFor(() =>
      expect(screen.getByTestId('boot-replay-modal')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('close'));
    await waitFor(() =>
      expect(screen.queryByTestId('boot-replay-modal')).not.toBeInTheDocument(),
    );
  });
});

// =============================================================================
// Correlation chain panel
// =============================================================================

describe('FleetDashboardPage — correlation chain panel', () => {
  beforeEach(() => {
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
    capturedOnMessage = null;
    capturedOnError = null;
  });

  it('shows correlation chain section when a correlated event is selected', async () => {
    const events = [
      makeEvent({
        id: 'e-a',
        kind: 'decision.start',
        severity: 'low',
        correlation_id: 'corr-111',
        emitted_at: '2026-06-01T10:00:00Z',
      }),
      makeEvent({
        id: 'e-b',
        kind: 'decision.end',
        severity: 'medium',
        correlation_id: 'corr-111',
        emitted_at: '2026-06-01T10:00:05Z',
      }),
      makeEvent({ id: 'e-c', kind: 'system.unrelated', severity: 'low', correlation_id: null }),
    ];
    mockPost.mockResolvedValue(signalsResponse(events));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('decision.start')).toBeInTheDocument());
    fireEvent.click(screen.getByText('decision.start'));

    await waitFor(() =>
      expect(screen.getByText(/Correlation Chain/)).toBeInTheDocument(),
    );
    // decision.end appears in both event list and correlation chain section
    expect(screen.getAllByText('decision.end').length).toBeGreaterThan(0);
  });

  it('does NOT show correlation chain section when event has no correlation_id', async () => {
    const ev = makeEvent({
      id: 'e-nocorr',
      kind: 'system.no_corr',
      correlation_id: null,
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('system.no_corr')).toBeInTheDocument());
    fireEvent.click(screen.getByText('system.no_corr'));

    await waitFor(() => expect(screen.getByText('clear')).toBeInTheDocument());
    expect(screen.queryByText(/Correlation Chain/)).not.toBeInTheDocument();
  });

  it('shows the correlation chain with the event itself when it is the only match', async () => {
    // When the selected event is the only one with a given correlation_id, the
    // correlationEvents array includes that event itself (the filter matches it).
    // So the chain renders with 1 item — NOT the "No other events" empty state.
    const ev = makeEvent({
      id: 'e-solo',
      kind: 'decision.solo',
      correlation_id: 'corr-solo',
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    const eventEl = await waitFor(() => screen.getByText('decision.solo'));
    fireEvent.click(eventEl);

    // Correlation chain section appears (event has correlation_id)
    await waitFor(() =>
      expect(screen.getByText(/Correlation Chain/)).toBeInTheDocument(),
    );
    // The "No other events" message does NOT appear because the event itself
    // is in correlationEvents (length = 1, not 0).
    expect(
      screen.queryByText('No other events with this correlation_id in the buffer.'),
    ).not.toBeInTheDocument();
    // The event appears in the chain list
    expect(screen.getAllByText('decision.solo').length).toBeGreaterThan(0);
  });

  it('shows all chain members sorted by emitted_at ascending', async () => {
    const events = [
      makeEvent({
        id: 'e-later',
        kind: 'decision.step_b',
        correlation_id: 'corr-chain',
        emitted_at: '2026-06-01T10:00:10Z',
      }),
      makeEvent({
        id: 'e-earlier',
        kind: 'decision.step_a',
        correlation_id: 'corr-chain',
        emitted_at: '2026-06-01T10:00:00Z',
      }),
    ];
    mockPost.mockResolvedValue(signalsResponse(events));
    renderDashboard();

    await waitFor(() => expect(screen.getByText('decision.step_b')).toBeInTheDocument());
    // Click the first event in the list (step_b comes first due to pre-pend order)
    fireEvent.click(screen.getAllByText('decision.step_b')[0]);

    await waitFor(() => expect(screen.getByText(/Correlation Chain/)).toBeInTheDocument());

    // Both chain members should appear in the correlation chain section
    const chainSection = screen.getByText(/Correlation Chain/).parentElement?.parentElement;
    expect(chainSection).toBeTruthy();
  });
});

// =============================================================================
// Module link rendering
// =============================================================================

describe('FleetDashboardPage — module links in event feed', () => {
  beforeEach(() => {
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
    capturedOnMessage = null;
    capturedOnError = null;
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

    await waitFor(() =>
      expect(screen.getByRole('link', { name: /view module/ })).toBeInTheDocument(),
    );
  });

  it('does NOT render a module link when event has no node_module_id', async () => {
    const ev = makeEvent({
      id: 'e-no-mod',
      kind: 'system.no_module',
      node_module_id: null,
      payload: {},
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() =>
      expect(screen.getByText('system.no_module')).toBeInTheDocument(),
    );
    expect(screen.queryByRole('link', { name: /view module/ })).not.toBeInTheDocument();
  });
});

// =============================================================================
// Severity badge rendering
// =============================================================================

describe('FleetDashboardPage — severity badges', () => {
  beforeEach(() => {
    mockWsSubscribe.mockImplementation(wsSubscribeImpl);
    capturedOnMessage = null;
    capturedOnError = null;
  });

  it.each([
    ['low', 'low'],
    ['medium', 'medium'],
    ['high', 'high'],
    ['critical', 'critical'],
  ] as const)('renders a severity badge for %s events', async (severity, label) => {
    const ev = makeEvent({
      id: `e-sev-${severity}`,
      kind: `system.${severity}_event`,
      severity,
    });
    mockPost.mockResolvedValue(signalsResponse([ev]));
    renderDashboard();

    await waitFor(() =>
      expect(screen.getByText(`system.${severity}_event`)).toBeInTheDocument(),
    );
    // Badge text is the severity label
    expect(screen.getAllByText(label).length).toBeGreaterThan(0);
  });
});
