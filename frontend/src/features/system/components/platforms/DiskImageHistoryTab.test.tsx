import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { DiskImageHistoryTab } from './DiskImageHistoryTab';
import type { SystemNodePlatform, SystemDiskImagePublication } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
  },
}));

// usePermissions — mockable via mockHasPermission
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

// useAuth — mockable via mockCurrentUser
let mockCurrentUser: { account?: { id?: string } } | null = { account: { id: 'acct-1' } };
jest.mock('@/shared/hooks/useAuth', () => ({
  useAuth: () => ({ currentUser: mockCurrentUser }),
}));

// WebSocketManager — capture subscribe callback so tests can fire live events.
jest.mock('@/shared/services/WebSocketManager', () => ({
  wsManager: {
    subscribe: jest.fn(() => () => undefined),
  },
}));

// EntityLink — render plain anchor so tests can assert on it.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { type: string; id: string; label: string }) => (
    <a href="#entity-mock">{label}</a>
  ),
}));

// diskImagePublicationsApi — mock the whole module so we control list + rollback.
const mockApiList = jest.fn();
const mockApiRollback = jest.fn();
jest.mock('@system/features/system/services/api/diskImagePublicationsApi', () => ({
  diskImagePublicationsApi: {
    list: (...args: unknown[]) => mockApiList(...args),
    rollback: (...args: unknown[]) => mockApiRollback(...args),
  },
}));

// Import wsManager AFTER mock so we get the jest-controlled version.
import { wsManager } from '@/shared/services/WebSocketManager';

// =============================================================================
// Fixtures
// =============================================================================

const PLATFORM: SystemNodePlatform = {
  id: 'plt-1',
  name: 'test-platform',
  enabled: true,
  public: false,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PUB_ACTIVE: SystemDiskImagePublication = {
  id: 'pub-active',
  platform_id: 'plt-1',
  account_id: 'acct-1',
  status: 'published',
  active: true,
  git_sha: 'abcdef1234567890abcdef1234567890abcdef12',
  git_sha_short: 'abcdef1',
  sha256: 'sha256fullhashactivepub0000000000000000000000000000000000000000000',
  sha256_short: 'sha256ac',
  arch: 'x86_64',
  size_bytes: 2 * 1024 * 1024 * 1024, // 2 GB
  attempt_count: 1,
  attestation_present: true,
  cosign_bundle_present: true,
  published_at: '2026-05-01T10:00:00Z',
  created_at: '2026-05-01T09:00:00Z',
  updated_at: '2026-05-01T10:00:00Z',
};

const PUB_RETIRED: SystemDiskImagePublication = {
  id: 'pub-retired',
  platform_id: 'plt-1',
  account_id: 'acct-1',
  status: 'retired',
  active: false,
  git_sha: 'deadbeef1234567890deadbeef1234567890dead',
  git_sha_short: 'deadbee',
  sha256: 'sha256fullhashretiredpub0000000000000000000000000000000000000000000',
  sha256_short: 'sha256re',
  arch: 'arm64',
  size_bytes: 512 * 1024, // 512 KB
  attempt_count: 2,
  attestation_present: false,
  cosign_bundle_present: false,
  retired_at: '2026-05-10T12:00:00Z',
  published_at: '2026-04-20T08:00:00Z',
  created_at: '2026-04-20T07:00:00Z',
  updated_at: '2026-05-10T12:00:00Z',
};

const PUB_FAILED: SystemDiskImagePublication = {
  id: 'pub-failed',
  platform_id: 'plt-1',
  account_id: 'acct-1',
  status: 'failed',
  active: false,
  git_sha: 'failedsha1234567890failedsha1234567890fa',
  git_sha_short: 'faileds',
  sha256: 'sha256fullhashfailedpub00000000000000000000000000000000000000000000',
  sha256_short: 'sha256fa',
  arch: 'x86_64',
  size_bytes: 0,
  attempt_count: 1,
  attestation_present: false,
  cosign_bundle_present: false,
  error_message: 'Cosign verification failed: no matching signature found',
  created_at: '2026-05-15T07:00:00Z',
  updated_at: '2026-05-15T07:30:00Z',
};

const PUB_PURGED: SystemDiskImagePublication = {
  id: 'pub-purged',
  platform_id: 'plt-1',
  account_id: 'acct-1',
  status: 'purged',
  active: false,
  git_sha: 'purgedsha1234567890purgedsha1234567890pu',
  git_sha_short: 'purgeds',
  sha256: 'sha256fullhashpurgedpub00000000000000000000000000000000000000000000',
  sha256_short: 'sha256pu',
  arch: 'x86_64',
  size_bytes: 1024,
  attempt_count: 1,
  attestation_present: false,
  cosign_bundle_present: false,
  created_at: '2026-03-01T00:00:00Z',
  updated_at: '2026-03-15T00:00:00Z',
};

const PUB_QUEUED: SystemDiskImagePublication = {
  id: 'pub-queued',
  platform_id: 'plt-1',
  account_id: 'acct-1',
  status: 'queued',
  active: false,
  git_sha: 'queuedsha1234567890queuedsha1234567890qu',
  git_sha_short: 'queueds',
  sha256: 'sha256fullhashqueuedpub00000000000000000000000000000000000000000000',
  sha256_short: 'sha256qu',
  arch: 'x86_64',
  size_bytes: 0,
  attempt_count: 1,
  attestation_present: false,
  cosign_bundle_present: false,
  created_at: '2026-06-01T00:00:00Z',
  updated_at: '2026-06-01T00:00:00Z',
};

// Helper: wrap in double envelope as expected by apiClient + extractPaginated
function paginatedEnvelope<T extends Record<string, unknown>>(data: T) {
  return {
    data: {
      success: true,
      data,
      meta: {
        current_page: 1,
        per_page: 50,
        total_count: Object.values(data).reduce<number>(
          (sum, v) => sum + (Array.isArray(v) ? v.length : 0),
          0,
        ),
        total_pages: 1,
        next_page: null,
        prev_page: null,
      },
    },
  };
}

// Helper: plain success envelope for the rollback POST
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

// =============================================================================
// Render helper
// =============================================================================

const renderTab = (platform: SystemNodePlatform = PLATFORM) =>
  render(
    <BrowserRouter>
      <DiskImageHistoryTab platform={platform} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('DiskImageHistoryTab', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockApiList.mockReset();
    mockApiRollback.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
    mockCurrentUser = { account: { id: 'acct-1' } };
    (wsManager.subscribe as jest.Mock).mockReset();
    (wsManager.subscribe as jest.Mock).mockReturnValue(() => undefined);
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows loading indicator while fetching publications', async () => {
    // Never resolve — component stays in loading state
    mockApiList.mockReturnValue(new Promise(() => undefined));

    renderTab();

    expect(screen.getByText('Loading…')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows empty-state message when there are no publications', async () => {
    mockApiList.mockResolvedValue({ publications: [] });

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByText(/No disk-image publications yet/i),
      ).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // List rendering
  // ---------------------------------------------------------------------------

  it('renders publication rows after fetch', async () => {
    mockApiList.mockResolvedValue({
      publications: [PUB_ACTIVE, PUB_RETIRED],
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_ACTIVE.git_sha_short)).toBeInTheDocument(),
    );
    expect(screen.getByText(PUB_RETIRED.git_sha_short)).toBeInTheDocument();
  });

  it('calls the correct API endpoint on mount', async () => {
    mockApiList.mockResolvedValue({ publications: [] });

    renderTab();

    await waitFor(() => expect(mockApiList).toHaveBeenCalledWith('plt-1'));
  });

  it('shows publication count badge when publications exist', async () => {
    mockApiList.mockResolvedValue({
      publications: [PUB_ACTIVE, PUB_RETIRED],
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('2')).toBeInTheDocument(),
    );
  });

  it('shows active badge on the active publication row', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_ACTIVE, PUB_RETIRED] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_ACTIVE.git_sha_short)).toBeInTheDocument(),
    );

    // The "active" badge should appear exactly once (only PUB_ACTIVE is active)
    expect(screen.getAllByText('active').length).toBe(1);
  });

  it('shows architecture badges for publications', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_ACTIVE, PUB_RETIRED] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_ACTIVE.git_sha_short)).toBeInTheDocument(),
    );

    expect(screen.getByText('x86_64')).toBeInTheDocument();
    expect(screen.getByText('arm64')).toBeInTheDocument();
  });

  it('shows the attestation shield icon when attestation_present is true', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_ACTIVE] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_ACTIVE.git_sha_short)).toBeInTheDocument(),
    );

    // The cosign attestation verified span has title text
    expect(screen.getByTitle('cosign attestation verified')).toBeInTheDocument();
  });

  it('shows retry indicator when attempt_count > 1', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_RETIRED] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_RETIRED.git_sha_short)).toBeInTheDocument(),
    );

    // PUB_RETIRED has attempt_count: 2
    expect(screen.getByText(/2 attempts/i)).toBeInTheDocument();
  });

  it('formats size_bytes as GB for large publications', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_ACTIVE] }); // 2 GB

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('2.00 GB')).toBeInTheDocument(),
    );
  });

  it('formats size_bytes as KB for small publications', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_RETIRED] }); // 512 KB

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('512.0 KB')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Status badge variants
  // ---------------------------------------------------------------------------

  it('renders published status as success variant', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_ACTIVE] });
    renderTab();
    await waitFor(() =>
      expect(screen.getByText('published')).toBeInTheDocument(),
    );
  });

  it('renders failed status for failed publication', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_FAILED] });
    renderTab();
    await waitFor(() =>
      expect(screen.getByText('failed')).toBeInTheDocument(),
    );
  });

  it('renders queued status for queued publication', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_QUEUED] });
    renderTab();
    await waitFor(() =>
      expect(screen.getByText('queued')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows error notification when list API call fails', async () => {
    mockApiList.mockRejectedValue(new Error('Network error'));

    renderTab();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Network error',
      }),
    );
  });

  it('shows generic error notification for non-Error rejections', async () => {
    mockApiList.mockRejectedValue('unexpected failure');

    renderTab();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load publication history',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Refresh button
  // ---------------------------------------------------------------------------

  it('refreshes publications when the refresh button is clicked', async () => {
    mockApiList.mockResolvedValue({ publications: [] });

    renderTab();

    // Wait for initial load to complete (loading spinner goes away)
    await waitFor(() =>
      expect(screen.getByText(/No disk-image publications yet/i)).toBeInTheDocument(),
    );

    expect(mockApiList).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByTitle('Refresh'));

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(2));
  });

  it('disables the refresh button while loading', async () => {
    let resolve: (v: { publications: SystemDiskImagePublication[] }) => void = () => undefined;
    mockApiList.mockReturnValue(
      new Promise<{ publications: SystemDiskImagePublication[] }>(r => { resolve = r; }),
    );

    renderTab();

    const refreshBtn = screen.getByTitle('Refresh');
    expect(refreshBtn).toBeDisabled();

    resolve({ publications: [] });
    await waitFor(() => expect(refreshBtn).not.toBeDisabled());
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse
  // ---------------------------------------------------------------------------

  it('expands row details when the chevron button is clicked', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_ACTIVE] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_ACTIVE.git_sha_short)).toBeInTheDocument(),
    );

    // Expand the row
    fireEvent.click(screen.getByTitle('Expand details'));

    // Full SHA-256 appears in the expanded panel
    await waitFor(() =>
      expect(screen.getByText(PUB_ACTIVE.sha256)).toBeInTheDocument(),
    );
    // Full git SHA
    expect(screen.getByText(PUB_ACTIVE.git_sha)).toBeInTheDocument();
    // Attestation detail
    expect(screen.getByText('present')).toBeInTheDocument();
    expect(screen.getByText(/cosign bundle/i)).toBeInTheDocument();
  });

  it('collapses row details on second click', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_ACTIVE] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_ACTIVE.git_sha_short)).toBeInTheDocument(),
    );

    // Expand then collapse
    fireEvent.click(screen.getByTitle('Expand details'));
    await waitFor(() =>
      expect(screen.getByText(PUB_ACTIVE.sha256)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() =>
      expect(screen.queryByText(PUB_ACTIVE.sha256)).not.toBeInTheDocument(),
    );
  });

  it('allows multiple rows to be expanded simultaneously', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_ACTIVE, PUB_RETIRED] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_ACTIVE.git_sha_short)).toBeInTheDocument(),
    );

    const expandButtons = screen.getAllByTitle('Expand details');
    fireEvent.click(expandButtons[0]);
    fireEvent.click(expandButtons[1]);

    await waitFor(() => {
      expect(screen.getByText(PUB_ACTIVE.sha256)).toBeInTheDocument();
      expect(screen.getByText(PUB_RETIRED.sha256)).toBeInTheDocument();
    });
  });

  it('shows error_message in expanded row for failed publication', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_FAILED] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_FAILED.git_sha_short)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(
        screen.getByText('Cosign verification failed: no matching signature found'),
      ).toBeInTheDocument(),
    );
  });

  it('shows oci_ref in expanded row when present', async () => {
    const pubWithOci: SystemDiskImagePublication = {
      ...PUB_ACTIVE,
      id: 'pub-oci',
      oci_ref: 'ghcr.io/org/repo:sha-abcdef1',
    };
    mockApiList.mockResolvedValue({ publications: [pubWithOci] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(pubWithOci.git_sha_short)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('ghcr.io/org/repo:sha-abcdef1')).toBeInTheDocument(),
    );
  });

  it('shows webhook_label in expanded row when present', async () => {
    const pubWithWebhook: SystemDiskImagePublication = {
      ...PUB_ACTIVE,
      id: 'pub-webhook',
      webhook_id: 'wh-1',
      webhook_label: 'github-main-push',
    };
    mockApiList.mockResolvedValue({ publications: [pubWithWebhook] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(pubWithWebhook.git_sha_short)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('github-main-push')).toBeInTheDocument(),
    );
  });

  it('shows EntityLink for triggered_by_worker_id in expanded row', async () => {
    const pubWithWorker: SystemDiskImagePublication = {
      ...PUB_ACTIVE,
      id: 'pub-worker',
      triggered_by_worker_id: 'worker-42',
    };
    mockApiList.mockResolvedValue({ publications: [pubWithWorker] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(pubWithWorker.git_sha_short)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('worker-42')).toBeInTheDocument(),
    );
  });

  it('shows firmware_ref in expanded row when present', async () => {
    const pubWithFirmware: SystemDiskImagePublication = {
      ...PUB_ACTIVE,
      id: 'pub-firmware',
      firmware_ref: 'uefi-v2.0.0',
    };
    mockApiList.mockResolvedValue({ publications: [pubWithFirmware] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(pubWithFirmware.git_sha_short)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('uefi-v2.0.0')).toBeInTheDocument(),
    );
  });

  it('shows — for firmware_ref when absent', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_ACTIVE] }); // no firmware_ref

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_ACTIVE.git_sha_short)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('—')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Activate / Rollback button visibility
  // ---------------------------------------------------------------------------

  it('shows Activate button for non-active, non-purged, non-failed, non-queued published publications', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_ACTIVE, PUB_RETIRED] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_ACTIVE.git_sha_short)).toBeInTheDocument(),
    );

    // PUB_RETIRED is retired (not active, not purged, not failed, not queued)
    // => should have Activate button
    expect(screen.getByRole('button', { name: /activate/i })).toBeInTheDocument();
  });

  it('does NOT show Activate button for the active publication', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_ACTIVE] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_ACTIVE.git_sha_short)).toBeInTheDocument(),
    );

    // PUB_ACTIVE is active — no Activate button
    expect(screen.queryByRole('button', { name: /^activate$/i })).not.toBeInTheDocument();
  });

  it('does NOT show Activate button for purged publications', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_PURGED] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_PURGED.git_sha_short)).toBeInTheDocument(),
    );

    expect(screen.queryByRole('button', { name: /^activate$/i })).not.toBeInTheDocument();
  });

  it('does NOT show Activate button for failed publications', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_FAILED] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_FAILED.git_sha_short)).toBeInTheDocument(),
    );

    expect(screen.queryByRole('button', { name: /^activate$/i })).not.toBeInTheDocument();
  });

  it('does NOT show Activate button for queued publications', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_QUEUED] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_QUEUED.git_sha_short)).toBeInTheDocument(),
    );

    expect(screen.queryByRole('button', { name: /^activate$/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Permission gating — canRollback = false
  // ---------------------------------------------------------------------------

  it('hides Activate button when user lacks rollback permission', async () => {
    // Override mockHasPermission to deny rollback permission
    mockHasPermission.mockReturnValue(false);

    mockApiList.mockResolvedValue({ publications: [PUB_RETIRED] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(PUB_RETIRED.git_sha_short)).toBeInTheDocument(),
    );

    expect(screen.queryByRole('button', { name: /^activate$/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Rollback confirmation modal
  // ---------------------------------------------------------------------------

  // Helper: open the confirm modal by clicking the row Activate button
  async function openConfirmModal() {
    // The row Activate button appears for PUB_RETIRED
    const activateBtns = await waitFor(() => screen.getAllByRole('button', { name: /activate/i }));
    // Find the row-level Activate button (not inside a modal heading)
    const rowActivateBtn = activateBtns.find(
      btn => !btn.closest('[class*="fixed"]'),
    );
    if (!rowActivateBtn) throw new Error('Row Activate button not found');
    fireEvent.click(rowActivateBtn);
    await waitFor(() =>
      expect(screen.getByText('Activate publication?')).toBeInTheDocument(),
    );
  }

  // Helper: get the confirm button inside the modal
  function getModalConfirmBtn() {
    const modal = document.querySelector('[class*="fixed"]');
    if (!modal) throw new Error('Modal not found');
    return within(modal as HTMLElement).getByRole('button', { name: /^activate$/i });
  }

  it('opens the rollback confirmation modal when Activate is clicked', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_RETIRED] });

    renderTab();

    await openConfirmModal();

    // Modal shows the git_sha_short and sha256_short
    expect(screen.getAllByText(PUB_RETIRED.git_sha_short).length).toBeGreaterThan(0);
    expect(screen.getByText(/7 days/i)).toBeInTheDocument();
  });

  it('closes the modal when Cancel is clicked', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_RETIRED] });

    renderTab();

    await openConfirmModal();

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByText('Activate publication?')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Rollback execution
  // ---------------------------------------------------------------------------

  it('calls rollback API with correct platform and publication IDs on confirm', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_RETIRED] });
    mockApiRollback.mockResolvedValue({
      activated_publication_id: PUB_RETIRED.id,
    });

    renderTab();

    await openConfirmModal();

    fireEvent.click(getModalConfirmBtn());

    await waitFor(() =>
      expect(mockApiRollback).toHaveBeenCalledWith('plt-1', 'pub-retired'),
    );
  });

  it('shows success notification after successful rollback', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_RETIRED] });
    mockApiRollback.mockResolvedValue({
      activated_publication_id: PUB_RETIRED.id,
    });

    renderTab();

    await openConfirmModal();
    fireEvent.click(getModalConfirmBtn());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Activated publication for git_sha ${PUB_RETIRED.git_sha_short}`,
      }),
    );
  });

  it('closes the modal after successful rollback', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_RETIRED] });
    mockApiRollback.mockResolvedValue({
      activated_publication_id: PUB_RETIRED.id,
    });

    renderTab();

    await openConfirmModal();
    fireEvent.click(getModalConfirmBtn());

    await waitFor(() =>
      expect(screen.queryByText('Activate publication?')).not.toBeInTheDocument(),
    );
  });

  it('refreshes the list after successful rollback', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_RETIRED] });
    mockApiRollback.mockResolvedValue({
      activated_publication_id: PUB_RETIRED.id,
    });

    renderTab();

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));

    await openConfirmModal();
    fireEvent.click(getModalConfirmBtn());

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(2));
  });

  it('shows error notification when rollback fails', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_RETIRED] });
    mockApiRollback.mockRejectedValue(new Error('Rollback blocked'));

    renderTab();

    await openConfirmModal();
    fireEvent.click(getModalConfirmBtn());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Rollback blocked',
      }),
    );
  });

  it('shows generic error notification for non-Error rollback failure', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_RETIRED] });
    mockApiRollback.mockRejectedValue('something bad');

    renderTab();

    await openConfirmModal();
    fireEvent.click(getModalConfirmBtn());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Rollback failed',
      }),
    );
  });

  it('disables the Activate button in modal while submitting', async () => {
    mockApiList.mockResolvedValue({ publications: [PUB_RETIRED] });
    // Never resolves — stays in submitting state
    mockApiRollback.mockReturnValue(new Promise(() => undefined));

    renderTab();

    await openConfirmModal();

    const confirmBtn = getModalConfirmBtn();
    fireEvent.click(confirmBtn);

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /activating…/i })).toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: /activating…/i })).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // WebSocket live updates
  // ---------------------------------------------------------------------------

  it('subscribes to SystemFleetChannel with the account_id', async () => {
    mockApiList.mockResolvedValue({ publications: [] });

    renderTab();

    await waitFor(() => expect(wsManager.subscribe).toHaveBeenCalledWith(
      expect.objectContaining({
        channel: 'SystemFleetChannel',
        params: { account_id: 'acct-1' },
      }),
    ));
  });

  it('refreshes on system.disk_image_published WS event for matching platform', async () => {
    mockApiList.mockResolvedValue({ publications: [] });

    let capturedOnMessage: ((data: unknown) => void) | undefined;
    (wsManager.subscribe as jest.Mock).mockImplementation(
      ({ onMessage }: { onMessage: (data: unknown) => void }) => {
        capturedOnMessage = onMessage;
        return () => undefined;
      },
    );

    renderTab();

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));

    // Fire relevant WS event for this platform
    capturedOnMessage?.({
      kind: 'system.disk_image_published',
      payload: { platform_id: 'plt-1' },
    });

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(2));
  });

  it('refreshes on system.disk_image_rolled_back WS event for matching platform', async () => {
    mockApiList.mockResolvedValue({ publications: [] });

    let capturedOnMessage: ((data: unknown) => void) | undefined;
    (wsManager.subscribe as jest.Mock).mockImplementation(
      ({ onMessage }: { onMessage: (data: unknown) => void }) => {
        capturedOnMessage = onMessage;
        return () => undefined;
      },
    );

    renderTab();

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));

    capturedOnMessage?.({
      kind: 'system.disk_image_rolled_back',
      payload: { platform_id: 'plt-1' },
    });

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(2));
  });

  it('refreshes on system.disk_image_retention_swept WS event for matching platform', async () => {
    mockApiList.mockResolvedValue({ publications: [] });

    let capturedOnMessage: ((data: unknown) => void) | undefined;
    (wsManager.subscribe as jest.Mock).mockImplementation(
      ({ onMessage }: { onMessage: (data: unknown) => void }) => {
        capturedOnMessage = onMessage;
        return () => undefined;
      },
    );

    renderTab();

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));

    capturedOnMessage?.({
      kind: 'system.disk_image_retention_swept',
      payload: { platform_id: 'plt-1' },
    });

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(2));
  });

  it('does NOT refresh on WS event for a different platform', async () => {
    mockApiList.mockResolvedValue({ publications: [] });

    let capturedOnMessage: ((data: unknown) => void) | undefined;
    (wsManager.subscribe as jest.Mock).mockImplementation(
      ({ onMessage }: { onMessage: (data: unknown) => void }) => {
        capturedOnMessage = onMessage;
        return () => undefined;
      },
    );

    renderTab();

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));

    // Different platform_id — should not trigger refresh
    capturedOnMessage?.({
      kind: 'system.disk_image_published',
      payload: { platform_id: 'plt-OTHER' },
    });

    // Still only the initial call
    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));
  });

  it('does NOT refresh on irrelevant WS event kinds', async () => {
    mockApiList.mockResolvedValue({ publications: [] });

    let capturedOnMessage: ((data: unknown) => void) | undefined;
    (wsManager.subscribe as jest.Mock).mockImplementation(
      ({ onMessage }: { onMessage: (data: unknown) => void }) => {
        capturedOnMessage = onMessage;
        return () => undefined;
      },
    );

    renderTab();

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));

    capturedOnMessage?.({
      kind: 'system.node_enrolled',
      payload: { platform_id: 'plt-1' },
    });

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));
  });

  it('refreshes on system.disk_image_publish_failed WS event', async () => {
    mockApiList.mockResolvedValue({ publications: [] });

    let capturedOnMessage: ((data: unknown) => void) | undefined;
    (wsManager.subscribe as jest.Mock).mockImplementation(
      ({ onMessage }: { onMessage: (data: unknown) => void }) => {
        capturedOnMessage = onMessage;
        return () => undefined;
      },
    );

    renderTab();

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));

    capturedOnMessage?.({
      kind: 'system.disk_image_publish_failed',
      payload: { platform_id: 'plt-1' },
    });

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(2));
  });

  it('does not subscribe to WS when accountId is absent', async () => {
    mockApiList.mockResolvedValue({ publications: [] });

    // Set currentUser to null so accountId is undefined
    mockCurrentUser = null;

    render(
      <BrowserRouter>
        <DiskImageHistoryTab platform={PLATFORM} />
      </BrowserRouter>,
    );

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));
    expect(wsManager.subscribe).not.toHaveBeenCalled();
  });
});
