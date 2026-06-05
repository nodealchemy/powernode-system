import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { VirtualIpList } from './VirtualIpList';

// =============================================================================
// Mocks
//
// VirtualIpList calls sdwanApi.listVirtualIps and sdwanApi.getPeers, both of
// which delegate to apiClient.get internally. We stub sdwanApi directly to
// keep the tests isolated from the HTTP layer.
// =============================================================================

const mockListVirtualIps = jest.fn();
const mockGetPeers = jest.fn();

jest.mock('../../../services/api/sdwanApi', () => ({
  sdwanApi: {
    listVirtualIps: (...args: unknown[]) => mockListVirtualIps(...args),
    getPeers: (...args: unknown[]) => mockGetPeers(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const PEER_A = {
  id: 'peer-aaaa-0000-0000-0000-000000000001',
  network_id: 'net-1',
  node_instance_id: 'inst-aaaa-1111-0000-0000-000000000001',
  assigned_address: '10.0.0.1',
  publicly_reachable: true,
  listen_port: 51820,
  status: 'active' as const,
};

const PEER_B = {
  id: 'peer-bbbb-0000-0000-0000-000000000002',
  network_id: 'net-1',
  node_instance_id: 'inst-bbbb-2222-0000-0000-000000000002',
  assigned_address: '10.0.0.2',
  publicly_reachable: false,
  listen_port: 51820,
  status: 'active' as const,
};

const VIP_ACTIVE_PASSIVE = {
  id: 'vip-1111-0000-0000-0000-000000000001',
  network_id: 'net-1',
  name: 'web-vip',
  cidr: '192.168.100.10/32',
  anycast: false,
  state: 'active' as const,
  holder_peer_ids: [],
  failover_holder_peer_ids: [PEER_B.id],
  primary_holder_peer_id: PEER_A.id,
  primary_holder_address: '10.0.0.1',
  advertised_med: 100,
  advertised_local_pref: 100,
  tags: ['prod', 'web'],
  description: 'Production web VIP',
  assignments: [
    {
      id: 'asgn-1',
      peer_id: PEER_A.id,
      assumed_at: '2026-01-01T00:00:00Z',
      released_at: null,
      reason: 'initial' as const,
      triggered_by_user_id: null,
      active: true,
    },
  ],
  created_at: '2026-01-01T00:00:00Z',
};

const VIP_ANYCAST = {
  id: 'vip-2222-0000-0000-0000-000000000002',
  network_id: 'net-1',
  name: 'anycast-vip',
  cidr: '192.168.200.0/24',
  anycast: true,
  state: 'pending' as const,
  holder_peer_ids: [PEER_A.id, PEER_B.id],
  failover_holder_peer_ids: [],
  primary_holder_peer_id: null,
  primary_holder_address: null,
  advertised_med: 50,
  advertised_local_pref: 200,
  tags: [],
  description: null,
  assignments: [],
  created_at: '2026-02-01T00:00:00Z',
};

const VIP_UNASSIGNED = {
  id: 'vip-3333-0000-0000-0000-000000000003',
  network_id: 'net-1',
  name: 'unassigned-vip',
  cidr: '10.99.0.1/32',
  anycast: false,
  state: 'unassigned' as const,
  holder_peer_ids: [],
  failover_holder_peer_ids: [],
  primary_holder_peer_id: null,
  primary_holder_address: null,
  advertised_med: 100,
  advertised_local_pref: 100,
  tags: [],
  description: null,
  assignments: [],
  created_at: null,
};

const PEERS_RESPONSE = { peers: [PEER_A, PEER_B] };
const VIPS_RESPONSE = (vips: typeof VIP_ACTIVE_PASSIVE[]) => ({
  virtual_ips: vips,
  count: vips.length,
});

// =============================================================================
// Helpers
// =============================================================================

interface RenderOptions {
  networkId?: string;
  refreshKey?: number;
  onEdit?: jest.Mock;
  onFailover?: jest.Mock;
  onDelete?: jest.Mock;
}

const renderList = ({
  networkId = 'net-1',
  refreshKey,
  onEdit,
  onFailover,
  onDelete,
}: RenderOptions = {}) =>
  render(
    <VirtualIpList
      networkId={networkId}
      refreshKey={refreshKey}
      onEdit={onEdit}
      onFailover={onFailover}
      onDelete={onDelete}
    />
  );

// =============================================================================
// Tests
// =============================================================================

describe('VirtualIpList', () => {
  beforeEach(() => {
    mockListVirtualIps.mockReset();
    mockGetPeers.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while the API calls are in flight', () => {
    // Never resolve so the component stays in the loading state
    mockListVirtualIps.mockReturnValue(new Promise(() => {}));
    mockGetPeers.mockReturnValue(new Promise(() => {}));

    renderList();

    expect(screen.getByText(/loading virtual ips/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('renders an error message when the API call fails', async () => {
    mockListVirtualIps.mockRejectedValue(new Error('Network error'));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() =>
      expect(screen.getByText('Network error')).toBeInTheDocument()
    );
  });

  it('renders a generic error message for non-Error rejections', async () => {
    mockListVirtualIps.mockRejectedValue('boom');
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() =>
      expect(screen.getByText(/failed to load virtual ips/i)).toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('renders the empty state when there are no VIPs', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() =>
      expect(screen.getByText(/no virtual ips in this network/i)).toBeInTheDocument()
    );
    expect(screen.getByText(/create a vip/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Data fetch — correct API calls
  // ---------------------------------------------------------------------------

  it('fetches VIPs and peers for the given networkId', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList({ networkId: 'net-1' });

    await waitFor(() =>
      expect(mockListVirtualIps).toHaveBeenCalledWith('net-1')
    );
    expect(mockGetPeers).toHaveBeenCalledWith('net-1');
  });

  it('re-fetches when refreshKey changes', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    const { rerender } = renderList({ refreshKey: 0 });

    await waitFor(() => expect(mockListVirtualIps).toHaveBeenCalledTimes(1));

    rerender(
      <VirtualIpList
        networkId="net-1"
        refreshKey={1}
      />
    );

    await waitFor(() => expect(mockListVirtualIps).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Table rendering
  // ---------------------------------------------------------------------------

  it('renders table headers', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());

    expect(screen.getByText('Name')).toBeInTheDocument();
    expect(screen.getByText('CIDR')).toBeInTheDocument();
    expect(screen.getByText('Mode')).toBeInTheDocument();
    expect(screen.getByText('State')).toBeInTheDocument();
    expect(screen.getByText('Holder')).toBeInTheDocument();
    expect(screen.getByText('Failover')).toBeInTheDocument();
    expect(screen.getByText('Actions')).toBeInTheDocument();
  });

  it('renders VIP name and CIDR in the table row', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());
    expect(screen.getByText('192.168.100.10/32')).toBeInTheDocument();
  });

  it('renders active/passive mode for non-anycast VIP', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('Active/passive')).toBeInTheDocument());
  });

  it('renders anycast mode with holder count for anycast VIP', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ANYCAST]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() =>
      expect(screen.getByText(/anycast \(2\)/i)).toBeInTheDocument()
    );
  });

  it('renders multiple VIPs in the table', async () => {
    mockListVirtualIps.mockResolvedValue(
      VIPS_RESPONSE([VIP_ACTIVE_PASSIVE, VIP_ANYCAST, VIP_UNASSIGNED])
    );
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());
    expect(screen.getByText('anycast-vip')).toBeInTheDocument();
    expect(screen.getByText('unassigned-vip')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // State color mapping
  // ---------------------------------------------------------------------------

  it('renders the VIP state text', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getAllByText('active').length).toBeGreaterThan(0));
  });

  it('renders pending state text for a pending VIP', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ANYCAST]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getAllByText('pending').length).toBeGreaterThan(0));
  });

  // ---------------------------------------------------------------------------
  // Failover column
  // ---------------------------------------------------------------------------

  it('shows "1 candidate" in the failover column when one failover peer exists', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() =>
      expect(screen.getByText('1 candidate')).toBeInTheDocument()
    );
  });

  it('shows "—" in the failover column when no failover peers exist', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ANYCAST]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('anycast-vip')).toBeInTheDocument());
    // The "—" emdash appears in the failover column (and also in holder for anycast)
    const dashes = screen.getAllByText('—');
    expect(dashes.length).toBeGreaterThan(0);
  });

  it('shows "2 candidates" for multiple failover peers', async () => {
    const vip = {
      ...VIP_UNASSIGNED,
      failover_holder_peer_ids: [PEER_A.id, PEER_B.id],
    };
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([vip]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() =>
      expect(screen.getByText('2 candidates')).toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // Holder column — peer label resolution
  // ---------------------------------------------------------------------------

  it('resolves the primary holder peer to node_instance_id prefix for active/passive VIP', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());
    // peerLabel uses node_instance_id sliced to 8 chars
    expect(screen.getByText('inst-aaa')).toBeInTheDocument();
  });

  it('shows "—" in the holder column when primary_holder_peer_id is null', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_UNASSIGNED]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() =>
      expect(screen.getByText('unassigned-vip')).toBeInTheDocument()
    );
    // multiple "—" are expected (holder + failover)
    expect(screen.getAllByText('—').length).toBeGreaterThan(0);
  });

  it('shows peer id prefix when the peer is not found in the peers map', async () => {
    const vip = {
      ...VIP_ACTIVE_PASSIVE,
      primary_holder_peer_id: 'unknown-peer-id-xyz',
    };
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([vip]));
    mockGetPeers.mockResolvedValue({ peers: [] });

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());
    // peerLabel falls back to peerId.slice(0, 8)
    expect(screen.getByText('unknown-')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Expand / Collapse row toggle
  // ---------------------------------------------------------------------------

  it('shows expand button for each VIP row', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());

    expect(
      screen.getByRole('button', { name: /expand vip web-vip/i })
    ).toBeInTheDocument();
  });

  it('toggles the expanded detail row when the expand button is clicked', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());

    // Detail row not visible yet
    expect(screen.queryByText('Primary Holder')).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /expand vip web-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('Primary Holder')).toBeInTheDocument()
    );

    // Button label should now say "Collapse"
    expect(
      screen.getByRole('button', { name: /collapse vip web-vip/i })
    ).toBeInTheDocument();
  });

  it('collapses the detail row when the button is clicked a second time', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /expand vip web-vip/i }));
    await waitFor(() =>
      expect(screen.getByText('Primary Holder')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByRole('button', { name: /collapse vip web-vip/i }));
    await waitFor(() =>
      expect(screen.queryByText('Primary Holder')).not.toBeInTheDocument()
    );
  });

  it('expands independently — expanding one VIP does not expand others', async () => {
    mockListVirtualIps.mockResolvedValue(
      VIPS_RESPONSE([VIP_ACTIVE_PASSIVE, VIP_ANYCAST])
    );
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /expand vip web-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('Primary Holder')).toBeInTheDocument()
    );

    // anycast-vip expand button still shows "Expand"
    expect(
      screen.getByRole('button', { name: /expand vip anycast-vip/i })
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Expanded row content
  // ---------------------------------------------------------------------------

  it('shows description in the expanded row when present', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand vip web-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('Production web VIP')).toBeInTheDocument()
    );
  });

  it('does not show description section when description is absent', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ANYCAST]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('anycast-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand vip anycast-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('Active Holders')).toBeInTheDocument()
    );
    expect(screen.queryByText('Description')).not.toBeInTheDocument();
  });

  it('shows tags in the expanded row', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand vip web-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('prod, web')).toBeInTheDocument()
    );
  });

  it('does not show Tags section when tags array is empty', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ANYCAST]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('anycast-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand vip anycast-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('Active Holders')).toBeInTheDocument()
    );
    expect(screen.queryByText('Tags')).not.toBeInTheDocument();
  });

  it('renders assignments in the expanded row (up to 5)', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand vip web-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('Recent Assignments')).toBeInTheDocument()
    );
    // The assignment renders the reason "initial"
    expect(screen.getByText(/initial/)).toBeInTheDocument();
    // Active assignment shows "· active"
    expect(screen.getByText(/· active/)).toBeInTheDocument();
  });

  it('shows "Primary Holder" section for active/passive VIP in expanded view', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand vip web-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('Primary Holder')).toBeInTheDocument()
    );
    // primary_holder_address should appear
    expect(screen.getByText('10.0.0.1')).toBeInTheDocument();
  });

  it('shows "Active Holders" section for anycast VIP in expanded view', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ANYCAST]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('anycast-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand vip anycast-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('Active Holders')).toBeInTheDocument()
    );
    // "Primary Holder" should NOT appear for anycast VIPs
    expect(screen.queryByText('Primary Holder')).not.toBeInTheDocument();
  });

  it('shows "Failover Candidates: none" when no failover peers in expanded view', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ANYCAST]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('anycast-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand vip anycast-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('Failover Candidates')).toBeInTheDocument()
    );
    expect(screen.getByText('none')).toBeInTheDocument();
  });

  it('shows advertised MED and local pref in expanded row', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand vip web-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('Advertised MED')).toBeInTheDocument()
    );
    expect(screen.getByText('Advertised Local Pref')).toBeInTheDocument();
  });

  it('shows the created_at date in the expanded row', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand vip web-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('Created')).toBeInTheDocument()
    );
  });

  it('does not show Created section when created_at is null', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_UNASSIGNED]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() =>
      expect(screen.getByText('unassigned-vip')).toBeInTheDocument()
    );
    fireEvent.click(screen.getByRole('button', { name: /expand vip unassigned-vip/i }));

    await waitFor(() =>
      expect(screen.getByText('Failover Candidates')).toBeInTheDocument()
    );
    expect(screen.queryByText('Created')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Action callbacks — onEdit
  // ---------------------------------------------------------------------------

  it('renders the edit button when onEdit is provided', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);
    const onEdit = jest.fn();

    renderList({ onEdit });

    await waitFor(() => expect(screen.getByTitle('Edit')).toBeInTheDocument());
  });

  it('does not render the edit button when onEdit is absent', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());
    expect(screen.queryByTitle('Edit')).not.toBeInTheDocument();
  });

  it('calls onEdit with the VIP when the edit button is clicked', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);
    const onEdit = jest.fn();

    renderList({ onEdit });

    await waitFor(() => expect(screen.getByTitle('Edit')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Edit'));

    expect(onEdit).toHaveBeenCalledTimes(1);
    expect(onEdit).toHaveBeenCalledWith(expect.objectContaining({ id: VIP_ACTIVE_PASSIVE.id }));
  });

  // ---------------------------------------------------------------------------
  // Action callbacks — onDelete
  // ---------------------------------------------------------------------------

  it('renders the delete button when onDelete is provided', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);
    const onDelete = jest.fn();

    renderList({ onDelete });

    await waitFor(() => expect(screen.getByTitle('Delete')).toBeInTheDocument());
  });

  it('calls onDelete with the VIP when the delete button is clicked', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);
    const onDelete = jest.fn();

    renderList({ onDelete });

    await waitFor(() => expect(screen.getByTitle('Delete')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Delete'));

    expect(onDelete).toHaveBeenCalledTimes(1);
    expect(onDelete).toHaveBeenCalledWith(
      expect.objectContaining({ id: VIP_ACTIVE_PASSIVE.id })
    );
  });

  // ---------------------------------------------------------------------------
  // Action callbacks — onFailover
  // ---------------------------------------------------------------------------

  it('renders the failover button only for active/passive VIPs with failover peers', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);
    const onFailover = jest.fn();

    renderList({ onFailover });

    await waitFor(() =>
      expect(screen.getByTitle('Trigger failover')).toBeInTheDocument()
    );
  });

  it('does not render the failover button for anycast VIPs even when onFailover provided', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ANYCAST]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);
    const onFailover = jest.fn();

    renderList({ onFailover });

    await waitFor(() =>
      expect(screen.getByText('anycast-vip')).toBeInTheDocument()
    );
    expect(screen.queryByTitle('Trigger failover')).not.toBeInTheDocument();
  });

  it('does not render the failover button when VIP has no failover peers', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_UNASSIGNED]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);
    const onFailover = jest.fn();

    renderList({ onFailover });

    await waitFor(() =>
      expect(screen.getByText('unassigned-vip')).toBeInTheDocument()
    );
    expect(screen.queryByTitle('Trigger failover')).not.toBeInTheDocument();
  });

  it('does not render the failover button when onFailover is not provided', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);

    renderList();

    await waitFor(() => expect(screen.getByText('web-vip')).toBeInTheDocument());
    expect(screen.queryByTitle('Trigger failover')).not.toBeInTheDocument();
  });

  it('calls onFailover with the VIP when the failover button is clicked', async () => {
    mockListVirtualIps.mockResolvedValue(VIPS_RESPONSE([VIP_ACTIVE_PASSIVE]));
    mockGetPeers.mockResolvedValue(PEERS_RESPONSE);
    const onFailover = jest.fn();

    renderList({ onFailover });

    await waitFor(() =>
      expect(screen.getByTitle('Trigger failover')).toBeInTheDocument()
    );
    fireEvent.click(screen.getByTitle('Trigger failover'));

    expect(onFailover).toHaveBeenCalledTimes(1);
    expect(onFailover).toHaveBeenCalledWith(
      expect.objectContaining({ id: VIP_ACTIVE_PASSIVE.id })
    );
  });
});
