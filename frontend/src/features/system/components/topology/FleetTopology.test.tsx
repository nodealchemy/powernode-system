import React from 'react';
import { render, screen, waitFor, act } from '@testing-library/react';
import { FleetTopology } from './FleetTopology';

// =============================================================================
// Mocks
//
// FleetTopology → loadFleetTopology() → nodes/templates/connections/topology
// (+ bounded per-node instance and per-network peer fan-outs) → apiClient.
// We mock apiClient at the shared layer and route by URL, which also pins the
// fetch budget (gap G3: "at most a few fetches").
//
// ReactFlow is mocked to a sentinel so jsdom doesn't choke on canvas APIs;
// wsManager is mocked so the SystemFleetChannel subscription (gap G9) can be
// driven synchronously from the test.
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

const mockUnsubscribe = jest.fn();
let capturedOnMessage: ((data: unknown) => void) | undefined;

jest.mock('@/shared/services/WebSocketManager', () => ({
  wsManager: {
    subscribe: (sub: { onMessage?: (data: unknown) => void }) => {
      capturedOnMessage = sub.onMessage;
      return mockUnsubscribe;
    },
  },
}));

jest.mock('@/shared/hooks/useAuth', () => ({
  useAuth: () => ({ currentUser: { account: { id: 'account-1' } } }),
}));

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

/** Wrap payload in the double-envelope apiClient.get resolves to. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

/** Paginated envelope — meta sits at the response root, not inside data. */
function paginated<T>(data: T, totalCount: number) {
  return {
    data: {
      success: true,
      data,
      meta: {
        current_page: 1,
        per_page: 24,
        total_count: totalCount,
        total_pages: 1,
        next_page: null,
        prev_page: null,
      },
    },
  };
}

const NODE_A = {
  id: 'node-a',
  name: 'edge-01',
  enabled: true,
  allocate_public_ip: false,
  config: {},
  node_template_id: 'tpl-1',
  node_template_name: 'baremetal',
  instance_count: 2,
  running_instances_count: 2,
  created_at: '2026-08-01T00:00:00Z',
  updated_at: '2026-08-01T00:00:00Z',
};

const INSTANCE_A1 = {
  id: 'inst-a1',
  name: 'edge-01-a',
  variety: 'cloud' as const,
  status: 'running',
  config: { provider_connection_id: 'conn-1' },
  node_id: 'node-a',
  created_at: '2026-08-01T00:00:00Z',
  updated_at: '2026-08-01T00:00:00Z',
};

const INSTANCE_A2 = {
  ...INSTANCE_A1,
  id: 'inst-a2',
  name: 'edge-01-b',
  status: 'stopped',
};

const TEMPLATE = {
  id: 'tpl-1',
  name: 'baremetal',
  enabled: true,
  public: false,
  config: {},
  node_platform_name: 'powernode-x86_64',
  modules: [
    { id: 'm1', name: 'system-base', variety: 'system', priority: 1, template_module_id: 'tm1' },
    { id: 'm2', name: 'hub-worker', variety: 'app', priority: 2, template_module_id: 'tm2' },
  ],
  created_at: '2026-08-01T00:00:00Z',
  updated_at: '2026-08-01T00:00:00Z',
};

const CONNECTION = {
  id: 'conn-1',
  name: 'proxmox-dna',
  config: {},
  provider_id: 'prov-1',
  provider_name: 'Proxmox',
  created_at: '2026-08-01T00:00:00Z',
  updated_at: '2026-08-01T00:00:00Z',
};

const NETWORK_TOPOLOGY = {
  self_id: 'self',
  self_label: 'My Platform',
  nodes: [
    { id: 'self', type: 'self', position: { x: 0, y: 0 }, data: { label: 'My Platform' } },
    {
      id: 'network-net-1',
      type: 'network',
      position: { x: 0, y: 200 },
      data: { label: 'primary-net', cidr_64: 'fd00::/64', status: 'active' },
    },
  ],
  edges: [],
  stats: {
    peer_count: 0,
    platform_peer_count: 0,
    sdwan_only_peer_count: 0,
    network_count: 1,
    bridge_count: 0,
    active_bridge_count: 0,
    grant_count: 0,
    generated_at: '2026-08-01T00:00:00Z',
  },
};

const SDWAN_PEER = {
  id: 'peer-1',
  network_id: 'net-1',
  node_instance_id: 'inst-a1',
  assigned_address: 'fd00::2',
  publicly_reachable: false,
  listen_port: 51820,
  status: 'active',
};

/**
 * Route a mocked GET by URL. Any lane can be flipped to a rejection to
 * exercise the soft-fetch degradation.
 */
function routeGet(overrides: Record<string, unknown> = {}) {
  mockGet.mockImplementation((url: string) => {
    if ('reject' in overrides && (overrides.reject as string[]).some((u) => url.startsWith(u))) {
      return Promise.reject(new Error(`boom: ${url}`));
    }
    if (url === '/system/nodes') {
      return Promise.resolve(paginated({ nodes: (overrides.nodes as unknown[]) ?? [NODE_A] }, 1));
    }
    if (url === '/system/node_templates') {
      return Promise.resolve(paginated({ node_templates: [TEMPLATE] }, 1));
    }
    if (url === '/system/provider_connections') {
      return Promise.resolve(envelope({ provider_connections: [CONNECTION] }));
    }
    if (url === '/system/network/topology') {
      return Promise.resolve(envelope(overrides.topology ?? NETWORK_TOPOLOGY));
    }
    if (url === '/system/nodes/node-a/node_instances') {
      return Promise.resolve(
        envelope({ node_instances: (overrides.instances as unknown[]) ?? [INSTANCE_A1, INSTANCE_A2] }),
      );
    }
    if (url === '/system/sdwan/networks/net-1/peers') {
      return Promise.resolve(envelope({ peers: (overrides.peers as unknown[]) ?? [SDWAN_PEER] }));
    }
    return Promise.resolve(envelope({}));
  });
}

// =============================================================================
// Tests
// =============================================================================

describe('FleetTopology', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockUnsubscribe.mockReset();
    capturedOnMessage = undefined;
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while fleet data is being fetched', () => {
    mockGet.mockReturnValue(new Promise(() => {})); // never resolves

    render(<FleetTopology />);

    expect(screen.getByText(/Loading fleet topology/i)).toBeInTheDocument();
    expect(screen.queryByTestId('react-flow')).not.toBeInTheDocument();
  });

  it('fetches the node list from the system nodes endpoint', async () => {
    routeGet();

    render(<FleetTopology />);

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/nodes', { params: { per_page: 24 } }),
    );
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('renders the empty-state message when the fleet has no nodes', async () => {
    routeGet({ nodes: [] });

    render(<FleetTopology />);

    await waitFor(() => expect(screen.getByText(/No nodes yet/i)).toBeInTheDocument());
    expect(screen.queryByTestId('react-flow')).not.toBeInTheDocument();
  });

  it('does not fan out instance fetches when there are no nodes', async () => {
    routeGet({ nodes: [] });

    render(<FleetTopology />);

    await waitFor(() => expect(screen.getByText(/No nodes yet/i)).toBeInTheDocument());
    expect(
      mockGet.mock.calls.filter((c) => String(c[0]).includes('node_instances')),
    ).toHaveLength(0);
  });

  // ---------------------------------------------------------------------------
  // Populated graph
  // ---------------------------------------------------------------------------

  it('renders the ReactFlow canvas once the fleet loads', async () => {
    routeGet();

    render(<FleetTopology />);

    await waitFor(() => expect(screen.getByTestId('react-flow')).toBeInTheDocument());
    expect(screen.getByTestId('rf-background')).toBeInTheDocument();
    expect(screen.getByTestId('rf-controls')).toBeInTheDocument();
  });

  it('builds a group + node + instances + network graph', async () => {
    routeGet();

    render(<FleetTopology />);

    // 1 group + 1 node + 2 instances + 1 SDWAN network
    await waitFor(() => expect(screen.getByTestId('node-count')).toHaveTextContent('5'));
  });

  it('draws containment edges plus the SDWAN membership edge', async () => {
    routeGet();

    render(<FleetTopology />);

    // group→node, node→instance ×2, instance→network
    await waitFor(() => expect(screen.getByTestId('edge-count')).toHaveTextContent('4'));
  });

  it('degrades to the containment graph when the SDWAN lane fails', async () => {
    routeGet({ reject: ['/system/network/topology', '/system/sdwan'] });

    render(<FleetTopology />);

    // 1 group + 1 node + 2 instances, no network node
    await waitFor(() => expect(screen.getByTestId('node-count')).toHaveTextContent('4'));
    expect(screen.getByTestId('edge-count')).toHaveTextContent('3');
  });

  it('still renders nodes when the template lane fails (no module chips)', async () => {
    routeGet({ reject: ['/system/node_templates'] });

    render(<FleetTopology />);

    await waitFor(() => expect(screen.getByTestId('react-flow')).toBeInTheDocument());
    expect(screen.getByTestId('node-count')).toHaveTextContent('5');
  });

  it('reports the loaded snapshot to its host page', async () => {
    routeGet();
    const onSnapshot = jest.fn();

    render(<FleetTopology onSnapshot={onSnapshot} />);

    await waitFor(() => expect(onSnapshot).toHaveBeenCalledTimes(1));
    const snapshot = onSnapshot.mock.calls[0][0];
    expect(snapshot.nodes).toHaveLength(1);
    expect(snapshot.groups[0].label).toBe('Proxmox');
    expect(snapshot.nodes[0].modules).toEqual(['system-base', 'hub-worker']);
    expect(snapshot.memberships).toEqual([
      { instanceId: 'inst-a1', networkId: 'net-1', status: 'active' },
    ]);
  });

  it('falls back to the platform group when no provider connection resolves', async () => {
    routeGet({ instances: [{ ...INSTANCE_A1, config: {} }] });
    const onSnapshot = jest.fn();

    render(<FleetTopology onSnapshot={onSnapshot} />);

    await waitFor(() => expect(onSnapshot).toHaveBeenCalled());
    expect(onSnapshot.mock.calls[0][0].groups[0]).toMatchObject({
      label: 'powernode-x86_64',
      kind: 'platform',
    });
  });

  // ---------------------------------------------------------------------------
  // refreshKey
  // ---------------------------------------------------------------------------

  it('re-fetches when refreshKey changes', async () => {
    routeGet();

    const { rerender } = render(<FleetTopology refreshKey={0} />);

    await waitFor(() => expect(screen.getByTestId('react-flow')).toBeInTheDocument());
    const before = mockGet.mock.calls.filter((c) => c[0] === '/system/nodes').length;

    act(() => {
      rerender(<FleetTopology refreshKey={1} />);
    });

    await waitFor(() =>
      expect(mockGet.mock.calls.filter((c) => c[0] === '/system/nodes').length).toBe(before + 1),
    );
  });

  // ---------------------------------------------------------------------------
  // Live SystemFleetChannel subscription (gap G9)
  // ---------------------------------------------------------------------------

  it('subscribes to SystemFleetChannel and unsubscribes on unmount', async () => {
    routeGet();

    const { unmount } = render(<FleetTopology />);

    await waitFor(() => expect(screen.getByTestId('react-flow')).toBeInTheDocument());
    expect(capturedOnMessage).toBeDefined();

    unmount();
    expect(mockUnsubscribe).toHaveBeenCalled();
  });

  it('refetches on an instance lifecycle event', async () => {
    jest.useFakeTimers();
    try {
      routeGet();

      render(<FleetTopology />);

      await waitFor(() => expect(mockGet).toHaveBeenCalled());
      const before = mockGet.mock.calls.filter((c) => c[0] === '/system/nodes').length;

      act(() => {
        capturedOnMessage?.({ id: 'e1', kind: 'system.instance_started', severity: 'low' });
        jest.advanceTimersByTime(2000);
      });

      await waitFor(() =>
        expect(mockGet.mock.calls.filter((c) => c[0] === '/system/nodes').length).toBe(before + 1),
      );
    } finally {
      jest.useRealTimers();
    }
  });

  it('coalesces an event burst into a single refetch', async () => {
    jest.useFakeTimers();
    try {
      routeGet();

      render(<FleetTopology />);

      await waitFor(() => expect(mockGet).toHaveBeenCalled());
      const before = mockGet.mock.calls.filter((c) => c[0] === '/system/nodes').length;

      act(() => {
        capturedOnMessage?.({ kind: 'system.instance_started' });
        capturedOnMessage?.({ kind: 'system.instance_stopped' });
        capturedOnMessage?.({ kind: 'system.module_drift_detected' });
        jest.advanceTimersByTime(2000);
      });

      await waitFor(() =>
        expect(mockGet.mock.calls.filter((c) => c[0] === '/system/nodes').length).toBe(before + 1),
      );
    } finally {
      jest.useRealTimers();
    }
  });

  it('ignores channel handshake frames and unrelated event kinds', async () => {
    jest.useFakeTimers();
    try {
      routeGet();

      render(<FleetTopology />);

      await waitFor(() => expect(mockGet).toHaveBeenCalled());
      const before = mockGet.mock.calls.filter((c) => c[0] === '/system/nodes').length;

      act(() => {
        capturedOnMessage?.({ type: 'connection_established' });
        capturedOnMessage?.({ type: 'pong' });
        capturedOnMessage?.({ kind: 'system.cve_critical_published' });
        jest.advanceTimersByTime(5000);
      });

      expect(mockGet.mock.calls.filter((c) => c[0] === '/system/nodes').length).toBe(before);
    } finally {
      jest.useRealTimers();
    }
  });
});
