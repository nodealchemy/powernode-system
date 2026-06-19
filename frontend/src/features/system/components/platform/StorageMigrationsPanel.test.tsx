import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { StorageMigrationsPanel } from './StorageMigrationsPanel';
import type { StorageMigrationSummary } from '../../types/storageMigration.types';

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

// EntityLink uses entityRegistry + useEntityModal — mock the whole module
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ id, label }: { id?: string | null; label?: React.ReactNode }) => (
    <span data-testid="entity-link">{label ?? id}</span>
  ),
}));

// PlanStorageMigrationModal and StorageMigrationDetailDrawer have their own
// full API flows — stub them so we test the panel in isolation.
const mockPlanModal = jest.fn();
jest.mock('./PlanStorageMigrationModal', () => ({
  PlanStorageMigrationModal: (props: Record<string, unknown>) => {
    mockPlanModal(props);
    if (!props.isOpen) return null;
    return (
      <div data-testid="plan-modal">
        <button
          onClick={() => (props.onClose as () => void)()}
          data-testid="plan-modal-close"
        >
          Close Plan Modal
        </button>
        <button
          onClick={() => (props.onPlanned as () => void)()}
          data-testid="plan-modal-planned"
        >
          Trigger Planned
        </button>
      </div>
    );
  },
}));

const mockDetailDrawer = jest.fn();
jest.mock('./StorageMigrationDetailDrawer', () => ({
  StorageMigrationDetailDrawer: (props: Record<string, unknown>) => {
    mockDetailDrawer(props);
    if (!props.migrationId) return null;
    return (
      <div data-testid="detail-drawer">
        <span data-testid="drawer-migration-id">{String(props.migrationId)}</span>
        <button
          onClick={() => (props.onClose as () => void)()}
          data-testid="detail-drawer-close"
        >
          Close Drawer
        </button>
      </div>
    );
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const MIG_PLANNED: StorageMigrationSummary = {
  id: 'mig-planned-001',
  status: 'planned',
  role: 'postgres',
  node_instance_id: 'inst-aaa',
  source_volume_id: 'vol-src-00000000',
  target_volume_id: 'vol-tgt-00000000',
  source_subpath: null,
  target_subpath: null,
  bytes_copied: null,
  bytes_total: null,
  terminal: false,
  error_message: null,
  created_at: '2026-01-01T10:00:00Z',
  approved_at: null,
  started_at: null,
  completed_at: null,
  failed_at: null,
  cancelled_at: null,
};

const MIG_SYNCING: StorageMigrationSummary = {
  id: 'mig-syncing-002',
  status: 'syncing',
  role: 'redis',
  node_instance_id: 'inst-bbb',
  source_volume_id: 'vol-src-11111111',
  target_volume_id: 'vol-tgt-11111111',
  source_subpath: '/data/redis',
  target_subpath: '/data/redis',
  bytes_copied: 512 * 1024 * 1024,
  bytes_total: 1024 * 1024 * 1024,
  terminal: false,
  error_message: null,
  created_at: '2026-01-02T10:00:00Z',
  approved_at: '2026-01-02T10:05:00Z',
  started_at: '2026-01-02T10:10:00Z',
  completed_at: null,
  failed_at: null,
  cancelled_at: null,
};

const MIG_COMPLETED: StorageMigrationSummary = {
  id: 'mig-completed-003',
  status: 'completed',
  role: 'minio',
  node_instance_id: 'inst-ccc',
  source_volume_id: 'vol-src-22222222',
  target_volume_id: 'vol-tgt-22222222',
  source_subpath: null,
  target_subpath: null,
  bytes_copied: 2048,
  bytes_total: 2048,
  terminal: true,
  error_message: null,
  created_at: '2026-01-03T10:00:00Z',
  approved_at: '2026-01-03T10:01:00Z',
  started_at: '2026-01-03T10:02:00Z',
  completed_at: '2026-01-03T10:10:00Z',
  failed_at: null,
  cancelled_at: null,
};

const MIG_APPROVED: StorageMigrationSummary = {
  id: 'mig-approved-004',
  status: 'approved',
  role: 'vault',
  node_instance_id: 'inst-ddd',
  source_volume_id: 'vol-src-33333333',
  target_volume_id: 'vol-tgt-33333333',
  source_subpath: null,
  target_subpath: null,
  bytes_copied: null,
  bytes_total: null,
  terminal: false,
  error_message: null,
  created_at: '2026-01-04T10:00:00Z',
  approved_at: '2026-01-04T10:01:00Z',
  started_at: null,
  completed_at: null,
  failed_at: null,
  cancelled_at: null,
};

const MIG_FAILED: StorageMigrationSummary = {
  id: 'mig-failed-005',
  status: 'failed',
  role: 'elasticsearch',
  node_instance_id: 'inst-eee',
  source_volume_id: 'vol-src-44444444',
  target_volume_id: 'vol-tgt-44444444',
  source_subpath: null,
  target_subpath: null,
  bytes_copied: 100,
  bytes_total: 1000,
  terminal: true,
  error_message: 'rsync checksum mismatch',
  created_at: '2026-01-05T10:00:00Z',
  approved_at: null,
  started_at: null,
  completed_at: null,
  failed_at: '2026-01-05T10:05:00Z',
  cancelled_at: null,
};

// Double-envelope: AxiosResponse whose body is { success: true, data: <payload> }
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

function listResponse(migrations: StorageMigrationSummary[]) {
  return envelope({ storage_migrations: migrations, count: migrations.length });
}

function approveEnvelope(migration: StorageMigrationSummary) {
  return envelope({ storage_migration: migration });
}

// =============================================================================
// Render helper
// =============================================================================

const renderPanel = () =>
  render(
    <BrowserRouter>
      <StorageMigrationsPanel />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('StorageMigrationsPanel', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockPlanModal.mockReset();
    mockDetailDrawer.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows "loading…" in the header while the list is being fetched', () => {
    mockGet.mockReturnValue(new Promise(() => {})); // never resolves

    renderPanel();

    expect(screen.getByText('loading…')).toBeInTheDocument();
  });

  it('disables the refresh button while loading', () => {
    mockGet.mockReturnValue(new Promise(() => {}));

    renderPanel();

    const refreshBtn = screen.getByTitle('Refresh');
    expect(refreshBtn).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // API call — endpoint + envelope
  // ---------------------------------------------------------------------------

  it('fetches migrations from the correct URL on mount', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderPanel();

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));
    expect(mockGet).toHaveBeenCalledWith('/system/platform/storage_migrations', {
      params: {},
    });
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows the empty-state message when no migrations are returned', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('No storage migrations recorded yet.')).toBeInTheDocument(),
    );
  });

  it('shows "0 records" in the header when list is empty', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('0 records')).toBeInTheDocument());
  });

  it('does not render the table when there are no migrations', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('No storage migrations recorded yet.')).toBeInTheDocument(),
    );
    expect(screen.queryByRole('table')).not.toBeInTheDocument();
  });

  it('shows the MCP action name in the empty-state guidance text', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('system_migrate_storage_component')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('displays an error banner when the API call fails with an Error', async () => {
    mockGet.mockRejectedValue(new Error('Network timeout'));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument(),
    );
  });

  it('uses the fallback error message when rejected with a non-Error value', async () => {
    mockGet.mockRejectedValue('opaque failure');

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('Failed to load storage migrations')).toBeInTheDocument(),
    );
  });

  it('dismisses the error banner when the X button is clicked', async () => {
    mockGet.mockRejectedValue(new Error('Boom'));

    renderPanel();

    await waitFor(() => expect(screen.getByText('Boom')).toBeInTheDocument());

    // The error banner outer div contains: AlertTriangle icon, span.flex-1 (error text), button.p-1 (X)
    // Find the outermost banner div that has the bg-theme-danger-bg class
    const errorSpan = screen.getByText('Boom');
    // Go up to the flex container that contains the X button
    const bannerContainer = errorSpan.closest('.flex-1')!.parentElement!;
    const dismissBtn = bannerContainer.querySelector('button');
    fireEvent.click(dismissBtn!);

    await waitFor(() =>
      expect(screen.queryByText('Boom')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // List rendering
  // ---------------------------------------------------------------------------

  it('renders a table row for each migration returned', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_PLANNED, MIG_SYNCING]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('postgres')).toBeInTheDocument());
    expect(screen.getByText('redis')).toBeInTheDocument();
  });

  it('shows singular "1 record" label when exactly one migration is returned', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_PLANNED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('1 record')).toBeInTheDocument());
  });

  it('shows plural "N records" label for multiple migrations', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_PLANNED, MIG_SYNCING]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('2 records')).toBeInTheDocument());
  });

  it('renders status pills for each migration', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_PLANNED, MIG_COMPLETED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('planned')).toBeInTheDocument());
    expect(screen.getByText('completed')).toBeInTheDocument();
  });

  it('renders volume ID truncated to 8 characters via EntityLink', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_PLANNED]));

    renderPanel();

    // source_volume_id is 'vol-src-00000000' → first 8 chars: 'vol-src-'
    await waitFor(() =>
      expect(screen.getAllByText('vol-src-').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('vol-tgt-').length).toBeGreaterThan(0);
  });

  it('renders the progress bar and percentage when bytes_total > 0', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_SYNCING]));

    renderPanel();

    // MIG_SYNCING: 512MB copied out of 1024MB = 50%
    await waitFor(() => expect(screen.getByText('50%')).toBeInTheDocument());
  });

  it('renders a dash when no byte progress is available', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_PLANNED]));

    renderPanel();

    // MIG_PLANNED has null bytes_total; the progress cell shows "—"
    await waitFor(() => expect(screen.getByText('postgres')).toBeInTheDocument());
    // The dash character for missing progress
    expect(screen.getByText('—')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Action buttons — planned migration
  // ---------------------------------------------------------------------------

  it('renders Approve and Cancel buttons for a "planned" migration', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_PLANNED]));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Approve/i })).toBeInTheDocument());
    expect(screen.getByRole('button', { name: /Cancel/i })).toBeInTheDocument();
  });

  it('renders only Cancel (no Approve) for an "approved" migration', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_APPROVED]));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Cancel/i })).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /Approve/i })).not.toBeInTheDocument();
  });

  it('renders no action buttons for a terminal migration', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_COMPLETED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('minio')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /Approve/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Cancel/i })).not.toBeInTheDocument();
  });

  it('renders only Cancel (no Approve) for a "preparing" migration', async () => {
    const migPreparing: StorageMigrationSummary = {
      ...MIG_PLANNED,
      id: 'mig-preparing-010',
      status: 'preparing',
      terminal: false,
    };
    mockGet.mockResolvedValue(listResponse([migPreparing]));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Cancel/i })).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /Approve/i })).not.toBeInTheDocument();
  });

  it('renders no Approve and no Cancel for a "syncing" migration', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_SYNCING]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('redis')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /Approve/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Cancel/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Approve action
  // ---------------------------------------------------------------------------

  it('calls the approve endpoint with the correct URL when Approve is clicked', async () => {
    // Initial load returns the planned migration
    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    mockPost.mockResolvedValueOnce(approveEnvelope({ ...MIG_PLANNED, status: 'approved' }));
    // Re-fetch after approve
    mockGet.mockResolvedValueOnce(listResponse([{ ...MIG_PLANNED, status: 'approved' }]));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Approve/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Approve/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/storage_migrations/mig-planned-001/approve',
        {},
      ),
    );
  });

  it('shows a success notification after approve succeeds', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    mockPost.mockResolvedValueOnce(approveEnvelope({ ...MIG_PLANNED, status: 'approved' }));
    mockGet.mockResolvedValueOnce(listResponse([{ ...MIG_PLANNED, status: 'approved' }]));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Approve/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Approve/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Storage migration approved.',
      }),
    );
  });

  it('shows an error notification when approve fails', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    mockPost.mockRejectedValue(new Error('Approve rejected by server'));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Approve/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Approve/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Approve rejected by server',
      }),
    );
  });

  it('shows a generic error notification when approve fails with a non-Error', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    mockPost.mockRejectedValue('server down');

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Approve/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Approve/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Approve failed',
      }),
    );
  });

  it('disables the Approve button while the approve request is in flight', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    let resolvePost!: (v: unknown) => void;
    mockPost.mockReturnValue(new Promise((res) => { resolvePost = res; }));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Approve/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Approve/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /Approve/i })).toBeDisabled(),
    );

    resolvePost(approveEnvelope({ ...MIG_PLANNED, status: 'approved' }));
  });

  it('re-fetches the list after a successful approve', async () => {
    // First call: initial load
    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    // approve response
    mockPost.mockResolvedValueOnce(approveEnvelope({ ...MIG_PLANNED, status: 'approved' }));
    // Second call: refresh after approve
    mockGet.mockResolvedValueOnce(listResponse([{ ...MIG_PLANNED, status: 'approved' }]));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Approve/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Approve/i }));

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Cancel action
  // ---------------------------------------------------------------------------

  it('calls the cancel endpoint with the correct URL when Cancel is clicked', async () => {
    // Suppress the window.prompt — return null (no reason)
    jest.spyOn(window, 'prompt').mockReturnValueOnce(null);

    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    mockPost.mockResolvedValueOnce(approveEnvelope({ ...MIG_PLANNED, status: 'cancelled' }));
    mockGet.mockResolvedValueOnce(listResponse([{ ...MIG_PLANNED, status: 'cancelled', terminal: true }]));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Cancel/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Cancel/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/storage_migrations/mig-planned-001/cancel',
        { reason: undefined },
      ),
    );
  });

  it('passes the prompt reason to the cancel endpoint when a reason is entered', async () => {
    jest.spyOn(window, 'prompt').mockReturnValueOnce('operator shutdown');

    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    mockPost.mockResolvedValueOnce(approveEnvelope({ ...MIG_PLANNED, status: 'cancelled' }));
    mockGet.mockResolvedValueOnce(listResponse([{ ...MIG_PLANNED, status: 'cancelled', terminal: true }]));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Cancel/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Cancel/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/storage_migrations/mig-planned-001/cancel',
        { reason: 'operator shutdown' },
      ),
    );
  });

  it('shows a success notification after cancel succeeds', async () => {
    jest.spyOn(window, 'prompt').mockReturnValueOnce(null);

    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    mockPost.mockResolvedValueOnce(approveEnvelope({ ...MIG_PLANNED, status: 'cancelled' }));
    mockGet.mockResolvedValueOnce(listResponse([{ ...MIG_PLANNED, status: 'cancelled', terminal: true }]));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Cancel/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Cancel/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Storage migration cancelled.',
      }),
    );
  });

  it('shows an error notification when cancel fails', async () => {
    jest.spyOn(window, 'prompt').mockReturnValueOnce(null);

    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    mockPost.mockRejectedValue(new Error('Cannot cancel after syncing started'));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Cancel/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Cancel/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Cannot cancel after syncing started',
      }),
    );
  });

  it('shows a generic error notification when cancel fails with a non-Error', async () => {
    jest.spyOn(window, 'prompt').mockReturnValueOnce(null);

    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    mockPost.mockRejectedValue(42);

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Cancel/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Cancel/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Cancel failed',
      }),
    );
  });

  it('re-fetches the list after a successful cancel', async () => {
    jest.spyOn(window, 'prompt').mockReturnValueOnce(null);

    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    mockPost.mockResolvedValueOnce(approveEnvelope({ ...MIG_PLANNED, status: 'cancelled' }));
    mockGet.mockResolvedValueOnce(listResponse([{ ...MIG_PLANNED, status: 'cancelled', terminal: true }]));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Cancel/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Cancel/i }));

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Row click — opens detail drawer
  // ---------------------------------------------------------------------------

  it('opens the detail drawer when a table row is clicked', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_PLANNED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('postgres')).toBeInTheDocument());

    // Click the role cell (inside the row, not the action buttons)
    fireEvent.click(screen.getByText('postgres'));

    await waitFor(() =>
      expect(screen.getByTestId('detail-drawer')).toBeInTheDocument(),
    );
  });

  it('passes the correct migrationId to the detail drawer', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_PLANNED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('postgres')).toBeInTheDocument());
    fireEvent.click(screen.getByText('postgres'));

    await waitFor(() =>
      expect(screen.getByTestId('drawer-migration-id').textContent).toBe('mig-planned-001'),
    );
  });

  it('closes the detail drawer when onClose is called', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_PLANNED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('postgres')).toBeInTheDocument());
    fireEvent.click(screen.getByText('postgres'));

    await waitFor(() => expect(screen.getByTestId('detail-drawer')).toBeInTheDocument());

    fireEvent.click(screen.getByTestId('detail-drawer-close'));

    await waitFor(() =>
      expect(screen.queryByTestId('detail-drawer')).not.toBeInTheDocument(),
    );
  });

  it('does not render the detail drawer before any row is clicked', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_PLANNED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('postgres')).toBeInTheDocument());
    expect(screen.queryByTestId('detail-drawer')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Action buttons do NOT propagate to row click
  // ---------------------------------------------------------------------------

  it('does not open the detail drawer when the Approve button is clicked', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));
    mockPost.mockResolvedValueOnce(approveEnvelope({ ...MIG_PLANNED, status: 'approved' }));
    mockGet.mockResolvedValueOnce(listResponse([{ ...MIG_PLANNED, status: 'approved' }]));

    renderPanel();

    await waitFor(() => expect(screen.getByRole('button', { name: /Approve/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Approve/i }));

    // Give React time to process any possible side effects
    await waitFor(() => expect(mockPost).toHaveBeenCalled());

    // Drawer should not have opened
    expect(screen.queryByTestId('detail-drawer')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Plan modal
  // ---------------------------------------------------------------------------

  it('opens the Plan modal when the Plan button in the header is clicked', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('0 records')).toBeInTheDocument());

    const planBtn = screen.getByRole('button', { name: /Plan/i });
    fireEvent.click(planBtn);

    await waitFor(() =>
      expect(screen.getByTestId('plan-modal')).toBeInTheDocument(),
    );
  });

  it('closes the Plan modal when its onClose is triggered', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('0 records')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Plan/i }));
    await waitFor(() => expect(screen.getByTestId('plan-modal')).toBeInTheDocument());

    fireEvent.click(screen.getByTestId('plan-modal-close'));

    await waitFor(() =>
      expect(screen.queryByTestId('plan-modal')).not.toBeInTheDocument(),
    );
  });

  it('re-fetches the list when onPlanned is triggered from the Plan modal', async () => {
    mockGet.mockResolvedValueOnce(listResponse([]));
    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('0 records')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Plan/i }));
    await waitFor(() => expect(screen.getByTestId('plan-modal')).toBeInTheDocument());

    fireEvent.click(screen.getByTestId('plan-modal-planned'));

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Refresh button
  // ---------------------------------------------------------------------------

  it('re-fetches the list when the refresh button is clicked', async () => {
    mockGet.mockResolvedValueOnce(listResponse([]));
    mockGet.mockResolvedValueOnce(listResponse([MIG_PLANNED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('No storage migrations recorded yet.')).toBeInTheDocument());

    const refreshBtn = screen.getByTitle('Refresh');
    fireEvent.click(refreshBtn);

    await waitFor(() => expect(screen.getByText('postgres')).toBeInTheDocument());
    expect(mockGet).toHaveBeenCalledTimes(2);
  });

  // ---------------------------------------------------------------------------
  // Progress calculation edge cases
  // ---------------------------------------------------------------------------

  it('shows 100% when bytes_copied equals bytes_total', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_COMPLETED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('100%')).toBeInTheDocument());
  });

  it('clamps progress to 100% when bytes_copied exceeds bytes_total', async () => {
    const overrun: StorageMigrationSummary = {
      ...MIG_SYNCING,
      bytes_copied: 2000,
      bytes_total: 1000,
    };
    mockGet.mockResolvedValue(listResponse([overrun]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('100%')).toBeInTheDocument());
  });

  it('does not show a progress bar when bytes_total is null', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_PLANNED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('postgres')).toBeInTheDocument());
    // The dash is shown instead of percentage
    expect(screen.queryByText(/%/)).not.toBeInTheDocument();
  });

  it('does not show a progress bar when bytes_total is 0', async () => {
    const zeroTotal: StorageMigrationSummary = {
      ...MIG_PLANNED,
      bytes_total: 0,
      bytes_copied: 0,
    };
    mockGet.mockResolvedValue(listResponse([zeroTotal]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('postgres')).toBeInTheDocument());
    expect(screen.queryByText(/%/)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Failed migration — no action buttons
  // ---------------------------------------------------------------------------

  it('shows no Approve or Cancel buttons for a "failed" terminal migration', async () => {
    mockGet.mockResolvedValue(listResponse([MIG_FAILED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('elasticsearch')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /Approve/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Cancel/i })).not.toBeInTheDocument();
  });
});
