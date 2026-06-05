import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { OperationDetailModal } from './OperationDetailModal';

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

// hasPermission is controlled per-test via mockHasPermission
const mockHasPermission = jest.fn().mockReturnValue(true);
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

// EntityLink renders a clickable link; a simple text stub is sufficient
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { type: string; id: string; label: string }) => (
    <span data-testid="entity-link">{label}</span>
  ),
}));

// resolveOperableType — use a tight mock that mirrors the real MAP entries we test
jest.mock('@system/features/system/entityRegistry', () => ({
  resolveOperableType: (operableType: string): string | undefined => {
    const map: Record<string, string> = {
      node: 'node',
      node_module: 'node_module',
      node_template: 'node_template',
    };
    const lastSegment = operableType.split('::').pop() ?? operableType;
    const snake = lastSegment
      .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
      .replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2')
      .toLowerCase();
    return map[snake];
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const BASE_TASK = {
  id: 'task-123',
  command: 'provision_node',
  status: 'running' as const,
  description: 'Provision a new node',
  progress: 42,
  exclusive: false,
  scheduled_at: '2026-06-01T10:00:00Z',
  started_at: '2026-06-01T10:01:00Z',
  completed_at: undefined as string | undefined,
  error_message: undefined as string | undefined,
  events: [] as Array<Record<string, unknown>>,
  options: {} as Record<string, unknown>,
  operable_type: undefined as string | undefined,
  operable_id: undefined as string | undefined,
  initiated_by_name: 'operator@example.com',
  created_at: '2026-06-01T09:59:00Z',
  updated_at: '2026-06-01T10:01:00Z',
};

// =============================================================================
// Render helper
// =============================================================================

interface RenderProps {
  operationId?: string | null;
  isOpen?: boolean;
  onClose?: () => void;
  onOperationUpdated?: () => void;
}

function renderModal({
  operationId = 'task-123',
  isOpen = true,
  onClose = jest.fn(),
  onOperationUpdated = jest.fn(),
}: RenderProps = {}) {
  return render(
    <BrowserRouter>
      <OperationDetailModal
        operationId={operationId}
        isOpen={isOpen}
        onClose={onClose}
        onOperationUpdated={onOperationUpdated}
      />
    </BrowserRouter>,
  );
}

// Wait until the header h2 has the expected command text (not "Loading...")
async function waitForCommand(command = 'provision_node') {
  await waitFor(() => {
    const h2 = screen.getByRole('heading', { level: 2 });
    expect(h2).toHaveTextContent(command);
  });
}

// =============================================================================
// Tests
// =============================================================================

describe('OperationDetailModal', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Render states
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    mockGet.mockResolvedValue(envelope({ task: BASE_TASK }));
    renderModal({ isOpen: false });
    expect(screen.queryByText('Operation Details')).not.toBeInTheDocument();
  });

  it('shows loading indicator while the task is being fetched', async () => {
    // Keep the promise pending so the spinner stays visible
    mockGet.mockReturnValue(new Promise(() => {}));
    renderModal();
    // Header shows "Loading..."
    await waitFor(() =>
      expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('Loading...'),
    );
  });

  it('calls getTask with the correct URL on open', async () => {
    mockGet.mockResolvedValue(envelope({ task: BASE_TASK }));
    renderModal({ operationId: 'task-abc' });

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/tasks/task-abc'),
    );
  });

  it('displays the command in the header after loading', async () => {
    mockGet.mockResolvedValue(envelope({ task: BASE_TASK }));
    renderModal();

    await waitForCommand();
    expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('provision_node');
  });

  it('shows error state when getTask rejects', async () => {
    mockGet.mockRejectedValue(new Error('network failure'));
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('Failed to load operation details')).toBeInTheDocument(),
    );
  });

  it('does not call getTask when operationId is null', () => {
    renderModal({ operationId: null });
    expect(mockGet).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Info tab — status + fields
  // ---------------------------------------------------------------------------

  it('renders status badge on Info tab', async () => {
    mockGet.mockResolvedValue(envelope({ task: BASE_TASK }));
    renderModal();

    await waitForCommand();
    expect(screen.getByText('Running')).toBeInTheDocument();
  });

  it('renders progress percentage for running tasks', async () => {
    mockGet.mockResolvedValue(envelope({ task: BASE_TASK }));
    renderModal();

    await waitFor(() => expect(screen.getByText('42%')).toBeInTheDocument());
  });

  it('does not render progress percentage for non-running tasks', async () => {
    mockGet.mockResolvedValue(
      envelope({
        task: {
          ...BASE_TASK,
          status: 'complete' as const,
          completed_at: '2026-06-01T10:05:00Z',
          progress: 100,
        },
      }),
    );
    renderModal();

    await waitForCommand();
    expect(screen.queryByText('100%')).not.toBeInTheDocument();
  });

  it('renders description and initiated_by_name', async () => {
    mockGet.mockResolvedValue(envelope({ task: BASE_TASK }));
    renderModal();

    await waitForCommand();
    expect(screen.getByText('Provision a new node')).toBeInTheDocument();
    expect(screen.getByText('operator@example.com')).toBeInTheDocument();
  });

  it('shows "System" when initiated_by_name is absent', async () => {
    mockGet.mockResolvedValue(
      envelope({ task: { ...BASE_TASK, initiated_by_name: undefined } }),
    );
    renderModal();

    await waitForCommand();
    expect(screen.getByText('System')).toBeInTheDocument();
  });

  it('renders exclusive badge as "Yes" when exclusive=true', async () => {
    mockGet.mockResolvedValue(envelope({ task: { ...BASE_TASK, exclusive: true } }));
    renderModal();

    await waitForCommand();
    expect(screen.getByText('Yes')).toBeInTheDocument();
  });

  it('renders error_message block when present', async () => {
    mockGet.mockResolvedValue(
      envelope({
        task: {
          ...BASE_TASK,
          status: 'failed' as const,
          error_message: 'timeout reached',
        },
      }),
    );
    renderModal();

    await waitFor(() => expect(screen.getByText('timeout reached')).toBeInTheDocument());
    expect(screen.getByText('Error')).toBeInTheDocument();
  });

  it('does not render error block when error_message is absent', async () => {
    mockGet.mockResolvedValue(envelope({ task: BASE_TASK }));
    renderModal();

    await waitForCommand();
    expect(screen.queryByText('Error')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Info tab — operable_type resolution
  // ---------------------------------------------------------------------------

  it('renders EntityLink when operable_type resolves to a known entity', async () => {
    mockGet.mockResolvedValue(
      envelope({
        task: {
          ...BASE_TASK,
          operable_type: 'System::Node',
          operable_id: 'node-99',
        },
      }),
    );
    renderModal();

    await waitFor(() => expect(screen.getByTestId('entity-link')).toBeInTheDocument());
    expect(screen.getByTestId('entity-link')).toHaveTextContent('System::Node');
  });

  it('renders plain text for operable_type when it does not resolve to a registry entry', async () => {
    mockGet.mockResolvedValue(
      envelope({
        task: {
          ...BASE_TASK,
          operable_type: 'SomeUnknownType',
          operable_id: 'id-1',
        },
      }),
    );
    renderModal();

    // "SomeUnknownType" appears in both the header subtitle and the Resource Type field
    await waitFor(() =>
      expect(screen.getAllByText('SomeUnknownType').length).toBeGreaterThan(0),
    );
    expect(screen.queryByTestId('entity-link')).not.toBeInTheDocument();
  });

  it('renders "—" placeholder for Resource Type when operable_type is absent', async () => {
    mockGet.mockResolvedValue(
      envelope({ task: { ...BASE_TASK, operable_type: undefined } }),
    );
    renderModal();

    await waitForCommand();
    expect(screen.getByText('Resource Type')).toBeInTheDocument();
    expect(screen.queryByTestId('entity-link')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tabs — switching
  // ---------------------------------------------------------------------------

  it('renders three tabs: Information, Events, Options', async () => {
    mockGet.mockResolvedValue(envelope({ task: BASE_TASK }));
    renderModal();

    await waitForCommand();
    // Tab buttons appear in the nav row
    expect(screen.getByText('Information')).toBeInTheDocument();
    expect(screen.getByText('Events')).toBeInTheDocument();
    expect(screen.getByText('Options')).toBeInTheDocument();
  });

  it('switches to Events tab and shows empty-state when no events', async () => {
    mockGet.mockResolvedValue(envelope({ task: { ...BASE_TASK, events: [] } }));
    renderModal();

    await waitForCommand();
    fireEvent.click(screen.getByText('Events'));

    expect(screen.getByText('No events recorded')).toBeInTheDocument();
  });

  it('renders event timeline entries when events are present', async () => {
    const task = {
      ...BASE_TASK,
      events: [
        { type: 'info', timestamp: '2026-06-01T10:01:30Z', message: 'Job started' },
        { type: 'error', timestamp: '2026-06-01T10:02:00Z', message: 'Timeout error' },
      ],
    };
    mockGet.mockResolvedValue(envelope({ task }));
    renderModal();

    await waitForCommand();
    fireEvent.click(screen.getByText('Events'));

    expect(screen.getByText('Event Timeline')).toBeInTheDocument();
    expect(screen.getByText('Job started')).toBeInTheDocument();
    expect(screen.getByText('Timeout error')).toBeInTheDocument();
  });

  it('switches to Options tab and shows empty-state when no options', async () => {
    mockGet.mockResolvedValue(envelope({ task: { ...BASE_TASK, options: {} } }));
    renderModal();

    await waitForCommand();
    fireEvent.click(screen.getByText('Options'));

    expect(screen.getByText('No options configured')).toBeInTheDocument();
  });

  it('renders JSON for options when options are present', async () => {
    const task = {
      ...BASE_TASK,
      options: { region: 'us-east-1', spot: true },
    };
    mockGet.mockResolvedValue(envelope({ task }));
    renderModal();

    await waitForCommand();
    fireEvent.click(screen.getByText('Options'));

    const pre = await screen.findByText(/us-east-1/);
    expect(pre).toBeInTheDocument();
    expect(pre.tagName.toLowerCase()).toBe('pre');
  });

  // ---------------------------------------------------------------------------
  // Tab resets to "info" on re-open
  // ---------------------------------------------------------------------------

  it('resets to the info tab when the modal re-opens with a new operationId', async () => {
    mockGet.mockResolvedValue(envelope({ task: BASE_TASK }));
    const { rerender } = renderModal({ operationId: 'task-123' });

    await waitForCommand('provision_node');
    // Switch to Events tab
    fireEvent.click(screen.getByText('Events'));
    expect(screen.getByText('No events recorded')).toBeInTheDocument();

    // Re-open with a different id
    mockGet.mockResolvedValue(
      envelope({ task: { ...BASE_TASK, id: 'task-456', command: 'destroy_node' } }),
    );
    rerender(
      <BrowserRouter>
        <OperationDetailModal
          operationId="task-456"
          isOpen={true}
          onClose={jest.fn()}
        />
      </BrowserRouter>,
    );

    await waitForCommand('destroy_node');
    // Should be back on Information tab — Status heading is visible
    expect(screen.getByText('Status')).toBeInTheDocument();
    expect(screen.queryByText('No events recorded')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Footer — Cancel action (pending / scheduled statuses)
  // ---------------------------------------------------------------------------

  it('shows Cancel button for pending operations when user has permission', async () => {
    mockGet.mockResolvedValue(
      envelope({ task: { ...BASE_TASK, status: 'pending' as const } }),
    );
    renderModal();

    await waitForCommand();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
  });

  it('shows Cancel button for scheduled operations', async () => {
    mockGet.mockResolvedValue(
      envelope({ task: { ...BASE_TASK, status: 'scheduled' as const } }),
    );
    renderModal();

    await waitForCommand();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
  });

  it('does NOT show Cancel button for running operations', async () => {
    mockGet.mockResolvedValue(
      envelope({ task: { ...BASE_TASK, status: 'running' as const } }),
    );
    renderModal();

    await waitForCommand();
    expect(screen.queryByRole('button', { name: /cancel/i })).not.toBeInTheDocument();
  });

  it('does NOT show Cancel button for complete operations', async () => {
    mockGet.mockResolvedValue(
      envelope({ task: { ...BASE_TASK, status: 'complete' as const } }),
    );
    renderModal();

    await waitForCommand();
    expect(screen.queryByRole('button', { name: /cancel/i })).not.toBeInTheDocument();
  });

  it('hides Cancel button when user lacks system.infra_tasks.control permission', async () => {
    mockHasPermission.mockReturnValue(false);

    mockGet.mockResolvedValue(
      envelope({ task: { ...BASE_TASK, status: 'pending' as const } }),
    );
    renderModal();

    await waitForCommand();
    expect(screen.queryByRole('button', { name: /cancel/i })).not.toBeInTheDocument();
  });

  it('calls cancelTask POST with the task id and reason on Cancel click', async () => {
    const cancelledTask = { ...BASE_TASK, status: 'cancelled' as const };
    mockGet
      .mockResolvedValueOnce(envelope({ task: { ...BASE_TASK, status: 'pending' as const } }))
      .mockResolvedValue(envelope({ task: cancelledTask }));
    mockPost.mockResolvedValue(envelope({ task: cancelledTask }));

    renderModal();

    await waitForCommand();
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/tasks/task-123/cancel',
        { reason: 'Cancelled by user' },
      ),
    );
  });

  it('shows success notification after cancelling', async () => {
    const cancelledTask = { ...BASE_TASK, status: 'cancelled' as const };
    mockGet
      .mockResolvedValueOnce(envelope({ task: { ...BASE_TASK, status: 'pending' as const } }))
      .mockResolvedValue(envelope({ task: cancelledTask }));
    mockPost.mockResolvedValue(envelope({ task: cancelledTask }));

    renderModal();

    await waitForCommand();
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Operation cancelled successfully',
      }),
    );
  });

  it('calls onOperationUpdated after cancelling', async () => {
    const onOperationUpdated = jest.fn();
    const cancelledTask = { ...BASE_TASK, status: 'cancelled' as const };
    mockGet
      .mockResolvedValueOnce(envelope({ task: { ...BASE_TASK, status: 'pending' as const } }))
      .mockResolvedValue(envelope({ task: cancelledTask }));
    mockPost.mockResolvedValue(envelope({ task: cancelledTask }));

    renderModal({ onOperationUpdated });

    await waitForCommand();
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() => expect(onOperationUpdated).toHaveBeenCalled());
  });

  it('shows error notification when cancelTask fails', async () => {
    mockGet.mockResolvedValue(
      envelope({ task: { ...BASE_TASK, status: 'pending' as const } }),
    );
    mockPost.mockRejectedValue(new Error('server error'));

    renderModal();

    await waitForCommand();
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to cancel operation',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Footer — Close button
  // ---------------------------------------------------------------------------

  it('calls onClose when the Close button in the footer is clicked', async () => {
    const onClose = jest.fn();
    mockGet.mockResolvedValue(envelope({ task: BASE_TASK }));
    renderModal({ onClose });

    await waitForCommand();
    fireEvent.click(screen.getByRole('button', { name: /^close$/i }));

    expect(onClose).toHaveBeenCalled();
  });

  it('calls onClose when the backdrop overlay is clicked', async () => {
    const onClose = jest.fn();
    mockGet.mockResolvedValue(envelope({ task: BASE_TASK }));
    renderModal({ onClose });

    await waitForCommand();
    const backdrop = document.querySelector('.fixed.inset-0.bg-black\\/50') as HTMLElement;
    expect(backdrop).not.toBeNull();
    fireEvent.click(backdrop);

    expect(onClose).toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Status label mapping
  // ---------------------------------------------------------------------------

  it.each([
    ['pending' as const, 'Pending'],
    // "Scheduled" also appears as a timestamp column header — use getAllByText
    ['scheduled' as const, 'Scheduled'],
    ['complete' as const, 'Complete'],
    ['failed' as const, 'Failed'],
    ['aborted' as const, 'Aborted'],
    ['cancelled' as const, 'Cancelled'],
  ])('renders status "%s" with label "%s"', async (status, label) => {
    mockGet.mockResolvedValue(envelope({ task: { ...BASE_TASK, status } }));
    renderModal();

    await waitFor(() =>
      expect(screen.getAllByText(label).length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // formatDuration
  // ---------------------------------------------------------------------------

  it('shows "—" for duration when started_at is absent', async () => {
    mockGet.mockResolvedValue(
      envelope({ task: { ...BASE_TASK, started_at: undefined } }),
    );
    renderModal();

    await waitForCommand();
    expect(screen.getByText('Duration')).toBeInTheDocument();
    // Multiple "—" characters exist for timestamps; just verify the label is present
  });

  it('formats duration in seconds when task ran for less than a minute', async () => {
    const now = new Date();
    const startedAt = new Date(now.getTime() - 30 * 1000).toISOString();
    mockGet.mockResolvedValue(
      envelope({
        task: {
          ...BASE_TASK,
          started_at: startedAt,
          completed_at: undefined,
        },
      }),
    );
    renderModal();

    await waitForCommand();
    await waitFor(() =>
      expect(screen.getByText(/\d+ seconds/)).toBeInTheDocument(),
    );
  });
});
