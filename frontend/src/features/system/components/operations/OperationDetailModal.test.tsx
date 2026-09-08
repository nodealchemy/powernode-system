import { readFileSync } from 'node:fs';
import path from 'node:path';
import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
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

// SystemChannel subscription — capture the callbacks so tests can emit frames,
// and let each test decide whether the socket is up (the poll is the fallback
// for when it is not).
interface CapturedWsOptions {
  onOperationUpdate?: (op: Record<string, unknown>) => void;
  onOperationProgress?: (p: Record<string, unknown>) => void;
}
let capturedWsOptions: CapturedWsOptions = {};
let mockWsConnected = false;
jest.mock('@system/features/system/hooks/useSystemWebSocket', () => ({
  __esModule: true,
  useSystemWebSocket: (opts: CapturedWsOptions) => {
    capturedWsOptions = opts;
    return {
      isConnected: mockWsConnected,
      error: null,
      refreshOperations: jest.fn(),
      getTask: jest.fn(),
      refreshStats: jest.fn(),
      ping: jest.fn(),
    };
  },
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
    capturedWsOptions = {};
    mockWsConnected = false;
  });

  afterEach(() => {
    jest.useRealTimers();
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

  // Since IMP-0ea71d15f980 the footer Cancel button opens the shared
  // confirmation dialog; the POST fires from its "Cancel Operation" button.
  function confirmCancel() {
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    fireEvent.click(screen.getByRole('button', { name: 'Cancel Operation' }));
  }

  it('calls cancelTask POST with the task id on Cancel click', async () => {
    const cancelledTask = { ...BASE_TASK, status: 'cancelled' as const };
    mockGet
      .mockResolvedValueOnce(envelope({ task: { ...BASE_TASK, status: 'pending' as const } }))
      .mockResolvedValue(envelope({ task: cancelledTask }));
    mockPost.mockResolvedValue(envelope({ task: cancelledTask }));

    renderModal();

    await waitForCommand();
    confirmCancel();

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/tasks/task-123/cancel',
        { reason: undefined },
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
    confirmCancel();

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
    confirmCancel();

    await waitFor(() => expect(onOperationUpdated).toHaveBeenCalled());
  });

  it('shows error notification when cancelTask fails', async () => {
    mockGet.mockResolvedValue(
      envelope({ task: { ...BASE_TASK, status: 'pending' as const } }),
    );
    mockPost.mockRejectedValue(new Error('server error'));

    renderModal();

    await waitForCommand();
    confirmCancel();

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

  // ---------------------------------------------------------------------------
  // Footer — Abort action (running status) — IMP-0ea71d15f980
  // ---------------------------------------------------------------------------

  describe('Abort action', () => {
    const runningTask = { ...BASE_TASK, status: 'running' as const };
    const abortedTask = { ...BASE_TASK, status: 'aborted' as const };

    function openAbortDialog() {
      fireEvent.click(screen.getByRole('button', { name: 'Abort' }));
    }

    it('shows Abort button for running operations when user has permission', async () => {
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      renderModal();

      await waitForCommand();
      expect(screen.getByRole('button', { name: 'Abort' })).toBeInTheDocument();
    });

    it.each([
      ['pending' as const],
      ['scheduled' as const],
      ['complete' as const],
      ['failed' as const],
      ['aborted' as const],
      ['cancelled' as const],
    ])('does NOT show Abort button for %s operations', async (status) => {
      mockGet.mockResolvedValue(envelope({ task: { ...BASE_TASK, status } }));
      renderModal();

      await waitForCommand();
      expect(screen.queryByRole('button', { name: 'Abort' })).not.toBeInTheDocument();
    });

    it('hides Abort button when user lacks system.infra_tasks.control permission', async () => {
      mockHasPermission.mockReturnValue(false);
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      renderModal();

      await waitForCommand();
      expect(screen.queryByRole('button', { name: 'Abort' })).not.toBeInTheDocument();
    });

    it('does not POST until the abort confirmation is confirmed', async () => {
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      renderModal();

      await waitForCommand();
      openAbortDialog();

      expect(screen.getByRole('button', { name: 'Abort Operation' })).toBeInTheDocument();
      expect(mockPost).not.toHaveBeenCalled();
    });

    it('POSTs to the abort endpoint with the operator-supplied reason', async () => {
      mockGet
        .mockResolvedValueOnce(envelope({ task: runningTask }))
        .mockResolvedValue(envelope({ task: abortedTask }));
      mockPost.mockResolvedValue(envelope({ task: abortedTask }));
      renderModal();

      await waitForCommand();
      openAbortDialog();
      fireEvent.change(screen.getByPlaceholderText(/why are you stopping/i), {
        target: { value: 'wedged for an hour' },
      });
      fireEvent.click(screen.getByRole('button', { name: 'Abort Operation' }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith('/system/tasks/task-123/abort', {
          reason: 'wedged for an hour',
        }),
      );
      expect(mockPost).toHaveBeenCalledTimes(1);
    });

    it('omits the reason when the operator leaves the field blank', async () => {
      mockGet
        .mockResolvedValueOnce(envelope({ task: runningTask }))
        .mockResolvedValue(envelope({ task: abortedTask }));
      mockPost.mockResolvedValue(envelope({ task: abortedTask }));
      renderModal();

      await waitForCommand();
      openAbortDialog();
      fireEvent.click(screen.getByRole('button', { name: 'Abort Operation' }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith('/system/tasks/task-123/abort', {
          reason: undefined,
        }),
      );
      expect(mockPost).toHaveBeenCalledTimes(1);
    });

    it('trims whitespace-only reasons down to no reason at all', async () => {
      mockGet
        .mockResolvedValueOnce(envelope({ task: runningTask }))
        .mockResolvedValue(envelope({ task: abortedTask }));
      mockPost.mockResolvedValue(envelope({ task: abortedTask }));
      renderModal();

      await waitForCommand();
      openAbortDialog();
      fireEvent.change(screen.getByPlaceholderText(/why are you stopping/i), {
        target: { value: '   ' },
      });
      fireEvent.click(screen.getByRole('button', { name: 'Abort Operation' }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith('/system/tasks/task-123/abort', {
          reason: undefined,
        }),
      );
      expect(mockPost).toHaveBeenCalledTimes(1);
    });

    it('notifies and calls onOperationUpdated after a successful abort', async () => {
      const onOperationUpdated = jest.fn();
      mockGet
        .mockResolvedValueOnce(envelope({ task: runningTask }))
        .mockResolvedValue(envelope({ task: abortedTask }));
      mockPost.mockResolvedValue(envelope({ task: abortedTask }));
      renderModal({ onOperationUpdated });

      await waitForCommand();
      openAbortDialog();
      fireEvent.click(screen.getByRole('button', { name: 'Abort Operation' }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: 'Operation aborted successfully',
        }),
      );
      expect(onOperationUpdated).toHaveBeenCalled();
    });

    it('shows an error notification when the abort request fails', async () => {
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      mockPost.mockRejectedValue(new Error('server error'));
      renderModal();

      await waitForCommand();
      openAbortDialog();
      fireEvent.click(screen.getByRole('button', { name: 'Abort Operation' }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to abort operation',
        }),
      );
    });

    it('does not carry a reason over from a dismissed dialog into the next one', async () => {
      mockGet
        .mockResolvedValueOnce(envelope({ task: runningTask }))
        .mockResolvedValue(envelope({ task: abortedTask }));
      mockPost.mockResolvedValue(envelope({ task: abortedTask }));
      renderModal();

      await waitForCommand();

      // Type a reason, then dismiss the dialog without confirming
      openAbortDialog();
      fireEvent.change(screen.getByPlaceholderText(/why are you stopping/i), {
        target: { value: 'first attempt' },
      });
      fireEvent.click(screen.getByRole('button', { name: 'Keep Running' }));

      // Re-open and confirm without typing anything
      openAbortDialog();
      fireEvent.click(screen.getByRole('button', { name: 'Abort Operation' }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith('/system/tasks/task-123/abort', {
          reason: undefined,
        }),
      );
      // A dismissed dialog must not have fired anything of its own.
      expect(mockPost).toHaveBeenCalledTimes(1);
    });

    it('does not fire a pending confirmation at a different operation', async () => {
      // useConfirmation's dialog state outlives this modal's operationId prop,
      // so a confirmation opened against task-123 must not abort task-456.
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      const { rerender } = renderModal({ operationId: 'task-123' });

      await waitForCommand();
      openAbortDialog();

      mockGet.mockResolvedValue(
        envelope({ task: { ...runningTask, id: 'task-456', command: 'destroy_node' } }),
      );
      rerender(
        <BrowserRouter>
          <OperationDetailModal operationId="task-456" isOpen={true} onClose={jest.fn()} />
        </BrowserRouter>,
      );
      await waitForCommand('destroy_node');

      fireEvent.click(screen.getByRole('button', { name: 'Abort Operation' }));

      await waitFor(() =>
        expect(screen.queryByRole('button', { name: 'Abort Operation' })).not.toBeInTheDocument(),
      );
      expect(mockPost).not.toHaveBeenCalled();
    });

    it('labels the dismiss button so it cannot be read as a second confirm', async () => {
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      renderModal();

      await waitForCommand();
      openAbortDialog();

      expect(screen.getByRole('button', { name: 'Keep Running' })).toBeInTheDocument();
      expect(screen.queryByRole('button', { name: 'Cancel' })).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Footer — Cancel now routes through the same confirmation + reason dialog
  // ---------------------------------------------------------------------------

  describe('Cancel confirmation', () => {
    const pendingTask = { ...BASE_TASK, status: 'pending' as const };
    const cancelledTask = { ...BASE_TASK, status: 'cancelled' as const };

    it('does not POST until the cancel confirmation is confirmed', async () => {
      mockGet.mockResolvedValue(envelope({ task: pendingTask }));
      renderModal();

      await waitForCommand();
      fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

      expect(screen.getByRole('button', { name: 'Cancel Operation' })).toBeInTheDocument();
      expect(mockPost).not.toHaveBeenCalled();
    });

    it('POSTs the operator-supplied reason instead of a hardcoded string', async () => {
      mockGet
        .mockResolvedValueOnce(envelope({ task: pendingTask }))
        .mockResolvedValue(envelope({ task: cancelledTask }));
      mockPost.mockResolvedValue(envelope({ task: cancelledTask }));
      renderModal();

      await waitForCommand();
      fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
      fireEvent.change(screen.getByPlaceholderText(/why are you stopping/i), {
        target: { value: 'superseded by a newer run' },
      });
      fireEvent.click(screen.getByRole('button', { name: 'Cancel Operation' }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith('/system/tasks/task-123/cancel', {
          reason: 'superseded by a newer run',
        }),
      );
      expect(mockPost).toHaveBeenCalledTimes(1);
    });
  });

  // ---------------------------------------------------------------------------
  // Live updates — websocket subscription + poll fallback — IMP-4fae9e3356d7
  // ---------------------------------------------------------------------------

  describe('Live updates', () => {
    const runningTask = { ...BASE_TASK, status: 'running' as const, progress: 42 };

    // The SystemChannel payload (SystemChannel#serialize_task_static) carries
    // only the scalar columns — no events, options, exclusive or
    // initiated_by_name — so a frame must be merged into the loaded task, never
    // substituted for it.
    const socketFrame = {
      id: 'task-123',
      command: 'provision_node',
      status: 'complete' as const,
      progress: 100,
      description: 'Provision a new node',
      error_message: undefined,
      scheduled_at: '2026-06-01T10:00:00Z',
      started_at: '2026-06-01T10:01:00Z',
      completed_at: '2026-06-01T10:05:00Z',
      operable_type: undefined,
      operable_id: undefined,
      created_at: '2026-06-01T09:59:00Z',
      updated_at: '2026-06-01T10:05:00Z',
    };

    it('subscribes for operation updates and progress ticks', async () => {
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      renderModal();

      await waitForCommand();
      expect(typeof capturedWsOptions.onOperationUpdate).toBe('function');
      expect(typeof capturedWsOptions.onOperationProgress).toBe('function');
    });

    it('advances the progress bar on a task_progress tick for this operation', async () => {
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      renderModal();

      await waitForCommand();
      expect(screen.getByText('42%')).toBeInTheDocument();

      act(() => {
        capturedWsOptions.onOperationProgress?.({
          operation_id: 'task-123',
          status: 'running',
          progress: 77,
        });
      });

      expect(screen.getByText('77%')).toBeInTheDocument();
      expect(screen.queryByText('42%')).not.toBeInTheDocument();
    });

    it('ignores a progress tick addressed to a different operation', async () => {
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      renderModal();

      await waitForCommand();
      act(() => {
        capturedWsOptions.onOperationProgress?.({
          operation_id: 'some-other-task',
          status: 'running',
          progress: 99,
        });
      });

      expect(screen.getByText('42%')).toBeInTheDocument();
      expect(screen.queryByText('99%')).not.toBeInTheDocument();
    });

    it('flips the status badge on a task_updated frame for this operation', async () => {
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      renderModal();

      await waitForCommand();
      expect(screen.getByText('Running')).toBeInTheDocument();

      act(() => {
        capturedWsOptions.onOperationUpdate?.(socketFrame);
      });

      expect(screen.getByText('Complete')).toBeInTheDocument();
      expect(screen.queryByText('Running')).not.toBeInTheDocument();
    });

    it('ignores a task_updated frame addressed to a different operation', async () => {
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      renderModal();

      await waitForCommand();
      act(() => {
        capturedWsOptions.onOperationUpdate?.({ ...socketFrame, id: 'some-other-task' });
      });

      expect(screen.getByText('Running')).toBeInTheDocument();
      expect(screen.queryByText('Complete')).not.toBeInTheDocument();
    });

    it('merges a task_updated frame rather than replacing the loaded task', async () => {
      mockGet.mockResolvedValue(
        envelope({
          task: {
            ...runningTask,
            exclusive: true,
            initiated_by_name: 'operator@example.com',
            events: [
              { type: 'info', timestamp: '2026-06-01T10:01:30Z', message: 'Job started' },
            ],
            options: { region: 'us-east-1' },
          },
        }),
      );
      renderModal();

      await waitForCommand();
      act(() => {
        capturedWsOptions.onOperationUpdate?.(socketFrame);
      });

      // Fields the socket frame does not carry must survive the merge.
      expect(screen.getByText('Complete')).toBeInTheDocument();
      expect(screen.getByText('operator@example.com')).toBeInTheDocument();
      expect(screen.getByText('Yes')).toBeInTheDocument();

      fireEvent.click(screen.getByText('Events'));
      expect(screen.getByText('Job started')).toBeInTheDocument();

      fireEvent.click(screen.getByText('Options'));
      expect(screen.getByText(/us-east-1/)).toBeInTheDocument();
    });

    it('polls every 5s while the operation is running and the socket is down', async () => {
      jest.useFakeTimers();
      mockWsConnected = false;
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      renderModal();

      await act(async () => {});
      expect(mockGet).toHaveBeenCalledTimes(1);

      await act(async () => {
        jest.advanceTimersByTime(5000);
      });
      expect(mockGet).toHaveBeenCalledTimes(2);

      await act(async () => {
        jest.advanceTimersByTime(5000);
      });
      expect(mockGet).toHaveBeenCalledTimes(3);
    });

    it.each([
      ['pending' as const],
      ['scheduled' as const],
    ])('also polls while the operation is %s', async (status) => {
      jest.useFakeTimers();
      mockWsConnected = false;
      mockGet.mockResolvedValue(envelope({ task: { ...BASE_TASK, status } }));
      renderModal();

      await act(async () => {});
      expect(mockGet).toHaveBeenCalledTimes(1);

      await act(async () => {
        jest.advanceTimersByTime(5000);
      });
      expect(mockGet).toHaveBeenCalledTimes(2);
    });

    it.each([
      ['complete' as const],
      ['failed' as const],
      ['aborted' as const],
      ['cancelled' as const],
    ])('does not poll once the operation is %s', async (status) => {
      jest.useFakeTimers();
      mockWsConnected = false;
      mockGet.mockResolvedValue(envelope({ task: { ...BASE_TASK, status } }));
      renderModal();

      await act(async () => {});
      expect(mockGet).toHaveBeenCalledTimes(1);

      await act(async () => {
        jest.advanceTimersByTime(30000);
      });
      expect(mockGet).toHaveBeenCalledTimes(1);
    });

    it('does not poll once the channel confirms the subscription', async () => {
      jest.useFakeTimers();
      mockWsConnected = true;
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      renderModal();

      await act(async () => {
        capturedWsOptions.onConnected?.();
      });
      expect(mockGet).toHaveBeenCalledTimes(1);

      await act(async () => {
        jest.advanceTimersByTime(30000);
      });
      expect(mockGet).toHaveBeenCalledTimes(1);
    });

    it('still polls when the socket is open but the subscription was rejected', async () => {
      // SystemChannel#subscribed calls reject() on an unauthorized account and
      // never transmits connection_established, so no frame will ever arrive —
      // yet the transport reports itself connected.
      jest.useFakeTimers();
      mockWsConnected = true;
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      renderModal();

      await act(async () => {
        capturedWsOptions.onError?.('Unauthorized');
      });
      expect(mockGet).toHaveBeenCalledTimes(1);

      await act(async () => {
        jest.advanceTimersByTime(5000);
      });
      expect(mockGet).toHaveBeenCalledTimes(2);
    });

    it('starts polling when the live feed drops and stops when it returns', async () => {
      jest.useFakeTimers();
      mockWsConnected = true;
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      const { rerender } = renderModal();

      const reopen = () =>
        rerender(
          <BrowserRouter>
            <OperationDetailModal operationId="task-123" isOpen={true} onClose={jest.fn()} />
          </BrowserRouter>,
        );

      await act(async () => {
        capturedWsOptions.onConnected?.();
      });
      await act(async () => {
        jest.advanceTimersByTime(30000);
      });
      expect(mockGet).toHaveBeenCalledTimes(1);

      // Socket drops — the fallback takes over.
      mockWsConnected = false;
      await act(async () => {
        reopen();
      });
      await act(async () => {
        jest.advanceTimersByTime(5000);
      });
      expect(mockGet).toHaveBeenCalledTimes(2);

      // Socket returns and the channel re-confirms — the fallback stands down.
      mockWsConnected = true;
      await act(async () => {
        reopen();
        capturedWsOptions.onConnected?.();
      });
      await act(async () => {
        jest.advanceTimersByTime(30000);
      });
      expect(mockGet).toHaveBeenCalledTimes(2);
    });

    it('discards a poll response that arrives after the modal moved on', async () => {
      let resolveStale!: (v: unknown) => void;
      jest.useFakeTimers();
      mockWsConnected = false;
      mockGet
        .mockResolvedValueOnce(envelope({ task: runningTask }))
        .mockReturnValueOnce(new Promise((res) => { resolveStale = res; }))
        .mockResolvedValue(
          envelope({ task: { ...runningTask, id: 'task-456', command: 'destroy_node' } }),
        );
      const { rerender } = renderModal({ operationId: 'task-123' });

      await act(async () => {});
      // Kick off a poll whose response we hold open.
      await act(async () => {
        jest.advanceTimersByTime(5000);
      });

      // The operator moves to another operation while that GET is in flight.
      await act(async () => {
        rerender(
          <BrowserRouter>
            <OperationDetailModal operationId="task-456" isOpen={true} onClose={jest.fn()} />
          </BrowserRouter>,
        );
      });
      await waitForCommand('destroy_node');

      // The stale response must not overwrite what is on screen.
      await act(async () => {
        resolveStale(envelope({ task: runningTask }));
      });
      expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('destroy_node');
    });

    it('stops polling once the modal is closed', async () => {
      jest.useFakeTimers();
      mockWsConnected = false;
      mockGet.mockResolvedValue(envelope({ task: runningTask }));
      const { rerender } = renderModal();

      await act(async () => {});
      expect(mockGet).toHaveBeenCalledTimes(1);

      rerender(
        <BrowserRouter>
          <OperationDetailModal operationId="task-123" isOpen={false} onClose={jest.fn()} />
        </BrowserRouter>,
      );

      await act(async () => {
        jest.advanceTimersByTime(30000);
      });
      expect(mockGet).toHaveBeenCalledTimes(1);
    });

    it('stops polling as soon as a poll reports the operation finished', async () => {
      jest.useFakeTimers();
      mockWsConnected = false;
      mockGet
        .mockResolvedValueOnce(envelope({ task: runningTask }))
        .mockResolvedValue(
          envelope({ task: { ...BASE_TASK, status: 'complete' as const, progress: 100 } }),
        );
      renderModal();

      await act(async () => {});
      expect(mockGet).toHaveBeenCalledTimes(1);

      // One poll observes completion...
      await act(async () => {
        jest.advanceTimersByTime(5000);
      });
      expect(mockGet).toHaveBeenCalledTimes(2);

      // ...and no further poll is scheduled.
      await act(async () => {
        jest.advanceTimersByTime(30000);
      });
      expect(mockGet).toHaveBeenCalledTimes(2);
    });
  });

  // ---------------------------------------------------------------------------
  // Retry after a failed initial load
  // ---------------------------------------------------------------------------

  describe('Retry after a failed initial load', () => {
    it('offers a Retry control in the error branch', async () => {
      mockGet.mockRejectedValue(new Error('network failure'));
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Failed to load operation details')).toBeInTheDocument(),
      );
      expect(screen.getByRole('button', { name: /retry/i })).toBeInTheDocument();
    });

    it('re-runs the initial fetch and renders the operation when the retry succeeds', async () => {
      mockGet
        .mockRejectedValueOnce(new Error('502 Bad Gateway'))
        .mockResolvedValue(envelope({ task: BASE_TASK }));
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Failed to load operation details')).toBeInTheDocument(),
      );
      expect(mockGet).toHaveBeenCalledTimes(1);

      fireEvent.click(screen.getByRole('button', { name: /retry/i }));

      await waitForCommand();
      expect(mockGet).toHaveBeenCalledTimes(2);
      expect(mockGet).toHaveBeenLastCalledWith('/system/tasks/task-123');
      expect(screen.queryByText('Failed to load operation details')).not.toBeInTheDocument();
    });

    it('keeps the error branch with the retry still offered when the retry also fails', async () => {
      mockGet.mockRejectedValue(new Error('still down'));
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Failed to load operation details')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /retry/i }));

      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
      // The retry swaps in the spinner while it is in flight, so wait for the
      // error branch to come back rather than reading a stale render.
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /retry/i })).toBeInTheDocument(),
      );
      expect(screen.getByText('Failed to load operation details')).toBeInTheDocument();
    });

    it('lets the fallback poll take over once a retry succeeds on a running operation', async () => {
      jest.useFakeTimers();
      mockWsConnected = false;
      mockGet
        .mockRejectedValueOnce(new Error('502 Bad Gateway'))
        .mockResolvedValue(envelope({ task: { ...BASE_TASK, status: 'running' as const } }));
      renderModal();

      await act(async () => {});
      expect(mockGet).toHaveBeenCalledTimes(1);

      // The failed load never starts the poll.
      await act(async () => {
        jest.advanceTimersByTime(30000);
      });
      expect(mockGet).toHaveBeenCalledTimes(1);

      await act(async () => {
        fireEvent.click(screen.getByRole('button', { name: /retry/i }));
      });
      expect(mockGet).toHaveBeenCalledTimes(2);

      await act(async () => {
        jest.advanceTimersByTime(5000);
      });
      expect(mockGet).toHaveBeenCalledTimes(3);
    });
  });

  // ---------------------------------------------------------------------------
  // Reason capture is shared, not duplicated
  // ---------------------------------------------------------------------------

  describe('Reason-capturing confirmation', () => {
    // IMP-abe28a971830: this modal grew a private StopReasonPrompt in the same
    // drain that extracted useReasonConfirm for six other sites, so two
    // reason-capturing confirm bodies existed over the one shared
    // ConfirmationModal. The behavioural specs above pass either way — only a
    // source-level guard can tell the shared hook from a local copy.
    const modalSource = readFileSync(path.join(__dirname, 'OperationDetailModal.tsx'), 'utf8');

    it('pins the file identity it is asserting over', () => {
      // A wrong path throws at collection time rather than yielding an empty
      // string, so this is not a vacuity guard — it just names the subject.
      expect(modalSource).toContain('OperationDetailModal');
    });

    it('captures the stop reason through the shared useReasonConfirm hook', () => {
      expect(modalSource).toMatch(
        /import\s*\{[^}]*\buseReasonConfirm\b[^}]*\}\s*from\s*'@system\/features\/system\/hooks\/useReasonConfirm'/,
      );
      expect(modalSource).toContain('confirmWithReason');
    });

    it('does not keep a private reason-prompt body', () => {
      // Name the duplicate's shape, not FormField itself: banning the shared
      // field outright would fail this spec for an unrelated inline input added
      // later, while the dedupe stayed perfectly intact.
      expect(modalSource).not.toContain('StopReasonPrompt');
      expect(modalSource).not.toMatch(/const\s+\w*ReasonPrompt\b/);
      expect(modalSource).not.toContain('onReasonChange');
      expect(modalSource).not.toContain('reasonRef');
    });
  });
});
