import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { PeerList } from './PeerList';
import type { SdwanPeer } from '../../types/sdwan.types';

// =============================================================================
// Mocks
//
// PeerList calls sdwanApi.getPeers(networkId), which internally calls
// apiClient.get and unwraps the envelope via extractData. We stub the
// sdwanApi facade directly so tests resolve to the already-unwrapped shape
// { peers: SdwanPeer[] } — no double-envelope needed here.
// =============================================================================

const mockGetPeers = jest.fn();

jest.mock('../../services/api/sdwanApi', () => ({
  sdwanApi: {
    getPeers: (...args: unknown[]) => mockGetPeers(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

/** sdwanApi.getPeers resolves to { peers } (already unwrapped). */
function peersResponse(peers: SdwanPeer[]) {
  return { peers };
}

const PEER_HUB: SdwanPeer = {
  id: 'peer-hub-1',
  network_id: 'net-abc',
  node_instance_id: 'ni-aabbccdd-1111-2222-3333-444455556666',
  assigned_address: 'fd00::1/128',
  publicly_reachable: true,
  endpoint: '203.0.113.10:51820',
  endpoint_host: '203.0.113.10',
  endpoint_host_v6: '2001:db8::1',
  endpoint_host_v4: '203.0.113.10',
  endpoint_port: 51820,
  effective_endpoint: '2001:db8::1:51820',
  effective_endpoint_family: 'v6',
  fallback_endpoint: '203.0.113.10:51820',
  listen_port: 51820,
  status: 'active',
  public_key: 'abc123pubkeyXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=',
  last_handshake_at: '2026-05-01T12:00:00Z',
  capabilities: { wg_kernel: true },
  created_at: '2026-01-01T00:00:00Z',
  lan_subnets: ['10.10.0.0/24', '10.20.0.0/24'],
  bgp_route_reflector_client: true,
  bgp_router_id_override: '10.10.0.1',
  advertised_prefix_count: 2,
};

const PEER_SPOKE: SdwanPeer = {
  id: 'peer-spoke-1',
  network_id: 'net-abc',
  node_instance_id: 'ni-bbccddee-2222-3333-4444-555566667777',
  assigned_address: 'fd00::2/128',
  publicly_reachable: false,
  endpoint: null,
  listen_port: 51820,
  status: 'degraded',
  last_handshake_at: null,
  created_at: '2026-01-02T00:00:00Z',
  lan_subnets: [],
  bgp_route_reflector_client: false,
  advertised_prefix_count: 0,
};

const PEER_PENDING: SdwanPeer = {
  id: 'peer-pending-1',
  network_id: 'net-abc',
  node_instance_id: 'ni-ccddee11-3333-4444-5555-666677778888',
  assigned_address: 'fd00::3/128',
  publicly_reachable: false,
  listen_port: 51820,
  status: 'pending',
  created_at: '2026-01-03T00:00:00Z',
};

const PEER_DISCONNECTED: SdwanPeer = {
  id: 'peer-disc-1',
  network_id: 'net-abc',
  node_instance_id: 'ni-ddee1122-4444-5555-6666-777788889999',
  assigned_address: 'fd00::4/128',
  publicly_reachable: false,
  listen_port: 51820,
  status: 'disconnected',
  created_at: '2026-01-04T00:00:00Z',
};

// =============================================================================
// Tests
// =============================================================================

describe('PeerList', () => {
  beforeEach(() => {
    mockGetPeers.mockReset();
  });

  // ── Loading state ────────────────────────────────────────────────────────────

  it('shows a loading indicator while fetching peers', () => {
    // Never resolves — keeps component in loading state.
    mockGetPeers.mockReturnValue(new Promise(() => {}));
    render(<PeerList networkId="net-abc" />);
    expect(screen.getByText(/loading peers/i)).toBeInTheDocument();
  });

  // ── Error state ──────────────────────────────────────────────────────────────

  it('shows an error message when the API call fails', async () => {
    mockGetPeers.mockRejectedValue(new Error('Network error'));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getByText('Network error')).toBeInTheDocument(),
    );
  });

  it('shows a fallback error message when the error has no message', async () => {
    mockGetPeers.mockRejectedValue('boom');
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getByText('Failed to load peers')).toBeInTheDocument(),
    );
  });

  // ── Empty state ──────────────────────────────────────────────────────────────

  it('renders the empty state when there are no peers', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(
        screen.getByText(/no peers attached yet/i),
      ).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/use the attach peer button/i),
    ).toBeInTheDocument();
  });

  // ── API call wiring ──────────────────────────────────────────────────────────

  it('calls sdwanApi.getPeers with the correct networkId', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-xyz" />);
    await waitFor(() => expect(mockGetPeers).toHaveBeenCalledWith('net-xyz'));
  });

  it('re-fetches peers when refreshKey changes', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    const { rerender } = render(<PeerList networkId="net-abc" refreshKey={0} />);
    await waitFor(() => expect(mockGetPeers).toHaveBeenCalledTimes(1));

    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB, PEER_SPOKE]));
    rerender(<PeerList networkId="net-abc" refreshKey={1} />);
    await waitFor(() => expect(mockGetPeers).toHaveBeenCalledTimes(2));
  });

  // ── Table rendering ──────────────────────────────────────────────────────────

  it('renders the table headers', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getByText('Role')).toBeInTheDocument(),
    );
    expect(screen.getByText('Address')).toBeInTheDocument();
    expect(screen.getByText('Endpoint')).toBeInTheDocument();
    expect(screen.getByText('Status')).toBeInTheDocument();
    expect(screen.getByText('Last handshake')).toBeInTheDocument();
    expect(screen.getByText('Actions')).toBeInTheDocument();
  });

  it('renders Hub label for publicly_reachable peers', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getByText('Hub')).toBeInTheDocument(),
    );
  });

  it('renders Spoke label for non-publicly_reachable peers', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_SPOKE]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getByText('Spoke')).toBeInTheDocument(),
    );
  });

  it('renders assigned_address for each peer', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB, PEER_SPOKE]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getAllByText('fd00::1/128').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('fd00::2/128').length).toBeGreaterThan(0);
  });

  it('renders the endpoint for hub peers', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getByText('203.0.113.10:51820')).toBeInTheDocument(),
    );
  });

  it('renders "outbound only" for spoke peers without an endpoint', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_SPOKE]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getByText('outbound only')).toBeInTheDocument(),
    );
  });

  it('renders "—" for hub peers without an endpoint', async () => {
    const hubNoEndpoint: SdwanPeer = {
      ...PEER_HUB,
      endpoint: null,
    };
    mockGetPeers.mockResolvedValue(peersResponse([hubNoEndpoint]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getByText('—')).toBeInTheDocument(),
    );
  });

  it('renders "never" for peers with no last_handshake_at', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_SPOKE]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getByText('never')).toBeInTheDocument(),
    );
  });

  it('renders the formatted last_handshake_at date when present', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      // The component renders new Date(p.last_handshake_at).toLocaleString()
      // We just verify the timestamp text is rendered at all (locale-dependent)
      expect(
        screen.getAllByText(
          new Date(PEER_HUB.last_handshake_at!).toLocaleString(),
        ).length,
      ).toBeGreaterThan(0),
    );
  });

  // ── Status badge colours ─────────────────────────────────────────────────────

  it('renders the status text for each peer', async () => {
    mockGetPeers.mockResolvedValue(
      peersResponse([PEER_HUB, PEER_SPOKE, PEER_PENDING, PEER_DISCONNECTED]),
    );
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getAllByText('active').length).toBeGreaterThan(0),
    );
    expect(screen.getByText('degraded')).toBeInTheDocument();
    expect(screen.getByText('pending')).toBeInTheDocument();
    expect(screen.getByText('disconnected')).toBeInTheDocument();
  });

  // ── Expand / collapse row ────────────────────────────────────────────────────

  it('shows expand button and hides detail panel initially', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(
        screen.getByTitle('Expand details'),
      ).toBeInTheDocument(),
    );
    // Detail label should not be visible before expansion
    expect(screen.queryByText('Overlay Address')).not.toBeInTheDocument();
  });

  it('expands a row to show detail when the chevron is clicked', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    const expandBtn = await waitFor(() =>
      screen.getByTitle('Expand details'),
    );
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getByText('Overlay Address')).toBeInTheDocument(),
    );
    expect(screen.getByText('Listen Port')).toBeInTheDocument();
    expect(screen.getByText('LAN Subnets')).toBeInTheDocument();
    expect(screen.getByText('Node Instance ID')).toBeInTheDocument();
  });

  it('shows the expand button aria-label containing the assigned_address', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(
        screen.getByLabelText('Expand peer fd00::1/128'),
      ).toBeInTheDocument(),
    );
  });

  it('updates the aria-label to Collapse after expanding', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(
      await waitFor(() => screen.getByLabelText('Expand peer fd00::1/128')),
    );

    await waitFor(() =>
      expect(
        screen.getByLabelText('Collapse peer fd00::1/128'),
      ).toBeInTheDocument(),
    );
  });

  it('collapses an expanded row when the chevron is clicked again', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Overlay Address')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() =>
      expect(screen.queryByText('Overlay Address')).not.toBeInTheDocument(),
    );
  });

  it('allows multiple rows to be expanded simultaneously', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB, PEER_SPOKE]));
    render(<PeerList networkId="net-abc" />);

    const expandBtns = await waitFor(() =>
      screen.getAllByTitle('Expand details'),
    );
    expect(expandBtns).toHaveLength(2);

    fireEvent.click(expandBtns[0]);
    fireEvent.click(expandBtns[1]);

    // Both detail panels have "Overlay Address" labels — one per expanded row
    await waitFor(() =>
      expect(screen.getAllByText('Overlay Address').length).toBe(2),
    );
  });

  // ── Expanded detail panel fields ─────────────────────────────────────────────

  it('shows Hub (publicly reachable) role in the expanded detail', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(
        screen.getByText('Hub (publicly reachable)'),
      ).toBeInTheDocument(),
    );
  });

  it('shows Spoke (outbound only) role in the expanded detail', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_SPOKE]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(
        screen.getByText('Spoke (outbound only)'),
      ).toBeInTheDocument(),
    );
  });

  it('shows the effective_endpoint in the expanded detail when present', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Effective Endpoint')).toBeInTheDocument(),
    );
    // The value + family suffix: "2001:db8::1:51820 (v6)"
    expect(
      screen.getByText(/2001:db8::1:51820.*v6/),
    ).toBeInTheDocument();
  });

  it('does NOT show the Effective Endpoint section when effective_endpoint is absent', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_SPOKE]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Overlay Address')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Effective Endpoint')).not.toBeInTheDocument();
  });

  it('shows the fallback_endpoint in the expanded detail when present', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Fallback Endpoint')).toBeInTheDocument(),
    );
    // The endpoint value appears in both the table row column and the detail
    // panel; verify at least one match for the fallback endpoint value.
    expect(
      screen.getAllByText('203.0.113.10:51820').length,
    ).toBeGreaterThan(0);
  });

  it('shows endpoint host v6 and v4 when both are present', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Endpoint Hosts')).toBeInTheDocument(),
    );
    // "v6 2001:db8::1 · v4 203.0.113.10:51820"
    expect(screen.getByText(/v6 2001:db8::1/)).toBeInTheDocument();
    expect(screen.getByText(/v4 203\.0\.113\.10/)).toBeInTheDocument();
  });

  it('shows the public_key in the expanded detail when present', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Public Key')).toBeInTheDocument(),
    );
    expect(
      screen.getByText('abc123pubkeyXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX='),
    ).toBeInTheDocument();
  });

  it('shows LAN subnets joined by comma in expanded detail', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(
        screen.getByText('10.10.0.0/24, 10.20.0.0/24'),
      ).toBeInTheDocument(),
    );
  });

  it('shows "none advertised" when LAN subnets array is empty', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_SPOKE]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('none advertised')).toBeInTheDocument(),
    );
  });

  it('shows BGP Route Reflector Client as "Yes" when flag is true', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('BGP Route Reflector Client')).toBeInTheDocument(),
    );
    expect(screen.getByText('Yes')).toBeInTheDocument();
  });

  it('shows BGP Route Reflector Client as "No" when flag is false', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_SPOKE]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('BGP Route Reflector Client')).toBeInTheDocument(),
    );
    expect(screen.getByText('No')).toBeInTheDocument();
  });

  it('shows BGP Router ID Override when set', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('BGP Router ID Override')).toBeInTheDocument(),
    );
    expect(screen.getByText('10.10.0.1')).toBeInTheDocument();
  });

  it('hides BGP Router ID Override section when not set', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_SPOKE]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Overlay Address')).toBeInTheDocument(),
    );
    expect(
      screen.queryByText('BGP Router ID Override'),
    ).not.toBeInTheDocument();
  });

  it('shows advertised_prefix_count in expanded detail', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Advertised Prefixes')).toBeInTheDocument(),
    );
    // PEER_HUB.advertised_prefix_count = 2
    expect(screen.getByText('2')).toBeInTheDocument();
  });

  it('shows 0 for advertised_prefix_count when undefined', async () => {
    const peerNoCount: SdwanPeer = { ...PEER_SPOKE, advertised_prefix_count: undefined };
    mockGetPeers.mockResolvedValue(peersResponse([peerNoCount]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Advertised Prefixes')).toBeInTheDocument(),
    );
    expect(screen.getByText('0')).toBeInTheDocument();
  });

  it('shows the node_instance_id in expanded detail', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Node Instance ID')).toBeInTheDocument(),
    );
    expect(
      screen.getByText('ni-aabbccdd-1111-2222-3333-444455556666'),
    ).toBeInTheDocument();
  });

  it('renders capabilities JSON in a pre block when capabilities are non-empty', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Capabilities')).toBeInTheDocument(),
    );
    // JSON.stringify({ wg_kernel: true }, null, 2) rendered in a pre block
    const pre = screen.getByText(/"wg_kernel"/);
    expect(pre.tagName).toBe('PRE');
  });

  it('does not show Capabilities section when capabilities is empty/undefined', async () => {
    const peerNoCaps: SdwanPeer = { ...PEER_SPOKE, capabilities: {} };
    mockGetPeers.mockResolvedValue(peersResponse([peerNoCaps]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Overlay Address')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Capabilities')).not.toBeInTheDocument();
  });

  it('shows Attached date in expanded detail when created_at is set', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Attached')).toBeInTheDocument(),
    );
    expect(
      screen.getByText(new Date('2026-01-01T00:00:00Z').toLocaleString()),
    ).toBeInTheDocument();
  });

  // ── onEdit callback ──────────────────────────────────────────────────────────

  it('renders the Edit button when onEdit prop is provided', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    const onEdit = jest.fn();
    render(<PeerList networkId="net-abc" onEdit={onEdit} />);
    await waitFor(() =>
      expect(
        screen.getByLabelText('Edit peer fd00::1/128'),
      ).toBeInTheDocument(),
    );
  });

  it('does NOT render the Edit button when onEdit prop is absent', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getAllByText('Hub').length).toBeGreaterThan(0),
    );
    expect(
      screen.queryByLabelText('Edit peer fd00::1/128'),
    ).not.toBeInTheDocument();
  });

  it('calls onEdit with the correct peer when the Edit button is clicked', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    const onEdit = jest.fn();
    render(<PeerList networkId="net-abc" onEdit={onEdit} />);

    fireEvent.click(
      await waitFor(() => screen.getByLabelText('Edit peer fd00::1/128')),
    );

    expect(onEdit).toHaveBeenCalledWith(PEER_HUB);
  });

  // ── onDetach callback ────────────────────────────────────────────────────────

  it('renders the Detach button when onDetach prop is provided', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    const onDetach = jest.fn();
    render(<PeerList networkId="net-abc" onDetach={onDetach} />);
    await waitFor(() =>
      expect(
        screen.getByLabelText('Detach peer fd00::1/128'),
      ).toBeInTheDocument(),
    );
  });

  it('does NOT render the Detach button when onDetach prop is absent', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    render(<PeerList networkId="net-abc" />);
    await waitFor(() =>
      expect(screen.getAllByText('Hub').length).toBeGreaterThan(0),
    );
    expect(
      screen.queryByLabelText('Detach peer fd00::1/128'),
    ).not.toBeInTheDocument();
  });

  it('calls onDetach with the correct peer when the Detach button is clicked', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB]));
    const onDetach = jest.fn();
    render(<PeerList networkId="net-abc" onDetach={onDetach} />);

    fireEvent.click(
      await waitFor(() => screen.getByLabelText('Detach peer fd00::1/128')),
    );

    expect(onDetach).toHaveBeenCalledWith(PEER_HUB);
  });

  it('calls each callback with the correct peer when multiple peers are present', async () => {
    mockGetPeers.mockResolvedValue(peersResponse([PEER_HUB, PEER_SPOKE]));
    const onEdit = jest.fn();
    const onDetach = jest.fn();
    render(<PeerList networkId="net-abc" onEdit={onEdit} onDetach={onDetach} />);

    // Click edit on the spoke peer
    fireEvent.click(
      await waitFor(() => screen.getByLabelText('Edit peer fd00::2/128')),
    );
    expect(onEdit).toHaveBeenCalledWith(PEER_SPOKE);

    // Click detach on the hub peer
    fireEvent.click(screen.getByLabelText('Detach peer fd00::1/128'));
    expect(onDetach).toHaveBeenCalledWith(PEER_HUB);
  });
});
