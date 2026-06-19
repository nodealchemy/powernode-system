import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BgpSessionsTable } from './BgpSessionsTable';
import type { SdwanBgpSession } from '../../../types/sdwan.types';

// =============================================================================
// Mocks
//
// BgpSessionsTable calls sdwanApi.getBgpSessions exclusively — mock the
// facade directly so we can control what each test sees without standing up
// apiClient or the network.
// =============================================================================

const mockGetBgpSessions = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    getBgpSessions: (...args: unknown[]) => mockGetBgpSessions(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const SESSION_ESTABLISHED: SdwanBgpSession = {
  id: 'sess-00000001-0000-0000-0000-000000000001',
  peer_id: 'peer-aaaa-0000-0000-0000-000000000001',
  network_id: 'net-0001',
  neighbor_peer_id: 'peer-bbbb-0000-0000-0000-000000000002',
  neighbor_address: '10.64.0.2',
  state: 'established',
  uptime_seconds: 7261,
  prefixes_received: 4,
  prefixes_sent: 2,
  last_state_change_at: '2026-06-01T08:00:00Z',
  last_observed_at: '2026-06-05T12:00:00Z',
  last_error: null,
};

const SESSION_IDLE: SdwanBgpSession = {
  id: 'sess-00000002-0000-0000-0000-000000000002',
  peer_id: 'peer-cccc-0000-0000-0000-000000000003',
  network_id: 'net-0001',
  neighbor_peer_id: null,
  neighbor_address: '10.64.0.3',
  state: 'idle',
  uptime_seconds: 0,
  prefixes_received: 0,
  prefixes_sent: 0,
  last_state_change_at: null,
  last_observed_at: null,
  last_error: 'Connection refused by remote peer',
};

const SESSION_ACTIVE: SdwanBgpSession = {
  id: 'sess-00000003-0000-0000-0000-000000000003',
  peer_id: 'peer-dddd-0000-0000-0000-000000000004',
  network_id: 'net-0001',
  neighbor_peer_id: null,
  neighbor_address: '10.64.0.4',
  state: 'active',
  uptime_seconds: 300,
  prefixes_received: 0,
  prefixes_sent: 0,
  last_state_change_at: '2026-06-05T11:55:00Z',
  last_observed_at: '2026-06-05T11:59:00Z',
  last_error: null,
};

function successResponse(sessions: SdwanBgpSession[], count?: number) {
  return Promise.resolve({ sessions, count: count ?? sessions.length });
}

// =============================================================================
// Tests
// =============================================================================

const renderTable = (props: { networkId?: string; refreshKey?: number } = {}) =>
  render(<BgpSessionsTable {...props} />);

describe('BgpSessionsTable', () => {
  beforeEach(() => {
    mockGetBgpSessions.mockReset();
  });

  // ── Loading state ──────────────────────────────────────────────────────────

  it('shows a loading indicator while the API call is in flight', () => {
    mockGetBgpSessions.mockReturnValue(new Promise(() => {})); // never resolves
    renderTable();
    expect(screen.getByText('Loading sessions…')).toBeInTheDocument();
  });

  // ── Error state ────────────────────────────────────────────────────────────

  it('shows an error message when getBgpSessions rejects', async () => {
    mockGetBgpSessions.mockRejectedValue(new Error('Network timeout'));
    renderTable();
    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument(),
    );
  });

  it('shows a fallback error message for non-Error rejections', async () => {
    mockGetBgpSessions.mockRejectedValue('some string error');
    renderTable();
    await waitFor(() =>
      expect(screen.getByText('Failed to load BGP sessions')).toBeInTheDocument(),
    );
  });

  // ── Empty state ────────────────────────────────────────────────────────────

  it('renders the empty-state message when no sessions are returned', async () => {
    mockGetBgpSessions.mockResolvedValue({ sessions: [], count: 0 });
    renderTable();
    await waitFor(() =>
      expect(screen.getByText('No BGP sessions reported yet.')).toBeInTheDocument(),
    );
    // Session counter shows "0 sessions"
    expect(screen.getByText('0 sessions')).toBeInTheDocument();
  });

  // ── Session list ───────────────────────────────────────────────────────────

  it('renders a table with all sessions returned by the API', async () => {
    mockGetBgpSessions.mockResolvedValue(
      successResponse([SESSION_ESTABLISHED, SESSION_IDLE]),
    );
    renderTable();

    await waitFor(() =>
      expect(screen.getByText('10.64.0.2')).toBeInTheDocument(),
    );

    // Both neighbor addresses appear in the table
    expect(screen.getByText('10.64.0.3')).toBeInTheDocument();

    // The counter shows the correct count
    expect(screen.getByText('2 sessions')).toBeInTheDocument();
  });

  it('shows truncated peer_id (first 8 chars) in the Local peer column', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() =>
      expect(screen.getByText('peer-aaa')).toBeInTheDocument(),
    );
  });

  it('shows singular "session" when exactly one session is returned', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() =>
      expect(screen.getByText('1 session')).toBeInTheDocument(),
    );
  });

  // ── State color classes ────────────────────────────────────────────────────

  it('applies success color class for "established" state', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() => screen.getByText('established'));
    const stateEl = screen.getByText('established');
    expect(stateEl).toHaveClass('text-theme-success-fg');
  });

  it('applies warning color class for "active" state', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ACTIVE]));
    renderTable();

    await waitFor(() => screen.getByText('active'));
    const stateEl = screen.getByText('active');
    expect(stateEl).toHaveClass('text-theme-warning-fg');
  });

  it('applies secondary color class for "idle" state', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_IDLE]));
    renderTable();

    await waitFor(() => screen.getByText('idle'));
    const stateEl = screen.getByText('idle');
    expect(stateEl).toHaveClass('text-theme-secondary');
  });

  // ── Uptime formatting ──────────────────────────────────────────────────────

  it('formats uptime in days+hours for >= 86400 seconds', async () => {
    const session: SdwanBgpSession = {
      ...SESSION_ESTABLISHED,
      uptime_seconds: 90061, // 1d 1h 1m
    };
    mockGetBgpSessions.mockResolvedValue(successResponse([session]));
    renderTable();

    // 90061s = 1d 1h
    await waitFor(() =>
      expect(screen.getByText('1d 1h')).toBeInTheDocument(),
    );
  });

  it('formats uptime in hours+minutes for < 86400 seconds', async () => {
    const session: SdwanBgpSession = {
      ...SESSION_ESTABLISHED,
      uptime_seconds: 7261, // 2h 1m
    };
    mockGetBgpSessions.mockResolvedValue(successResponse([session]));
    renderTable();

    await waitFor(() =>
      expect(screen.getByText('2h 1m')).toBeInTheDocument(),
    );
  });

  it('formats uptime in minutes only for < 3600 seconds', async () => {
    const session: SdwanBgpSession = {
      ...SESSION_ACTIVE,
      uptime_seconds: 300, // 5m
    };
    mockGetBgpSessions.mockResolvedValue(successResponse([session]));
    renderTable();

    await waitFor(() =>
      expect(screen.getByText('5m')).toBeInTheDocument(),
    );
  });

  it('shows em-dash for zero uptime', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_IDLE]));
    renderTable();

    await waitFor(() => screen.getByText('idle'));
    // uptime_seconds = 0 → '—'
    const uptimeCells = screen.getAllByText('—');
    expect(uptimeCells.length).toBeGreaterThan(0);
  });

  // ── last_observed_at rendering ─────────────────────────────────────────────

  it('renders "—" when last_observed_at is null', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_IDLE]));
    renderTable();

    await waitFor(() => screen.getByText('idle'));
    // SESSION_IDLE has null last_observed_at
    const dashCells = screen.getAllByText('—');
    expect(dashCells.length).toBeGreaterThan(0);
  });

  it('renders a date string when last_observed_at is set', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() => screen.getByText('established'));
    // last_observed_at is '2026-06-05T12:00:00Z' — toLocaleString() result appears
    const dateString = new Date('2026-06-05T12:00:00Z').toLocaleString();
    expect(screen.getAllByText(dateString).length).toBeGreaterThan(0);
  });

  // ── API call: initial load ─────────────────────────────────────────────────

  it('calls getBgpSessions with no filters on initial load', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([]));
    renderTable();

    await waitFor(() => expect(mockGetBgpSessions).toHaveBeenCalledTimes(1));
    expect(mockGetBgpSessions).toHaveBeenCalledWith({
      network_id: undefined,
      state: undefined,
    });
  });

  it('calls getBgpSessions with the provided networkId on initial load', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([]));
    renderTable({ networkId: 'net-0001' });

    await waitFor(() => expect(mockGetBgpSessions).toHaveBeenCalledTimes(1));
    expect(mockGetBgpSessions).toHaveBeenCalledWith({
      network_id: 'net-0001',
      state: undefined,
    });
  });

  it('re-fetches when refreshKey changes', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([]));

    const { rerender } = renderTable({ refreshKey: 0 });
    await waitFor(() => expect(mockGetBgpSessions).toHaveBeenCalledTimes(1));

    rerender(<BgpSessionsTable refreshKey={1} />);
    await waitFor(() => expect(mockGetBgpSessions).toHaveBeenCalledTimes(2));
  });

  // ── State filter ───────────────────────────────────────────────────────────

  it('calls getBgpSessions with the selected state when the filter changes', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([]));
    renderTable();

    await waitFor(() => expect(mockGetBgpSessions).toHaveBeenCalledTimes(1));

    const select = screen.getByRole('combobox');
    fireEvent.change(select, { target: { value: 'established' } });

    await waitFor(() => expect(mockGetBgpSessions).toHaveBeenCalledTimes(2));
    expect(mockGetBgpSessions).toHaveBeenLastCalledWith({
      network_id: undefined,
      state: 'established',
    });
  });

  it('passes undefined for state when the "All states" option is selected', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([]));
    renderTable();

    await waitFor(() => expect(mockGetBgpSessions).toHaveBeenCalledTimes(1));

    const select = screen.getByRole('combobox');
    // select a value then reset
    fireEvent.change(select, { target: { value: 'idle' } });
    await waitFor(() => expect(mockGetBgpSessions).toHaveBeenCalledTimes(2));

    fireEvent.change(select, { target: { value: '' } });
    await waitFor(() => expect(mockGetBgpSessions).toHaveBeenCalledTimes(3));
    expect(mockGetBgpSessions).toHaveBeenLastCalledWith({
      network_id: undefined,
      state: undefined,
    });
  });

  it('filter select contains all expected state options', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([]));
    renderTable();

    await waitFor(() => screen.getByRole('combobox'));

    const select = screen.getByRole('combobox');
    const options = within(select).getAllByRole('option');
    const values = options.map((o) => (o as HTMLOptionElement).value);

    expect(values).toEqual(
      expect.arrayContaining(['', 'established', 'active', 'connect', 'opensent', 'openconfirm', 'idle']),
    );
  });

  // ── Refresh button ─────────────────────────────────────────────────────────

  it('re-fetches when the Refresh button is clicked', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([]));
    renderTable();

    await waitFor(() => expect(mockGetBgpSessions).toHaveBeenCalledTimes(1));

    const refreshButton = screen.getByTitle('Refresh');
    fireEvent.click(refreshButton);

    await waitFor(() => expect(mockGetBgpSessions).toHaveBeenCalledTimes(2));
  });

  // ── Row expansion ──────────────────────────────────────────────────────────

  it('starts with all rows collapsed (no detail panel visible)', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.2'));

    // The full peer_id should NOT be visible in the collapsed state
    expect(screen.queryByTitle(SESSION_ESTABLISHED.peer_id)).not.toBeInTheDocument();
  });

  it('expands a row to show the detail panel when the expand button is clicked', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.2'));

    const expandButton = screen.getByTitle('Expand details');
    fireEvent.click(expandButton);

    await waitFor(() => {
      // "Local peer" appears in both the <th> header and the detail-panel <label>
      const localPeerEls = screen.getAllByText('Local peer');
      expect(localPeerEls.length).toBeGreaterThanOrEqual(2);
    });
    // Full peer_id shown in the detail panel
    expect(screen.getByTitle(SESSION_ESTABLISHED.peer_id)).toBeInTheDocument();
  });

  it('collapses a row when the collapse button is clicked after expansion', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.2'));

    // Expand
    const expandButton = screen.getByTitle('Expand details');
    fireEvent.click(expandButton);
    await waitFor(() =>
      expect(screen.getByTitle('Collapse details')).toBeInTheDocument(),
    );

    // Collapse
    const collapseButton = screen.getByTitle('Collapse details');
    fireEvent.click(collapseButton);

    await waitFor(() =>
      expect(screen.queryByTitle('Collapse details')).not.toBeInTheDocument(),
    );
  });

  it('allows multiple rows to be independently expanded simultaneously', async () => {
    mockGetBgpSessions.mockResolvedValue(
      successResponse([SESSION_ESTABLISHED, SESSION_IDLE]),
    );
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.2'));

    const expandButtons = screen.getAllByTitle('Expand details');
    expect(expandButtons).toHaveLength(2);

    // Expand both
    fireEvent.click(expandButtons[0]);
    fireEvent.click(expandButtons[1]);

    // Both detail panels are open — each shows its Session ID label
    const sessionIdLabels = await screen.findAllByText('Session ID');
    expect(sessionIdLabels).toHaveLength(2);
  });

  // ── Detail panel contents ─────────────────────────────────────────────────

  it('shows neighbor_peer_id in the detail panel when it is set', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.2'));
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Neighbor peer')).toBeInTheDocument(),
    );
    // The full neighbor_peer_id appears in the panel
    expect(screen.getByTitle(SESSION_ESTABLISHED.neighbor_peer_id!)).toBeInTheDocument();
  });

  it('hides neighbor_peer_id field when it is null', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_IDLE]));
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.3'));
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Session ID')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Neighbor peer')).not.toBeInTheDocument();
  });

  it('shows last_state_change_at in the detail panel when set', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.2'));
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Last state change')).toBeInTheDocument(),
    );
    const expected = new Date(SESSION_ESTABLISHED.last_state_change_at!).toLocaleString();
    // There may be multiple matches (the table row also shows last_observed_at)
    expect(screen.getAllByText(expected).length).toBeGreaterThan(0);
  });

  it('hides last_state_change_at field when it is null', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_IDLE]));
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.3'));
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Session ID')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Last state change')).not.toBeInTheDocument();
  });

  it('shows last_error in a <pre> block when set', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_IDLE]));
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.3'));
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Last error')).toBeInTheDocument(),
    );
    expect(screen.getByText('Connection refused by remote peer')).toBeInTheDocument();
  });

  it('hides the last_error block when last_error is null', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.2'));
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Session ID')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Last error')).not.toBeInTheDocument();
  });

  it('shows the uptime in seconds alongside the formatted value in the detail panel', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.2'));
    fireEvent.click(screen.getByTitle('Expand details'));

    // '2h 1m (7261s)' appears in the Uptime detail field
    await waitFor(() =>
      expect(screen.getByText('2h 1m (7261s)')).toBeInTheDocument(),
    );
  });

  it('shows prefixes received and sent in the detail panel', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.2'));
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Prefixes Rx / Tx')).toBeInTheDocument(),
    );
    expect(screen.getByText('4 received · 2 sent')).toBeInTheDocument();
  });

  it('shows the MCP tool hint in every expanded panel', async () => {
    mockGetBgpSessions.mockResolvedValue(successResponse([SESSION_ESTABLISHED]));
    renderTable();

    await waitFor(() => screen.getByText('10.64.0.2'));
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('system_sdwan_get_bgp_config_for_peer')).toBeInTheDocument(),
    );
  });
});
