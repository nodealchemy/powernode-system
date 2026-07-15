import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
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

// moduleBuildsApi — mock the whole module so we control list + get.
const mockList = jest.fn();
const mockGet = jest.fn();
jest.mock('@system/features/system/services/api/moduleBuildsApi', () => ({
  moduleBuildsApi: {
    list: (...args: unknown[]) => mockList(...args),
    get: (...args: unknown[]) => mockGet(...args),
  },
}));

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

// =============================================================================
// Helpers
// =============================================================================

const renderTab = (props: Partial<React.ComponentProps<typeof ModuleBuildsTab>> = {}) =>
  render(<ModuleBuildsTab {...props} />);

// =============================================================================
// Tests
// =============================================================================

describe('ModuleBuildsTab', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockCurrentUser = { account: { id: 'acct-1' } };
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

  it('displays a batch count badge when batches are present', async () => {
    mockList.mockResolvedValue({ module_build_batches: [BATCH_ACTIVE, BATCH_DONE], meta: META });

    renderTab();

    await waitFor(() => expect(screen.getByText('2')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows error notification when fetch fails', async () => {
    mockList.mockRejectedValue(new Error('Network error'));

    renderTab();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Network error',
      }),
    );
  });

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
    // Per-module table row rendered from BATCH_DONE_FULL.modules — unique
    // text, unlike the "Modules" section heading (also present in the
    // summary grid's "Modules" label).
    await waitFor(() => expect(screen.getByText('pkg-closure')).toBeInTheDocument());
  });

  it('closes the batch detail modal when Close is clicked', async () => {
    mockList.mockResolvedValue({ module_build_batches: [BATCH_DONE], meta: META });
    mockGet.mockResolvedValue(BATCH_DONE_FULL);

    renderTab();

    const link = await screen.findByTitle('View batch details');
    fireEvent.click(link);

    await waitFor(() => expect(screen.getByText('pkg-closure')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /close/i }));

    await waitFor(() => expect(screen.queryByText('pkg-closure')).not.toBeInTheDocument());
  });
});
