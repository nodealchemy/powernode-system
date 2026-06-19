import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { NetworkList } from './NetworkList';
import type { SdwanNetwork } from '../../types/sdwan.types';

// =============================================================================
// Mocks
//
// NetworkList imports sdwanApi directly (not via apiClient). The sdwanApi
// module in turn calls apiClient internally, but from the component's
// perspective we stub the full sdwanApi facade.
// =============================================================================

const mockGetNetworks = jest.fn();

jest.mock('../../services/api/sdwanApi', () => ({
  sdwanApi: {
    getNetworks: (...args: unknown[]) => mockGetNetworks(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_ACTIVE: SdwanNetwork = {
  id: 'net-aaa',
  name: 'prod-overlay',
  slug: 'prod-overlay',
  status: 'active',
  cidr_64: 'fd00:aabb::/64',
  peer_count: 4,
  hub_count: 2,
  spoke_count: 2,
  description: 'Production overlay network',
  settings: { topology_strategy: 'hub-spoke' },
  created_at: '2026-01-10T08:00:00Z',
  updated_at: '2026-03-15T12:00:00Z',
};

const NETWORK_REGISTERED: SdwanNetwork = {
  id: 'net-bbb',
  name: 'staging-net',
  slug: 'staging-net',
  status: 'registered',
  cidr_64: 'fd00:ccdd::/64',
  peer_count: 1,
  hub_count: 1,
  spoke_count: 0,
  created_at: '2026-02-01T00:00:00Z',
};

const NETWORK_SUSPENDED: SdwanNetwork = {
  id: 'net-ccc',
  name: 'maintenance-net',
  slug: 'maintenance-net',
  status: 'suspended',
  cidr_64: 'fd00:eeff::/64',
  peer_count: 0,
  hub_count: 0,
  spoke_count: 0,
  created_at: '2026-03-01T00:00:00Z',
};

const NETWORK_ARCHIVED: SdwanNetwork = {
  id: 'net-ddd',
  name: 'old-net',
  slug: 'old-net',
  status: 'archived',
  cidr_64: 'fd00:1122::/64',
  peer_count: 0,
  hub_count: 0,
  spoke_count: 0,
  created_at: '2025-01-01T00:00:00Z',
};

/**
 * sdwanApi.getNetworks() returns the extractPaginated result shape:
 * { networks: SdwanNetwork[], meta: PaginationMeta }.
 * The component reads result.networks, so we resolve directly with that shape.
 */
function networksResult(networks: SdwanNetwork[]) {
  return {
    networks,
    meta: {
      current_page: 1,
      per_page: networks.length || 50,
      total_count: networks.length,
      total_pages: 1,
      next_page: null,
      prev_page: null,
    },
  };
}

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  onOpenDetails?: jest.Mock;
  onDelete?: jest.Mock;
  refreshKey?: number;
}

function renderList({ onOpenDetails = jest.fn(), onDelete, refreshKey }: RenderProps = {}) {
  return render(
    <NetworkList
      onOpenDetails={onOpenDetails}
      onDelete={onDelete}
      refreshKey={refreshKey}
    />,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('NetworkList', () => {
  beforeEach(() => {
    mockGetNetworks.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while the API call is in flight', () => {
    // Never resolve so we stay in loading state.
    mockGetNetworks.mockReturnValue(new Promise(() => {}));
    renderList();
    expect(screen.getByText(/loading networks/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('renders the error message when the API call rejects', async () => {
    mockGetNetworks.mockRejectedValue(new Error('Connection refused'));
    renderList();
    await waitFor(() =>
      expect(screen.getByText('Connection refused')).toBeInTheDocument(),
    );
  });

  it('renders a generic error for non-Error rejections', async () => {
    mockGetNetworks.mockRejectedValue('boom');
    renderList();
    await waitFor(() =>
      expect(screen.getByText('Failed to load networks')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('renders the empty-state message when the API returns no networks', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([]));
    renderList();
    await waitFor(() =>
      expect(screen.getByText('No SDWAN networks yet')).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/create your first overlay network/i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Populated list rendering
  // ---------------------------------------------------------------------------

  it('renders a row for each returned network', async () => {
    mockGetNetworks.mockResolvedValue(
      networksResult([NETWORK_ACTIVE, NETWORK_REGISTERED]),
    );
    renderList();
    await waitFor(() =>
      expect(screen.getByTestId('network-row-net-aaa')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('network-row-net-bbb')).toBeInTheDocument();
    // Each network's name appears at least once (name span + slug sub-row share the same text).
    expect(screen.getAllByText('prod-overlay').length).toBeGreaterThan(0);
    expect(screen.getAllByText('staging-net').length).toBeGreaterThan(0);
  });

  it('displays CIDR, peer count, hub/spoke counts, and slug for each row', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList();
    await waitFor(() =>
      expect(screen.getByTestId('network-row-net-aaa')).toBeInTheDocument(),
    );
    expect(screen.getByText('fd00:aabb::/64')).toBeInTheDocument();
    // Peer count column
    expect(screen.getByText('4')).toBeInTheDocument();
    // Hub/Spoke combined cell: "2 hubs · 2 spokes"
    expect(screen.getByText(/2 hubs · 2 spokes/)).toBeInTheDocument();
    // Slug sub-row under the name (appears at least once; name + slug may share text)
    expect(screen.getAllByText('prod-overlay').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Status badge colours (class-based assertions)
  // ---------------------------------------------------------------------------

  it('applies the success badge class for active networks', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList();
    await waitFor(() =>
      expect(screen.getByTestId('network-row-net-aaa')).toBeInTheDocument(),
    );
    const badge = screen.getByText('active');
    expect(badge.className).toContain('bg-theme-success-bg');
    expect(badge.className).toContain('text-theme-success-fg');
  });

  it('applies the info badge class for registered networks', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_REGISTERED]));
    renderList();
    await waitFor(() =>
      expect(screen.getByTestId('network-row-net-bbb')).toBeInTheDocument(),
    );
    const badge = screen.getByText('registered');
    expect(badge.className).toContain('bg-theme-info-bg');
    expect(badge.className).toContain('text-theme-info-fg');
  });

  it('applies the warning badge class for suspended networks', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_SUSPENDED]));
    renderList();
    await waitFor(() =>
      expect(screen.getByTestId('network-row-net-ccc')).toBeInTheDocument(),
    );
    const badge = screen.getByText('suspended');
    expect(badge.className).toContain('bg-theme-warning-bg');
    expect(badge.className).toContain('text-theme-warning-fg');
  });

  it('applies the muted badge class for archived networks', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ARCHIVED]));
    renderList();
    await waitFor(() =>
      expect(screen.getByTestId('network-row-net-ddd')).toBeInTheDocument(),
    );
    const badge = screen.getByText('archived');
    expect(badge.className).toContain('bg-theme-background-secondary');
    expect(badge.className).toContain('text-theme-secondary');
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse
  // ---------------------------------------------------------------------------

  it('expands inline details when a row is clicked', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList();
    const row = await waitFor(() => screen.getByTestId('network-row-net-aaa'));

    // The detail panel should not be visible before clicking.
    expect(screen.queryByText(/production overlay network/i)).not.toBeInTheDocument();

    fireEvent.click(row);

    // Expanded row should show the slug detail field label.
    await waitFor(() => expect(screen.getByText('Slug')).toBeInTheDocument());
    expect(screen.getByText('hub-spoke')).toBeInTheDocument();
    expect(screen.getByText('Production overlay network')).toBeInTheDocument();
  });

  it('collapses the row when clicked a second time', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList();
    const row = await waitFor(() => screen.getByTestId('network-row-net-aaa'));

    fireEvent.click(row);
    await waitFor(() => expect(screen.getByText('Slug')).toBeInTheDocument());

    fireEvent.click(row);
    await waitFor(() =>
      expect(screen.queryByText('Slug')).not.toBeInTheDocument(),
    );
  });

  it('shows the description in expanded details when present', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList();
    const row = await waitFor(() => screen.getByTestId('network-row-net-aaa'));
    fireEvent.click(row);
    await waitFor(() =>
      expect(screen.getByText('Production overlay network')).toBeInTheDocument(),
    );
  });

  it('omits the description detail field when absent', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_REGISTERED]));
    renderList();
    const row = await waitFor(() => screen.getByTestId('network-row-net-bbb'));
    fireEvent.click(row);
    await waitFor(() => expect(screen.getByText('Slug')).toBeInTheDocument());
    // NETWORK_REGISTERED has no description — the Description label should be absent.
    expect(screen.queryByText('Description')).not.toBeInTheDocument();
  });

  it('shows topology strategy from settings in expanded details', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList();
    const row = await waitFor(() => screen.getByTestId('network-row-net-aaa'));
    fireEvent.click(row);
    await waitFor(() =>
      expect(screen.getByText('hub-spoke')).toBeInTheDocument(),
    );
  });

  it('shows em-dash for topology when settings.topology_strategy is absent', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_REGISTERED]));
    renderList();
    const row = await waitFor(() => screen.getByTestId('network-row-net-bbb'));
    fireEvent.click(row);
    await waitFor(() => expect(screen.getByText('Topology')).toBeInTheDocument());
    expect(screen.getByText('—')).toBeInTheDocument();
  });

  it('shows peer breakdown in expanded details', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList();
    const row = await waitFor(() => screen.getByTestId('network-row-net-aaa'));
    fireEvent.click(row);
    await waitFor(() =>
      expect(screen.getByText('Peer breakdown')).toBeInTheDocument(),
    );
    // "4 total · 2 hubs · 2 spokes"
    expect(screen.getByText(/4 total.*2 hub/)).toBeInTheDocument();
  });

  it('shows Created / Updated timestamps in expanded details', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList();
    const row = await waitFor(() => screen.getByTestId('network-row-net-aaa'));
    fireEvent.click(row);
    await waitFor(() =>
      expect(screen.getByText('Created')).toBeInTheDocument(),
    );
    expect(screen.getByText('Updated')).toBeInTheDocument();
  });

  it('expands multiple rows independently', async () => {
    mockGetNetworks.mockResolvedValue(
      networksResult([NETWORK_ACTIVE, NETWORK_REGISTERED]),
    );
    renderList();
    const rowA = await waitFor(() => screen.getByTestId('network-row-net-aaa'));
    const rowB = screen.getByTestId('network-row-net-bbb');

    fireEvent.click(rowA);
    fireEvent.click(rowB);

    await waitFor(() =>
      expect(screen.getAllByText('Slug').length).toBe(2),
    );
  });

  // ---------------------------------------------------------------------------
  // Eye button → onOpenDetails callback
  // ---------------------------------------------------------------------------

  it('calls onOpenDetails with the correct network when the eye icon is clicked', async () => {
    const onOpenDetails = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE, NETWORK_REGISTERED]));
    renderList({ onOpenDetails });

    await waitFor(() =>
      expect(screen.getByTestId('open-network-net-aaa')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('open-network-net-aaa'));
    expect(onOpenDetails).toHaveBeenCalledTimes(1);
    expect(onOpenDetails).toHaveBeenCalledWith(NETWORK_ACTIVE);
  });

  it('does NOT expand the row when the eye button is clicked (stopPropagation)', async () => {
    const onOpenDetails = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList({ onOpenDetails });

    await waitFor(() =>
      expect(screen.getByTestId('open-network-net-aaa')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('open-network-net-aaa'));

    // Row should not be expanded — no expanded detail fields visible.
    expect(screen.queryByText('Slug')).not.toBeInTheDocument();
    expect(onOpenDetails).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Delete button — conditional rendering + callback
  // ---------------------------------------------------------------------------

  it('renders the delete button only when onDelete is provided', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));

    // Without onDelete — no delete button.
    const { rerender } = renderList({ onDelete: undefined });
    await waitFor(() =>
      expect(screen.getByTestId('open-network-net-aaa')).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('delete-network-net-aaa')).not.toBeInTheDocument();

    // With onDelete — delete button appears.
    const onDelete = jest.fn();
    rerender(
      <NetworkList
        onOpenDetails={jest.fn()}
        onDelete={onDelete}
        refreshKey={0}
      />,
    );
    await waitFor(() =>
      expect(screen.getByTestId('delete-network-net-aaa')).toBeInTheDocument(),
    );
  });

  it('calls onDelete with the correct network when the delete button is clicked', async () => {
    const onDelete = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE, NETWORK_REGISTERED]));
    renderList({ onDelete });

    await waitFor(() =>
      expect(screen.getByTestId('delete-network-net-aaa')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('delete-network-net-aaa'));
    expect(onDelete).toHaveBeenCalledTimes(1);
    expect(onDelete).toHaveBeenCalledWith(NETWORK_ACTIVE);
  });

  it('does NOT expand the row when the delete button is clicked (stopPropagation)', async () => {
    const onDelete = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList({ onDelete });

    await waitFor(() =>
      expect(screen.getByTestId('delete-network-net-aaa')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('delete-network-net-aaa'));

    expect(screen.queryByText('Slug')).not.toBeInTheDocument();
    expect(onDelete).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // API call parameters
  // ---------------------------------------------------------------------------

  it('calls sdwanApi.getNetworks with no arguments by default', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([]));
    renderList();
    await waitFor(() => expect(mockGetNetworks).toHaveBeenCalledTimes(1));
    expect(mockGetNetworks).toHaveBeenCalledWith();
  });

  // ---------------------------------------------------------------------------
  // refreshKey triggers reload
  // ---------------------------------------------------------------------------

  it('re-fetches when refreshKey changes', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    const { rerender } = render(
      <NetworkList onOpenDetails={jest.fn()} refreshKey={0} />,
    );
    await waitFor(() => expect(mockGetNetworks).toHaveBeenCalledTimes(1));

    rerender(<NetworkList onOpenDetails={jest.fn()} refreshKey={1} />);
    await waitFor(() => expect(mockGetNetworks).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Hub/spoke pluralisation in table row
  // ---------------------------------------------------------------------------

  it('uses singular "hub" and "spoke" labels when counts are 1', async () => {
    const singleNetwork: SdwanNetwork = {
      ...NETWORK_REGISTERED,
      hub_count: 1,
      spoke_count: 1,
    };
    mockGetNetworks.mockResolvedValue(networksResult([singleNetwork]));
    renderList();
    await waitFor(() =>
      expect(screen.getByTestId('network-row-net-bbb')).toBeInTheDocument(),
    );
    expect(screen.getByText(/1 hub · 1 spoke/)).toBeInTheDocument();
  });

  it('defaults hub_count and spoke_count to 0 when absent', async () => {
    const noCountNetwork: SdwanNetwork = {
      id: 'net-zzz',
      name: 'bare-net',
      slug: 'bare-net',
      status: 'registered',
      cidr_64: 'fd00:ffff::/64',
      peer_count: 0,
      created_at: '2026-01-01T00:00:00Z',
    };
    mockGetNetworks.mockResolvedValue(networksResult([noCountNetwork]));
    renderList();
    await waitFor(() =>
      expect(screen.getByTestId('network-row-net-zzz')).toBeInTheDocument(),
    );
    expect(screen.getByText(/0 hubs · 0 spokes/)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Table header columns
  // ---------------------------------------------------------------------------

  it('renders the expected table column headers', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList();
    await waitFor(() =>
      expect(screen.getByTestId('network-row-net-aaa')).toBeInTheDocument(),
    );
    expect(screen.getByText('Name')).toBeInTheDocument();
    expect(screen.getByText('Status')).toBeInTheDocument();
    expect(screen.getByText('CIDR')).toBeInTheDocument();
    expect(screen.getByText('Peers')).toBeInTheDocument();
    expect(screen.getByText('Hub / Spoke')).toBeInTheDocument();
    expect(screen.getByText('Actions')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Aria labels on action buttons
  // ---------------------------------------------------------------------------

  it('gives the eye button an aria-label referencing the network name', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList();
    await waitFor(() =>
      expect(
        screen.getByRole('button', { name: /view details for prod-overlay/i }),
      ).toBeInTheDocument(),
    );
  });

  it('gives the delete button an aria-label referencing the network name', async () => {
    const onDelete = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_ACTIVE]));
    renderList({ onDelete });
    await waitFor(() =>
      expect(
        screen.getByRole('button', { name: /delete prod-overlay/i }),
      ).toBeInTheDocument(),
    );
  });
});
