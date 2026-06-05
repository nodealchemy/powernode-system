import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PackageRepositoriesTab } from './PackageRepositoriesTab';

// =============================================================================
// API mocks — the component calls packageRepositoriesApi and architecturesApi
// which are thin wrappers around apiClient.
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

// Heavy child components — mock them out so tests stay behavioural at this
// level without dragging in their own API surface.
jest.mock('@system/features/system/components/packages/PackageRepositoryFormModal', () => ({
  PackageRepositoryFormModal: ({
    open,
    onClose,
    onSaved,
    repository,
  }: {
    open: boolean;
    onClose: () => void;
    onSaved: () => void;
    repository: { id: string; name: string } | null;
  }) =>
    open ? (
      <div data-testid="pkg-repo-form-modal">
        <span data-testid="form-modal-repo-name">{repository?.name ?? 'new'}</span>
        <button data-testid="form-modal-close" onClick={onClose}>
          Close
        </button>
        <button data-testid="form-modal-save" onClick={onSaved}>
          Save
        </button>
      </div>
    ) : null,
}));

jest.mock('@system/features/system/components/packages/PackageBrowser', () => ({
  PackageBrowser: ({ repository }: { repository: { id: string; name: string } }) => (
    <div data-testid={`package-browser-${repository.id}`}>
      PackageBrowser for {repository.name}
    </div>
  ),
}));

jest.mock('@system/features/system/components/packages/CreateModuleFromPackageModal', () => ({
  CreateModuleFromPackageModal: ({
    open,
    onClose,
  }: {
    open: boolean;
    onClose: () => void;
  }) =>
    open ? (
      <div data-testid="create-module-modal">
        <button data-testid="create-module-close" onClick={onClose}>
          Close
        </button>
      </div>
    ) : null,
}));

// ResponsiveListContainer — keep the real implementation so Desktop/Mobile
// slot rendering is exercised, but suppress the InfiniteScrollSentinel which
// relies on IntersectionObserver not available in jsdom.
jest.mock('@system/features/system/components/shared/InfiniteScrollSentinel', () => ({
  InfiniteScrollSentinel: () => null,
}));

// =============================================================================
// Fixtures
// =============================================================================

/** Double-envelope helper: AxiosResponse body wrapping the payload. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const REPO_APT = {
  id: 'repo-1',
  name: 'ubuntu-noble',
  description: 'Ubuntu 24.04 Noble',
  kind: 'apt' as const,
  visibility: 'account' as const,
  base_url: 'http://archive.ubuntu.com/ubuntu',
  architectures: ['amd64'],
  priority: 100,
  enabled: true,
  sync_status: 'idle' as const,
  last_synced_at: '2026-06-01T10:00:00Z',
  package_count: 50000,
  shared: false,
  embedding_pending_count: 0,
  node_platform_ids: [],
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-06-01T10:00:00Z',
};

const REPO_RPM = {
  id: 'repo-2',
  name: 'centos-stream-9',
  kind: 'rpm' as const,
  visibility: 'shared' as const,
  base_url: 'https://mirror.centos.org/centos/9-stream',
  architectures: ['x86_64'],
  priority: 50,
  enabled: true,
  sync_status: 'syncing' as const,
  package_count: 12000,
  shared: true,
  embedding_pending_count: 120,
  node_platform_ids: [],
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-06-01T00:00:00Z',
};

const REPO_FAILED = {
  id: 'repo-3',
  name: 'broken-repo',
  kind: 'dnf' as const,
  visibility: 'account' as const,
  base_url: 'http://bad.example.com/dnf',
  architectures: [],
  priority: 10,
  enabled: false,
  sync_status: 'failed' as const,
  package_count: 0,
  shared: false,
  node_platform_ids: [],
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const ARCH_AMD64 = {
  id: 'arch-1',
  name: 'amd64',
  display_name: 'x86-64',
  family: 'x86' as const,
  apt_name: 'amd64',
  rpm_name: 'x86_64',
  enabled: true,
  is_canonical: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

/** Build the AxiosResponse shape that packageRepositoriesApi.list() resolves. */
function reposResponse(repos: unknown[]) {
  return envelope({ package_repositories: repos });
}

/** Build the AxiosResponse shape that architecturesApi.getArchitectures() resolves. */
function archsResponse(archs: unknown[]) {
  return envelope({ node_architectures: archs });
}

// =============================================================================
// Render helper
// =============================================================================

const renderTab = (props: { onActionsReady?: (a: { openCreate: () => void } | null) => void } = {}) =>
  render(
    <BrowserRouter>
      <PackageRepositoriesTab {...props} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('PackageRepositoriesTab', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();

    // Default: architectures endpoint returns one arch.
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/node_architectures') return Promise.resolve(archsResponse([ARCH_AMD64]));
      if (url === '/system/package_repositories') return Promise.resolve(reposResponse([REPO_APT, REPO_RPM]));
      return Promise.reject(new Error(`Unexpected GET ${url}`));
    });
  });

  // ---------------------------------------------------------------------------
  // Render + loading states
  // ---------------------------------------------------------------------------

  it('renders the Package Repositories heading', async () => {
    mockGet.mockImplementation(() => Promise.resolve(reposResponse([])));
    renderTab();
    expect(screen.getByText('Package Repositories')).toBeInTheDocument();
  });

  it('fetches repositories from the correct endpoint on mount', async () => {
    renderTab();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/package_repositories', { params: undefined }),
    );
  });

  it('fetches canonical enabled architectures on mount', async () => {
    renderTab();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', {
        params: { is_canonical: 'true', enabled: 'true' },
      }),
    );
  });

  it('renders a row for each repository returned by the API', async () => {
    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('package-repo-row-repo-1')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('package-repo-row-repo-2')).toBeInTheDocument();
  });

  it('shows the empty state when no repositories exist', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/package_repositories') return Promise.resolve(reposResponse([]));
      return Promise.resolve(archsResponse([]));
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('No package repositories')).toBeInTheDocument(),
    );
    expect(screen.getByText(/Register an apt or rpm source/)).toBeInTheDocument();
  });

  it('shows an error notification when the list fetch fails', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/package_repositories') return Promise.reject(new Error('network error'));
      return Promise.resolve(archsResponse([]));
    });

    renderTab();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load package repositories',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Row content — name, kind, visibility badges, sync badge
  // ---------------------------------------------------------------------------

  it('displays repository name, base_url, and kind in the row', async () => {
    renderTab();

    const row = await waitFor(() => screen.getByTestId('package-repo-row-repo-1'));
    expect(within(row).getByText('ubuntu-noble')).toBeInTheDocument();
    expect(within(row).getByText('http://archive.ubuntu.com/ubuntu')).toBeInTheDocument();
    expect(within(row).getByText('apt')).toBeInTheDocument();
  });

  it('renders "account" visibility badge for non-shared repos', async () => {
    renderTab();

    const row = await waitFor(() => screen.getByTestId('package-repo-row-repo-1'));
    expect(within(row).getByText('account')).toBeInTheDocument();
  });

  it('renders "shared" visibility badge for shared repos', async () => {
    renderTab();

    const row = await waitFor(() => screen.getByTestId('package-repo-row-repo-2'));
    expect(within(row).getByText('shared')).toBeInTheDocument();
  });

  it('renders "idle" sync status badge correctly', async () => {
    renderTab();

    const row = await waitFor(() => screen.getByTestId('package-repo-row-repo-1'));
    expect(within(row).getByText('idle')).toBeInTheDocument();
  });

  it('renders "syncing" sync status badge for in-progress repos', async () => {
    renderTab();

    const row = await waitFor(() => screen.getByTestId('package-repo-row-repo-2'));
    expect(within(row).getByText('syncing')).toBeInTheDocument();
  });

  it('renders "failed" sync status badge', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/package_repositories') return Promise.resolve(reposResponse([REPO_FAILED]));
      return Promise.resolve(archsResponse([]));
    });

    renderTab();

    const row = await waitFor(() => screen.getByTestId('package-repo-row-repo-3'));
    expect(within(row).getByText('failed')).toBeInTheDocument();
  });

  it('shows package_count formatted with toLocaleString', async () => {
    renderTab();

    await waitFor(() => screen.getByTestId('package-repo-row-repo-1'));
    // 50000 formatted — accept locale-dependent separator
    expect(screen.getByText((50000).toLocaleString())).toBeInTheDocument();
  });

  it('shows "embedded" label when embedding_pending_count is 0', async () => {
    renderTab();

    const row = await waitFor(() => screen.getByTestId('package-repo-row-repo-1'));
    expect(within(row).getByText('embedded')).toBeInTheDocument();
  });

  it('shows pending embedding count when embedding_pending_count > 0', async () => {
    renderTab();

    const row = await waitFor(() => screen.getByTestId('package-repo-row-repo-2'));
    expect(within(row).getByText((120).toLocaleString())).toBeInTheDocument();
  });

  it('shows "—" when embedding_pending_count is absent', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/package_repositories')
        return Promise.resolve(reposResponse([REPO_FAILED]));
      return Promise.resolve(archsResponse([]));
    });

    renderTab();

    const row = await waitFor(() => screen.getByTestId('package-repo-row-repo-3'));
    expect(within(row).getByText('—')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Search filter
  // ---------------------------------------------------------------------------

  it('filters rows by name via the search input', async () => {
    renderTab();

    await waitFor(() => screen.getByTestId('package-repo-row-repo-1'));
    const search = screen.getByTestId('package-repo-filter-search');
    fireEvent.change(search, { target: { value: 'centos' } });

    await waitFor(() =>
      expect(screen.queryByTestId('package-repo-row-repo-1')).not.toBeInTheDocument(),
    );
    expect(screen.getByTestId('package-repo-row-repo-2')).toBeInTheDocument();
  });

  it('filters rows by base_url via the search input', async () => {
    renderTab();

    await waitFor(() => screen.getByTestId('package-repo-row-repo-1'));
    const search = screen.getByTestId('package-repo-filter-search');
    fireEvent.change(search, { target: { value: 'archive.ubuntu' } });

    await waitFor(() =>
      expect(screen.queryByTestId('package-repo-row-repo-2')).not.toBeInTheDocument(),
    );
    expect(screen.getByTestId('package-repo-row-repo-1')).toBeInTheDocument();
  });

  it('shows no rows when search does not match anything', async () => {
    renderTab();

    await waitFor(() => screen.getByTestId('package-repo-row-repo-1'));
    const search = screen.getByTestId('package-repo-filter-search');
    fireEvent.change(search, { target: { value: 'zzz-no-match-zzz' } });

    await waitFor(() =>
      expect(screen.queryByTestId('package-repo-row-repo-1')).not.toBeInTheDocument(),
    );
    expect(screen.queryByTestId('package-repo-row-repo-2')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Row selection → PackageBrowser
  // ---------------------------------------------------------------------------

  it('shows PackageBrowser when a row is clicked', async () => {
    renderTab();

    const row = await waitFor(() => screen.getByTestId('package-repo-row-repo-1'));
    fireEvent.click(row);

    await waitFor(() =>
      expect(screen.getByTestId('package-browser-repo-1')).toBeInTheDocument(),
    );
    expect(screen.getByText('PackageBrowser for ubuntu-noble')).toBeInTheDocument();
  });

  it('switches PackageBrowser when a different row is clicked', async () => {
    renderTab();

    const row1 = await waitFor(() => screen.getByTestId('package-repo-row-repo-1'));
    fireEvent.click(row1);

    await waitFor(() => screen.getByTestId('package-browser-repo-1'));

    const row2 = screen.getByTestId('package-repo-row-repo-2');
    fireEvent.click(row2);

    await waitFor(() =>
      expect(screen.getByTestId('package-browser-repo-2')).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('package-browser-repo-1')).not.toBeInTheDocument();
  });

  it('does NOT show PackageBrowser before a row is selected', async () => {
    renderTab();

    await waitFor(() => screen.getByTestId('package-repo-row-repo-1'));
    expect(screen.queryByTestId('package-browser-repo-1')).not.toBeInTheDocument();
    expect(screen.queryByTestId('package-browser-repo-2')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Edit action → PackageRepositoryFormModal (pre-filled)
  // ---------------------------------------------------------------------------

  it('opens the form modal pre-filled when the edit button is clicked', async () => {
    renderTab();

    // Both Desktop and Mobile render the same testid — pick the first (desktop).
    await waitFor(() => screen.getAllByTestId('package-repo-edit-repo-1'));
    fireEvent.click(screen.getAllByTestId('package-repo-edit-repo-1')[0]);

    await waitFor(() =>
      expect(screen.getByTestId('pkg-repo-form-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('form-modal-repo-name')).toHaveTextContent('ubuntu-noble');
  });

  it('closes the form modal when onClose is called', async () => {
    renderTab();

    await waitFor(() => screen.getAllByTestId('package-repo-edit-repo-1'));
    fireEvent.click(screen.getAllByTestId('package-repo-edit-repo-1')[0]);

    await waitFor(() => screen.getByTestId('pkg-repo-form-modal'));
    fireEvent.click(screen.getByTestId('form-modal-close'));

    await waitFor(() =>
      expect(screen.queryByTestId('pkg-repo-form-modal')).not.toBeInTheDocument(),
    );
  });

  it('refreshes the list after the form modal saves', async () => {
    const secondLoad = reposResponse([REPO_APT, REPO_RPM]);
    let callCount = 0;
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/package_repositories') {
        callCount++;
        return Promise.resolve(secondLoad);
      }
      return Promise.resolve(archsResponse([]));
    });

    renderTab();

    await waitFor(() => screen.getAllByTestId('package-repo-edit-repo-1'));
    fireEvent.click(screen.getAllByTestId('package-repo-edit-repo-1')[0]);

    await waitFor(() => screen.getByTestId('form-modal-save'));
    const callsBefore = callCount;
    fireEvent.click(screen.getByTestId('form-modal-save'));

    await waitFor(() => expect(callCount).toBeGreaterThan(callsBefore));
  });

  // ---------------------------------------------------------------------------
  // Create action via onActionsReady callback
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with an openCreate function when canCreate is true', async () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(onActionsReady).toHaveBeenCalledWith(
        expect.objectContaining({ openCreate: expect.any(Function) }),
      ),
    );
  });

  it('opens the create form modal (repository=null) via the onActionsReady callback', async () => {
    let capturedActions: { openCreate: () => void } | null = null;
    const onActionsReady = jest.fn((actions) => {
      capturedActions = actions;
    });
    renderTab({ onActionsReady });

    await waitFor(() => expect(capturedActions).not.toBeNull());

    capturedActions!.openCreate();

    await waitFor(() =>
      expect(screen.getByTestId('pkg-repo-form-modal')).toBeInTheDocument(),
    );
    // For create, repository prop is null → name slot shows 'new'
    expect(screen.getByTestId('form-modal-repo-name')).toHaveTextContent('new');
  });

  it('calls onActionsReady(null) on unmount', async () => {
    const onActionsReady = jest.fn();
    const { unmount } = renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mockClear();
    unmount();
    expect(onActionsReady).toHaveBeenCalledWith(null);
  });

  // ---------------------------------------------------------------------------
  // Sync action
  // ---------------------------------------------------------------------------

  it('calls the sync endpoint and refreshes the list', async () => {
    mockPost.mockResolvedValueOnce(
      envelope({ ok: true, upserted: 100, obsoleted: 5, package_count: 50000 }),
    );

    let repoCallCount = 0;
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/package_repositories') {
        repoCallCount++;
        return Promise.resolve(reposResponse([REPO_APT, REPO_RPM]));
      }
      return Promise.resolve(archsResponse([ARCH_AMD64]));
    });

    renderTab();

    // Both Desktop and Mobile render the same testid — pick the first.
    await waitFor(() => screen.getAllByTestId('package-repo-sync-repo-1'));
    const callsBefore = repoCallCount;
    fireEvent.click(screen.getAllByTestId('package-repo-sync-repo-1')[0]);

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/package_repositories/repo-1/sync',
        {},
      ),
    );
    await waitFor(() => expect(repoCallCount).toBeGreaterThan(callsBefore));
  });

  // ---------------------------------------------------------------------------
  // Delete: arm-and-confirm pattern
  // ---------------------------------------------------------------------------

  it('first delete click arms (does NOT call the delete API)', async () => {
    renderTab();

    // Both Desktop and Mobile render the same testid — pick the first.
    await waitFor(() => screen.getAllByTestId('package-repo-delete-repo-1'));
    fireEvent.click(screen.getAllByTestId('package-repo-delete-repo-1')[0]);

    // Still no DELETE call — only armed
    expect(mockDelete).not.toHaveBeenCalled();
  });

  it('second delete click commits the delete and refreshes the list', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    let repoCallCount = 0;
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/package_repositories') {
        repoCallCount++;
        return Promise.resolve(reposResponse([REPO_APT, REPO_RPM]));
      }
      return Promise.resolve(archsResponse([ARCH_AMD64]));
    });

    renderTab();

    // Both Desktop and Mobile render the same testid — pick the first (desktop).
    await waitFor(() => screen.getAllByTestId('package-repo-delete-repo-1'));
    const deleteBtn = screen.getAllByTestId('package-repo-delete-repo-1')[0];

    // First click — arm
    fireEvent.click(deleteBtn);
    expect(mockDelete).not.toHaveBeenCalled();

    // Second click — confirm
    const callsBefore = repoCallCount;
    fireEvent.click(deleteBtn);

    await waitFor(() =>
      expect(mockDelete).toHaveBeenCalledWith('/system/package_repositories/repo-1'),
    );
    await waitFor(() => expect(repoCallCount).toBeGreaterThan(callsBefore));
  });

  it('deleting the selected repo deselects it (hides PackageBrowser)', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    mockGet.mockImplementation((url: string) => {
      if (url === '/system/package_repositories')
        return Promise.resolve(reposResponse([REPO_APT, REPO_RPM]));
      return Promise.resolve(archsResponse([ARCH_AMD64]));
    });

    renderTab();

    // Select a repo first
    const row = await waitFor(() => screen.getByTestId('package-repo-row-repo-1'));
    fireEvent.click(row);
    await waitFor(() => screen.getByTestId('package-browser-repo-1'));

    // Arm + confirm delete — both Desktop and Mobile share the testid; pick first.
    const deleteBtn = screen.getAllByTestId('package-repo-delete-repo-1')[0];
    fireEvent.click(deleteBtn);
    fireEvent.click(deleteBtn);

    await waitFor(() => expect(mockDelete).toHaveBeenCalled());
    await waitFor(() =>
      expect(screen.queryByTestId('package-browser-repo-1')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Action buttons are not rendered outside the actions cell (stopPropagation)
  // ---------------------------------------------------------------------------

  it('clicking the actions cell does not also trigger row selection', async () => {
    renderTab();

    await waitFor(() => screen.getAllByTestId('package-repo-edit-repo-1'));

    // Click the edit button (inside the stopPropagation cell) — pick first (desktop).
    fireEvent.click(screen.getAllByTestId('package-repo-edit-repo-1')[0]);

    // The form modal opens — PackageBrowser should NOT appear (row not selected)
    await waitFor(() => screen.getByTestId('pkg-repo-form-modal'));
    expect(screen.queryByTestId('package-browser-repo-1')).not.toBeInTheDocument();
  });
});
