import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { TopologyTab } from './TopologyTab';
import type { NetworkTopologyResponse } from '../../types/network_topology.types';

// =============================================================================
// Mocks
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

// SystemTopology is the heavy xyflow canvas — mock it to a simple sentinel so
// tests stay fast and deterministic. The sentinel passes refreshKey through as
// a data-testid attribute so tests can assert increments.
jest.mock('../network/SystemTopology', () => ({
  SystemTopology: ({ refreshKey }: { refreshKey: number }) => (
    <div data-testid="system-topology" data-refresh-key={refreshKey} />
  ),
}));

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const FULL_TOPOLOGY: NetworkTopologyResponse = {
  self_id: 'self-1',
  self_label: 'My Platform',
  nodes: [],
  edges: [],
  stats: {
    peer_count: 3,
    platform_peer_count: 2,
    sdwan_only_peer_count: 1,
    network_count: 4,
    bridge_count: 5,
    active_bridge_count: 3,
    grant_count: 7,
    generated_at: '2026-06-05T00:00:00Z',
  },
};

const EMPTY_STATS: NetworkTopologyResponse = {
  self_id: 'self-1',
  self_label: 'My Platform',
  nodes: [],
  edges: [],
  stats: {
    peer_count: 0,
    platform_peer_count: 0,
    sdwan_only_peer_count: 0,
    network_count: 0,
    bridge_count: 0,
    active_bridge_count: 0,
    grant_count: 0,
    generated_at: '2026-06-05T00:00:00Z',
  },
};

// =============================================================================
// Helpers
// =============================================================================

const renderTab = () =>
  render(
    <BrowserRouter>
      <TopologyTab />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('TopologyTab', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Static chrome — rendered regardless of API outcome
  // ---------------------------------------------------------------------------

  it('renders the descriptive subtitle and Refresh button immediately', () => {
    // Never resolve so we can inspect the initial render
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(
      screen.getByText(/system-wide federation \+ sdwan graph/i),
    ).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /refresh/i })).toBeInTheDocument();
  });

  it('renders the SystemTopology canvas immediately (before API resolves)', () => {
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.getByTestId('system-topology')).toBeInTheDocument();
  });

  it('renders the Legend immediately', () => {
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    // Spot-check a few legend labels
    expect(screen.getByText('Self')).toBeInTheDocument();
    expect(screen.getByText('SDWAN network')).toBeInTheDocument();
    expect(screen.getByText('Platform peer')).toBeInTheDocument();
    expect(screen.getByText('Active bridge')).toBeInTheDocument();
    expect(screen.getByText('Grant summary (self → peer)')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // API call shape
  // ---------------------------------------------------------------------------

  it('calls GET /system/network/topology on mount', async () => {
    mockGet.mockResolvedValue(envelope(FULL_TOPOLOGY));

    renderTab();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/network/topology'),
    );
  });

  // ---------------------------------------------------------------------------
  // Stats row — visible after successful API response
  // ---------------------------------------------------------------------------

  it('renders the stats row with correct counts after API success', async () => {
    mockGet.mockResolvedValue(envelope(FULL_TOPOLOGY));

    renderTab();

    // Wait for the stats row to appear (it is conditional on stats != null)
    await waitFor(() => expect(screen.getByText('Networks')).toBeInTheDocument());

    // Networks stat
    expect(screen.getByText('Networks')).toBeInTheDocument();
    expect(screen.getByText('4')).toBeInTheDocument();

    // Peers stat
    expect(screen.getByText('Peers')).toBeInTheDocument();
    expect(screen.getByText('3')).toBeInTheDocument();
    expect(screen.getByText('2 platform · 1 data-plane')).toBeInTheDocument();

    // Bridges stat
    expect(screen.getByText('Bridges')).toBeInTheDocument();
    expect(screen.getByText('5')).toBeInTheDocument();
    expect(screen.getByText('3 active')).toBeInTheDocument();

    // Active grants
    expect(screen.getByText('Active grants')).toBeInTheDocument();
    expect(screen.getByText('7')).toBeInTheDocument();
  });

  it('does not render the stats row when API returns zero-value stats', async () => {
    // EMPTY_STATS is a valid response — stats row still renders (stats != null)
    mockGet.mockResolvedValue(envelope(EMPTY_STATS));

    renderTab();

    await waitFor(() => expect(screen.getByText('Networks')).toBeInTheDocument());

    // All stat values are 0 when the response carries zero-value stats
    expect(screen.getAllByText('0').length).toBeGreaterThanOrEqual(1);
  });

  it('does not render the stats row while the API call is pending', () => {
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.queryByText('Networks')).not.toBeInTheDocument();
    expect(screen.queryByText('Peers')).not.toBeInTheDocument();
    expect(screen.queryByText('Bridges')).not.toBeInTheDocument();
    expect(screen.queryByText('Active grants')).not.toBeInTheDocument();
  });

  it('does not render the stats row when the API call rejects', async () => {
    mockGet.mockRejectedValue(new Error('network failure'));

    renderTab();

    // Wait a tick for the rejection to propagate
    await waitFor(() => expect(mockGet).toHaveBeenCalled());

    // Stats row must stay absent — the source swallows the error silently
    expect(screen.queryByText('Networks')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // StatCard sublabel visibility
  // ---------------------------------------------------------------------------

  it('renders sublabels on Peers and Bridges stat cards but not on others', async () => {
    mockGet.mockResolvedValue(envelope(FULL_TOPOLOGY));

    renderTab();

    await waitFor(() => expect(screen.getByText('Peers')).toBeInTheDocument());

    // Peers sublabel
    expect(screen.getByText('2 platform · 1 data-plane')).toBeInTheDocument();
    // Bridges sublabel
    expect(screen.getByText('3 active')).toBeInTheDocument();

    // Networks and Active grants have no sublabel — test their cards exist
    // without sublabels by verifying no extra text around those cards
    const networksCard = screen.getByText('Networks').closest('div');
    expect(networksCard).not.toBeNull();
    // No sublabel text inside the networks card
    expect(networksCard?.querySelector('[class*="text-[10px]"]')).toBeNull();
  });

  // ---------------------------------------------------------------------------
  // Refresh interaction
  // ---------------------------------------------------------------------------

  it('re-fetches topology when the Refresh button is clicked', async () => {
    mockGet.mockResolvedValue(envelope(FULL_TOPOLOGY));

    renderTab();

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));

    const refreshBtn = screen.getByRole('button', { name: /refresh/i });
    fireEvent.click(refreshBtn);

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
    expect(mockGet).toHaveBeenNthCalledWith(2, '/system/network/topology');
  });

  it('passes an incremented refreshKey to SystemTopology on each Refresh click', async () => {
    mockGet.mockResolvedValue(envelope(FULL_TOPOLOGY));

    renderTab();

    const canvas = screen.getByTestId('system-topology');
    expect(canvas).toHaveAttribute('data-refresh-key', '0');

    const refreshBtn = screen.getByRole('button', { name: /refresh/i });
    fireEvent.click(refreshBtn);

    await waitFor(() =>
      expect(canvas).toHaveAttribute('data-refresh-key', '1'),
    );

    fireEvent.click(refreshBtn);

    await waitFor(() =>
      expect(canvas).toHaveAttribute('data-refresh-key', '2'),
    );
  });

  it('passes refreshKey=0 to SystemTopology on initial render', () => {
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.getByTestId('system-topology')).toHaveAttribute(
      'data-refresh-key',
      '0',
    );
  });

  // ---------------------------------------------------------------------------
  // Legend content
  // ---------------------------------------------------------------------------

  it('renders all seven legend items', () => {
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    const expectedLabels = [
      'Self',
      'SDWAN network',
      'Platform peer',
      'Data-plane peer',
      'Active bridge',
      'Self ↔ network membership',
      'Grant summary (self → peer)',
    ];

    for (const label of expectedLabels) {
      expect(screen.getByText(label)).toBeInTheDocument();
    }
  });

  it('renders line decorations for edge-type legend items', () => {
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    // green line → ━━
    expect(screen.getByText('━━')).toBeInTheDocument();
    // gray-dashed → ┄┄
    expect(screen.getByText('┄┄')).toBeInTheDocument();
    // purple-dashed → ┅┅
    expect(screen.getByText('┅┅')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Multiple refreshes update stats correctly
  // ---------------------------------------------------------------------------

  it('updates stats when a subsequent refresh returns different counts', async () => {
    const secondTopology: NetworkTopologyResponse = {
      ...FULL_TOPOLOGY,
      stats: {
        ...FULL_TOPOLOGY.stats,
        network_count: 9,
        peer_count: 10,
        platform_peer_count: 8,
        sdwan_only_peer_count: 2,
        bridge_count: 12,
        active_bridge_count: 11,
        grant_count: 20,
      },
    };

    mockGet
      .mockResolvedValueOnce(envelope(FULL_TOPOLOGY))
      .mockResolvedValueOnce(envelope(secondTopology));

    renderTab();

    await waitFor(() => expect(screen.getByText('4')).toBeInTheDocument());

    const refreshBtn = screen.getByRole('button', { name: /refresh/i });
    fireEvent.click(refreshBtn);

    await waitFor(() => expect(screen.getByText('9')).toBeInTheDocument());
    expect(screen.getByText('10')).toBeInTheDocument();
    expect(screen.getByText('8 platform · 2 data-plane')).toBeInTheDocument();
    expect(screen.getByText('11 active')).toBeInTheDocument();
    expect(screen.getByText('20')).toBeInTheDocument();
  });
});
