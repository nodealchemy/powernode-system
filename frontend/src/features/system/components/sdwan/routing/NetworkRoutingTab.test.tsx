import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NetworkRoutingTab } from './NetworkRoutingTab';
import type { SdwanNetwork, SdwanPeer } from '../../../types/sdwan.types';

// =============================================================================
// Mocks
//
// NetworkRoutingTab calls sdwanApi.getPeers on mount and sdwanApi.updateNetwork
// when the user changes routing mode. BgpSessionsTable is a child component
// that makes its own sdwanApi.getBgpSessions call — it's mocked to a sentinel
// so the routing tab tests are fully isolated.
// =============================================================================

const mockGet = jest.fn();
const mockPut = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => jest.fn()(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => jest.fn()(...args),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => true,
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

// Stub BgpSessionsTable so it doesn't fire its own API calls and pollute mocks
jest.mock(
  '@system/features/system/components/sdwan/routing/BgpSessionsTable',
  () => ({
    BgpSessionsTable: ({ networkId }: { networkId: string }) => (
      <div data-testid="bgp-sessions-table" data-network-id={networkId}>
        BGP Sessions
      </div>
    ),
  }),
);

// =============================================================================
// Helpers — double-envelope pattern (apiClient → AxiosResponse body)
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function peersEnvelope(peers: SdwanPeer[]) {
  return envelope({ peers, count: peers.length });
}

// =============================================================================
// Fixtures
// =============================================================================

const STATIC_NETWORK: SdwanNetwork = {
  id: 'net-static-1',
  name: 'prod-overlay',
  slug: 'prod-overlay',
  status: 'active',
  cidr_64: 'fd00::/64',
  peer_count: 2,
  created_at: '2026-01-01T00:00:00Z',
  routing_protocol: 'static',
  route_reflector_redundancy: 1,
};

const IBGP_NETWORK: SdwanNetwork = {
  ...STATIC_NETWORK,
  id: 'net-ibgp-1',
  routing_protocol: 'ibgp',
  route_reflector_redundancy: 2,
};

const HUB_PEER: SdwanPeer = {
  id: 'peer-hub-abcd1234',
  network_id: 'net-static-1',
  node_instance_id: 'inst-hub-efgh5678',
  assigned_address: 'fd00::1',
  publicly_reachable: true,
  listen_port: 51820,
  status: 'active',
  lan_subnets: ['192.168.1.0/24', '10.0.0.0/8'],
};

const SPOKE_PEER: SdwanPeer = {
  id: 'peer-spoke-wxyz9012',
  network_id: 'net-static-1',
  node_instance_id: 'inst-spoke-mnop3456',
  assigned_address: 'fd00::2',
  publicly_reachable: false,
  listen_port: 51820,
  status: 'active',
  lan_subnets: [],
};

// =============================================================================
// Render helpers
// =============================================================================

interface RenderOptions {
  network?: SdwanNetwork;
  onNetworkUpdated?: jest.Mock;
  onActionsReady?: jest.Mock;
}

function renderTab({
  network = STATIC_NETWORK,
  onNetworkUpdated = jest.fn(),
  onActionsReady = jest.fn(),
}: RenderOptions = {}) {
  return render(
    <BrowserRouter>
      <NetworkRoutingTab
        network={network}
        onNetworkUpdated={onNetworkUpdated}
        onActionsReady={onActionsReady}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('NetworkRoutingTab', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPut.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while peers are fetching', () => {
    // Never resolve so we stay in loading state
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.getByText(/loading routing data/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows the error message when getPeers rejects', async () => {
    mockGet.mockRejectedValueOnce(new Error('Network request failed'));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Network request failed')).toBeInTheDocument(),
    );
  });

  it('shows a generic error for non-Error rejections', async () => {
    mockGet.mockRejectedValueOnce('unknown failure');

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Failed to load routing data')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Routing protocol banner — static
  // ---------------------------------------------------------------------------

  it('renders the static routing protocol banner when protocol is static', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    renderTab({ network: STATIC_NETWORK });

    await waitFor(() =>
      expect(screen.getByText(/routing protocol:/i)).toBeInTheDocument(),
    );
    expect(screen.getByText('static')).toBeInTheDocument();
    expect(
      screen.getByText(/Static — declared LAN subnets/i),
    ).toBeInTheDocument();
  });

  it('renders the iBGP routing protocol banner when protocol is ibgp', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    renderTab({ network: IBGP_NETWORK });

    await waitFor(() =>
      expect(screen.getByText('ibgp')).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/iBGP — FRR daemon distributes routes/i),
    ).toBeInTheDocument();
  });

  it('falls back to "static" label when routing_protocol is undefined', async () => {
    const networkWithoutProtocol: SdwanNetwork = {
      ...STATIC_NETWORK,
      routing_protocol: undefined,
    };
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    renderTab({ network: networkWithoutProtocol });

    await waitFor(() =>
      expect(screen.getByText(/routing protocol:/i)).toBeInTheDocument(),
    );
    // The fallback text renders as "static" in the font-mono span
    expect(screen.getByText('static')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Peer list — empty state
  // ---------------------------------------------------------------------------

  it('shows "No peers in this network yet" when peer list is empty', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByText(/no peers in this network yet/i),
      ).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Peer list — populated
  // ---------------------------------------------------------------------------

  it('renders peer rows with correct hub/spoke role labels', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([HUB_PEER, SPOKE_PEER]));

    renderTab();

    await waitFor(() => expect(screen.getByText('Hub')).toBeInTheDocument());
    expect(screen.getByText('Spoke')).toBeInTheDocument();
  });

  it('renders peer overlay addresses', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([HUB_PEER]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('fd00::1')).toBeInTheDocument(),
    );
  });

  it('renders LAN subnets as individual tags', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([HUB_PEER]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('192.168.1.0/24')).toBeInTheDocument(),
    );
    expect(screen.getByText('10.0.0.0/8')).toBeInTheDocument();
  });

  it('shows a dash for peers with no LAN subnets', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([SPOKE_PEER]));

    renderTab();

    // The "—" for empty subnets
    await waitFor(() =>
      expect(screen.getByText('—')).toBeInTheDocument(),
    );
  });

  it('counts total prefixes correctly in the header', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([HUB_PEER, SPOKE_PEER]));

    renderTab();

    // HUB_PEER has 2 subnets, SPOKE_PEER has 0 → total 2
    await waitFor(() =>
      expect(screen.getByText('2 prefixes')).toBeInTheDocument(),
    );
  });

  it('uses singular "prefix" when only one subnet exists', async () => {
    const singleSubnetPeer: SdwanPeer = {
      ...HUB_PEER,
      lan_subnets: ['192.168.1.0/24'],
    };
    mockGet.mockResolvedValueOnce(peersEnvelope([singleSubnetPeer]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('1 prefix')).toBeInTheDocument(),
    );
  });

  it('renders a truncated node_instance_id as the peer identifier', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([HUB_PEER]));

    renderTab();

    // node_instance_id: 'inst-hub-efgh5678' → first 8 chars = 'inst-hub'
    await waitFor(() =>
      expect(screen.getByText('inst-hub')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // API call — correct URL and network id
  // ---------------------------------------------------------------------------

  it('fetches peers with the correct network id URL', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    renderTab({ network: STATIC_NETWORK });

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(
        `/system/sdwan/networks/${STATIC_NETWORK.id}/peers`,
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // onActionsReady callback
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with a handle on mount', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(onActionsReady).toHaveBeenCalledWith(
        expect.objectContaining({ openModeToggle: expect.any(Function) }),
      ),
    );
  });

  it('calls onActionsReady(null) on unmount', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    const onActionsReady = jest.fn();
    const { unmount } = renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalledTimes(1));

    unmount();

    expect(onActionsReady).toHaveBeenLastCalledWith(null);
  });

  // ---------------------------------------------------------------------------
  // Mode toggle modal — opening via onActionsReady handle
  // ---------------------------------------------------------------------------

  it('opens the mode toggle modal when openModeToggle handle is called', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    const handle = onActionsReady.mock.calls[0][0];
    handle.openModeToggle();

    await waitFor(() =>
      expect(
        screen.getByText('Change routing protocol'),
      ).toBeInTheDocument(),
    );
  });

  it('modal shows two routing options: Static and iBGP', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openModeToggle();

    await waitFor(() =>
      expect(screen.getByText('Static')).toBeInTheDocument(),
    );
    expect(screen.getByText('iBGP (Free Range Routing)')).toBeInTheDocument();
  });

  it('disables Static button when already on static protocol', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    const onActionsReady = jest.fn();
    renderTab({ network: STATIC_NETWORK, onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openModeToggle();

    await waitFor(() =>
      expect(screen.getByText('Static')).toBeInTheDocument(),
    );

    // The Static button should be disabled (current protocol)
    const staticBtn = screen.getByText('Static').closest('button');
    expect(staticBtn).toBeDisabled();

    // The iBGP button should be enabled
    const ibgpBtn = screen.getByText('iBGP (Free Range Routing)').closest('button');
    expect(ibgpBtn).not.toBeDisabled();
  });

  it('disables iBGP button when already on ibgp protocol', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    const onActionsReady = jest.fn();
    renderTab({ network: IBGP_NETWORK, onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openModeToggle();

    await waitFor(() =>
      expect(screen.getByText('iBGP (Free Range Routing)')).toBeInTheDocument(),
    );

    const ibgpBtn = screen.getByText('iBGP (Free Range Routing)').closest('button');
    expect(ibgpBtn).toBeDisabled();

    const staticBtn = screen.getByText('Static').closest('button');
    expect(staticBtn).not.toBeDisabled();
  });

  it('closes the modal when onClose is triggered (clicking outside/X)', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openModeToggle();

    await waitFor(() =>
      expect(screen.getByText('Change routing protocol')).toBeInTheDocument(),
    );

    // Find and click the modal close button (the X)
    const closeBtn = screen.getByRole('button', { name: /close/i });
    fireEvent.click(closeBtn);

    await waitFor(() =>
      expect(
        screen.queryByText('Change routing protocol'),
      ).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Mode toggle — success flow: static → ibgp
  // ---------------------------------------------------------------------------

  it('calls updateNetwork with correct payload when switching to ibgp', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));
    mockPut.mockResolvedValueOnce(
      envelope({ network: { ...STATIC_NETWORK, routing_protocol: 'ibgp' } }),
    );

    const onActionsReady = jest.fn();
    const onNetworkUpdated = jest.fn();
    renderTab({ network: STATIC_NETWORK, onActionsReady, onNetworkUpdated });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openModeToggle();

    await waitFor(() =>
      expect(screen.getByText('iBGP (Free Range Routing)')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('iBGP (Free Range Routing)').closest('button')!);

    await waitFor(() =>
      expect(mockPut).toHaveBeenCalledWith(
        `/system/sdwan/networks/${STATIC_NETWORK.id}`,
        { network: { routing_protocol: 'ibgp' } },
      ),
    );
  });

  it('calls onNetworkUpdated with the updated network after mode switch', async () => {
    const updatedNetwork = { ...STATIC_NETWORK, routing_protocol: 'ibgp' as const };
    mockGet.mockResolvedValueOnce(peersEnvelope([]));
    // First put, then a re-fetch for the refreshKey
    mockPut.mockResolvedValueOnce(envelope({ network: updatedNetwork }));
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    const onActionsReady = jest.fn();
    const onNetworkUpdated = jest.fn();
    renderTab({ network: STATIC_NETWORK, onActionsReady, onNetworkUpdated });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openModeToggle();

    await waitFor(() =>
      expect(screen.getByText('iBGP (Free Range Routing)')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('iBGP (Free Range Routing)').closest('button')!);

    await waitFor(() =>
      expect(onNetworkUpdated).toHaveBeenCalledWith(updatedNetwork),
    );
  });

  it('shows a success notification after mode switch and closes modal', async () => {
    const updatedNetwork = { ...STATIC_NETWORK, routing_protocol: 'ibgp' as const };
    mockGet.mockResolvedValueOnce(peersEnvelope([]));
    mockPut.mockResolvedValueOnce(envelope({ network: updatedNetwork }));
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    const onActionsReady = jest.fn();
    renderTab({ network: STATIC_NETWORK, onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openModeToggle();

    await waitFor(() =>
      expect(screen.getByText('iBGP (Free Range Routing)')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('iBGP (Free Range Routing)').closest('button')!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Network routing mode changed to ibgp.',
      }),
    );

    // Modal should be closed after success
    await waitFor(() =>
      expect(
        screen.queryByText('Change routing protocol'),
      ).not.toBeInTheDocument(),
    );
  });

  it('calls updateNetwork with "static" payload when switching from ibgp to static', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));
    mockPut.mockResolvedValueOnce(
      envelope({ network: { ...IBGP_NETWORK, routing_protocol: 'static' } }),
    );
    mockGet.mockResolvedValueOnce(peersEnvelope([]));

    const onActionsReady = jest.fn();
    renderTab({ network: IBGP_NETWORK, onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openModeToggle();

    await waitFor(() =>
      expect(screen.getByText('Static')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('Static').closest('button')!);

    await waitFor(() =>
      expect(mockPut).toHaveBeenCalledWith(
        `/system/sdwan/networks/${IBGP_NETWORK.id}`,
        { network: { routing_protocol: 'static' } },
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Mode toggle — error flow
  // ---------------------------------------------------------------------------

  it('shows an error notification when updateNetwork rejects', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));
    mockPut.mockRejectedValueOnce(new Error('Server rejected the mode switch'));

    const onActionsReady = jest.fn();
    renderTab({ network: STATIC_NETWORK, onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openModeToggle();

    await waitFor(() =>
      expect(screen.getByText('iBGP (Free Range Routing)')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('iBGP (Free Range Routing)').closest('button')!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Server rejected the mode switch',
      }),
    );
  });

  it('shows a generic error notification for non-Error rejection', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));
    mockPut.mockRejectedValueOnce('opaque error');

    const onActionsReady = jest.fn();
    renderTab({ network: STATIC_NETWORK, onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openModeToggle();

    await waitFor(() =>
      expect(screen.getByText('iBGP (Free Range Routing)')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('iBGP (Free Range Routing)').closest('button')!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to change routing mode',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // iBGP-only sections — hidden for static networks
  // ---------------------------------------------------------------------------

  it('does NOT render route reflectors section for static networks', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([HUB_PEER]));

    renderTab({ network: STATIC_NETWORK });

    await waitFor(() =>
      expect(screen.getByText('Hub')).toBeInTheDocument(),
    );

    expect(screen.queryByText('Route reflectors')).not.toBeInTheDocument();
    expect(screen.queryByTestId('bgp-sessions-table')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // iBGP-only sections — visible for ibgp networks
  // ---------------------------------------------------------------------------

  it('renders the route reflectors section for ibgp networks', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([HUB_PEER, SPOKE_PEER]));

    renderTab({ network: IBGP_NETWORK });

    await waitFor(() =>
      expect(screen.getByText('Route reflectors')).toBeInTheDocument(),
    );
  });

  it('renders hub peers as route reflectors in iBGP mode', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([HUB_PEER, SPOKE_PEER]));

    renderTab({ network: IBGP_NETWORK });

    await waitFor(() =>
      expect(screen.getByText(/\(RR\)/)).toBeInTheDocument(),
    );
    // Hub peer's node_instance_id sliced: 'inst-hub-efgh5678' → 'inst-hub'
    expect(screen.getAllByText(/inst-hub/)[0]).toBeInTheDocument();
  });

  it('shows warning when no hubs exist in iBGP mode', async () => {
    // Only a spoke peer — no publicly_reachable peers
    mockGet.mockResolvedValueOnce(peersEnvelope([SPOKE_PEER]));

    renderTab({ network: IBGP_NETWORK });

    await waitFor(() =>
      expect(
        screen.getByText(/No publicly reachable hubs/i),
      ).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/iBGP needs at least one route reflector/i),
    ).toBeInTheDocument();
  });

  it('renders the BgpSessionsTable with correct networkId in iBGP mode', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([HUB_PEER]));

    renderTab({ network: IBGP_NETWORK });

    await waitFor(() =>
      expect(screen.getByTestId('bgp-sessions-table')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('bgp-sessions-table')).toHaveAttribute(
      'data-network-id',
      IBGP_NETWORK.id,
    );
  });

  it('shows the route_reflector_redundancy count in the iBGP panel', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([HUB_PEER]));

    renderTab({ network: IBGP_NETWORK });

    await waitFor(() =>
      expect(screen.getByText('Route reflectors')).toBeInTheDocument(),
    );
    // redundancy = 2 from IBGP_NETWORK fixture
    expect(screen.getByText('2')).toBeInTheDocument();
  });

  it('renders the advertisement audit trail placeholder in iBGP mode', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([HUB_PEER]));

    renderTab({ network: IBGP_NETWORK });

    await waitFor(() =>
      expect(
        screen.getByText(/Advertisement audit trail/),
      ).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/system_sdwan_list_subnet_advertisements/),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Refresh behavior — refreshKey increments after a successful mode switch
  // ---------------------------------------------------------------------------

  it('re-fetches peers after a successful mode switch', async () => {
    const updatedNetwork = { ...STATIC_NETWORK, routing_protocol: 'ibgp' as const };
    mockGet
      .mockResolvedValueOnce(peersEnvelope([]))       // initial fetch
      .mockResolvedValueOnce(peersEnvelope([HUB_PEER])); // after refresh

    mockPut.mockResolvedValueOnce(envelope({ network: updatedNetwork }));

    const onActionsReady = jest.fn();
    renderTab({ network: STATIC_NETWORK, onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openModeToggle();

    await waitFor(() =>
      expect(screen.getByText('iBGP (Free Range Routing)')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('iBGP (Free Range Routing)').closest('button')!);

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Pending-approval branch (IMP-87ec6f651f07)
  // ---------------------------------------------------------------------------

  it('shows the pending-approval notification (not success) and skips onNetworkUpdated when the mode change is parked', async () => {
    mockGet.mockResolvedValueOnce(peersEnvelope([]));
    mockPut.mockResolvedValueOnce({
      status: 202,
      data: {
        success: true,
        data: {
          pending: true,
          deferred_operation_id: 'dop-1',
          action_category: 'sdwan.network_update',
          approval_request_id: 'ar-1',
          message: 'Approval required',
        },
      },
    });

    const onActionsReady = jest.fn();
    const onNetworkUpdated = jest.fn();
    renderTab({ network: STATIC_NETWORK, onActionsReady, onNetworkUpdated });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openModeToggle();

    await waitFor(() =>
      expect(screen.getByText('iBGP (Free Range Routing)')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('iBGP (Free Range Routing)').closest('button')!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringMatching(/approval required/i),
          link: expect.objectContaining({ to: '/app/ai/agents/autonomy' }),
        }),
      ),
    );
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' }),
    );
    expect(onNetworkUpdated).not.toHaveBeenCalled();
  });
});
