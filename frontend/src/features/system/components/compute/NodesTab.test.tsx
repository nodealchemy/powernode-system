import React from 'react';
import { render, screen, within, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NodesTab } from './NodesTab';
import type { SystemNode } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

// apiClient is used by nodesApi (via systemApi.getNodes) for the list fetch.
// NodesTab also calls systemApi.getNode / deleteNode / updateNode, which
// resolve through apiClient.get/put/delete respectively.
jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

const mockHasPermission = jest.fn(() => true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (...args: unknown[]) => mockHasPermission(...args),
  }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
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

// WebSocket — no-op stub so NodeList renders without a real WS.
jest.mock('@system/features/system/hooks/useSystemWebSocket', () => ({
  useSystemWebSocket: () => ({
    isConnected: false,
    error: null,
    refreshOperations: jest.fn(),
    getTask: jest.fn(),
    refreshStats: jest.fn(),
    ping: jest.fn(),
  }),
}));

// EntityLink — plain anchor so we can check template name text.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { type: string; id: string; label: string }) => (
    <a data-testid="entity-link">{label}</a>
  ),
}));

// InfiniteScrollSentinel — IntersectionObserver not available in jsdom.
jest.mock(
  '@system/features/system/components/shared/InfiniteScrollSentinel',
  () => ({
    InfiniteScrollSentinel: () => null,
  }),
);

// Redux — useSelector pulled in transitively by useSystemWebSocket.
jest.mock('react-redux', () => ({
  ...jest.requireActual('react-redux'),
  useSelector: () => ({ account: { id: 'acc-1' } }),
}));

// Modal — pass-through rendering so we can query buttons/text inside modals.
jest.mock('@/shared/components/ui/Modal', () => ({
  Modal: ({
    isOpen,
    title,
    subtitle,
    children,
    footer,
  }: {
    isOpen: boolean;
    title?: string;
    subtitle?: string;
    children: React.ReactNode;
    footer?: React.ReactNode;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="modal">
        {title && <h2>{title}</h2>}
        {subtitle && <p>{subtitle}</p>}
        {children}
        {footer}
      </div>
    );
  },
}));

jest.mock('@/shared/components/ui/Button', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    variant,
    title,
  }: {
    children: React.ReactNode;
    onClick?: (e: React.MouseEvent) => void;
    disabled?: boolean;
    variant?: string;
    title?: string;
  }) => (
    <button onClick={onClick} disabled={disabled} data-variant={variant} title={title}>
      {children}
    </button>
  ),
}));

// =============================================================================
// Helpers
// =============================================================================

/**
 * Double-envelope: AxiosResponse.data = { success: true, data: payload, meta? }
 * meta lives at the body ROOT (not inside data).
 */
function envelope<T>(data: T, meta?: object) {
  return {
    data: {
      success: true,
      data,
      ...(meta ? { meta } : {}),
    },
  };
}

function defaultMeta(count = 0) {
  return {
    current_page: 1,
    per_page: 20,
    total_count: count,
    total_pages: 1,
    next_page: null,
    prev_page: null,
  };
}

/** List response: { success, data: { nodes }, meta } */
function nodesResponse(nodes: SystemNode[]) {
  return envelope({ nodes }, defaultMeta(nodes.length));
}

/** Single-node response: { success, data: { node } } */
function nodeResponse(node: SystemNode) {
  return envelope({ node });
}

// =============================================================================
// Fixtures
// =============================================================================

const NODE_A: SystemNode = {
  id: 'node-aaa',
  name: 'alpha-node',
  description: 'Primary compute node',
  enabled: true,
  status: 'ready',
  public_address: '10.0.0.1',
  allocate_public_ip: true,
  config: {},
  node_template_id: 'tpl-1',
  node_template_name: 'ubuntu-base',
  worker_id: 'worker-xyz',
  instance_count: 3,
  running_instances_count: 2,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const NODE_B: SystemNode = {
  id: 'node-bbb',
  name: 'beta-node',
  enabled: false,
  allocate_public_ip: false,
  config: {},
  instance_count: 0,
  running_instances_count: 0,
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-02T00:00:00Z',
};

const NODE_WITH_INSTANCES: SystemNode = {
  ...NODE_A,
  instance_count: 3,
};

// =============================================================================
// Render helper
// =============================================================================

function renderTab(onActionsReady?: jest.Mock) {
  return render(
    <BrowserRouter>
      <NodesTab onActionsReady={onActionsReady} />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('NodesTab', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Render — NodeList is mounted
  // ---------------------------------------------------------------------------

  it('renders without crashing and shows no nodes while loading', () => {
    mockGet.mockReturnValue(new Promise(() => {}));
    renderTab();
    expect(screen.queryByText('alpha-node')).not.toBeInTheDocument();
  });

  it('renders nodes fetched via NodeList child component', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A, NODE_B]));
    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('beta-node').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // onActionsReady lifecycle
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with an { openCreate } handle on mount', async () => {
    mockGet.mockResolvedValue(nodesResponse([]));
    const onActionsReady = jest.fn();
    renderTab(onActionsReady);

    await waitFor(() =>
      expect(onActionsReady).toHaveBeenCalledWith(
        expect.objectContaining({ openCreate: expect.any(Function) }),
      ),
    );
  });

  it('calls onActionsReady(null) on unmount', () => {
    mockGet.mockResolvedValue(nodesResponse([]));
    const onActionsReady = jest.fn();
    const { unmount } = renderTab(onActionsReady);

    unmount();

    expect(onActionsReady).toHaveBeenLastCalledWith(null);
  });

  it('openCreate handle opens the CreateNodeModal', async () => {
    mockGet.mockResolvedValue(nodesResponse([]));
    const onActionsReady = jest.fn();
    renderTab(onActionsReady);

    await waitFor(() =>
      expect(onActionsReady).toHaveBeenCalledWith(
        expect.objectContaining({ openCreate: expect.any(Function) }),
      ),
    );

    const { openCreate } = onActionsReady.mock.calls[0][0] as { openCreate: () => void };

    act(() => {
      openCreate();
    });

    await waitFor(() =>
      expect(screen.getByTestId('modal')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // CreateNodeModal — open via NodeList's onCreate (empty-state button)
  // ---------------------------------------------------------------------------

  it('opens CreateNodeModal when NodeList onCreate is triggered (empty-state button)', async () => {
    mockGet.mockResolvedValue(nodesResponse([]));
    renderTab();

    await waitFor(() =>
      expect(screen.getByText('No nodes configured')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    await waitFor(() =>
      expect(screen.getByTestId('modal')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // NodeDetailModal — opens when View Details button is clicked
  // ---------------------------------------------------------------------------

  it('opens NodeDetailModal when the Eye (View Details) button is clicked', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const viewBtns = screen.getAllByTitle('View Details');
    fireEvent.click(viewBtns[0]);

    await waitFor(() =>
      expect(screen.getByTestId('modal')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // EditNodeModal — opens when Edit button is clicked
  // ---------------------------------------------------------------------------

  it('opens EditNodeModal when the Edit button is clicked', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const editBtns = screen.getAllByTitle('Edit Node');
    fireEvent.click(editBtns[0]);

    await waitFor(() =>
      expect(screen.getByTestId('modal')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Delete confirmation modal — opens after NodeList fires onDelete (arm+fire)
  // ---------------------------------------------------------------------------

  it('opens the delete confirmation modal after NodeList fires onDelete', async () => {
    // mockGet is called for both the list (GET /system/nodes) and the detail
    // fetch triggered by handleDeleteNode (GET /system/nodes/:id).
    // We differentiate by the URL argument.
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/nodes') return Promise.resolve(nodesResponse([NODE_A]));
      if (url === '/system/nodes/node-aaa') return Promise.resolve(nodeResponse(NODE_A));
      return Promise.resolve(nodesResponse([]));
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    // Arm the delete button (first click arms, second fires)
    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);

    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));

    // Delete confirmation modal appears
    await waitFor(() =>
      expect(screen.getAllByText('Delete Node').length).toBeGreaterThan(0),
    );
    expect(screen.getByText('This action cannot be undone')).toBeInTheDocument();
  });

  it('fetches node detail via GET /system/nodes/:id when setting up delete confirmation', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/nodes') return Promise.resolve(nodesResponse([NODE_A]));
      if (url === '/system/nodes/node-aaa') return Promise.resolve(nodeResponse(NODE_A));
      return Promise.resolve(nodesResponse([]));
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);
    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/nodes/node-aaa'),
    );
  });

  it('shows an error notification when node detail fetch fails during delete setup', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/nodes') return Promise.resolve(nodesResponse([NODE_A]));
      // Reject for the single-node fetch
      return Promise.reject(new Error('Not found'));
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);
    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load node details for deletion',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Delete — confirm flow calls DELETE /system/nodes/:id
  // ---------------------------------------------------------------------------

  it('calls DELETE /system/nodes/:id when the "Delete Node" confirm button is clicked', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/nodes') return Promise.resolve(nodesResponse([NODE_A]));
      if (url === '/system/nodes/node-aaa') return Promise.resolve(nodeResponse(NODE_A));
      return Promise.resolve(nodesResponse([]));
    });
    mockDelete.mockResolvedValue({ data: { success: true } });

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);
    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));

    await waitFor(() =>
      expect(screen.getAllByText('Delete Node').length).toBeGreaterThan(0),
    );

    // In the confirmation modal, click the "Delete Node" button
    const modal = screen.getByTestId('modal');
    const deleteConfirmBtn = within(modal).getByRole('button', { name: /^delete node$/i });
    fireEvent.click(deleteConfirmBtn);

    await waitFor(() =>
      expect(mockDelete).toHaveBeenCalledWith('/system/nodes/node-aaa'),
    );
  });

  it('shows a success notification after deleting a node', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/nodes') return Promise.resolve(nodesResponse([NODE_A]));
      if (url === '/system/nodes/node-aaa') return Promise.resolve(nodeResponse(NODE_A));
      return Promise.resolve(nodesResponse([]));
    });
    mockDelete.mockResolvedValue({ data: { success: true } });

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);
    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));

    await waitFor(() =>
      expect(screen.getAllByText('Delete Node').length).toBeGreaterThan(0),
    );

    fireEvent.click(within(screen.getByTestId('modal')).getByRole('button', { name: /^delete node$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Node "alpha-node" deleted successfully',
      }),
    );
  });

  it('shows an error notification when deleteNode fails with an Error instance', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/nodes') return Promise.resolve(nodesResponse([NODE_A]));
      if (url === '/system/nodes/node-aaa') return Promise.resolve(nodeResponse(NODE_A));
      return Promise.resolve(nodesResponse([]));
    });
    mockDelete.mockRejectedValue(new Error('Delete failed'));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);
    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));

    await waitFor(() =>
      expect(screen.getAllByText('Delete Node').length).toBeGreaterThan(0),
    );

    fireEvent.click(within(screen.getByTestId('modal')).getByRole('button', { name: /^delete node$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Delete failed',
      }),
    );
  });

  it('shows generic error when deleteNode rejects with a non-Error', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/nodes') return Promise.resolve(nodesResponse([NODE_A]));
      if (url === '/system/nodes/node-aaa') return Promise.resolve(nodeResponse(NODE_A));
      return Promise.resolve(nodesResponse([]));
    });
    mockDelete.mockRejectedValue('unknown-failure');

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);
    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));

    await waitFor(() =>
      expect(screen.getAllByText('Delete Node').length).toBeGreaterThan(0),
    );

    fireEvent.click(within(screen.getByTestId('modal')).getByRole('button', { name: /^delete node$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete node',
      }),
    );
  });

  it('shows "Deleting..." on the confirm button while delete is in flight', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/nodes') return Promise.resolve(nodesResponse([NODE_A]));
      if (url === '/system/nodes/node-aaa') return Promise.resolve(nodeResponse(NODE_A));
      return Promise.resolve(nodesResponse([]));
    });

    let resolveDelete!: () => void;
    mockDelete.mockReturnValue(new Promise<void>((r) => { resolveDelete = r; }));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);
    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));

    await waitFor(() =>
      expect(screen.getAllByText('Delete Node').length).toBeGreaterThan(0),
    );

    fireEvent.click(within(screen.getByTestId('modal')).getByRole('button', { name: /^delete node$/i }));

    await waitFor(() =>
      expect(screen.getByText('Deleting...')).toBeInTheDocument(),
    );

    act(() => { resolveDelete(); });
    await waitFor(() =>
      expect(screen.queryByText('Deleting...')).not.toBeInTheDocument(),
    );
  });

  it('disables Cancel while delete is in flight', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/nodes') return Promise.resolve(nodesResponse([NODE_A]));
      if (url === '/system/nodes/node-aaa') return Promise.resolve(nodeResponse(NODE_A));
      return Promise.resolve(nodesResponse([]));
    });

    let resolveDelete!: () => void;
    mockDelete.mockReturnValue(new Promise<void>((r) => { resolveDelete = r; }));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);
    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));

    await waitFor(() =>
      expect(screen.getAllByText('Delete Node').length).toBeGreaterThan(0),
    );

    fireEvent.click(within(screen.getByTestId('modal')).getByRole('button', { name: /^delete node$/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled(),
    );

    act(() => { resolveDelete(); });
    await waitFor(() =>
      expect(screen.queryByText('Deleting...')).not.toBeInTheDocument(),
    );
  });

  it('closes the delete confirmation modal when Cancel is clicked', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/nodes') return Promise.resolve(nodesResponse([NODE_A]));
      if (url === '/system/nodes/node-aaa') return Promise.resolve(nodeResponse(NODE_A));
      return Promise.resolve(nodesResponse([]));
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);
    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));

    await waitFor(() =>
      expect(screen.getAllByText('Delete Node').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByTestId('modal')).not.toBeInTheDocument(),
    );
    expect(mockDelete).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Delete confirmation — instance count warning
  // ---------------------------------------------------------------------------

  it('shows the instance-count warning when the node has instances', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/nodes') return Promise.resolve(nodesResponse([NODE_WITH_INSTANCES]));
      if (url === '/system/nodes/node-aaa') return Promise.resolve(nodeResponse(NODE_WITH_INSTANCES));
      return Promise.resolve(nodesResponse([]));
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);
    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));

    await waitFor(() =>
      expect(screen.getAllByText('Delete Node').length).toBeGreaterThan(0),
    );

    await waitFor(() =>
      expect(
        screen.getByText(/this node has 3 instance\(s\)/i),
      ).toBeInTheDocument(),
    );
  });

  it('does NOT show the instance-count warning when the node has 0 instances', async () => {
    const nodeZeroInstances: SystemNode = { ...NODE_A, instance_count: 0 };
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/nodes') return Promise.resolve(nodesResponse([nodeZeroInstances]));
      if (url === '/system/nodes/node-aaa') return Promise.resolve(nodeResponse(nodeZeroInstances));
      return Promise.resolve(nodesResponse([]));
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);
    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));

    await waitFor(() =>
      expect(screen.getAllByText('Delete Node').length).toBeGreaterThan(0),
    );

    expect(screen.queryByText(/deleting this node will also remove/i)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Toggle enabled — calls PUT /system/nodes/:id with { node: { enabled } }
  // ---------------------------------------------------------------------------

  it('calls PUT /system/nodes/:id with { enabled: false } when disabling an enabled node', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    mockPut.mockResolvedValue(envelope({ node: { ...NODE_A, enabled: false } }));
    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getAllByTitle('Disable Node')[0]);

    await waitFor(() =>
      expect(mockPut).toHaveBeenCalledWith(
        '/system/nodes/node-aaa',
        { node: { enabled: false } },
      ),
    );
  });

  it('calls PUT /system/nodes/:id with { enabled: true } when enabling a disabled node', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_B]));
    mockPut.mockResolvedValue(envelope({ node: { ...NODE_B, enabled: true } }));
    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('beta-node').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getAllByTitle('Enable Node')[0]);

    await waitFor(() =>
      expect(mockPut).toHaveBeenCalledWith(
        '/system/nodes/node-bbb',
        { node: { enabled: true } },
      ),
    );
  });

  it('shows success notification after enabling a node', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_B]));
    mockPut.mockResolvedValue(envelope({ node: { ...NODE_B, enabled: true } }));
    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('beta-node').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getAllByTitle('Enable Node')[0]);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Node "beta-node" enabled successfully',
      }),
    );
  });

  it('shows success notification after disabling a node', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    mockPut.mockResolvedValue(envelope({ node: { ...NODE_A, enabled: false } }));
    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getAllByTitle('Disable Node')[0]);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Node "alpha-node" disabled successfully',
      }),
    );
  });

  it('shows error notification when updateNode fails with an Error instance', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    mockPut.mockRejectedValue(new Error('Toggle failed'));
    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getAllByTitle('Disable Node')[0]);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Toggle failed',
      }),
    );
  });

  it('shows generic error when updateNode rejects with a non-Error', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    mockPut.mockRejectedValue('kaboom');
    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getAllByTitle('Disable Node')[0]);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to update node',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Permission gating — NodesTab passes undefined for restricted handlers
  // ---------------------------------------------------------------------------

  it('does not render Edit/Delete/Toggle buttons when user lacks all permissions', async () => {
    mockHasPermission.mockReturnValue(false);
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0),
    );

    expect(screen.queryAllByTitle('Edit Node').length).toBe(0);
    expect(screen.queryAllByTitle('Delete Node').length).toBe(0);
    expect(screen.queryAllByTitle('Disable Node').length).toBe(0);
    // View Details is always rendered regardless of permissions
    expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0);
  });

  it('does not show the empty-state Create Node button when canCreate is false', async () => {
    mockHasPermission.mockReturnValue(false);
    mockGet.mockResolvedValue(nodesResponse([]));
    renderTab();

    await waitFor(() =>
      expect(screen.getByText('No nodes configured')).toBeInTheDocument(),
    );

    expect(screen.queryByRole('button', { name: /create node/i })).not.toBeInTheDocument();
  });
});
