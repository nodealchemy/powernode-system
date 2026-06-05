import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { TasksTab } from './TasksTab';
import type { SystemTask } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: jest.fn(),
    delete: jest.fn(),
  },
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => true,
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

// EntityLink — render a plain anchor so operable references appear in the DOM.
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

// Redux — useSelector is pulled by useSystemWebSocket indirectly.
jest.mock('react-redux', () => ({
  ...jest.requireActual('react-redux'),
  useSelector: () => ({ account: { id: 'acc-1' } }),
}));

// WebSocket — capture the option callbacks so tests can simulate WS pushes.
type WsOpts = {
  onOperationUpdate?: (op: unknown) => void;
  onOperationProgress?: (p: { operation_id: string; status: SystemTask['status']; progress: number; description?: string }) => void;
};
let capturedWsOpts: WsOpts = {};

jest.mock('@system/features/system/hooks/useSystemWebSocket', () => ({
  useSystemWebSocket: (opts: WsOpts) => {
    capturedWsOpts = opts;
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

// entityRegistry — resolveOperableType has its own unit tests; here we just
// need a predictable stub so OperableReference renders deterministically.
jest.mock('@system/features/system/entityRegistry', () => ({
  resolveOperableType: (t: string) => (t === 'System::Node' ? 'node' : undefined),
}));

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const TASK_PENDING: SystemTask = {
  id: 'task-pending-1',
  command: 'node.provision',
  status: 'pending',
  description: 'Provision new node',
  progress: 0,
  exclusive: false,
  events: [],
  options: {},
  operable_type: undefined,
  operable_id: undefined,
  initiated_by_id: 'user-1',
  initiated_by_name: 'Alice',
  scheduled_at: undefined,
  started_at: undefined,
  completed_at: undefined,
  error_message: undefined,
  created_at: '2026-06-01T10:00:00Z',
  updated_at: '2026-06-01T10:00:00Z',
};

const TASK_RUNNING: SystemTask = {
  id: 'task-running-1',
  command: 'module.upgrade',
  status: 'running',
  description: 'Upgrade nginx module',
  progress: 45,
  exclusive: true,
  events: [
    { type: 'info', timestamp: '2026-06-01T11:00:00Z', message: 'Starting upgrade' },
    { type: 'success', timestamp: '2026-06-01T11:01:00Z', message: 'Downloaded package' },
  ],
  options: { version: '2.0.0' },
  operable_type: 'System::Node',
  operable_id: 'node-abc-1',
  initiated_by_name: 'System',
  started_at: '2026-06-01T11:00:00Z',
  completed_at: undefined,
  scheduled_at: undefined,
  error_message: undefined,
  created_at: '2026-06-01T11:00:00Z',
  updated_at: '2026-06-01T11:05:00Z',
};

const TASK_FAILED: SystemTask = {
  id: 'task-failed-1',
  command: 'disk.wipe',
  status: 'failed',
  description: 'Wipe disk on node',
  progress: 0,
  exclusive: false,
  events: [],
  options: {},
  error_message: 'Disk not found: /dev/sdb',
  started_at: '2026-06-01T09:00:00Z',
  completed_at: '2026-06-01T09:01:00Z',
  created_at: '2026-06-01T09:00:00Z',
  updated_at: '2026-06-01T09:01:00Z',
};

const TASK_COMPLETE: SystemTask = {
  id: 'task-complete-1',
  command: 'node.sync',
  status: 'complete',
  description: 'Sync node modules',
  progress: 100,
  exclusive: false,
  events: [],
  options: {},
  started_at: '2026-06-01T08:00:00Z',
  completed_at: '2026-06-01T08:02:00Z',
  created_at: '2026-06-01T08:00:00Z',
  updated_at: '2026-06-01T08:02:00Z',
};

const TASK_SCHEDULED: SystemTask = {
  id: 'task-scheduled-1',
  command: 'node.reboot',
  status: 'scheduled',
  description: 'Scheduled reboot',
  progress: 0,
  exclusive: false,
  events: [],
  options: {},
  scheduled_at: '2026-06-02T02:00:00Z',
  started_at: undefined,
  completed_at: undefined,
  created_at: '2026-06-01T12:00:00Z',
  updated_at: '2026-06-01T12:00:00Z',
};

// systemApi.getTasks resolves directly (not via apiClient double-envelope).
// tasksApi.getTasks calls apiClient.get and uses extractPaginated internally.
// We mock apiClient.get to return the paginated shape.
function taskListResponse(tasks: SystemTask[]) {
  return {
    data: {
      success: true,
      data: { tasks },
      meta: {
        current_page: 1,
        per_page: 100,
        total_count: tasks.length,
        total_pages: 1,
        next_page: null,
        prev_page: null,
      },
    },
  };
}

// systemApi.getTask returns the single task — also via apiClient.get.
function taskDetailResponse(task: SystemTask) {
  return envelope({ task });
}

// systemApi.cancelTask calls apiClient.post.
function cancelResponse(task: SystemTask) {
  return envelope({ task });
}

// =============================================================================
// Render helper
// =============================================================================

const renderTab = () =>
  render(
    <BrowserRouter>
      <TasksTab />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('TasksTab', () => {
  beforeEach(() => {
    capturedWsOpts = {};
    mockGet.mockReset();
    mockPost.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading spinner on initial mount before the API resolves', async () => {
    // Never resolve — stays loading.
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    // ResponsiveListContainer renders a LoadingSpinner (an SVG) when loading
    // and no items are loaded yet. The spinner wraps in a centered flex container.
    await waitFor(() =>
      expect(document.querySelector('.flex.items-center.justify-center')).toBeTruthy(),
    );
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows "No operations" empty state when the API returns an empty task list', async () => {
    mockGet.mockResolvedValue(taskListResponse([]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('No operations')).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/Operations will appear here when system tasks are executed/i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Render tasks from API
  // ---------------------------------------------------------------------------

  it('renders the task list fetched from GET /system/tasks', async () => {
    mockGet.mockResolvedValue(taskListResponse([TASK_PENDING, TASK_RUNNING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('node.provision').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('module.upgrade').length).toBeGreaterThan(0);

    expect(mockGet).toHaveBeenCalledWith('/system/tasks', { params: undefined });
  });

  it('renders all status badges for tasks with different statuses', async () => {
    mockGet.mockResolvedValue(
      taskListResponse([TASK_PENDING, TASK_RUNNING, TASK_FAILED, TASK_COMPLETE, TASK_SCHEDULED]),
    );

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('Pending').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('Running').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Failed').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Complete').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Scheduled').length).toBeGreaterThan(0);
  });

  it('shows a progress bar with percentage for running tasks', async () => {
    mockGet.mockResolvedValue(taskListResponse([TASK_RUNNING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('45%').length).toBeGreaterThan(0),
    );
  });

  it('renders description text for tasks that have one', async () => {
    mockGet.mockResolvedValue(taskListResponse([TASK_PENDING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('Provision new node').length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // Search filter
  // ---------------------------------------------------------------------------

  it('filters the visible task list by the search input (command match)', async () => {
    mockGet.mockResolvedValue(taskListResponse([TASK_PENDING, TASK_RUNNING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('node.provision').length).toBeGreaterThan(0),
    );

    fireEvent.change(screen.getByPlaceholderText('Search operations...'), {
      target: { value: 'module.upgrade' },
    });

    await waitFor(() =>
      expect(screen.queryAllByText('node.provision').length).toBe(0),
    );
    expect(screen.getAllByText('module.upgrade').length).toBeGreaterThan(0);
  });

  it('filters by description text when searching', async () => {
    mockGet.mockResolvedValue(taskListResponse([TASK_PENDING, TASK_RUNNING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('node.provision').length).toBeGreaterThan(0),
    );

    fireEvent.change(screen.getByPlaceholderText('Search operations...'), {
      target: { value: 'Upgrade nginx' },
    });

    await waitFor(() =>
      expect(screen.queryAllByText('node.provision').length).toBe(0),
    );
    expect(screen.getAllByText('module.upgrade').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Status filter
  // ---------------------------------------------------------------------------

  it('filters the task list by status via the status select', async () => {
    mockGet.mockResolvedValue(
      taskListResponse([TASK_PENDING, TASK_RUNNING, TASK_FAILED]),
    );

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('node.provision').length).toBeGreaterThan(0),
    );

    // Change to "running" filter
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'running' },
    });

    await waitFor(() =>
      expect(screen.queryAllByText('node.provision').length).toBe(0),
    );
    expect(screen.getAllByText('module.upgrade').length).toBeGreaterThan(0);
    expect(screen.queryAllByText('disk.wipe').length).toBe(0);
  });

  it('shows all tasks again when status filter is reset to "all"', async () => {
    mockGet.mockResolvedValue(taskListResponse([TASK_PENDING, TASK_RUNNING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('node.provision').length).toBeGreaterThan(0),
    );

    const select = screen.getByRole('combobox');

    fireEvent.change(select, { target: { value: 'failed' } });
    await waitFor(() =>
      expect(screen.queryAllByText('node.provision').length).toBe(0),
    );

    fireEvent.change(select, { target: { value: 'all' } });
    await waitFor(() =>
      expect(screen.getAllByText('node.provision').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('module.upgrade').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse
  // ---------------------------------------------------------------------------

  it('expands a row to show detail metadata when the chevron button is clicked', async () => {
    mockGet.mockResolvedValue(taskListResponse([TASK_RUNNING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('module.upgrade').length).toBeGreaterThan(0),
    );

    // Find the expand chevron button by its title — Desktop and Mobile both render
    // expand buttons, so getAllByTitle is correct; click the first.
    const expandButtons = screen.getAllByTitle('Expand details');
    expect(expandButtons.length).toBeGreaterThan(0);

    fireEvent.click(expandButtons[0]);

    await waitFor(() => {
      // Expanded rows (Desktop + Mobile both show) — at least one "Initiated By" label.
      expect(screen.getAllByText('Initiated By').length).toBeGreaterThan(0);
    });
    expect(screen.getAllByText('System').length).toBeGreaterThan(0);
    // Exclusive: true → 'Yes'
    expect(screen.getAllByText('Yes').length).toBeGreaterThan(0);
  });

  it('collapses an expanded row when the chevron is clicked again', async () => {
    mockGet.mockResolvedValue(taskListResponse([TASK_RUNNING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('module.upgrade').length).toBeGreaterThan(0),
    );

    // Click the FIRST expand button (Desktop row)
    const expandBtns = screen.getAllByTitle('Expand details');
    fireEvent.click(expandBtns[0]);

    // After expanding the first row, all expand buttons for that row become "Collapse details"
    await waitFor(() =>
      expect(screen.getAllByTitle('Collapse details').length).toBeGreaterThan(0),
    );

    // Click the FIRST collapse button
    fireEvent.click(screen.getAllByTitle('Collapse details')[0]);

    await waitFor(() =>
      expect(screen.queryAllByTitle('Collapse details').length).toBe(0),
    );
    expect(screen.getAllByTitle('Expand details').length).toBeGreaterThan(0);
  });

  it('shows the Operation ID in the expanded row detail', async () => {
    mockGet.mockResolvedValue(taskListResponse([TASK_RUNNING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('module.upgrade').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getAllByTitle('Expand details')[0]);

    // Both Desktop and Mobile expanded rows render the operation id
    await waitFor(() =>
      expect(screen.getAllByText('task-running-1').length).toBeGreaterThan(0),
    );
  });

  it('shows error message in expanded row for failed tasks', async () => {
    mockGet.mockResolvedValue(taskListResponse([TASK_FAILED]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('disk.wipe').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getAllByTitle('Expand details')[0]);

    // Both Desktop and Mobile expanded rows render the error_message
    await waitFor(() =>
      expect(screen.getAllByText('Disk not found: /dev/sdb').length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // View Details modal — opening
  // ---------------------------------------------------------------------------

  it('opens the OperationDetailModal when the Eye/View button is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_PENDING]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_PENDING));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    // Modal opens and fetches the task detail
    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(`/system/tasks/${TASK_PENDING.id}`),
    );

    // Modal shows the operation command
    await waitFor(() =>
      expect(screen.getAllByText('node.provision').length).toBeGreaterThan(1),
    );
  });

  it('opens the modal when the command text is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_RUNNING]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_RUNNING));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('module.upgrade').length).toBeGreaterThan(0),
    );

    // Click the command name text (the span with cursor-pointer)
    fireEvent.click(screen.getAllByText('module.upgrade')[0]);

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(`/system/tasks/${TASK_RUNNING.id}`),
    );
  });

  // ---------------------------------------------------------------------------
  // View Details modal — content tabs
  // ---------------------------------------------------------------------------

  it('renders the Information tab by default in the detail modal', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_RUNNING]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_RUNNING));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    // Wait for modal tabs to appear
    await waitFor(() => expect(screen.getByText('Information')).toBeInTheDocument());
    // Modal info tab renders a Duration label — use getAllByText since the
    // list row may also render 'Initiated By' in an expanded section.
    await waitFor(() =>
      expect(screen.getAllByText('Initiated By').length).toBeGreaterThan(0),
    );
    // The modal command heading shows the task command
    expect(screen.getAllByText('module.upgrade').length).toBeGreaterThan(0);
  });

  it('renders the Events tab with event timeline when selected', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_RUNNING]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_RUNNING));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    await waitFor(() => expect(screen.getByText('Events')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Events'));

    await waitFor(() =>
      expect(screen.getByText('Event Timeline')).toBeInTheDocument(),
    );
    expect(screen.getByText('Starting upgrade')).toBeInTheDocument();
    expect(screen.getByText('Downloaded package')).toBeInTheDocument();
  });

  it('shows "No events recorded" when the task has no events', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_PENDING]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_PENDING));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    await waitFor(() => expect(screen.getByText('Events')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Events'));

    await waitFor(() =>
      expect(screen.getByText('No events recorded')).toBeInTheDocument(),
    );
  });

  it('renders the Options tab with JSON when selected', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_RUNNING]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_RUNNING));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    await waitFor(() => expect(screen.getByText('Options')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Options'));

    await waitFor(() =>
      expect(screen.getByText('Operation Options')).toBeInTheDocument(),
    );
    // Options JSON should include the version key
    expect(screen.getByText(/"version"/)).toBeInTheDocument();
  });

  it('shows "No options configured" on the Options tab for tasks with empty options', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_PENDING]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_PENDING));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    await waitFor(() => expect(screen.getByText('Options')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Options'));

    await waitFor(() =>
      expect(screen.getByText('No options configured')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Modal error state
  // ---------------------------------------------------------------------------

  it('shows "Failed to load operation details" when getTask rejects', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_PENDING]))
      .mockRejectedValueOnce(new Error('network error'));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    await waitFor(() =>
      expect(screen.getByText('Failed to load operation details')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Modal — Cancel action (pending/scheduled tasks with permission)
  // ---------------------------------------------------------------------------

  it('shows Cancel button for pending operations when operator has control permission', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_PENDING]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_PENDING));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument(),
    );
  });

  it('shows Cancel button for scheduled operations', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_SCHEDULED]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_SCHEDULED));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument(),
    );
  });

  it('does NOT show Cancel button for completed operations', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_COMPLETE]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_COMPLETE));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    // Wait for modal content to appear
    await waitFor(() =>
      expect(screen.getByText('Information')).toBeInTheDocument(),
    );

    expect(screen.queryByRole('button', { name: /cancel/i })).not.toBeInTheDocument();
  });

  it('calls POST /system/tasks/:id/cancel when Cancel is clicked', async () => {
    const cancelledTask: SystemTask = { ...TASK_PENDING, status: 'cancelled' };

    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_PENDING]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_PENDING))
      .mockResolvedValueOnce(taskDetailResponse(cancelledTask));

    mockPost.mockResolvedValueOnce(cancelResponse(cancelledTask));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        `/system/tasks/${TASK_PENDING.id}/cancel`,
        { reason: 'Cancelled by user' },
      ),
    );

    // Success notification should fire
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Operation cancelled successfully',
      }),
    );
  });

  it('shows an error notification when cancel fails', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_PENDING]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_PENDING));

    mockPost.mockRejectedValueOnce(new Error('server error'));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to cancel operation',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Modal — Close
  // ---------------------------------------------------------------------------

  it('closes the modal when the Close button is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_PENDING]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_PENDING));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByTitle('View Details')[0]);

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^close$/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /^close$/i }));

    await waitFor(() =>
      expect(screen.queryByText('Information')).not.toBeInTheDocument(),
    );
  });

  it('resets selectedOperationId to null after the modal is closed', async () => {
    // Open with TASK_PENDING, close, then open TASK_RUNNING to prove state resets.
    mockGet
      .mockResolvedValueOnce(taskListResponse([TASK_PENDING, TASK_RUNNING]))
      .mockResolvedValueOnce(taskDetailResponse(TASK_PENDING))
      .mockResolvedValueOnce(taskDetailResponse(TASK_RUNNING));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('View Details').length).toBeGreaterThan(0),
    );

    // Open first task modal
    const viewButtons = screen.getAllByTitle('View Details');
    fireEvent.click(viewButtons[0]);

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^close$/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /^close$/i }));

    await waitFor(() =>
      expect(screen.queryByText('Information')).not.toBeInTheDocument(),
    );

    // Open second task
    fireEvent.click(screen.getAllByTitle('View Details')[1]);

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(`/system/tasks/${TASK_RUNNING.id}`),
    );
  });

  // ---------------------------------------------------------------------------
  // Error notification — list fetch failure
  // ---------------------------------------------------------------------------

  it('shows an error notification when the tasks list fetch fails', async () => {
    mockGet.mockRejectedValueOnce(new Error('network error'));

    renderTab();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load operations',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // WebSocket live updates
  // ---------------------------------------------------------------------------

  it('upserts a new task into the list when onOperationUpdate fires', async () => {
    mockGet.mockResolvedValueOnce(taskListResponse([TASK_PENDING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('node.provision').length).toBeGreaterThan(0),
    );

    // WebSocket pushes a brand-new task
    const newTask: SystemTask = {
      id: 'task-ws-new',
      command: 'fleet.reconcile',
      status: 'running',
      progress: 10,
      exclusive: false,
      events: [],
      options: {},
      created_at: '2026-06-01T13:00:00Z',
      updated_at: '2026-06-01T13:00:00Z',
    };

    act(() => {
      capturedWsOpts.onOperationUpdate?.(newTask);
    });

    await waitFor(() =>
      expect(screen.getAllByText('fleet.reconcile').length).toBeGreaterThan(0),
    );
  });

  it('updates an existing task in-place when onOperationUpdate fires for an existing id', async () => {
    mockGet.mockResolvedValueOnce(taskListResponse([TASK_PENDING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('Pending').length).toBeGreaterThan(0),
    );

    act(() => {
      capturedWsOpts.onOperationUpdate?.({
        ...TASK_PENDING,
        status: 'running',
        progress: 20,
      });
    });

    await waitFor(() =>
      expect(screen.getAllByText('Running').length).toBeGreaterThan(0),
    );
    // 'Pending' badge is now gone from the list rows (status select option has "Pending"
    // as text but it's inside an <option> element — filter it out).
    const pendingInBadges = screen.queryAllByText('Pending').filter(
      (el) => el.tagName.toLowerCase() !== 'option',
    );
    expect(pendingInBadges.length).toBe(0);
  });

  it('patches progress on an existing task when onOperationProgress fires', async () => {
    mockGet.mockResolvedValueOnce(taskListResponse([TASK_RUNNING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('45%').length).toBeGreaterThan(0),
    );

    act(() => {
      capturedWsOpts.onOperationProgress?.({
        operation_id: TASK_RUNNING.id,
        status: 'running',
        progress: 80,
      });
    });

    await waitFor(() =>
      expect(screen.getAllByText('80%').length).toBeGreaterThan(0),
    );
    expect(screen.queryAllByText('45%').length).toBe(0);
  });

  // ---------------------------------------------------------------------------
  // Filter count summary
  // ---------------------------------------------------------------------------

  it('shows "Showing N of M" when a filter reduces the visible count', async () => {
    mockGet.mockResolvedValue(
      taskListResponse([TASK_PENDING, TASK_RUNNING, TASK_FAILED]),
    );

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('node.provision').length).toBeGreaterThan(0),
    );

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'failed' },
    });

    await waitFor(() =>
      expect(screen.getByText('Showing 1 of 3')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Operable reference rendering
  // ---------------------------------------------------------------------------

  it('renders "—" for tasks without an operable_type in the expanded detail', async () => {
    // TASK_PENDING has no operable_type
    mockGet.mockResolvedValue(taskListResponse([TASK_PENDING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('node.provision').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getAllByTitle('Expand details')[0]);

    await waitFor(() => {
      const dashElements = screen.getAllByText('—');
      expect(dashElements.length).toBeGreaterThan(0);
    });
  });

  it('renders an EntityLink for tasks whose operable_type resolves to a registry type', async () => {
    // TASK_RUNNING has operable_type='System::Node' → resolves to 'node'
    mockGet.mockResolvedValue(taskListResponse([TASK_RUNNING]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('module.upgrade').length).toBeGreaterThan(0),
    );

    // EntityLink rendered with label='System::Node'
    expect(screen.getAllByTestId('entity-link').length).toBeGreaterThan(0);
  });
});
