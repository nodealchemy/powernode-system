import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { HoneypotCanaryTile } from './HoneypotCanaryTile';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: jest.fn(),
    post: (...args: unknown[]) => mockPost(...args),
    put: jest.fn(),
    delete: jest.fn(),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

// Double-envelope: AxiosResponse.data = { success: true, data: <payload> }
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function signalsResponse(events: FleetEventStub[]) {
  return envelope({ events, count: events.length, channel: 'system_fleet' });
}

interface FleetEventStub {
  id: string;
  account_id: string;
  kind: string;
  severity: 'low' | 'medium' | 'high' | 'critical';
  payload: Record<string, unknown>;
  correlation_id: string | null;
  source: string | null;
  emitted_at: string;
}

function makeEvent(id: string, emittedAt: Date): FleetEventStub {
  return {
    id,
    account_id: 'acct-1',
    kind: 'system.honeypot_triggered',
    severity: 'high',
    payload: {},
    correlation_id: null,
    source: null,
    emitted_at: emittedAt.toISOString(),
  };
}

// Build timestamps relative to now
const now = Date.now();
const TWENTY_THREE_HOURS_AGO = new Date(now - 23 * 60 * 60 * 1000);
const TWENTY_FIVE_HOURS_AGO = new Date(now - 25 * 60 * 60 * 1000);
const SIX_DAYS_AGO = new Date(now - 6 * 24 * 60 * 60 * 1000);
const EIGHT_DAYS_AGO = new Date(now - 8 * 24 * 60 * 60 * 1000);

const EVENT_WITHIN_24H = makeEvent('evt-1', TWENTY_THREE_HOURS_AGO);
const EVENT_WITHIN_7D_NOT_24H = makeEvent('evt-2', TWENTY_FIVE_HOURS_AGO);
const EVENT_WITHIN_7D_ALSO = makeEvent('evt-3', SIX_DAYS_AGO);
const EVENT_OLDER_THAN_7D = makeEvent('evt-4', EIGHT_DAYS_AGO);

// =============================================================================
// Tests
// =============================================================================

describe('HoneypotCanaryTile', () => {
  beforeEach(() => {
    mockPost.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render / Loading state
  // ---------------------------------------------------------------------------

  it('renders the tile label "Honeypot Canaries" immediately', () => {
    mockPost.mockReturnValue(new Promise(() => {})); // never resolves
    render(<HoneypotCanaryTile />);
    expect(screen.getByText('Honeypot Canaries')).toBeInTheDocument();
  });

  it('shows Loading… text while the API call is in flight', () => {
    mockPost.mockReturnValue(new Promise(() => {}));
    render(<HoneypotCanaryTile />);
    expect(screen.getByText(/Loading…/)).toBeInTheDocument();
  });

  it('hides the loading text once the API resolves', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // API call shape
  // ---------------------------------------------------------------------------

  it('POSTs to /system/fleet/signals with kind and limit params', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));
    expect(mockPost).toHaveBeenCalledWith('/system/fleet/signals', {
      kind: 'system.honeypot_triggered',
      limit: 100,
    });
  });

  // ---------------------------------------------------------------------------
  // Empty / clean state (no events)
  // ---------------------------------------------------------------------------

  it('shows 0 for both windows when there are no events', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());

    // Both 24h and 7d counts should be 0
    const allZeroes = screen.getAllByText('0');
    expect(allZeroes.length).toBeGreaterThanOrEqual(2);
  });

  it('does not show the ALERT badge when there are no recent events', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    expect(screen.queryByText('ALERT')).not.toBeInTheDocument();
  });

  it('does not show "Last access:" when there are no recent events', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    expect(screen.queryByText(/Last access:/)).not.toBeInTheDocument();
  });

  it('uses the plain Shield icon (no ShieldAlert) when last24h is empty', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    // ShieldAlert is not rendered — no element with the text-theme-error-fg icon class in icon area
    // We verify by absence of the ALERT badge (indicator of ShieldAlert path)
    expect(screen.queryByText('ALERT')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Events within 24h — alert state
  // ---------------------------------------------------------------------------

  it('shows ALERT badge when there is at least one event within 24h', async () => {
    mockPost.mockResolvedValue(signalsResponse([EVENT_WITHIN_24H]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText('ALERT')).toBeInTheDocument());
  });

  it('counts the correct number of events within last 24h', async () => {
    mockPost.mockResolvedValue(signalsResponse([EVENT_WITHIN_24H, EVENT_WITHIN_7D_NOT_24H]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    // last24h count is 1 (only EVENT_WITHIN_24H qualifies)
    expect(screen.getByText('1')).toBeInTheDocument();
  });

  it('shows "Last access:" timestamp when last24h > 0', async () => {
    mockPost.mockResolvedValue(signalsResponse([EVENT_WITHIN_24H]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText(/Last access:/)).toBeInTheDocument());
  });

  it('Last access timestamp reflects the first event (accessEvents[0])', async () => {
    // When the API returns events, accessEvents[0] is what drives the Last access line.
    // EVENT_WITHIN_24H has emitted_at = TWENTY_THREE_HOURS_AGO.
    mockPost.mockResolvedValue(signalsResponse([EVENT_WITHIN_24H]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText(/Last access:/)).toBeInTheDocument());
    // Timestamp rendered via toLocaleString() — just ensure something follows "Last access:"
    const lastAccessEl = screen.getByText(/Last access:/);
    expect(lastAccessEl.textContent).toMatch(/Last access:\s*.+/);
  });

  // ---------------------------------------------------------------------------
  // Events within 7d but not 24h — warning state (no ALERT badge)
  // ---------------------------------------------------------------------------

  it('does not show ALERT badge when events are only within 7d (not 24h)', async () => {
    mockPost.mockResolvedValue(signalsResponse([EVENT_WITHIN_7D_NOT_24H]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    expect(screen.queryByText('ALERT')).not.toBeInTheDocument();
  });

  it('shows 0 for last 24h and correct count for last 7d when events are older than 24h', async () => {
    mockPost.mockResolvedValue(
      signalsResponse([EVENT_WITHIN_7D_NOT_24H, EVENT_WITHIN_7D_ALSO]),
    );
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    // last24h = 0
    expect(screen.getByText('0')).toBeInTheDocument();
    // last7d = 2
    expect(screen.getByText('2')).toBeInTheDocument();
  });

  it('does not show "Last access:" when events are only within 7d', async () => {
    mockPost.mockResolvedValue(signalsResponse([EVENT_WITHIN_7D_NOT_24H]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    expect(screen.queryByText(/Last access:/)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Events older than 7d — clean state (counted in accessEvents but filtered out)
  // ---------------------------------------------------------------------------

  it('excludes events older than 7d from both window counts', async () => {
    mockPost.mockResolvedValue(signalsResponse([EVENT_OLDER_THAN_7D]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    // Both counts should be 0
    const zeroes = screen.getAllByText('0');
    expect(zeroes.length).toBeGreaterThanOrEqual(2);
    expect(screen.queryByText('ALERT')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Mixed events across windows
  // ---------------------------------------------------------------------------

  it('correctly counts events across multiple windows simultaneously', async () => {
    const events = [
      EVENT_WITHIN_24H,         // in both last24h and last7d
      EVENT_WITHIN_7D_NOT_24H,  // in last7d only
      EVENT_WITHIN_7D_ALSO,     // in last7d only
      EVENT_OLDER_THAN_7D,      // excluded from both
    ];
    mockPost.mockResolvedValue(signalsResponse(events));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText('ALERT')).toBeInTheDocument());
    // last24h = 1
    expect(screen.getByText('1')).toBeInTheDocument();
    // last7d = 3 (events within 7d window includes the one within 24h too)
    expect(screen.getByText('3')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Window labels
  // ---------------------------------------------------------------------------

  it('renders "last 24h" and "last 7d" labels', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    expect(screen.getByText('last 24h')).toBeInTheDocument();
    expect(screen.getByText('last 7d')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error / network failure
  // ---------------------------------------------------------------------------

  it('shows 0 counts and no ALERT badge on API error', async () => {
    mockPost.mockRejectedValue(new Error('network failure'));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    const zeroes = screen.getAllByText('0');
    expect(zeroes.length).toBeGreaterThanOrEqual(2);
    expect(screen.queryByText('ALERT')).not.toBeInTheDocument();
  });

  it('does not show "Last access:" on API error', async () => {
    mockPost.mockRejectedValue(new Error('network failure'));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    expect(screen.queryByText(/Last access:/)).not.toBeInTheDocument();
  });

  it('renders "last 24h" and "last 7d" labels even on API error', async () => {
    mockPost.mockRejectedValue(new Error('network failure'));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    expect(screen.getByText('last 24h')).toBeInTheDocument();
    expect(screen.getByText('last 7d')).toBeInTheDocument();
  });
});
