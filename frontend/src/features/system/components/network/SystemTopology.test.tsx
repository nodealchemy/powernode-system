import React from 'react';
import { render, screen, waitFor, act } from '@testing-library/react';
import { SystemTopology } from './SystemTopology';
import type {
  NetworkTopologyResponse,
  TopologyNode,
  TopologyEdge,
} from '../../types/network_topology.types';

// =============================================================================
// Mocks
//
// SystemTopology → networkTopologyApi.getTopology() → apiClient.get(...)
// We mock apiClient at the shared layer (what networkTopologyApi imports).
// ReactFlow is mocked to a sentinel so jsdom doesn't choke on canvas APIs.
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

// Mock @xyflow/react — expose node/edge counts + children so tests can assert
// topology shape without a real WebGL/SVG canvas.
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
  BaseEdge: () => null,
  getSmoothStepPath: () => ['M0,0', 0, 0],
  Handle: () => null,
  Position: { Top: 'top', Bottom: 'bottom', Left: 'left', Right: 'right' },
}));

// =============================================================================
// Fixtures
// =============================================================================

/** Wrap payload in the double-envelope that apiClient.get resolves to. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const SELF_NODE: TopologyNode = {
  id: 'self',
  type: 'self',
  position: { x: 0, y: 0 },
  data: {
    label: 'My Platform',
    subtitle: 'account-abc',
    handle_counts: { source_top: 0, source_bottom: 2, target_top: 0, target_bottom: 0 },
  },
};

const NETWORK_NODE: TopologyNode = {
  id: 'net-1',
  type: 'network',
  position: { x: 0, y: 200 },
  data: {
    label: 'primary-net',
    cidr_64: 'fd00::/64',
    routing_protocol: 'bgp',
    status: 'active',
    handle_counts: { source_top: 0, source_bottom: 1, target_top: 1, target_bottom: 0 },
  },
};

const PEER_PLATFORM_NODE: TopologyNode = {
  id: 'peer-1',
  type: 'peer-platform',
  position: { x: 0, y: 400 },
  data: {
    label: 'Partner Node',
    status: 'active',
    spawn_role: 'child',
    active_bridge_count: 1,
    grant_count: 3,
    handle_counts: { source_top: 0, source_bottom: 0, target_top: 1, target_bottom: 0 },
  },
};

const PEER_SDWAN_NODE: TopologyNode = {
  id: 'sdwan-peer-1',
  type: 'peer-sdwan',
  position: { x: 200, y: 400 },
  data: {
    label: 'Data-Plane Peer',
    handle_counts: { source_top: 0, source_bottom: 0, target_top: 1, target_bottom: 0 },
  },
};

const MEMBERSHIP_EDGE: TopologyEdge = {
  id: 'membership-self-net-1',
  source: 'self',
  target: 'net-1',
  type: 'membership',
  data: { label: undefined },
  animated: false,
};

const BRIDGE_EDGE_ACTIVE: TopologyEdge = {
  id: 'bridge-peer-1-net-1',
  source: 'peer-1',
  target: 'net-1',
  type: 'bridge',
  data: { bridge_id: 'br-uuid-1', state: 'active', label: undefined },
  animated: true,
};

const GRANT_SUMMARY_EDGE: TopologyEdge = {
  id: 'grant_summary-self-peer-1',
  source: 'self',
  target: 'peer-1',
  type: 'grant_summary',
  data: { grant_count: 3, label: '3 grants' },
  animated: false,
};

const makeStats = (peer_count: number, network_count: number) => ({
  peer_count,
  platform_peer_count: peer_count,
  sdwan_only_peer_count: 0,
  network_count,
  bridge_count: 0,
  active_bridge_count: 0,
  grant_count: 0,
  generated_at: '2026-06-01T00:00:00Z',
});

const TOPOLOGY_EMPTY: NetworkTopologyResponse = {
  self_id: 'self',
  self_label: 'My Platform',
  nodes: [],
  edges: [],
  stats: makeStats(0, 0),
};

const TOPOLOGY_POPULATED: NetworkTopologyResponse = {
  self_id: 'self',
  self_label: 'My Platform',
  nodes: [SELF_NODE, NETWORK_NODE, PEER_PLATFORM_NODE],
  edges: [MEMBERSHIP_EDGE, BRIDGE_EDGE_ACTIVE, GRANT_SUMMARY_EDGE],
  stats: makeStats(1, 1),
};

const TOPOLOGY_MULTI_NODE: NetworkTopologyResponse = {
  self_id: 'self',
  self_label: 'My Platform',
  nodes: [SELF_NODE, NETWORK_NODE, PEER_PLATFORM_NODE, PEER_SDWAN_NODE],
  edges: [MEMBERSHIP_EDGE, BRIDGE_EDGE_ACTIVE],
  stats: makeStats(2, 1),
};

// =============================================================================
// Render helper
// =============================================================================

const renderTopology = (props: { refreshKey?: number } = {}) =>
  render(<SystemTopology {...props} />);

// =============================================================================
// Tests
// =============================================================================

describe('SystemTopology', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while topology data is being fetched', () => {
    mockGet.mockReturnValue(new Promise(() => {})); // never resolves

    renderTopology();

    expect(screen.getByText(/Loading topology/i)).toBeInTheDocument();
    expect(screen.queryByTestId('react-flow')).not.toBeInTheDocument();
  });

  it('calls apiClient.get with the topology endpoint URL', async () => {
    mockGet.mockResolvedValue(envelope(TOPOLOGY_EMPTY));

    renderTopology();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/network/topology'),
    );
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('displays the error message when the API rejects with an Error instance', async () => {
    mockGet.mockRejectedValue(new Error('Network unavailable'));

    renderTopology();

    await waitFor(() =>
      expect(screen.getByText('Network unavailable')).toBeInTheDocument(),
    );
  });

  it('displays a fallback message when the API rejects with a non-Error value', async () => {
    mockGet.mockRejectedValue('something bad');

    renderTopology();

    await waitFor(() =>
      expect(screen.getByText('Failed to load topology')).toBeInTheDocument(),
    );
  });

  it('does not render the ReactFlow canvas when in error state', async () => {
    mockGet.mockRejectedValue(new Error('oops'));

    renderTopology();

    await waitFor(() => expect(screen.getByText('oops')).toBeInTheDocument());
    expect(screen.queryByTestId('react-flow')).not.toBeInTheDocument();
  });

  it('hides the loading indicator after an error', async () => {
    mockGet.mockRejectedValue(new Error('fail'));

    renderTopology();

    await waitFor(() => expect(screen.getByText('fail')).toBeInTheDocument());
    expect(screen.queryByText(/Loading topology/i)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state (both peer_count and network_count are 0)
  // ---------------------------------------------------------------------------

  it('renders the empty-state message when peer_count and network_count are both 0', async () => {
    mockGet.mockResolvedValue(envelope(TOPOLOGY_EMPTY));

    renderTopology();

    await waitFor(() =>
      expect(
        screen.getByText(/No SDWAN networks or federation peers yet/i),
      ).toBeInTheDocument(),
    );
  });

  it('does not render the ReactFlow canvas in empty state', async () => {
    mockGet.mockResolvedValue(envelope(TOPOLOGY_EMPTY));

    renderTopology();

    await waitFor(() =>
      expect(screen.getByText(/No SDWAN networks or federation peers yet/i)).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('react-flow')).not.toBeInTheDocument();
  });

  it('hides the loading indicator in empty state', async () => {
    mockGet.mockResolvedValue(envelope(TOPOLOGY_EMPTY));

    renderTopology();

    await waitFor(() =>
      expect(screen.queryByText(/Loading topology/i)).not.toBeInTheDocument(),
    );
    expect(screen.getByText(/No SDWAN networks or federation peers yet/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Populated topology
  // ---------------------------------------------------------------------------

  it('renders the ReactFlow canvas when topology has nodes', async () => {
    mockGet.mockResolvedValue(envelope(TOPOLOGY_POPULATED));

    renderTopology();

    await waitFor(() =>
      expect(screen.getByTestId('react-flow')).toBeInTheDocument(),
    );
  });

  it('passes the correct node count to ReactFlow', async () => {
    mockGet.mockResolvedValue(envelope(TOPOLOGY_POPULATED));

    renderTopology();

    await waitFor(() =>
      expect(screen.getByTestId('node-count')).toHaveTextContent('3'),
    );
  });

  it('passes the correct edge count to ReactFlow', async () => {
    mockGet.mockResolvedValue(envelope(TOPOLOGY_POPULATED));

    renderTopology();

    await waitFor(() =>
      expect(screen.getByTestId('edge-count')).toHaveTextContent('3'),
    );
  });

  it('renders Background and Controls inside the flow canvas', async () => {
    mockGet.mockResolvedValue(envelope(TOPOLOGY_POPULATED));

    renderTopology();

    await waitFor(() => expect(screen.getByTestId('react-flow')).toBeInTheDocument());
    expect(screen.getByTestId('rf-background')).toBeInTheDocument();
    expect(screen.getByTestId('rf-controls')).toBeInTheDocument();
  });

  it('renders all four node types in a multi-node topology', async () => {
    mockGet.mockResolvedValue(envelope(TOPOLOGY_MULTI_NODE));

    renderTopology();

    await waitFor(() =>
      expect(screen.getByTestId('node-count')).toHaveTextContent('4'),
    );
  });

  it('hides the loading indicator after topology loads', async () => {
    mockGet.mockResolvedValue(envelope(TOPOLOGY_POPULATED));

    renderTopology();

    await waitFor(() =>
      expect(screen.queryByText(/Loading topology/i)).not.toBeInTheDocument(),
    );
    expect(screen.getByTestId('react-flow')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty-state boundary: only peers present (no networks) → not empty
  // ---------------------------------------------------------------------------

  it('renders the ReactFlow canvas when peer_count > 0 even if network_count is 0', async () => {
    const topologyPeersOnly: NetworkTopologyResponse = {
      ...TOPOLOGY_EMPTY,
      nodes: [SELF_NODE, PEER_PLATFORM_NODE],
      stats: makeStats(1, 0), // peer_count=1, network_count=0 → NOT empty
    };
    mockGet.mockResolvedValue(envelope(topologyPeersOnly));

    renderTopology();

    await waitFor(() =>
      expect(screen.getByTestId('react-flow')).toBeInTheDocument(),
    );
  });

  it('renders the ReactFlow canvas when network_count > 0 even if peer_count is 0', async () => {
    const topologyNetworksOnly: NetworkTopologyResponse = {
      ...TOPOLOGY_EMPTY,
      nodes: [SELF_NODE, NETWORK_NODE],
      stats: makeStats(0, 1), // peer_count=0, network_count=1 → NOT empty
    };
    mockGet.mockResolvedValue(envelope(topologyNetworksOnly));

    renderTopology();

    await waitFor(() =>
      expect(screen.getByTestId('react-flow')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // refreshKey prop triggers re-fetch
  // ---------------------------------------------------------------------------

  it('re-fetches the topology when refreshKey changes', async () => {
    mockGet.mockResolvedValue(envelope(TOPOLOGY_POPULATED));

    const { rerender } = renderTopology({ refreshKey: 0 });

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));

    act(() => {
      rerender(<SystemTopology refreshKey={1} />);
    });

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
    expect(mockGet).toHaveBeenNthCalledWith(2, '/system/network/topology');
  });

  it('fetches once on initial mount with no refreshKey', async () => {
    mockGet.mockResolvedValue(envelope(TOPOLOGY_POPULATED));

    renderTopology();

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));
    expect(mockGet).toHaveBeenCalledWith('/system/network/topology');
  });
});
