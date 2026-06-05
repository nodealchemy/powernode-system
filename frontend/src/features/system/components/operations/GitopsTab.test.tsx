import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { GitopsTab } from './GitopsTab';
import type {
  SystemGitopsRepository,
  SystemGitopsSyncRun,
  SystemGitopsSyncResult,
} from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGitopsApiList = jest.fn();
const mockGitopsApiCreate = jest.fn();
const mockGitopsApiSyncNow = jest.fn();
const mockGitopsApiDestroy = jest.fn();
const mockGitopsApiSyncRuns = jest.fn();

jest.mock('@system/features/system/services/api/gitopsApi', () => ({
  gitopsApi: {
    list: (...args: unknown[]) => mockGitopsApiList(...args),
    create: (...args: unknown[]) => mockGitopsApiCreate(...args),
    syncNow: (...args: unknown[]) => mockGitopsApiSyncNow(...args),
    destroy: (...args: unknown[]) => mockGitopsApiDestroy(...args),
    syncRuns: (...args: unknown[]) => mockGitopsApiSyncRuns(...args),
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

// EntityLink — render a plain anchor so tests can check repo name text.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { type: string; id: string; label: string; className?: string }) => (
    <a data-testid="entity-link">{label}</a>
  ),
}));

// =============================================================================
// Fixtures
// =============================================================================

const REPO_A: SystemGitopsRepository = {
  id: 'repo-a',
  name: 'fleet-desired-state',
  repo_url: 'https://git.example.com/org/fleet.git',
  branch: 'main',
  path_prefix: 'configs/',
  enabled: true,
  auto_apply: false,
  last_synced_at: '2026-05-01T10:00:00Z',
  last_synced_revision: 'abc1234',
  last_diff_count: 3,
  last_status: 'success',
  last_error: null,
  metadata: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-05-01T10:00:00Z',
};

const REPO_B: SystemGitopsRepository = {
  id: 'repo-b',
  name: 'staging-fleet',
  repo_url: 'https://git.example.com/org/staging.git',
  branch: 'develop',
  path_prefix: '',
  enabled: false,
  auto_apply: true,
  last_synced_at: null,
  last_synced_revision: null,
  last_diff_count: 0,
  last_status: 'failed',
  last_error: 'Connection refused',
  metadata: {},
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
};

const SYNC_RUN_1: SystemGitopsSyncRun = {
  id: 'run-1',
  started_at: '2026-05-01T10:00:00Z',
  completed_at: '2026-05-01T10:00:05Z',
  duration_seconds: 5,
  diff_count: 3,
  proposal_ids: ['prop-1', 'prop-2'],
  status: 'success',
  synced_revision: 'abc1234',
  error_message: null,
  diff_summary: {},
};

const SYNC_RUN_2: SystemGitopsSyncRun = {
  id: 'run-2',
  started_at: '2026-04-30T09:00:00Z',
  completed_at: '2026-04-30T09:00:10Z',
  duration_seconds: 10,
  diff_count: 0,
  proposal_ids: [],
  status: 'failed',
  synced_revision: null,
  error_message: 'auth error',
  diff_summary: {},
};

function listEnvelope(repos: SystemGitopsRepository[]) {
  return {
    gitops_repositories: repos,
    meta: {
      current_page: 1,
      per_page: 50,
      total_count: repos.length,
      total_pages: 1,
      next_page: null,
      prev_page: null,
    },
  };
}

const SYNC_RESULT_OK: SystemGitopsSyncResult = {
  sync_run: SYNC_RUN_1,
  ok: true,
  diff_count: 3,
  proposal_ids: ['prop-1', 'prop-2'],
};

const SYNC_RESULT_WARN: SystemGitopsSyncResult = {
  sync_run: { ...SYNC_RUN_1, status: 'partial' },
  ok: false,
  diff_count: 1,
  proposal_ids: [],
};

// =============================================================================
// Helpers
// =============================================================================

const renderTab = (props: React.ComponentProps<typeof GitopsTab> = {}) =>
  render(
    <BrowserRouter>
      <GitopsTab {...props} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('GitopsTab', () => {
  beforeEach(() => {
    mockGitopsApiList.mockReset();
    mockGitopsApiCreate.mockReset();
    mockGitopsApiSyncNow.mockReset();
    mockGitopsApiDestroy.mockReset();
    mockGitopsApiSyncRuns.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockImplementation(() => true);
    // Suppress window.confirm interactions by default
    jest.spyOn(window, 'confirm').mockReturnValue(false);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while repositories are being fetched', () => {
    // Never resolves during this test — keeps loading state active.
    mockGitopsApiList.mockReturnValue(new Promise(() => {}));
    renderTab();
    expect(screen.getByText('Loading…')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows the empty-state message when there are no repositories', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    renderTab();
    await waitFor(() =>
      expect(screen.getByText(/No GitOps repositories yet/i)).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Repository list rendering
  // ---------------------------------------------------------------------------

  it('renders repository names from the API response', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A, REPO_B]));
    renderTab();
    await waitFor(() => expect(screen.getByText('fleet-desired-state')).toBeInTheDocument());
    expect(screen.getByText('staging-fleet')).toBeInTheDocument();
  });

  it('fetches from the correct URL: GET /system/gitops_repositories', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    renderTab();
    await waitFor(() => expect(mockGitopsApiList).toHaveBeenCalledTimes(1));
    // The facade is called with no extra params (component passes nothing).
    expect(mockGitopsApiList).toHaveBeenCalledWith();
  });

  it('shows the count badge when repositories are present', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A, REPO_B]));
    renderTab();
    await waitFor(() => expect(screen.getByText('2')).toBeInTheDocument());
  });

  it('does not show the count badge when there are no repositories', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    renderTab();
    await waitFor(() =>
      expect(screen.queryByText('0')).not.toBeInTheDocument(),
    );
  });

  it('shows the repo_url and branch in the row', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    renderTab();
    await waitFor(() => expect(screen.getByText('https://git.example.com/org/fleet.git')).toBeInTheDocument());
    expect(screen.getByText('main')).toBeInTheDocument();
  });

  it('shows the path_prefix when present', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    renderTab();
    await waitFor(() => expect(screen.getByText('configs/')).toBeInTheDocument());
  });

  it('shows last synced info when last_synced_at is set', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    renderTab();
    await waitFor(() => expect(screen.getByText(/Last synced/)).toBeInTheDocument());
    expect(screen.getByText(/3 diff\(s\)/)).toBeInTheDocument();
  });

  it('shows "Never synced" when last_synced_at is null', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_B]));
    renderTab();
    await waitFor(() => expect(screen.getByText('Never synced')).toBeInTheDocument());
  });

  it('shows "disabled" badge for disabled repos', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_B]));
    renderTab();
    await waitFor(() => expect(screen.getByText('disabled')).toBeInTheDocument());
  });

  it('does not show "disabled" badge for enabled repos', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    renderTab();
    await waitFor(() => expect(screen.queryByText('disabled')).not.toBeInTheDocument());
  });

  it('shows "auto-apply" badge when auto_apply is true', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_B]));
    renderTab();
    await waitFor(() => expect(screen.getByText('auto-apply')).toBeInTheDocument());
  });

  it('shows last_error text when repo has an error', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_B]));
    renderTab();
    await waitFor(() => expect(screen.getByText(/Connection refused/)).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Expand / collapse row details
  // ---------------------------------------------------------------------------

  it('expands a row and shows detail fields when the chevron button is clicked', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncRuns.mockResolvedValue([SYNC_RUN_1]);
    renderTab();

    const expandBtn = await waitFor(() =>
      screen.getByTitle('Expand details'),
    );
    fireEvent.click(expandBtn);

    await waitFor(() => expect(screen.getByText('Last status')).toBeInTheDocument());
    expect(screen.getByText('Last diff count')).toBeInTheDocument();
    expect(screen.getByText('Last synced')).toBeInTheDocument();
    expect(screen.getByText('Auto-apply')).toBeInTheDocument();
    expect(screen.getByText('Enabled')).toBeInTheDocument();
  });

  it('collapses a row when the chevron is clicked a second time', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncRuns.mockResolvedValue([]);
    renderTab();

    const expandBtn = await waitFor(() => screen.getByTitle('Expand details'));
    fireEvent.click(expandBtn);
    await waitFor(() => expect(screen.getByTitle('Collapse details')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() =>
      expect(screen.queryByText('Last status')).not.toBeInTheDocument(),
    );
  });

  it('lazily fetches sync history on first expand', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncRuns.mockResolvedValue([SYNC_RUN_1]);
    renderTab();

    const expandBtn = await waitFor(() => screen.getByTitle('Expand details'));
    expect(mockGitopsApiSyncRuns).not.toHaveBeenCalled();
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(mockGitopsApiSyncRuns).toHaveBeenCalledWith('repo-a'),
    );
  });

  it('renders sync run history after expanding', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncRuns.mockResolvedValue([SYNC_RUN_1, SYNC_RUN_2]);
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));

    await waitFor(() => expect(screen.getByText(/2 proposal\(s\)/)).toBeInTheDocument());
    expect(screen.getByText(/5s/)).toBeInTheDocument();
    expect(screen.getByText(/auth error/)).toBeInTheDocument();
  });

  it('shows "No sync runs recorded yet." when history is empty', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncRuns.mockResolvedValue([]);
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));

    await waitFor(() =>
      expect(screen.getByText('No sync runs recorded yet.')).toBeInTheDocument(),
    );
  });

  it('shows an error notification when sync history fetch fails', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncRuns.mockRejectedValue(new Error('network error'));
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load sync history',
      }),
    );
  });

  it('does not re-fetch sync history on second expand of same row', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncRuns.mockResolvedValue([SYNC_RUN_1]);
    renderTab();

    // First expand — fetches
    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() => expect(mockGitopsApiSyncRuns).toHaveBeenCalledTimes(1));

    // Collapse
    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() => expect(screen.queryByText('Last status')).not.toBeInTheDocument());

    // Second expand — should NOT re-fetch
    fireEvent.click(screen.getByTitle('Expand details'));
    await waitFor(() => expect(screen.getByText('Last status')).toBeInTheDocument());
    expect(mockGitopsApiSyncRuns).toHaveBeenCalledTimes(1);
  });

  it('shows last_synced_revision in expanded detail when set', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncRuns.mockResolvedValue([]);
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));

    await waitFor(() => expect(screen.getByText('Last revision')).toBeInTheDocument());
    // The revision value truncates — check via title attribute
    const revEl = screen.getByTitle('abc1234');
    expect(revEl).toBeInTheDocument();
  });

  it('shows last_error in expanded detail when set', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_B]));
    mockGitopsApiSyncRuns.mockResolvedValue([]);
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));

    await waitFor(() => expect(screen.getByText('Last error')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Sync Now action
  // ---------------------------------------------------------------------------

  it('calls syncNow with the repo id when "Sync now" button is clicked', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncNow.mockResolvedValue(SYNC_RESULT_OK);
    renderTab();

    const syncBtn = await waitFor(() => screen.getByTitle('Sync now'));
    fireEvent.click(syncBtn);

    await waitFor(() =>
      expect(mockGitopsApiSyncNow).toHaveBeenCalledWith('repo-a'),
    );
  });

  it('shows a success notification after a successful sync', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncNow.mockResolvedValue(SYNC_RESULT_OK);
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Sync now')));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Reconciled "fleet-desired-state" — 3 diff(s), 2 proposal(s)',
      }),
    );
  });

  it('shows a warning notification when sync completes with errors (ok=false)', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncNow.mockResolvedValue(SYNC_RESULT_WARN);
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Sync now')));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'warning',
        message: 'Reconcile of "fleet-desired-state" completed with errors',
      }),
    );
  });

  it('shows an error notification when sync throws', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncNow.mockRejectedValue(new Error('timeout'));
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Sync now')));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'timeout',
      }),
    );
  });

  it('refreshes the list after a successful sync', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncNow.mockResolvedValue(SYNC_RESULT_OK);
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Sync now')));

    // Should call list at least twice: initial load + post-sync refresh.
    await waitFor(() => expect(mockGitopsApiList).toHaveBeenCalledTimes(2));
  });

  it('disables the Sync now button while a sync is in progress', async () => {
    let resolveSyncNow!: (v: SystemGitopsSyncResult) => void;
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    mockGitopsApiSyncNow.mockReturnValue(
      new Promise<SystemGitopsSyncResult>((res) => { resolveSyncNow = res; }),
    );
    renderTab();

    const syncBtn = await waitFor(() => screen.getByTitle('Sync now'));
    fireEvent.click(syncBtn);

    // Button should become disabled while in-flight
    await waitFor(() => expect(syncBtn).toBeDisabled());
    resolveSyncNow(SYNC_RESULT_OK);
    await waitFor(() => expect(syncBtn).not.toBeDisabled());
  });

  it('disables the Sync now button for disabled repos', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_B]));
    renderTab();

    // REPO_B is disabled — sync button should be disabled
    const syncBtn = await waitFor(() => screen.getByTitle('Sync now'));
    expect(syncBtn).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Permission gating — canSync / canWrite
  // ---------------------------------------------------------------------------

  it('hides Sync now button when user lacks system.gitops.sync', async () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.gitops.sync');
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    renderTab();

    await waitFor(() => expect(screen.getByText('fleet-desired-state')).toBeInTheDocument());
    expect(screen.queryByTitle('Sync now')).not.toBeInTheDocument();
  });

  it('hides Delete button when user lacks system.gitops.write', async () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.gitops.write');
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    renderTab();

    await waitFor(() => expect(screen.getByText('fleet-desired-state')).toBeInTheDocument());
    expect(screen.queryByTitle('Delete repository')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Delete action
  // ---------------------------------------------------------------------------

  it('prompts for confirmation before deleting a repository', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    const confirmSpy = jest.spyOn(window, 'confirm').mockReturnValue(false);
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Delete repository')));

    expect(confirmSpy).toHaveBeenCalledWith(
      'Delete GitOps repository "fleet-desired-state"? Reconciliation will stop and its sync history is removed.',
    );
    expect(mockGitopsApiDestroy).not.toHaveBeenCalled();
  });

  it('calls destroy with the repo id when user confirms deletion', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockGitopsApiDestroy.mockResolvedValue(undefined);
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Delete repository')));

    await waitFor(() =>
      expect(mockGitopsApiDestroy).toHaveBeenCalledWith('repo-a'),
    );
  });

  it('shows a success notification after successful deletion', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockGitopsApiDestroy.mockResolvedValue(undefined);
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Delete repository')));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Repository "fleet-desired-state" deleted',
      }),
    );
  });

  it('shows an error notification when deletion throws', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockGitopsApiDestroy.mockRejectedValue(new Error('server error'));
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Delete repository')));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'server error',
      }),
    );
  });

  it('refreshes the list after successful deletion', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockGitopsApiDestroy.mockResolvedValue(undefined);
    renderTab();

    fireEvent.click(await waitFor(() => screen.getByTitle('Delete repository')));

    // Initial load + post-delete refresh
    await waitFor(() => expect(mockGitopsApiList).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Load error
  // ---------------------------------------------------------------------------

  it('shows an error notification when the initial repository fetch fails', async () => {
    mockGitopsApiList.mockRejectedValue(new Error('network error'));
    renderTab();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load GitOps repositories',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // onActionsReady callback
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with an openCreate handle on mount', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(onActionsReady).toHaveBeenCalledWith(
        expect.objectContaining({ openCreate: expect.any(Function) }),
      ),
    );
  });

  it('calls onActionsReady with null on unmount', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    const onActionsReady = jest.fn();
    const { unmount } = renderTab({ onActionsReady });
    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    unmount();
    expect(onActionsReady).toHaveBeenLastCalledWith(null);
  });

  // ---------------------------------------------------------------------------
  // Create modal
  // ---------------------------------------------------------------------------

  it('opens the create modal when openCreate is called via onActionsReady', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    let capturedHandle: { openCreate: () => void } | null = null;
    const onActionsReady = jest.fn((h) => { capturedHandle = h; });
    renderTab({ onActionsReady });

    await waitFor(() => expect(capturedHandle).not.toBeNull());
    capturedHandle!.openCreate();

    await waitFor(() =>
      expect(screen.getByText('New GitOps repository')).toBeInTheDocument(),
    );
  });

  it('renders all form fields in the create modal', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    let capturedHandle: { openCreate: () => void } | null = null;
    renderTab({ onActionsReady: (h) => { capturedHandle = h; } });
    await waitFor(() => expect(capturedHandle).not.toBeNull());
    capturedHandle!.openCreate();

    await waitFor(() =>
      expect(screen.getByLabelText(/^Name/)).toBeInTheDocument(),
    );
    expect(screen.getByLabelText(/Repository URL/)).toBeInTheDocument();
    expect(screen.getByLabelText(/Branch/)).toBeInTheDocument();
    expect(screen.getByLabelText(/Path prefix/)).toBeInTheDocument();
    expect(screen.getByLabelText(/Vault credential path/)).toBeInTheDocument();
  });

  it('disables the submit button when name or repo_url is empty', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    let capturedHandle: { openCreate: () => void } | null = null;
    renderTab({ onActionsReady: (h) => { capturedHandle = h; } });
    await waitFor(() => expect(capturedHandle).not.toBeNull());
    capturedHandle!.openCreate();

    await waitFor(() => expect(screen.getByText('Register repository')).toBeInTheDocument());
    const submitBtn = screen.getByRole('button', { name: /Register repository/i });
    expect(submitBtn).toBeDisabled();
  });

  it('enables the submit button once name and repo_url are filled', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    let capturedHandle: { openCreate: () => void } | null = null;
    renderTab({ onActionsReady: (h) => { capturedHandle = h; } });
    await waitFor(() => expect(capturedHandle).not.toBeNull());
    capturedHandle!.openCreate();

    await waitFor(() => expect(screen.getByLabelText(/^Name/)).toBeInTheDocument());
    fireEvent.change(screen.getByLabelText(/^Name/), { target: { value: 'my-fleet' } });
    fireEvent.change(screen.getByLabelText(/Repository URL/), {
      target: { value: 'https://git.example.com/repo.git' },
    });

    const submitBtn = screen.getByRole('button', { name: /Register repository/i });
    expect(submitBtn).not.toBeDisabled();
  });

  it('calls gitopsApi.create with the correct payload on submit', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    mockGitopsApiCreate.mockResolvedValue(REPO_A);
    let capturedHandle: { openCreate: () => void } | null = null;
    renderTab({ onActionsReady: (h) => { capturedHandle = h; } });
    await waitFor(() => expect(capturedHandle).not.toBeNull());
    capturedHandle!.openCreate();

    await waitFor(() => expect(screen.getByLabelText(/^Name/)).toBeInTheDocument());
    fireEvent.change(screen.getByLabelText(/^Name/), { target: { value: 'fleet-desired-state' } });
    fireEvent.change(screen.getByLabelText(/Repository URL/), {
      target: { value: 'https://git.example.com/org/fleet.git' },
    });
    fireEvent.change(screen.getByLabelText(/Branch/), { target: { value: 'develop' } });
    fireEvent.change(screen.getByLabelText(/Path prefix/), { target: { value: 'configs/' } });
    fireEvent.change(screen.getByLabelText(/Vault credential path/), {
      target: { value: 'secret/data/gitops/key' },
    });

    fireEvent.click(screen.getByRole('button', { name: /Register repository/i }));

    await waitFor(() =>
      expect(mockGitopsApiCreate).toHaveBeenCalledWith({
        name: 'fleet-desired-state',
        repo_url: 'https://git.example.com/org/fleet.git',
        branch: 'develop',
        path_prefix: 'configs/',
        vault_credential_path: 'secret/data/gitops/key',
      }),
    );
  });

  it('omits path_prefix and vault_credential_path from create payload when empty', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    mockGitopsApiCreate.mockResolvedValue(REPO_A);
    let capturedHandle: { openCreate: () => void } | null = null;
    renderTab({ onActionsReady: (h) => { capturedHandle = h; } });
    await waitFor(() => expect(capturedHandle).not.toBeNull());
    capturedHandle!.openCreate();

    await waitFor(() => expect(screen.getByLabelText(/^Name/)).toBeInTheDocument());
    fireEvent.change(screen.getByLabelText(/^Name/), { target: { value: 'my-fleet' } });
    fireEvent.change(screen.getByLabelText(/Repository URL/), {
      target: { value: 'https://git.example.com/repo.git' },
    });
    // Leave path_prefix and vault_credential_path blank

    fireEvent.click(screen.getByRole('button', { name: /Register repository/i }));

    await waitFor(() =>
      expect(mockGitopsApiCreate).toHaveBeenCalledWith(
        expect.not.objectContaining({ path_prefix: expect.anything() }),
      ),
    );
    expect(mockGitopsApiCreate).toHaveBeenCalledWith(
      expect.not.objectContaining({ vault_credential_path: expect.anything() }),
    );
  });

  it('defaults branch to "main" in create payload when branch field is cleared', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    mockGitopsApiCreate.mockResolvedValue(REPO_A);
    let capturedHandle: { openCreate: () => void } | null = null;
    renderTab({ onActionsReady: (h) => { capturedHandle = h; } });
    await waitFor(() => expect(capturedHandle).not.toBeNull());
    capturedHandle!.openCreate();

    await waitFor(() => expect(screen.getByLabelText(/^Name/)).toBeInTheDocument());
    fireEvent.change(screen.getByLabelText(/^Name/), { target: { value: 'my-fleet' } });
    fireEvent.change(screen.getByLabelText(/Repository URL/), {
      target: { value: 'https://git.example.com/repo.git' },
    });
    // Clear the branch field (default is 'main', clear it to empty)
    fireEvent.change(screen.getByLabelText(/Branch/), { target: { value: '' } });

    fireEvent.click(screen.getByRole('button', { name: /Register repository/i }));

    await waitFor(() =>
      expect(mockGitopsApiCreate).toHaveBeenCalledWith(
        expect.objectContaining({ branch: 'main' }),
      ),
    );
  });

  it('shows a success notification after creating a repository', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    mockGitopsApiCreate.mockResolvedValue(REPO_A);
    let capturedHandle: { openCreate: () => void } | null = null;
    renderTab({ onActionsReady: (h) => { capturedHandle = h; } });
    await waitFor(() => expect(capturedHandle).not.toBeNull());
    capturedHandle!.openCreate();

    await waitFor(() => expect(screen.getByLabelText(/^Name/)).toBeInTheDocument());
    fireEvent.change(screen.getByLabelText(/^Name/), { target: { value: 'fleet-desired-state' } });
    fireEvent.change(screen.getByLabelText(/Repository URL/), {
      target: { value: 'https://git.example.com/org/fleet.git' },
    });
    fireEvent.click(screen.getByRole('button', { name: /Register repository/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Repository "fleet-desired-state" registered',
      }),
    );
  });

  it('closes the create modal after successful creation', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    mockGitopsApiCreate.mockResolvedValue(REPO_A);
    let capturedHandle: { openCreate: () => void } | null = null;
    renderTab({ onActionsReady: (h) => { capturedHandle = h; } });
    await waitFor(() => expect(capturedHandle).not.toBeNull());
    capturedHandle!.openCreate();

    await waitFor(() => expect(screen.getByLabelText(/^Name/)).toBeInTheDocument());
    fireEvent.change(screen.getByLabelText(/^Name/), { target: { value: 'fleet-desired-state' } });
    fireEvent.change(screen.getByLabelText(/Repository URL/), {
      target: { value: 'https://git.example.com/org/fleet.git' },
    });
    fireEvent.click(screen.getByRole('button', { name: /Register repository/i }));

    await waitFor(() =>
      expect(screen.queryByText('New GitOps repository')).not.toBeInTheDocument(),
    );
  });

  it('refreshes the list after successful creation', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    mockGitopsApiCreate.mockResolvedValue(REPO_A);
    let capturedHandle: { openCreate: () => void } | null = null;
    renderTab({ onActionsReady: (h) => { capturedHandle = h; } });
    await waitFor(() => expect(capturedHandle).not.toBeNull());
    capturedHandle!.openCreate();

    await waitFor(() => expect(screen.getByLabelText(/^Name/)).toBeInTheDocument());
    fireEvent.change(screen.getByLabelText(/^Name/), { target: { value: 'fleet-desired-state' } });
    fireEvent.change(screen.getByLabelText(/Repository URL/), {
      target: { value: 'https://git.example.com/org/fleet.git' },
    });
    fireEvent.click(screen.getByRole('button', { name: /Register repository/i }));

    // Initial load + post-create refresh
    await waitFor(() => expect(mockGitopsApiList).toHaveBeenCalledTimes(2));
  });

  it('shows an error notification when create fails', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    mockGitopsApiCreate.mockRejectedValue(new Error('create error'));
    let capturedHandle: { openCreate: () => void } | null = null;
    renderTab({ onActionsReady: (h) => { capturedHandle = h; } });
    await waitFor(() => expect(capturedHandle).not.toBeNull());
    capturedHandle!.openCreate();

    await waitFor(() => expect(screen.getByLabelText(/^Name/)).toBeInTheDocument());
    fireEvent.change(screen.getByLabelText(/^Name/), { target: { value: 'fleet-desired-state' } });
    fireEvent.change(screen.getByLabelText(/Repository URL/), {
      target: { value: 'https://git.example.com/org/fleet.git' },
    });
    fireEvent.click(screen.getByRole('button', { name: /Register repository/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'create error',
      }),
    );
  });

  it('closes the create modal when Cancel is clicked', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([]));
    let capturedHandle: { openCreate: () => void } | null = null;
    renderTab({ onActionsReady: (h) => { capturedHandle = h; } });
    await waitFor(() => expect(capturedHandle).not.toBeNull());
    capturedHandle!.openCreate();

    await waitFor(() => expect(screen.getByText('New GitOps repository')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /Cancel/i }));

    await waitFor(() =>
      expect(screen.queryByText('New GitOps repository')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // statusVariant mapping
  // ---------------------------------------------------------------------------

  it('renders success status badge for repos with last_status "success"', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_A]));
    renderTab();
    await waitFor(() => expect(screen.getByText('success')).toBeInTheDocument());
  });

  it('renders failed status badge for repos with last_status "failed"', async () => {
    mockGitopsApiList.mockResolvedValue(listEnvelope([REPO_B]));
    renderTab();
    await waitFor(() => expect(screen.getByText('failed')).toBeInTheDocument());
  });
});
