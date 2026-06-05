import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { StorageMigrationDetailDrawer } from './StorageMigrationDetailDrawer';
import type { StorageMigrationDetail } from '../../types/storageMigration.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();

jest.mock('@system/features/system/services/api/storageMigrationsApi', () => ({
  storageMigrationsApi: {
    get: (...args: unknown[]) => mockGet(...args),
  },
}));

// EntityLink pulls in usePermissions + entityRegistry + useEntityModal.
// We stub the whole shared/components/entity barrel to keep tests self-contained.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { label: string }) => <span data-testid="entity-link">{label}</span>,
}));

// usePermissions is used by EntityLink (via the real import path before our mock)
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: () => true }),
}));

// =============================================================================
// Fixtures & Helpers
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const SOURCE_VOL_ID = 'aaaabbbb-1234-5678-0000-111111111111';
const TARGET_VOL_ID = 'ccccdddd-abcd-efab-0000-222222222222';

const MIGRATION_DETAIL: StorageMigrationDetail = {
  id: 'mig-detail-0001',
  status: 'syncing',
  role: 'database',
  node_instance_id: 'inst-0001',
  source_volume_id: SOURCE_VOL_ID,
  target_volume_id: TARGET_VOL_ID,
  source_subpath: '/data',
  target_subpath: '/data-new',
  bytes_copied: 512 * 1024 * 1024,   // 512 MB
  bytes_total: 1024 * 1024 * 1024,   // 1 GB
  bytes_verified: null,
  terminal: false,
  error_message: null,
  created_at: '2026-05-01T10:00:00Z',
  approved_at: '2026-05-01T10:01:00Z',
  started_at: '2026-05-01T10:02:00Z',
  completed_at: null,
  failed_at: null,
  cancelled_at: null,
  plan: { version: 1, steps: ['prepare', 'sync', 'cutover'] },
  audit_log: [
    {
      at: '2026-05-01T10:02:00Z',
      message: 'Migration started',
      status_before: 'approved',
      status_after: 'syncing',
      details: {},
    },
    {
      at: '2026-05-01T10:03:00Z',
      message: 'Rsync pass 1 complete',
      details: { bytes: 268435456 },
    },
  ],
  metadata: {},
  snapshot_subpath: null,
  initiated_by_user_id: 'user-001',
};

const MIGRATION_TERMINAL: StorageMigrationDetail = {
  ...MIGRATION_DETAIL,
  id: 'mig-terminal-0002',
  status: 'completed',
  terminal: true,
  bytes_copied: 1024 * 1024 * 1024,
  bytes_verified: 1024 * 1024 * 1024,
  completed_at: '2026-05-01T11:00:00Z',
  audit_log: [],
};

const MIGRATION_FAILED: StorageMigrationDetail = {
  ...MIGRATION_DETAIL,
  id: 'mig-failed-0003',
  status: 'failed',
  terminal: true,
  error_message: 'Disk quota exceeded',
  failed_at: '2026-05-01T10:30:00Z',
  audit_log: [],
};

const MIGRATION_NULL_SUBPATHS: StorageMigrationDetail = {
  ...MIGRATION_DETAIL,
  id: 'mig-null-0004',
  source_subpath: null,
  target_subpath: null,
  bytes_copied: null,
  bytes_total: null,
  bytes_verified: null,
  audit_log: [],
};

// =============================================================================
// Render helper
// =============================================================================

interface RenderProps {
  migrationId: string | null;
  onClose?: () => void;
}

function renderDrawer({ migrationId, onClose = jest.fn() }: RenderProps) {
  return render(
    <BrowserRouter>
      <StorageMigrationDetailDrawer migrationId={migrationId} onClose={onClose} />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('StorageMigrationDetailDrawer', () => {
  beforeEach(() => {
    mockGet.mockReset();
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  // ---------------------------------------------------------------------------
  // Null migration id — renders nothing
  // ---------------------------------------------------------------------------

  it('renders nothing when migrationId is null', () => {
    const { container } = renderDrawer({ migrationId: null });
    expect(container.firstChild).toBeNull();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows the loading indicator while fetching', () => {
    mockGet.mockReturnValue(new Promise(() => {})); // never resolves

    renderDrawer({ migrationId: 'mig-detail-0001' });

    expect(screen.getByText('Loading…')).toBeInTheDocument();
  });

  it('renders the drawer header with "Storage Migration" title when open', () => {
    mockGet.mockReturnValue(new Promise(() => {}));

    renderDrawer({ migrationId: 'mig-detail-0001' });

    expect(screen.getByText('Storage Migration')).toBeInTheDocument();
  });

  it('calls storageMigrationsApi.get with the correct id on mount', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(mockGet).toHaveBeenCalledWith('mig-detail-0001'));
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error banner when the API call rejects with an Error', async () => {
    mockGet.mockRejectedValue(new Error('Network timeout'));

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument(),
    );
  });

  it('uses the fallback message for non-Error rejections', async () => {
    mockGet.mockRejectedValue('server down');

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() =>
      expect(screen.getByText('Failed to load migration')).toBeInTheDocument(),
    );
  });

  it('does not render migration content when in error state', async () => {
    mockGet.mockRejectedValue(new Error('API error'));

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(screen.getByText('API error')).toBeInTheDocument());
    expect(screen.queryByText('syncing')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Migration content — status and role
  // ---------------------------------------------------------------------------

  it('renders the migration status and role as key-value pairs', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(screen.getByText('syncing')).toBeInTheDocument());
    expect(screen.getByText('database')).toBeInTheDocument();
  });

  it('renders the Status and Role labels in the key-value grid', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(screen.getByText('Status')).toBeInTheDocument());
    expect(screen.getByText('Role')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Migration content — volume links
  // ---------------------------------------------------------------------------

  it('renders EntityLink for source volume with the truncated id label', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => {
      const links = screen.getAllByTestId('entity-link');
      const labels = links.map((l) => l.textContent);
      expect(labels).toContain(SOURCE_VOL_ID.slice(0, 8) + '…');
    });
  });

  it('renders EntityLink for target volume with the truncated id label', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => {
      const links = screen.getAllByTestId('entity-link');
      const labels = links.map((l) => l.textContent);
      expect(labels).toContain(TARGET_VOL_ID.slice(0, 8) + '…');
    });
  });

  // ---------------------------------------------------------------------------
  // Migration content — subpaths
  // ---------------------------------------------------------------------------

  it('renders source and target subpaths when set', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(screen.getByText('/data')).toBeInTheDocument());
    expect(screen.getByText('/data-new')).toBeInTheDocument();
  });

  it('renders em dash for null subpaths', async () => {
    mockGet.mockResolvedValue(MIGRATION_NULL_SUBPATHS);

    renderDrawer({ migrationId: 'mig-null-0004' });

    await waitFor(() => {
      // null subpaths render as "—" (em dash). Two "—" expected for source+target.
      const dashes = screen.getAllByText('—');
      expect(dashes.length).toBeGreaterThanOrEqual(2);
    });
  });

  // ---------------------------------------------------------------------------
  // Migration content — byte counters
  // ---------------------------------------------------------------------------

  it('renders copied bytes as MB', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    // 512 MB
    await waitFor(() => expect(screen.getByText('512.0 MB')).toBeInTheDocument());
  });

  it('renders total bytes as MB', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    // 1024 MB
    await waitFor(() => expect(screen.getByText('1024.0 MB')).toBeInTheDocument());
  });

  it('renders progress percentage when bytes_copied and bytes_total are set', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    // 512 / 1024 = 50%
    await waitFor(() => expect(screen.getByText('50%')).toBeInTheDocument());
  });

  it('renders em dash for null byte values', async () => {
    mockGet.mockResolvedValue(MIGRATION_NULL_SUBPATHS);

    renderDrawer({ migrationId: 'mig-null-0004' });

    await waitFor(() => expect(screen.getByText('Status')).toBeInTheDocument());
    // null bytes render as "—" in the byte counter spans
    const dashes = screen.getAllByText('—');
    expect(dashes.length).toBeGreaterThanOrEqual(1);
  });

  it('does not render a progress bar when bytes_total is null', async () => {
    mockGet.mockResolvedValue(MIGRATION_NULL_SUBPATHS);

    renderDrawer({ migrationId: 'mig-null-0004' });

    await waitFor(() => expect(screen.getByText('Status')).toBeInTheDocument());
    expect(screen.queryByText(/%/)).not.toBeInTheDocument();
  });

  it('renders verified bytes as MB when set', async () => {
    mockGet.mockResolvedValue(MIGRATION_TERMINAL);

    renderDrawer({ migrationId: 'mig-terminal-0002' });

    // bytes_verified = 1024 MB
    await waitFor(() => {
      const elements = screen.getAllByText('1024.0 MB');
      expect(elements.length).toBeGreaterThanOrEqual(1);
    });
  });

  // ---------------------------------------------------------------------------
  // Migration content — lifecycle timestamps
  // ---------------------------------------------------------------------------

  it('renders lifecycle section with Created, Approved, Started labels', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(screen.getByText('Created')).toBeInTheDocument());
    expect(screen.getByText('Approved')).toBeInTheDocument();
    expect(screen.getByText('Started')).toBeInTheDocument();
  });

  it('renders em dashes for null timestamp fields', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    // completed_at, failed_at, cancelled_at are null → "—"
    await waitFor(() => expect(screen.getByText('Completed')).toBeInTheDocument());
    // Multiple "—" entries expected for the null timestamps
    const dashes = screen.getAllByText('—');
    expect(dashes.length).toBeGreaterThanOrEqual(3);
  });

  // ---------------------------------------------------------------------------
  // Migration content — error_message
  // ---------------------------------------------------------------------------

  it('renders the error_message with an AlertTriangle when set', async () => {
    mockGet.mockResolvedValue(MIGRATION_FAILED);

    renderDrawer({ migrationId: 'mig-failed-0003' });

    await waitFor(() =>
      expect(screen.getByText('Disk quota exceeded')).toBeInTheDocument(),
    );
  });

  it('does not render error_message section when error_message is null', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(screen.getByText('syncing')).toBeInTheDocument());
    expect(screen.queryByText('Disk quota exceeded')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Migration content — plan (JSON)
  // ---------------------------------------------------------------------------

  it('renders the plan section as pretty-printed JSON in a pre element', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(screen.getByText('Plan')).toBeInTheDocument());
    // The pre element should contain key from the plan object
    expect(screen.getByText(/prepare/)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Migration content — audit log
  // ---------------------------------------------------------------------------

  it('renders the Audit log section header', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(screen.getByText('Audit log')).toBeInTheDocument());
  });

  it('renders each audit log entry message', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() =>
      expect(screen.getByText('Migration started')).toBeInTheDocument(),
    );
    expect(screen.getByText('Rsync pass 1 complete')).toBeInTheDocument();
  });

  it('renders the status transition in the audit log entry', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() =>
      expect(screen.getByText('approved → syncing')).toBeInTheDocument(),
    );
  });

  it('renders audit log entry details as JSON in a pre element', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() =>
      expect(screen.getByText(/268435456/)).toBeInTheDocument(),
    );
  });

  it('shows "No entries." when the audit log is empty', async () => {
    mockGet.mockResolvedValue(MIGRATION_TERMINAL);

    renderDrawer({ migrationId: 'mig-terminal-0002' });

    await waitFor(() =>
      expect(screen.getByText('No entries.')).toBeInTheDocument(),
    );
  });

  it('does not render the entry details pre block when details is an empty object', async () => {
    // MIGRATION_DETAIL's first entry has details: {} (empty)
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() =>
      expect(screen.getByText('Migration started')).toBeInTheDocument(),
    );
    // The first entry has empty details; expect no pre block for it.
    // (The second entry with bytes does produce a pre block)
    const preBlocks = document.querySelectorAll('pre');
    // Only the plan pre + the second audit entry pre (with bytes) should exist
    // The empty-details entry should not add another pre block
    expect(preBlocks.length).toBeLessThanOrEqual(2);
  });

  // ---------------------------------------------------------------------------
  // Close interactions
  // ---------------------------------------------------------------------------

  it('calls onClose when the X button in the header is clicked', async () => {
    const onClose = jest.fn();
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001', onClose });

    await waitFor(() => expect(screen.getByText('Storage Migration')).toBeInTheDocument());

    const header = screen.getByText('Storage Migration').closest('header')!;
    const closeBtn = header.querySelector('button')!;
    fireEvent.click(closeBtn);

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onClose when the backdrop overlay is clicked', async () => {
    const onClose = jest.fn();
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001', onClose });

    await waitFor(() => expect(screen.getByText('Storage Migration')).toBeInTheDocument());

    const backdrop = document.querySelector('div[aria-hidden="true"]')!;
    fireEvent.click(backdrop);

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Auto-refresh behavior (non-terminal status)
  // ---------------------------------------------------------------------------

  it('auto-refreshes every 5 seconds for non-terminal migrations', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(screen.getByText('syncing')).toBeInTheDocument());
    expect(mockGet).toHaveBeenCalledTimes(1);

    await act(async () => {
      jest.advanceTimersByTime(5_000);
    });

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
    expect(mockGet).toHaveBeenNthCalledWith(2, 'mig-detail-0001');
  });

  it('does not auto-refresh for terminal migrations', async () => {
    mockGet.mockResolvedValue(MIGRATION_TERMINAL);

    renderDrawer({ migrationId: 'mig-terminal-0002' });

    await waitFor(() => expect(screen.getByText('completed')).toBeInTheDocument());
    expect(mockGet).toHaveBeenCalledTimes(1);

    await act(async () => {
      jest.advanceTimersByTime(15_000);
    });

    // No additional calls
    expect(mockGet).toHaveBeenCalledTimes(1);
  });

  it('stops auto-refreshing once the migration reaches a terminal state', async () => {
    // First fetch returns non-terminal; second returns completed
    mockGet
      .mockResolvedValueOnce(MIGRATION_DETAIL)
      .mockResolvedValueOnce(MIGRATION_TERMINAL);

    renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(screen.getByText('syncing')).toBeInTheDocument());

    // Trigger first auto-refresh
    await act(async () => {
      jest.advanceTimersByTime(5_000);
    });

    await waitFor(() => expect(screen.getByText('completed')).toBeInTheDocument());
    expect(mockGet).toHaveBeenCalledTimes(2);

    // Advance another 15 seconds — no more fetches
    await act(async () => {
      jest.advanceTimersByTime(15_000);
    });

    expect(mockGet).toHaveBeenCalledTimes(2);
  });

  it('clears the auto-refresh interval when migrationId becomes null', async () => {
    mockGet.mockResolvedValue(MIGRATION_DETAIL);

    const { rerender } = renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(screen.getByText('syncing')).toBeInTheDocument());
    expect(mockGet).toHaveBeenCalledTimes(1);

    rerender(
      <BrowserRouter>
        <StorageMigrationDetailDrawer migrationId={null} onClose={jest.fn()} />
      </BrowserRouter>,
    );

    await act(async () => {
      jest.advanceTimersByTime(15_000);
    });

    // No additional calls after unmount
    expect(mockGet).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Migration id change
  // ---------------------------------------------------------------------------

  it('re-fetches when migrationId changes', async () => {
    mockGet
      .mockResolvedValueOnce(MIGRATION_DETAIL)
      .mockResolvedValueOnce({ ...MIGRATION_TERMINAL, id: 'mig-other-9999' });

    const { rerender } = renderDrawer({ migrationId: 'mig-detail-0001' });

    await waitFor(() => expect(mockGet).toHaveBeenCalledWith('mig-detail-0001'));

    rerender(
      <BrowserRouter>
        <StorageMigrationDetailDrawer migrationId="mig-other-9999" onClose={jest.fn()} />
      </BrowserRouter>,
    );

    await waitFor(() => expect(mockGet).toHaveBeenCalledWith('mig-other-9999'));
  });
});
