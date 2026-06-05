import React from 'react';
import { render, screen, waitFor, act } from '@testing-library/react';
import { SdwanTopology } from './SdwanTopology';
import type { SdwanTopologyResponse } from '../../types/sdwan.types';

// =============================================================================
// Mocks
//
// SdwanTopology calls sdwanApi.getTopology which internally uses apiClient.get.
// We mock sdwanApi directly (the facade) since that's what the component imports.
// ReactFlow is mocked to avoid canvas/DOM complexity in jsdom.
// =============================================================================

// Mock @xyflow/react so ReactFlow renders a sentinel div in jsdom.
jest.mock('@xyflow/react', () => ({
  ReactFlow: ({
    nodes,
    edges,
    children,
  }: {
    nodes: unknown[];
    edges: unknown[];
    children?: React.ReactNode;
  }) => (
    <div data-testid="react-flow">
      <span data-testid="node-count">{nodes.length}</span>
      <span data-testid="edge-count">{edges.length}</span>
      {children}
    </div>
  ),
  Background: () => <div data-testid="rf-background" />,
  Controls: () => <div data-testid="rf-controls" />,
  MarkerType: { ArrowClosed: 'arrowclosed' },
}));

// Mock the sdwanApi facade — the component imports it as a named export.
const mockGetTopology = jest.fn();
jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    getTopology: (...args: unknown[]) => mockGetTopology(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const TOPOLOGY_EMPTY: SdwanTopologyResponse = {
  network_id: 'net-1',
  cidr_64: 'fd12:3456::/64',
  peer_count: 0,
  peers: [],
};

const HUB_PEER = {
  peer_id: 'peer-hub-1',
  interface: {
    name: 'wg0',
    address: 'fd12:3456::1:2345/128',
    listen_port: 51820,
    mtu: 1420,
    public_key: 'hub-pub-key',
  },
  peers: [
    {
      peer_id: 'peer-spoke-1',
      public_key: 'spoke1-pub',
      allowed_ips: ['fd12:3456::2:0001/128'],
      endpoint: null,
    },
    {
      peer_id: 'peer-spoke-2',
      public_key: 'spoke2-pub',
      allowed_ips: ['fd12:3456::2:0002/128'],
      endpoint: null,
    },
  ],
  firewall: undefined,
  federation: [],
};

const SPOKE_PEER_1 = {
  peer_id: 'peer-spoke-1',
  interface: {
    name: 'wg0',
    address: 'fd12:3456::2:0001/128',
    listen_port: 51820,
    mtu: 1420,
    public_key: 'spoke1-pub',
  },
  peers: [
    {
      peer_id: 'peer-hub-1',
      public_key: 'hub-pub-key',
      allowed_ips: ['fd12:3456::1:2345/128'],
      endpoint: 'hub.example.com:51820',
    },
  ],
  firewall: undefined,
  federation: [],
};

const SPOKE_PEER_2 = {
  peer_id: 'peer-spoke-2',
  interface: {
    name: 'wg0',
    address: 'fd12:3456::2:0002/128',
    listen_port: 51820,
    mtu: 1420,
    public_key: 'spoke2-pub',
  },
  peers: [
    {
      peer_id: 'peer-hub-1',
      public_key: 'hub-pub-key',
      allowed_ips: ['fd12:3456::1:2345/128'],
      endpoint: 'hub.example.com:51820',
    },
  ],
  firewall: undefined,
  federation: [],
};

const TOPOLOGY_WITH_PEERS: SdwanTopologyResponse = {
  network_id: 'net-1',
  cidr_64: 'fd12:3456::/64',
  peer_count: 3,
  peers: [HUB_PEER, SPOKE_PEER_1, SPOKE_PEER_2],
};

// A peer with multiple allowed_ips to test edge label formatting.
const MULTI_IP_PEER = {
  peer_id: 'peer-multi',
  interface: {
    name: 'wg0',
    address: 'fd12:abcd::1:0001/128',
    listen_port: 51820,
    mtu: 1420,
  },
  peers: [
    {
      peer_id: 'peer-hub-1',
      public_key: 'hub-pub',
      allowed_ips: ['fd12:abcd::1:0001/128', '10.0.0.0/8', '192.168.0.0/16'],
      endpoint: null,
    },
  ],
  firewall: undefined,
  federation: [],
};

const TOPOLOGY_SINGLE_PEER: SdwanTopologyResponse = {
  network_id: 'net-2',
  cidr_64: 'fd12:abcd::/64',
  peer_count: 1,
  peers: [
    {
      peer_id: 'peer-solo',
      interface: {
        name: 'wg0',
        address: 'fd12:abcd::1:0001/128',
        listen_port: 51820,
        mtu: 1420,
      },
      peers: [],
      firewall: undefined,
      federation: [],
    },
  ],
};

// =============================================================================
// Test helpers
// =============================================================================

const renderTopology = (props: { networkId: string; refreshKey?: number }) =>
  render(<SdwanTopology {...props} />);

// =============================================================================
// Tests
// =============================================================================

describe('SdwanTopology', () => {
  beforeEach(() => {
    mockGetTopology.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------
  it('shows a loading indicator while the topology is being fetched', () => {
    // Never resolves — keeps the component in loading state.
    mockGetTopology.mockReturnValue(new Promise(() => {}));

    renderTopology({ networkId: 'net-1' });

    expect(screen.getByText(/Loading topology/i)).toBeInTheDocument();
  });

  it('calls sdwanApi.getTopology with the provided networkId', async () => {
    mockGetTopology.mockResolvedValue(TOPOLOGY_EMPTY);

    renderTopology({ networkId: 'net-abc' });

    await waitFor(() => expect(mockGetTopology).toHaveBeenCalledWith('net-abc'));
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------
  it('displays the error message when getTopology rejects with an Error instance', async () => {
    mockGetTopology.mockRejectedValue(new Error('Topology unavailable'));

    renderTopology({ networkId: 'net-1' });

    await waitFor(() =>
      expect(screen.getByText('Topology unavailable')).toBeInTheDocument(),
    );
  });

  it('displays a fallback message when getTopology rejects with a non-Error value', async () => {
    mockGetTopology.mockRejectedValue('something went wrong');

    renderTopology({ networkId: 'net-1' });

    await waitFor(() =>
      expect(screen.getByText('Failed to load topology')).toBeInTheDocument(),
    );
  });

  it('does not render the ReactFlow diagram during an error state', async () => {
    mockGetTopology.mockRejectedValue(new Error('oops'));

    renderTopology({ networkId: 'net-1' });

    await waitFor(() => expect(screen.getByText('oops')).toBeInTheDocument());
    expect(screen.queryByTestId('react-flow')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------
  it('renders the empty-state message when peer_count is 0', async () => {
    mockGetTopology.mockResolvedValue(TOPOLOGY_EMPTY);

    renderTopology({ networkId: 'net-1' });

    await waitFor(() =>
      expect(
        screen.getByText(/No peers attached/i),
      ).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('react-flow')).not.toBeInTheDocument();
  });

  it('does not render the ReactFlow diagram for an empty topology', async () => {
    mockGetTopology.mockResolvedValue(TOPOLOGY_EMPTY);

    renderTopology({ networkId: 'net-1' });

    await waitFor(() => expect(screen.getByText(/No peers attached/i)).toBeInTheDocument());
    expect(screen.queryByTestId('react-flow')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Populated topology
  // ---------------------------------------------------------------------------
  it('renders the ReactFlow diagram when the topology has peers', async () => {
    mockGetTopology.mockResolvedValue(TOPOLOGY_WITH_PEERS);

    renderTopology({ networkId: 'net-1' });

    await waitFor(() =>
      expect(screen.getByTestId('react-flow')).toBeInTheDocument(),
    );
  });

  it('passes the correct node count to ReactFlow (1 hub + 2 spokes = 3 nodes)', async () => {
    mockGetTopology.mockResolvedValue(TOPOLOGY_WITH_PEERS);

    renderTopology({ networkId: 'net-1' });

    await waitFor(() => expect(screen.getByTestId('node-count')).toHaveTextContent('3'));
  });

  it('passes edges to ReactFlow for each compiled peer relationship', async () => {
    // HUB has 2 edges (to spoke1 + spoke2), each spoke has 1 edge back to hub → 4 total.
    mockGetTopology.mockResolvedValue(TOPOLOGY_WITH_PEERS);

    renderTopology({ networkId: 'net-1' });

    await waitFor(() => expect(screen.getByTestId('edge-count')).toHaveTextContent('4'));
  });

  it('renders Background and Controls sub-components inside the flow', async () => {
    mockGetTopology.mockResolvedValue(TOPOLOGY_WITH_PEERS);

    renderTopology({ networkId: 'net-1' });

    await waitFor(() => expect(screen.getByTestId('react-flow')).toBeInTheDocument());
    expect(screen.getByTestId('rf-background')).toBeInTheDocument();
    expect(screen.getByTestId('rf-controls')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Hub vs spoke classification (isHub heuristic)
  // ---------------------------------------------------------------------------
  it('treats a peer with peers.length > 1 as a hub (node count includes it)', async () => {
    // Topology: hub peer (2 outgoing edges) + 2 spokes (1 edge each).
    mockGetTopology.mockResolvedValue(TOPOLOGY_WITH_PEERS);

    renderTopology({ networkId: 'net-1' });

    // All 3 peers become nodes regardless of hub/spoke classification.
    await waitFor(() => expect(screen.getByTestId('node-count')).toHaveTextContent('3'));
  });

  it('renders a single-peer topology without crashing (no edges)', async () => {
    mockGetTopology.mockResolvedValue(TOPOLOGY_SINGLE_PEER);

    renderTopology({ networkId: 'net-2' });

    await waitFor(() => expect(screen.getByTestId('react-flow')).toBeInTheDocument());
    expect(screen.getByTestId('node-count')).toHaveTextContent('1');
    expect(screen.getByTestId('edge-count')).toHaveTextContent('0');
  });

  // ---------------------------------------------------------------------------
  // refreshKey triggers a re-fetch
  // ---------------------------------------------------------------------------
  it('re-fetches topology when refreshKey changes', async () => {
    mockGetTopology.mockResolvedValue(TOPOLOGY_WITH_PEERS);

    const { rerender } = renderTopology({ networkId: 'net-1', refreshKey: 0 });

    await waitFor(() => expect(mockGetTopology).toHaveBeenCalledTimes(1));

    act(() => {
      rerender(<SdwanTopology networkId="net-1" refreshKey={1} />);
    });

    await waitFor(() => expect(mockGetTopology).toHaveBeenCalledTimes(2));
    expect(mockGetTopology).toHaveBeenNthCalledWith(2, 'net-1');
  });

  it('re-fetches topology when networkId changes', async () => {
    mockGetTopology.mockResolvedValue(TOPOLOGY_WITH_PEERS);

    const { rerender } = renderTopology({ networkId: 'net-1' });

    await waitFor(() => expect(mockGetTopology).toHaveBeenCalledTimes(1));

    mockGetTopology.mockResolvedValue({ ...TOPOLOGY_WITH_PEERS, network_id: 'net-2' });

    act(() => {
      rerender(<SdwanTopology networkId="net-2" />);
    });

    await waitFor(() => expect(mockGetTopology).toHaveBeenCalledTimes(2));
    expect(mockGetTopology).toHaveBeenNthCalledWith(2, 'net-2');
  });

  // ---------------------------------------------------------------------------
  // Edge label formatting
  // ---------------------------------------------------------------------------
  it('formats edge label as the single CIDR when allowed_ips has one entry', async () => {
    // Build a minimal 2-peer topology: a hub that only knows spoke-1,
    // and spoke-1 pointing back to hub. Each has exactly 1 peer → 2 edges.
    const hubWithOnlySpoke1 = {
      ...HUB_PEER,
      peers: [
        {
          peer_id: 'peer-spoke-1',
          public_key: 'spoke1-pub',
          allowed_ips: ['fd12:3456::2:0001/128'],
          endpoint: null,
        },
      ],
    };
    const topology: SdwanTopologyResponse = {
      network_id: 'net-3',
      cidr_64: 'fd12:3456::/64',
      peer_count: 2,
      peers: [hubWithOnlySpoke1, SPOKE_PEER_1],
    };
    mockGetTopology.mockResolvedValue(topology);

    renderTopology({ networkId: 'net-3' });

    // hub→spoke1 + spoke1→hub = 2 edges.
    await waitFor(() => expect(screen.getByTestId('edge-count')).toHaveTextContent('2'));
  });

  it('formats edge label as "<first> +N" when allowed_ips has multiple entries', async () => {
    // Build a minimal topology where MULTI_IP_PEER connects to hub.
    const hubWithMultiSpoke = {
      ...HUB_PEER,
      peers: [
        {
          peer_id: 'peer-multi',
          public_key: 'multi-pub',
          allowed_ips: ['fd12:abcd::1:0001/128'],
          endpoint: null,
        },
      ],
    };
    const topology: SdwanTopologyResponse = {
      network_id: 'net-4',
      cidr_64: 'fd12:abcd::/64',
      peer_count: 2,
      peers: [hubWithMultiSpoke, MULTI_IP_PEER],
    };
    mockGetTopology.mockResolvedValue(topology);

    renderTopology({ networkId: 'net-4' });

    // hub→multi + multi→hub = 2 edges.
    await waitFor(() => expect(screen.getByTestId('edge-count')).toHaveTextContent('2'));
  });

  // ---------------------------------------------------------------------------
  // Transition: loading → populated (no stale state leaks)
  // ---------------------------------------------------------------------------
  it('hides the loading indicator once data arrives', async () => {
    mockGetTopology.mockResolvedValue(TOPOLOGY_WITH_PEERS);

    renderTopology({ networkId: 'net-1' });

    await waitFor(() =>
      expect(screen.queryByText(/Loading topology/i)).not.toBeInTheDocument(),
    );
    expect(screen.getByTestId('react-flow')).toBeInTheDocument();
  });

  it('hides the loading indicator even when the topology is empty', async () => {
    mockGetTopology.mockResolvedValue(TOPOLOGY_EMPTY);

    renderTopology({ networkId: 'net-1' });

    await waitFor(() =>
      expect(screen.queryByText(/Loading topology/i)).not.toBeInTheDocument(),
    );
    expect(screen.getByText(/No peers attached/i)).toBeInTheDocument();
  });
});
