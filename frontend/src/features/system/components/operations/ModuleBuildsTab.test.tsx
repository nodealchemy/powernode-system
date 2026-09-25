import React from 'react';
import { render, screen, fireEvent, waitFor, act, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { ModuleBuildsTab } from './ModuleBuildsTab';
import type { SystemModuleBuildBatch, SystemModuleBuildBatchFull } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// useAuth — mockable via mockCurrentUser
let mockCurrentUser: { account?: { id?: string } } | null = { account: { id: 'acct-1' } };
jest.mock('@/shared/hooks/useAuth', () => ({
  useAuth: () => ({ currentUser: mockCurrentUser }),
}));

// usePermissions — fc-34 cancel action gating (system.module_builds.cancel).
// Defaults to granted; individual tests override to prove the gate.
const mockHasPermission = jest.fn(() => true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (...args: unknown[]) => mockHasPermission(...args),
  }),
}));

// WebSocketManager — capture subscribe callback so tests can fire live events.
const mockWsSubscribe = jest.fn(() => () => undefined);
jest.mock('@/shared/services/WebSocketManager', () => ({
  wsManager: {
    subscribe: (...args: unknown[]) => mockWsSubscribe(...args),
  },
}));

// EntityLink — render plain anchor so tests can assert on it without pulling
// in the real entity registry / modal host.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { type: string; id: string; label: React.ReactNode }) => (
    <a href="#entity-mock">{label}</a>
  ),
}));

// moduleBuildsApi — mock the whole module so we control list + get + cancel.
const mockList = jest.fn();
const mockGet = jest.fn();
const mockCancel = jest.fn();
jest.mock('@system/features/system/services/api/moduleBuildsApi', () => ({
  moduleBuildsApi: {
    list: (...args: unknown[]) => mockList(...args),
    get: (...args: unknown[]) => mockGet(...args),
    cancel: (...args: unknown[]) => mockCancel(...args),
  },
}));

// Revoke/cancel go through the shared themed ConfirmationModal, not
// window.confirm (same convention as CiWorkersTab.test.tsx).
const confirmDialog = async (heading: RegExp, button: RegExp) => {
  await waitFor(() =>
    expect(screen.getByRole('heading', { name: heading })).toBeInTheDocument(),
  );
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: button }));
};

const cancelDialog = async (heading: RegExp) => {
  await waitFor(() =>
    expect(screen.getByRole('heading', { name: heading })).toBeInTheDocument(),
  );
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: /^cancel$/i }));
};

// =============================================================================
// Fixtures
// =============================================================================

const META = {
  current_page: 1,
  per_page: 25,
  total_count: 1,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

// The server pages 20 at a time (review fix, fc-34): a real multi-page meta,
// so the header badge and pagination controls have something to show.
const META_PAGE_1_OF_3 = {
  current_page: 1,
  per_page: 20,
  total_count: 45,
  total_pages: 3,
  next_page: 2,
  prev_page: null,
};

const META_PAGE_2_OF_3 = {
  ...META_PAGE_1_OF_3,
  current_page: 2,
  next_page: 3,
  prev_page: 1,
};

const BATCH_ACTIVE: SystemModuleBuildBatch = {
  id: 'batch-active',
  status: 'dispatched',
  trigger: 'push',
  shadow: false,
  base_sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  head_sha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  module_slugs: ['core-runtime'],
  planned_count: 1,
  succeeded_count: 0,
  failed_count: 0,
  active: true,
  finished: false,
  package_context: null,
  created_at: '2026-06-01T00:00:00Z',
  updated_at: '2026-06-01T00:00:00Z',
};

const BATCH_DONE: SystemModuleBuildBatch = {
  id: 'batch-done',
  status: 'complete',
  trigger: 'package',
  shadow: false,
  base_sha: 'cccccccccccccccccccccccccccccccccccccccc',
  head_sha: 'dddddddddddddddddddddddddddddddddddddddd',
  module_slugs: ['pkg-closure'],
  planned_count: 1,
  succeeded_count: 1,
  failed_count: 0,
  active: false,
  finished: true,
  package_context: {
    repository_id: 'repo-1',
    package_repo_kind: 'apt',
    architecture: 'amd64',
    snapshot: '2026-06-01',
    tag: 'stable',
  },
  created_at: '2026-06-01T01:00:00Z',
  updated_at: '2026-06-01T02:00:00Z',
};

const BATCH_DONE_FULL: SystemModuleBuildBatchFull = {
  ...BATCH_DONE,
  dispatched_at: '2026-06-01T01:01:00Z',
  awaiting_signature_at: '2026-06-01T01:05:00Z',
  publishing_at: '2026-06-01T01:06:00Z',
  completed_at: '2026-06-01T01:10:00Z',
  failed_at: null,
  error_message: null,
  modules: [
    {
      module: 'pkg-closure',
      tag: 'ddddddd',
      state: 'succeeded',
      attempts: 1,
      error: null,
      task: { id: 'task-1', status: 'complete', progress: 100, started_at: null, completed_at: null, error_message: null },
      lease: { id: 'lease-1', status: 'released', node_instance_id: 'ni-1', runner_name: 'builder-1' },
      artifact: {
        version_number: '1.0.0',
        promotion_state: 'stable',
        oci_ref: 'registry/pkg-closure:ddddddd',
        oci_digest: 'sha256:abc',
        size_bytes: 1024,
        architecture: 'amd64',
        signed: true,
      },
      parity: null,
    },
  ],
};

const BATCH_ACTIVE_FULL: SystemModuleBuildBatchFull = {
  ...BATCH_ACTIVE,
  dispatched_at: '2026-06-01T00:00:30Z',
  awaiting_signature_at: null,
  publishing_at: null,
  completed_at: null,
  failed_at: null,
  cancelled_at: null,
  error_message: null,
  modules: [
    {
      module: 'core-runtime',
      tag: 'bbbbbbb',
      state: 'dispatched',
      attempts: 1,
      error: null,
      task: { id: 'task-1', status: 'running', progress: 40, started_at: null, completed_at: null, error_message: null },
      lease: { id: 'lease-1', status: 'busy', node_instance_id: 'ni-1', runner_name: 'builder-1' },
      artifact: null,
      parity: null,
    },
  ],
};

const BATCH_CANCELLED_FULL: SystemModuleBuildBatchFull = {
  ...BATCH_ACTIVE_FULL,
  status: 'cancelled',
  active: false,
  finished: true,
  cancelled_at: '2026-06-01T00:05:00Z',
};

// Review fix, fc-34: module-slug CHIPS instead of only a count — a batch
// with more than 2 modules to exercise the "+N more" overflow.
const BATCH_MANY_MODULES: SystemModuleBuildBatch = {
  ...BATCH_ACTIVE,
  id: 'batch-many',
  module_slugs: ['fleet-autonomy', 'sdwan-manager', 'core-runtime', 'billing-engine'],
};

// =============================================================================
// Helpers
// =============================================================================

const renderTab = (
  props: Partial<React.ComponentProps<typeof ModuleBuildsTab>> = {},
  initialPath = '/app/devops/ci-cd/module-builds',
) =>
  render(
    <MemoryRouter initialEntries={[initialPath]}>
      <ModuleBuildsTab {...props} />
    </MemoryRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('ModuleBuildsTab', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockCurrentUser = { account: { id: 'acct-1' } };
    mockHasPermission.mockReturnValue(true);
    mockList.mockResolvedValue({ module_build_batches: [], meta: META });
    mockWsSubscribe.mockReturnValue(() => undefined);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  // ---------------------------------------------------------------------------
  // Loading / empty / list states
  // ---------------------------------------------------------------------------

  it('shows loading indicator while fetching batches', async () => {
    let resolve!: (value: { module_build_batches: SystemModuleBuildBatch[]; meta: typeof META }) => void;
    mockList.mockReturnValue(new Promise((r) => { resolve = r; }));

    renderTab();

    expect(screen.getByText(/loading…/i)).toBeInTheDocument();

    await act(async () => { resolve({ module_build_batches: [], meta: META }); });
  });

  it('shows empty-state message when no batches exist', async () => {
    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/no module build batches yet/i)).toBeInTheDocument(),
    );
  });

  it('calls moduleBuildsApi.list() on mount', async () => {
    renderTab();
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));
  });

  it('renders batch rows after a successful fetch', async () => {
    mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE, BATCH_DONE], meta: META });

    renderTab();

    await waitFor(() => expect(screen.getByText('aaaaaaa→bbbbbbb')).toBeInTheDocument());
    expect(screen.getByText('ccccccc→ddddddd')).toBeInTheDocument();
  });

  it('displays the real total from pagination meta as the count badge, not just the fetched page length', async () => {
    // Review fix: the badge shows meta.total_count (the server-side total),
    // not batches.length (only the current page) — deliberately different
    // here (2 fetched, 5 total) to prove which one the badge actually reads.
    mockList.mockResolvedValue({
      module_build_batches: [BATCH_ACTIVE, BATCH_DONE],
      meta: { ...META, total_count: 5 },
    });

    renderTab();

    await waitFor(() => expect(screen.getByText('5')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Error state — see "inline error with retry" below (review fix: fetch
  // failures now show an inline banner + Try Again, not only a toast).
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // onActionsReady (Refresh)
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with a refresh handle on mount', async () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(onActionsReady).toHaveBeenCalledWith(
        expect.objectContaining({ refresh: expect.any(Function) }),
      ),
    );
  });

  it('calls onActionsReady(null) on unmount', async () => {
    const onActionsReady = jest.fn();
    const { unmount } = renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalledTimes(1));
    unmount();

    expect(onActionsReady).toHaveBeenLastCalledWith(null);
  });

  it('re-fetches when the refresh handle is invoked', async () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    const handle = onActionsReady.mock.calls[0][0] as { refresh: () => void };
    act(() => { handle.refresh(); });

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Polling — only while a batch is active
  // ---------------------------------------------------------------------------

  it('polls for updates while a listed batch is active', async () => {
    jest.useFakeTimers();
    mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE], meta: META });

    renderTab();

    // Wait for the batch row itself (not just the call count — the mock is
    // invoked synchronously when refresh() starts, before its promise
    // resolves and state commits, so a call-count assertion alone would
    // race ahead of the interval-registration effect that depends on the
    // committed `hasActiveBatch` state).
    await waitFor(() => expect(screen.getByText('aaaaaaa→bbbbbbb')).toBeInTheDocument());
    expect(mockList).toHaveBeenCalledTimes(1);

    // advanceTimersByTimeAsync (not the sync variant) interleaves timer
    // advancement with microtask flushing, which the interval callback's
    // refresh() → setBatches() → re-render chain needs.
    await act(async () => { await jest.advanceTimersByTimeAsync(12_000); });

    expect(mockList).toHaveBeenCalledTimes(2);
  });

  it('does not poll when every listed batch has finished', async () => {
    jest.useFakeTimers();
    mockList.mockResolvedValue({ module_build_batches: [BATCH_DONE], meta: META });

    renderTab();

    await waitFor(() => expect(screen.getByText('ccccccc→ddddddd')).toBeInTheDocument());
    expect(mockList).toHaveBeenCalledTimes(1);

    await act(async () => { await jest.advanceTimersByTimeAsync(30_000); });

    // No interval was ever scheduled — nothing to flush, and the count stays put.
    expect(mockList).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Live updates — SystemFleetChannel
  // ---------------------------------------------------------------------------

  it('subscribes to SystemFleetChannel with the current account id', async () => {
    renderTab();

    await waitFor(() =>
      expect(mockWsSubscribe).toHaveBeenCalledWith(
        expect.objectContaining({
          channel: 'SystemFleetChannel',
          params: { account_id: 'acct-1' },
        }),
      ),
    );
  });

  it('does not subscribe when there is no current account', async () => {
    mockCurrentUser = null;
    renderTab();

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));
    expect(mockWsSubscribe).not.toHaveBeenCalled();
  });

  it('refetches when a system.module_build_* FleetEvent arrives', async () => {
    renderTab();
    await waitFor(() => expect(mockWsSubscribe).toHaveBeenCalledTimes(1));

    const onMessage = (mockWsSubscribe.mock.calls[0][0] as { onMessage: (data: unknown) => void }).onMessage;
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    act(() => { onMessage({ kind: 'system.module_build_parity_ok' }); });

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  it('ignores FleetEvents whose kind does not start with system.module_build', async () => {
    renderTab();
    await waitFor(() => expect(mockWsSubscribe).toHaveBeenCalledTimes(1));

    const onMessage = (mockWsSubscribe.mock.calls[0][0] as { onMessage: (data: unknown) => void }).onMessage;
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    act(() => { onMessage({ kind: 'system.disk_image_published' }); });

    // Give any (incorrect) async refetch a chance to fire before asserting it didn't.
    await new Promise((r) => setTimeout(r, 20));
    expect(mockList).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Detail modal
  // ---------------------------------------------------------------------------

  it('opens the batch detail modal when a batch row is clicked, and fetches its detail', async () => {
    mockList.mockResolvedValue({ module_build_batches: [BATCH_DONE], meta: META });
    mockGet.mockResolvedValue(BATCH_DONE_FULL);

    renderTab();

    const link = await screen.findByTitle('View batch details');
    fireEvent.click(link);

    await waitFor(() => expect(mockGet).toHaveBeenCalledWith('batch-done'));
    // Per-module table row rendered from BATCH_DONE_FULL.modules, scoped to
    // the dialog — the review-fix module-slug chip on the LIST row behind the
    // modal renders the same slug text ('pkg-closure'), so an unscoped lookup
    // is ambiguous once both are on screen at once.
    await waitFor(() =>
      expect(within(screen.getByRole('dialog')).getByText('pkg-closure')).toBeInTheDocument(),
    );
  });

  it('closes the batch detail modal when Close is clicked', async () => {
    mockList.mockResolvedValue({ module_build_batches: [BATCH_DONE], meta: META });
    mockGet.mockResolvedValue(BATCH_DONE_FULL);

    renderTab();

    const link = await screen.findByTitle('View batch details');
    fireEvent.click(link);

    await waitFor(() => expect(screen.getByRole('dialog')).toBeInTheDocument());

    // The core Modal shell adds its own "Close modal" control alongside the
    // footer's Close button, so the lookup has to be exact.
    fireEvent.click(screen.getByRole('button', { name: /^close$/i }));

    // Query for the dialog itself, not 'pkg-closure' — the list row behind it
    // renders that same slug as its own chip (review fix) and stays mounted
    // once the modal closes, which would make a text-based query ambiguous
    // and pass vacuously even if the modal never actually closed.
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Cancel action (fc-34) — list row
  //
  // Ported from the deleted core CancelBatchButton/ModuleBuildsPage: visible
  // only for an ACTIVE batch, gated on system.module_builds.cancel, and using
  // the shared themed ConfirmationModal (not window.confirm) — same
  // convention as CiWorkersTab's revoke action.
  // ---------------------------------------------------------------------------

  describe('cancel action — list row', () => {
    it('shows a Cancel button for an active batch in the list', async () => {
      mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE], meta: META });

      renderTab();

      await waitFor(() => expect(screen.getByTitle('Cancel build batch')).toBeInTheDocument());
    });

    it('hides the Cancel button for a finished batch in the list', async () => {
      mockList.mockResolvedValue({ module_build_batches: [BATCH_DONE], meta: META });

      renderTab();

      await waitFor(() => expect(screen.getByText('ccccccc→ddddddd')).toBeInTheDocument());
      expect(screen.queryByTitle('Cancel build batch')).not.toBeInTheDocument();
    });

    it('hides the Cancel button when the operator lacks system.module_builds.cancel', async () => {
      mockHasPermission.mockImplementation((perm: unknown) => perm !== 'system.module_builds.cancel');
      mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE], meta: META });

      renderTab();

      await waitFor(() => expect(screen.getByText('aaaaaaa→bbbbbbb')).toBeInTheDocument());
      expect(screen.queryByTitle('Cancel build batch')).not.toBeInTheDocument();
    });

    it('calls moduleBuildsApi.cancel() and refreshes the list after confirmed cancel', async () => {
      mockList
        .mockResolvedValueOnce({ module_build_batches: [BATCH_ACTIVE], meta: META })
        .mockResolvedValue({ module_build_batches: [BATCH_CANCELLED_FULL], meta: META });
      mockCancel.mockResolvedValue(BATCH_CANCELLED_FULL);

      renderTab();

      await waitFor(() => expect(screen.getByTitle('Cancel build batch')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Cancel build batch'));
      await confirmDialog(/cancel module build/i, /^cancel batch$/i);

      await waitFor(() => expect(mockCancel).toHaveBeenCalledWith('batch-active'));
      await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
    });

    it('does NOT call moduleBuildsApi.cancel() when the confirmation is dismissed', async () => {
      mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE], meta: META });

      renderTab();

      await waitFor(() => expect(screen.getByTitle('Cancel build batch')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Cancel build batch'));
      await cancelDialog(/cancel module build/i);

      await new Promise((r) => setTimeout(r, 20));
      expect(mockCancel).not.toHaveBeenCalled();
    });

    it('shows an error notification when cancel fails', async () => {
      mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE], meta: META });
      mockCancel.mockRejectedValue(new Error('Batch is already complete and cannot be cancelled'));

      renderTab();

      await waitFor(() => expect(screen.getByTitle('Cancel build batch')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Cancel build batch'));
      await confirmDialog(/cancel module build/i, /^cancel batch$/i);

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Batch is already complete and cannot be cancelled',
        }),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Cancel action (fc-34) — detail modal
  // ---------------------------------------------------------------------------

  describe('cancel action — detail modal', () => {
    it('shows a Cancel Batch button for an active batch in the detail modal', async () => {
      mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE], meta: META });
      mockGet.mockResolvedValue(BATCH_ACTIVE_FULL);

      renderTab();

      fireEvent.click(await screen.findByTitle('View batch details'));

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /^cancel batch$/i })).toBeInTheDocument(),
      );
    });

    it('hides the Cancel Batch button in the detail modal when the operator lacks permission', async () => {
      mockHasPermission.mockImplementation((perm: unknown) => perm !== 'system.module_builds.cancel');
      mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE], meta: META });
      mockGet.mockResolvedValue(BATCH_ACTIVE_FULL);

      renderTab();

      fireEvent.click(await screen.findByTitle('View batch details'));

      await waitFor(() => expect(screen.getByText('core-runtime')).toBeInTheDocument());
      expect(screen.queryByRole('button', { name: /^cancel batch$/i })).not.toBeInTheDocument();
    });

    it('cancels from the detail modal and refetches its own detail', async () => {
      mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE], meta: META });
      mockGet
        .mockResolvedValueOnce(BATCH_ACTIVE_FULL)
        .mockResolvedValue(BATCH_CANCELLED_FULL);
      mockCancel.mockResolvedValue(BATCH_CANCELLED_FULL);

      renderTab();

      fireEvent.click(await screen.findByTitle('View batch details'));
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /^cancel batch$/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /^cancel batch$/i }));

      // Two `role="dialog"` elements are open at once here (BatchDetailModal
      // itself, and the confirmation on top of it) — both wrap the shared
      // core Modal, so the generic confirmDialog()/cancelDialog() helpers
      // (which assume a single dialog) can't be reused; scope explicitly to
      // the LAST one (the confirmation, mounted after and portalled last).
      await waitFor(() => expect(screen.getAllByRole('dialog')).toHaveLength(2));
      const confirmation = within(screen.getAllByRole('dialog').at(-1)!);
      expect(confirmation.getByRole('heading', { name: /cancel module build/i })).toBeInTheDocument();
      fireEvent.click(confirmation.getByRole('button', { name: /^cancel batch$/i }));

      await waitFor(() => expect(mockCancel).toHaveBeenCalledWith('batch-active'));
      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
    });
  });

  // ---------------------------------------------------------------------------
  // Parity restoration (fc-34 review fix) — status/trigger filters,
  // pagination with the real total, module-slug chips, inline error + retry.
  // Based on the deleted core ModuleBuildsPage (git show a1b5b13d9:
  // frontend/src/features/devops/module-builds/pages/ModuleBuildsPage.tsx).
  // ---------------------------------------------------------------------------

  describe('status and trigger filters', () => {
    it('renders status and trigger filter selects', async () => {
      mockList.mockResolvedValue({ module_build_batches: [], meta: META });
      renderTab();

      await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

      expect(screen.getByLabelText(/status/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/trigger/i)).toBeInTheDocument();
    });

    it('refetches with the status filter when changed', async () => {
      mockList.mockResolvedValue({ module_build_batches: [], meta: META });
      renderTab();
      await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

      fireEvent.change(screen.getByLabelText(/status/i), { target: { value: 'failed' } });

      await waitFor(() =>
        expect(mockList).toHaveBeenLastCalledWith(
          expect.objectContaining({ status: 'failed' }),
        ),
      );
    });

    it('refetches with the trigger filter when changed', async () => {
      mockList.mockResolvedValue({ module_build_batches: [], meta: META });
      renderTab();
      await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

      fireEvent.change(screen.getByLabelText(/trigger/i), { target: { value: 'package' } });

      await waitFor(() =>
        expect(mockList).toHaveBeenLastCalledWith(
          expect.objectContaining({ trigger: 'package' }),
        ),
      );
    });

    it('omits status/trigger from the list params when both filters are "All"', async () => {
      mockList.mockResolvedValue({ module_build_batches: [], meta: META });
      renderTab();

      await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));
      const [params] = mockList.mock.calls[0];
      expect(params?.status).toBeUndefined();
      expect(params?.trigger).toBeUndefined();
    });
  });

  describe('pagination', () => {
    it('shows the real total from pagination meta, not just the fetched page length', async () => {
      mockList.mockResolvedValue({
        module_build_batches: [BATCH_ACTIVE],
        meta: META_PAGE_1_OF_3,
      });
      renderTab();

      // 45 total batches server-side; only 1 came back on this page.
      await waitFor(() => expect(screen.getByText('45')).toBeInTheDocument());
    });

    it('shows Previous/Next controls and the current/total page', async () => {
      mockList.mockResolvedValue({
        module_build_batches: [BATCH_ACTIVE],
        meta: META_PAGE_1_OF_3,
      });
      renderTab();

      await waitFor(() => expect(screen.getByText(/page 1 of 3/i)).toBeInTheDocument());
      expect(screen.getByRole('button', { name: /previous/i })).toBeDisabled();
      expect(screen.getByRole('button', { name: /^next$/i })).not.toBeDisabled();
    });

    it('does not render pagination controls for a single-page result', async () => {
      mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE], meta: META });
      renderTab();

      await waitFor(() => expect(screen.getByTestId('batch-row-batch-active')).toBeInTheDocument());
      expect(screen.queryByRole('button', { name: /^next$/i })).not.toBeInTheDocument();
    });

    it('requests the next page when Next is clicked, and reaches every batch (not just the first 20)', async () => {
      mockList
        .mockResolvedValueOnce({ module_build_batches: [BATCH_ACTIVE], meta: META_PAGE_1_OF_3 })
        .mockResolvedValue({ module_build_batches: [BATCH_DONE], meta: META_PAGE_2_OF_3 });
      renderTab();

      await waitFor(() => expect(screen.getByText(/page 1 of 3/i)).toBeInTheDocument());

      fireEvent.click(screen.getByRole('button', { name: /^next$/i }));

      await waitFor(() =>
        expect(mockList).toHaveBeenLastCalledWith(expect.objectContaining({ page: 2 })),
      );
      await waitFor(() => expect(screen.getByText(/page 2 of 3/i)).toBeInTheDocument());
    });

    // Genuinely reaches page 2 first (sequential resolves keyed to the
    // requested page), THEN changes a filter — proving the reset actually
    // moved something, not just that page started and stayed at 1. The old
    // version mocked every call to return page-2 metadata regardless of what
    // was requested, so `page` state itself was never anything but 1 and the
    // assertion passed whether or not the reset effect existed.
    it('resets to page 1 when a filter changes, after genuinely being on page 2', async () => {
      mockList
        .mockResolvedValueOnce({ module_build_batches: [BATCH_ACTIVE], meta: META_PAGE_1_OF_3 })
        .mockResolvedValueOnce({ module_build_batches: [BATCH_DONE], meta: META_PAGE_2_OF_3 });
      renderTab();
      await waitFor(() => expect(screen.getByText(/page 1 of 3/i)).toBeInTheDocument());

      fireEvent.click(screen.getByRole('button', { name: /^next$/i }));
      await waitFor(() => expect(screen.getByText(/page 2 of 3/i)).toBeInTheDocument());

      mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE], meta: META_PAGE_1_OF_3 });
      fireEvent.change(screen.getByLabelText(/status/i), { target: { value: 'failed' } });

      await waitFor(() =>
        expect(mockList).toHaveBeenLastCalledWith(
          expect.objectContaining({ status: 'failed', page: 1 }),
        ),
      );
    });
  });

  describe('module-slug chips', () => {
    it('renders a chip per module slug, up to 2, with a "+N more" overflow', async () => {
      mockList.mockResolvedValue({ module_build_batches: [BATCH_MANY_MODULES], meta: META });
      renderTab();

      await waitFor(() => expect(screen.getByText('fleet-autonomy')).toBeInTheDocument());
      expect(screen.getByText('sdwan-manager')).toBeInTheDocument();
      expect(screen.queryByText('core-runtime')).not.toBeInTheDocument();
      expect(screen.getByText('+2 more')).toBeInTheDocument();
    });

    it('shows a placeholder, not chips, for a batch with no modules', async () => {
      mockList.mockResolvedValue({
        module_build_batches: [{ ...BATCH_ACTIVE, module_slugs: [] }],
        meta: META,
      });
      renderTab();

      await waitFor(() => expect(screen.getByTestId('batch-row-batch-active')).toBeInTheDocument());
      expect(within(screen.getByTestId('batch-row-batch-active')).getByText('—')).toBeInTheDocument();
    });
  });

  describe('inline error with retry', () => {
    it('shows an inline error banner with a Try Again button on fetch failure, not only a toast', async () => {
      mockList.mockRejectedValue(new Error('Network error'));
      renderTab();

      await waitFor(() => expect(screen.getByText('Network error')).toBeInTheDocument());
      expect(screen.getByRole('button', { name: /try again/i })).toBeInTheDocument();
    });

    it('retries the fetch when Try Again is clicked', async () => {
      mockList.mockRejectedValueOnce(new Error('Network error'));
      mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE], meta: META });
      renderTab();

      await waitFor(() => expect(screen.getByText('Network error')).toBeInTheDocument());

      fireEvent.click(screen.getByRole('button', { name: /try again/i }));

      await waitFor(() => expect(screen.getByTestId('batch-row-batch-active')).toBeInTheDocument());
      expect(screen.queryByText('Network error')).not.toBeInTheDocument();
    });
  });

  describe('deep-linkable batch detail (?batch=<id>)', () => {
    it('opens BatchDetailModal for the batch named in the ?batch= query param on load', async () => {
      mockList.mockResolvedValue({ module_build_batches: [BATCH_DONE], meta: META });
      mockGet.mockResolvedValue(BATCH_DONE_FULL);

      renderTab({}, '/app/devops/ci-cd/module-builds?batch=batch-done');

      await waitFor(() => expect(mockGet).toHaveBeenCalledWith('batch-done'));
      // Scoped to the dialog — the list row behind it renders the same slug
      // as its own module-slug chip (review fix), so an unscoped lookup is
      // ambiguous once both are on screen.
      await waitFor(() =>
        expect(within(screen.getByRole('dialog')).getByText('pkg-closure')).toBeInTheDocument(),
      );
    });

    // Observes the CURRENT URL's search string alongside ModuleBuildsTab, so
    // a test can assert the param itself changed — not just that the modal's
    // own state did (which could pass even if the URL never actually moved).
    const SearchParamProbe: React.FC = () => {
      const [params] = require('react-router-dom').useSearchParams();
      return <div data-testid="search-probe">{params.toString()}</div>;
    };

    const renderTabWithProbe = (initialPath = '/app/devops/ci-cd/module-builds') =>
      render(
        <MemoryRouter initialEntries={[initialPath]}>
          <ModuleBuildsTab />
          <SearchParamProbe />
        </MemoryRouter>,
      );

    it('sets the ?batch= query param when a row is opened', async () => {
      mockList.mockResolvedValue({ module_build_batches: [BATCH_DONE], meta: META });
      mockGet.mockResolvedValue(BATCH_DONE_FULL);
      renderTabWithProbe();

      fireEvent.click(await screen.findByTitle('View batch details'));

      await waitFor(() => expect(screen.getByTestId('search-probe')).toHaveTextContent('batch=batch-done'));
    });

    it('clears the ?batch= query param when the modal is closed', async () => {
      mockList.mockResolvedValue({ module_build_batches: [BATCH_DONE], meta: META });
      mockGet.mockResolvedValue(BATCH_DONE_FULL);
      renderTabWithProbe('/app/devops/ci-cd/module-builds?batch=batch-done');

      await waitFor(() => expect(screen.getByRole('dialog')).toBeInTheDocument());

      fireEvent.click(screen.getByRole('button', { name: /^close$/i }));

      // Query for the dialog itself, not 'pkg-closure' — the list row behind
      // it renders that same slug as its own chip and stays mounted.
      await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
      expect(screen.getByTestId('search-probe')).toHaveTextContent('');
    });
  });
});
