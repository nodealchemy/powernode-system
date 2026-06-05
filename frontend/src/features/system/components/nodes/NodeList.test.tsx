import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NodeList } from './NodeList';
import type { SystemNode } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// usePermissions is mocked as a jest.fn() so individual tests can override it.
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

// WebSocket — stub with no-op callbacks so tests can trigger onNodeUpdate.
let capturedOnNodeUpdate: ((n: unknown) => void) | undefined;
jest.mock('@system/features/system/hooks/useSystemWebSocket', () => ({
  useSystemWebSocket: (opts: { onNodeUpdate?: (n: unknown) => void }) => {
    capturedOnNodeUpdate = opts?.onNodeUpdate;
    return {
      isConnected: false,
      error: null,
      refreshOperations: jest.fn(),
      getTask: jest.fn(),
      refreshStats: jest.fn(),
      ping: jest.fn(),
    };
  },
}));

// EntityLink — render a plain anchor so tests can check template name text.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { type: string; id: string; label: string }) => (
    <a data-testid="entity-link">{label}</a>
  ),
}));

// InfiniteScrollSentinel — Observer API not available in jsdom; stub it.
jest.mock(
  '@system/features/system/components/shared/InfiniteScrollSentinel',
  () => ({
    InfiniteScrollSentinel: () => null,
  }),
);

// Redux — useSelector is used by useSystemWebSocket (already mocked), but
// useWebSocket may pull from the store too. Stub the store access.
jest.mock('react-redux', () => ({
  ...jest.requireActual('react-redux'),
  useSelector: () => ({ account: { id: 'acc-1' } }),
}));

// =============================================================================
// Helpers
// =============================================================================

/**
 * Double-envelope: AxiosResponse.data = { success: true, data: payload, meta }
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

function defaultMeta(count = 0, nextPage: number | null = null) {
  return {
    current_page: 1,
    per_page: 20,
    total_count: count,
    total_pages: 1,
    next_page: nextPage,
    prev_page: null,
  };
}

function nodesResponse(nodes: SystemNode[], next_page: number | null = null) {
  return envelope({ nodes }, defaultMeta(nodes.length, next_page));
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
  instance_count: 5,
  running_instances_count: 3,
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

// =============================================================================
// Render helper
// =============================================================================

interface RenderOptions {
  onView?: jest.Mock;
  onEdit?: jest.Mock;
  onDelete?: jest.Mock;
  onCreate?: jest.Mock;
  onToggleEnabled?: jest.Mock;
  refreshKey?: number;
}

function renderNodeList(opts: RenderOptions = {}) {
  const {
    onView = jest.fn(),
    onEdit = jest.fn(),
    onDelete = jest.fn(),
    onCreate = jest.fn(),
    onToggleEnabled = jest.fn(),
    refreshKey,
  } = opts;

  return render(
    <BrowserRouter>
      <NodeList
        onView={onView}
        onEdit={onEdit}
        onDelete={onDelete}
        onCreate={onCreate}
        onToggleEnabled={onToggleEnabled}
        refreshKey={refreshKey}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('NodeList', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    capturedOnNodeUpdate = undefined;
    // Reset permission mock to allow everything by default.
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading spinner on initial load', () => {
    // Delay resolution so loading state is visible.
    mockGet.mockReturnValue(new Promise(() => {}));
    renderNodeList();
    // The spinner is a presentation element — confirm it renders (no crash) and
    // that no node names appear while loading.
    expect(screen.queryByText('alpha-node')).not.toBeInTheDocument();
    expect(screen.queryByText('beta-node')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('renders the empty state when no nodes are returned', async () => {
    mockGet.mockResolvedValue(nodesResponse([]));
    renderNodeList();

    await waitFor(() =>
      expect(screen.getByText('No nodes configured')).toBeInTheDocument(),
    );
    expect(
      screen.getByText('Create your first infrastructure node to start managing your systems'),
    ).toBeInTheDocument();
    // "Create Node" CTA is shown when onCreate is provided and canCreate is true.
    expect(screen.getByRole('button', { name: /create node/i })).toBeInTheDocument();
  });

  it('calls onCreate when the empty-state Create Node button is clicked', async () => {
    const onCreate = jest.fn();
    mockGet.mockResolvedValue(nodesResponse([]));
    renderNodeList({ onCreate });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /create node/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /create node/i }));
    expect(onCreate).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Fetch — correct URL + params
  // ---------------------------------------------------------------------------

  it('fetches nodes from GET /system/nodes with page and per_page params', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    expect(mockGet).toHaveBeenCalledWith(
      '/system/nodes',
      expect.objectContaining({
        params: expect.objectContaining({ page: 1, per_page: 20 }),
      }),
    );
  });

  it('renders both nodes from the API response', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A, NODE_B]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    expect(screen.getAllByText('beta-node').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error notification when the fetch fails', async () => {
    mockGet.mockRejectedValue(new Error('Network error'));
    renderNodeList();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Failed to load nodes' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Node row — display fields
  // ---------------------------------------------------------------------------

  it('renders node name, status badge, instance count, and address in the desktop table', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    // Status badge
    expect(screen.getAllByText('Enabled').length).toBeGreaterThan(0);
    // Instance count
    expect(screen.getAllByText('5').length).toBeGreaterThan(0);
    // Address
    expect(screen.getAllByText('10.0.0.1').length).toBeGreaterThan(0);
    // Template via EntityLink
    expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0);
  });

  it('renders "Disabled" badge for a disabled node', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_B]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('beta-node').length).toBeGreaterThan(0));
    expect(screen.getAllByText('Disabled').length).toBeGreaterThan(0);
  });

  it('renders "-" for address when public_address is absent', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_B]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('beta-node').length).toBeGreaterThan(0));
    // Both desktop and mobile may render '-'
    expect(screen.getAllByText('-').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // onView callback
  // ---------------------------------------------------------------------------

  it('calls onView when the node name is clicked', async () => {
    const onView = jest.fn();
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList({ onView });

    // There are multiple alpha-node spans (desktop + mobile); click the first.
    const names = await waitFor(() => screen.getAllByText('alpha-node'));
    // The clickable span is rendered as plain text, not a button.
    fireEvent.click(names[0]);
    expect(onView).toHaveBeenCalledWith(expect.objectContaining({ id: 'node-aaa' }));
  });

  it('calls onView when the Eye button is clicked', async () => {
    const onView = jest.fn();
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList({ onView });

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    // "View Details" buttons (title attribute)
    const viewBtns = screen.getAllByTitle('View Details');
    fireEvent.click(viewBtns[0]);
    expect(onView).toHaveBeenCalledWith(expect.objectContaining({ id: 'node-aaa' }));
  });

  // ---------------------------------------------------------------------------
  // onEdit callback
  // ---------------------------------------------------------------------------

  it('calls onEdit when the Edit button is clicked', async () => {
    const onEdit = jest.fn();
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList({ onEdit });

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    const editBtns = screen.getAllByTitle('Edit Node');
    fireEvent.click(editBtns[0]);
    expect(onEdit).toHaveBeenCalledWith(expect.objectContaining({ id: 'node-aaa' }));
  });

  // ---------------------------------------------------------------------------
  // onToggleEnabled callback
  // ---------------------------------------------------------------------------

  it('calls onToggleEnabled with the node when "Disable Node" is clicked for an enabled node', async () => {
    const onToggleEnabled = jest.fn();
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList({ onToggleEnabled });

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    const toggleBtns = screen.getAllByTitle('Disable Node');
    fireEvent.click(toggleBtns[0]);
    expect(onToggleEnabled).toHaveBeenCalledWith(expect.objectContaining({ id: 'node-aaa' }));
  });

  it('calls onToggleEnabled when "Enable Node" is clicked for a disabled node', async () => {
    const onToggleEnabled = jest.fn();
    mockGet.mockResolvedValue(nodesResponse([NODE_B]));
    renderNodeList({ onToggleEnabled });

    await waitFor(() => expect(screen.getAllByText('beta-node').length).toBeGreaterThan(0));
    const toggleBtns = screen.getAllByTitle('Enable Node');
    fireEvent.click(toggleBtns[0]);
    expect(onToggleEnabled).toHaveBeenCalledWith(expect.objectContaining({ id: 'node-bbb' }));
  });

  // ---------------------------------------------------------------------------
  // Arm-and-confirm delete
  // ---------------------------------------------------------------------------

  it('arms the delete button on first click and shows "Confirm?" text', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    // First click should arm
    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);

    await waitFor(() =>
      expect(screen.getByText('Confirm?')).toBeInTheDocument(),
    );
  });

  it('calls onDelete on second click within the arm window', async () => {
    const onDelete = jest.fn();
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList({ onDelete });

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    // First click: arm
    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);

    // Wait for armed state (title changes)
    await waitFor(() =>
      expect(screen.getByTitle('Click again to confirm delete')).toBeInTheDocument(),
    );

    // Second click: fires onDelete
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));
    expect(onDelete).toHaveBeenCalledWith('node-aaa');
  });

  it('does NOT call onDelete on the first click', async () => {
    const onDelete = jest.fn();
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList({ onDelete });

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    const deleteBtns = screen.getAllByTitle('Delete Node');
    fireEvent.click(deleteBtns[0]);

    expect(onDelete).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse
  // ---------------------------------------------------------------------------

  it('toggles the expanded detail row when the chevron button is clicked', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    // Expand
    const expandBtns = screen.getAllByTitle('Expand details');
    fireEvent.click(expandBtns[0]);

    // Detail fields appear — Node ID is always shown in the expanded row
    await waitFor(() =>
      expect(screen.getAllByText('Node ID').length).toBeGreaterThan(0),
    );

    // Collapse
    const collapseBtns = screen.getAllByTitle('Collapse details');
    fireEvent.click(collapseBtns[0]);

    await waitFor(() =>
      expect(screen.queryAllByText('Node ID').length).toBe(0),
    );
  });

  it('shows running/total instance counts in the expanded row', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    // NODE_A has 3 running of 5 total
    const expandBtns = screen.getAllByTitle('Expand details');
    fireEvent.click(expandBtns[0]);

    await waitFor(() =>
      // Desktop expanded row: "3 running of 5 total"
      expect(screen.getByText(/3 running of 5 total/)).toBeInTheDocument(),
    );
  });

  it('shows worker_id in the expanded row when present', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    const expandBtns = screen.getAllByTitle('Expand details');
    fireEvent.click(expandBtns[0]);

    await waitFor(() =>
      expect(screen.getAllByText('worker-xyz').length).toBeGreaterThan(0),
    );
  });

  it('shows description in the expanded row when present', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    const expandBtns = screen.getAllByTitle('Expand details');
    fireEvent.click(expandBtns[0]);

    await waitFor(() =>
      expect(screen.getAllByText('Primary compute node').length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // Search filter (client-side)
  // ---------------------------------------------------------------------------

  it('filters nodes by name via the search box (client-side, no extra API call)', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A, NODE_B]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    const callCountBefore = mockGet.mock.calls.length;

    const searchInput = screen.getByPlaceholderText('Search nodes...');
    fireEvent.change(searchInput, { target: { value: 'alpha' } });

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    // beta-node should be filtered out
    await waitFor(() =>
      expect(screen.queryAllByText('beta-node').length).toBe(0),
    );

    // No extra fetch should have fired (search is client-side)
    expect(mockGet.mock.calls.length).toBe(callCountBefore);
  });

  it('filters by public_address via the search box', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A, NODE_B]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    const searchInput = screen.getByPlaceholderText('Search nodes...');
    fireEvent.change(searchInput, { target: { value: '10.0.0.1' } });

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    await waitFor(() =>
      expect(screen.queryAllByText('beta-node').length).toBe(0),
    );
  });

  // ---------------------------------------------------------------------------
  // Server-side enabled filter (causes refetch)
  // ---------------------------------------------------------------------------

  it('refetches with enabled=true when the Enabled filter is selected', async () => {
    mockGet
      .mockResolvedValueOnce(nodesResponse([NODE_A, NODE_B]))
      .mockResolvedValueOnce(nodesResponse([NODE_A]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    const select = screen.getByDisplayValue('All Status');
    fireEvent.change(select, { target: { value: 'enabled' } });

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(
        '/system/nodes',
        expect.objectContaining({
          params: expect.objectContaining({ enabled: true }),
        }),
      ),
    );
  });

  it('refetches with enabled=false when the Disabled filter is selected', async () => {
    mockGet
      .mockResolvedValueOnce(nodesResponse([NODE_A, NODE_B]))
      .mockResolvedValueOnce(nodesResponse([NODE_B]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    const select = screen.getByDisplayValue('All Status');
    fireEvent.change(select, { target: { value: 'disabled' } });

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(
        '/system/nodes',
        expect.objectContaining({
          params: expect.objectContaining({ enabled: false }),
        }),
      ),
    );
  });

  it('does NOT include enabled param when "All Status" is selected', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A, NODE_B]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    // The initial call with 'all' should NOT pass `enabled`
    const firstCall = mockGet.mock.calls[0];
    expect(firstCall[1].params).not.toHaveProperty('enabled');
  });

  // ---------------------------------------------------------------------------
  // WebSocket live update (upsert)
  // ---------------------------------------------------------------------------

  it('updates a node in-place when useSystemWebSocket fires onNodeUpdate', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    // Trigger the WebSocket callback with an updated node
    const updatedNode: SystemNode = {
      ...NODE_A,
      name: 'alpha-node-updated',
      public_address: '10.0.0.99',
    };

    act(() => {
      capturedOnNodeUpdate?.(updatedNode);
    });

    await waitFor(() =>
      expect(screen.getAllByText('alpha-node-updated').length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // refreshKey triggers a refresh
  // ---------------------------------------------------------------------------

  it('calls refresh when refreshKey changes from 0 to a positive value', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));

    const { rerender } = render(
      <BrowserRouter>
        <NodeList onView={jest.fn()} refreshKey={0} />
      </BrowserRouter>,
    );

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    const prevCallCount = mockGet.mock.calls.length;

    mockGet.mockResolvedValue(nodesResponse([NODE_A, NODE_B]));

    rerender(
      <BrowserRouter>
        <NodeList onView={jest.fn()} refreshKey={1} />
      </BrowserRouter>,
    );

    await waitFor(() =>
      expect(mockGet.mock.calls.length).toBeGreaterThan(prevCallCount),
    );
  });

  // ---------------------------------------------------------------------------
  // Permission gating — buttons absent without permissions
  // ---------------------------------------------------------------------------

  it('hides Edit, Delete, and Toggle buttons when user lacks update/delete permissions', async () => {
    // Override permission mock to deny everything for this test.
    mockHasPermission.mockReturnValue(false);

    mockGet.mockResolvedValue(nodesResponse([NODE_A]));

    render(
      <BrowserRouter>
        <NodeList onView={jest.fn()} onEdit={jest.fn()} onDelete={jest.fn()} onToggleEnabled={jest.fn()} />
      </BrowserRouter>,
    );

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    expect(screen.queryAllByTitle('Edit Node').length).toBe(0);
    expect(screen.queryAllByTitle('Delete Node').length).toBe(0);
    expect(screen.queryAllByTitle('Disable Node').length).toBe(0);
    // The View button should still show (it's always rendered).
    expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Template column — no link when node_template_id is absent
  // ---------------------------------------------------------------------------

  it('renders template name without EntityLink when node has no template id', async () => {
    const nodeNoTemplate: SystemNode = {
      ...NODE_B,
      node_template_name: 'bare-template',
      node_template_id: undefined,
    };
    mockGet.mockResolvedValue(nodesResponse([nodeNoTemplate]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('beta-node').length).toBeGreaterThan(0));
    // Template name shown as plain text, not EntityLink
    expect(screen.getAllByText('bare-template').length).toBeGreaterThan(0);
    expect(screen.queryByTestId('entity-link')).not.toBeInTheDocument();
  });

  it('renders EntityLink when node has both template id and name', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));
    expect(screen.getAllByTestId('entity-link').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // "Showing N of M" hint when search filters reduce visible count
  // ---------------------------------------------------------------------------

  it('shows "Showing N of M" when client-side filter reduces the display count', async () => {
    mockGet.mockResolvedValue(nodesResponse([NODE_A, NODE_B]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search nodes...');
    fireEvent.change(searchInput, { target: { value: 'alpha' } });

    await waitFor(() =>
      expect(screen.getByText('Showing 1 of 2')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Mobile dropdown — open/close + callbacks
  // ---------------------------------------------------------------------------

  it('opens the mobile dropdown and calls onView from "View Details" item', async () => {
    const onView = jest.fn();
    mockGet.mockResolvedValue(nodesResponse([NODE_A]));
    renderNodeList({ onView });

    await waitFor(() => expect(screen.getAllByText('alpha-node').length).toBeGreaterThan(0));

    // Desktop action buttons all have title attributes. The MoreVertical
    // button in the mobile card does NOT have a title — find it that way.
    const allButtons = screen.getAllByRole('button');
    const noTitleButtons = allButtons.filter(
      (b) => !b.hasAttribute('title'),
    );
    // There should be at least one MoreVertical button (the mobile card)
    expect(noTitleButtons.length).toBeGreaterThan(0);

    fireEvent.click(noTitleButtons[0]);

    // "View Details" appears in the dropdown
    await waitFor(() =>
      expect(screen.getAllByText('View Details').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getAllByText('View Details')[0]);
    expect(onView).toHaveBeenCalledWith(expect.objectContaining({ id: 'node-aaa' }));
  });

  // ---------------------------------------------------------------------------
  // No template — display dash
  // ---------------------------------------------------------------------------

  it('shows "-" in the template column when node has neither id nor name', async () => {
    const nodeNoTpl: SystemNode = {
      ...NODE_B,
      node_template_id: undefined,
      node_template_name: undefined,
    };
    mockGet.mockResolvedValue(nodesResponse([nodeNoTpl]));
    renderNodeList();

    await waitFor(() => expect(screen.getAllByText('beta-node').length).toBeGreaterThan(0));
    // Both desktop table and mobile card should show '-'
    expect(screen.getAllByText('-').length).toBeGreaterThan(0);
  });
});
