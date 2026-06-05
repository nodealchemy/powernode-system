import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PackageBrowser } from './PackageBrowser';
import type {
  SystemPackageRepository,
  SystemPackage,
  PackageDiscoverResult,
} from '@system/features/system/services/api/packageRepositoriesApi';
import type { MultiSelectOption } from '@/shared/components/ui/MultiSelect';

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

// =============================================================================
// Fixtures
// =============================================================================

const REPO: SystemPackageRepository = {
  id: 'repo-1',
  name: 'ubuntu-noble',
  kind: 'apt',
  visibility: 'account',
  base_url: 'http://archive.ubuntu.com/ubuntu',
  architectures: ['amd64', 'arm64'],
  priority: 0,
  enabled: true,
  sync_status: 'idle',
  package_count: 100,
  shared: false,
  node_platform_ids: [],
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const REPO_EMPTY: SystemPackageRepository = {
  ...REPO,
  id: 'repo-empty',
  package_count: 0,
};

const PKG_A: SystemPackage = {
  id: 'pkg-a',
  name: 'nginx',
  version: '1.24.0',
  architecture: 'amd64',
  section: 'web',
  summary: 'high performance web server',
  license: 'BSD',
  provides_names: ['httpd', 'web-server'],
  package_repository_id: 'repo-1',
};

const PKG_B: SystemPackage = {
  id: 'pkg-b',
  name: 'curl',
  version: '8.5.0',
  architecture: 'amd64',
  section: 'net',
  summary: 'command line tool for transferring data',
  package_repository_id: 'repo-1',
};

const PKG_SIMILARITY: SystemPackage = {
  id: 'pkg-c',
  name: 'varnish',
  version: '7.4.0',
  architecture: 'amd64',
  summary: 'reverse proxy caching server',
  similarity: 0.87,
  package_repository_id: 'repo-1',
};

const ARCH_OPTIONS: MultiSelectOption[] = [
  { value: 'amd64', label: 'amd64' },
  { value: 'arm64', label: 'arm64' },
];

// =============================================================================
// Envelope helpers
// =============================================================================

// The packagesApi.search method calls apiClient.get and then unwraps via
// extractData: response.data.data.packages + response.data.data.meta
function searchEnvelope(
  packages: SystemPackage[],
  opts?: { total?: number | null; page?: number; per_page?: number; next_page?: number | null }
) {
  const total = opts?.total ?? packages.length;
  const page = opts?.page ?? 1;
  const per_page = opts?.per_page ?? 30;
  const next_page = opts?.next_page ?? null;
  return {
    data: {
      success: true,
      data: {
        packages,
        meta: {
          total,
          page,
          per_page,
          mode: 'lexical' as const,
          applied_filters: {},
        },
      },
    },
  };
}

// packagesApi.discoverByIntent calls apiClient.post and unwraps via extractData:
// response.data.data = PackageDiscoverResult
function discoverEnvelope(result: PackageDiscoverResult) {
  return {
    data: {
      success: true,
      data: result,
    },
  };
}

// =============================================================================
// Render helper
// =============================================================================

interface RenderProps {
  repository?: SystemPackageRepository;
  canCreateModule?: boolean;
  onCreateModule?: jest.Mock;
  architectureOptions?: MultiSelectOption[];
}

function renderBrowser(props: RenderProps = {}) {
  const {
    repository = REPO,
    canCreateModule = false,
    onCreateModule = jest.fn(),
    architectureOptions = ARCH_OPTIONS,
  } = props;

  return render(
    <BrowserRouter>
      <PackageBrowser
        repository={repository}
        canCreateModule={canCreateModule}
        onCreateModule={onCreateModule}
        architectureOptions={architectureOptions}
      />
    </BrowserRouter>
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('PackageBrowser', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    mockGet.mockReset();
    mockPost.mockReset();
    mockAddNotification.mockReset();
  });

  afterEach(() => {
    jest.runAllTimers();
    jest.useRealTimers();
  });

  // ============================================================
  // Browse mode — render states
  // ============================================================

  describe('browse mode — render states', () => {
    it('shows loading state while fetching', async () => {
      // Never resolves during the loading check
      mockGet.mockReturnValue(new Promise(() => {}));
      renderBrowser();

      expect(screen.getByText('Searching…')).toBeInTheDocument();
    });

    it('renders package list after successful fetch', async () => {
      mockGet.mockResolvedValue(searchEnvelope([PKG_A, PKG_B]));
      renderBrowser();

      await waitFor(() => expect(screen.getByTestId('package-row-pkg-a')).toBeInTheDocument());
      expect(screen.getByTestId('package-row-pkg-b')).toBeInTheDocument();
      expect(screen.getByText('nginx')).toBeInTheDocument();
      expect(screen.getByText('curl')).toBeInTheDocument();
    });

    it('shows count of loaded packages', async () => {
      mockGet.mockResolvedValue(searchEnvelope([PKG_A, PKG_B]));
      renderBrowser();

      await waitFor(() => expect(screen.getByTestId('package-browser-count')).toHaveTextContent('2 loaded'));
    });

    it('shows empty state with no-sync message when package_count is 0', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser({ repository: REPO_EMPTY });

      await waitFor(() =>
        expect(
          screen.getByText(/no packages synced yet/i)
        ).toBeInTheDocument()
      );
    });

    it('shows filter-no-match message when package_count > 0 but results are empty', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser({ repository: REPO });

      await waitFor(() =>
        expect(
          screen.getByText(/no packages match the current filters/i)
        ).toBeInTheDocument()
      );
    });

    it('renders package name, version, architecture inline', async () => {
      mockGet.mockResolvedValue(searchEnvelope([PKG_A]));
      renderBrowser();

      await waitFor(() => screen.getByTestId('package-row-pkg-a'));
      expect(screen.getByText('nginx')).toBeInTheDocument();
      expect(screen.getByText('v1.24.0')).toBeInTheDocument();
      expect(screen.getByText('(amd64)')).toBeInTheDocument();
    });

    it('renders license badge when present', async () => {
      mockGet.mockResolvedValue(searchEnvelope([PKG_A]));
      renderBrowser();

      await waitFor(() => screen.getByTestId('package-row-pkg-a'));
      expect(screen.getByText('BSD')).toBeInTheDocument();
    });

    it('renders summary text when present', async () => {
      mockGet.mockResolvedValue(searchEnvelope([PKG_A]));
      renderBrowser();

      await waitFor(() => screen.getByTestId('package-row-pkg-a'));
      expect(screen.getByText('high performance web server')).toBeInTheDocument();
    });

    it('renders provides_names when present', async () => {
      mockGet.mockResolvedValue(searchEnvelope([PKG_A]));
      renderBrowser();

      await waitFor(() => screen.getByTestId('package-row-pkg-a'));
      expect(screen.getByText(/provides: httpd, web-server/i)).toBeInTheDocument();
    });

    it('renders similarity badge when similarity is present', async () => {
      mockGet.mockResolvedValue(searchEnvelope([PKG_SIMILARITY]));
      renderBrowser();

      await waitFor(() => screen.getByTestId('package-row-pkg-c'));
      expect(screen.getByText('87% match')).toBeInTheDocument();
    });

    it('shows Load more button when more pages exist', async () => {
      // With per_page=30, total=61 means page 1 has next_page
      mockGet.mockResolvedValue(
        searchEnvelope([PKG_A], { total: 61, page: 1, per_page: 30, next_page: 2 })
      );
      renderBrowser();

      await waitFor(() => expect(screen.getByTestId('package-browser-load-more')).toBeInTheDocument());
    });

    it('does not show Load more when there is only one page', async () => {
      mockGet.mockResolvedValue(searchEnvelope([PKG_A, PKG_B], { total: 2, next_page: null }));
      renderBrowser();

      await waitFor(() => screen.getByTestId('package-browser-list'));
      expect(screen.queryByTestId('package-browser-load-more')).not.toBeInTheDocument();
    });
  });

  // ============================================================
  // Browse mode — API call shape
  // ============================================================

  describe('browse mode — API call shape', () => {
    it('calls GET /system/packages with repository_id on mount', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();

      await waitFor(() => expect(mockGet).toHaveBeenCalled());
      expect(mockGet).toHaveBeenCalledWith(
        '/system/packages',
        expect.objectContaining({
          params: expect.objectContaining({
            repository_id: 'repo-1',
            mode: 'lexical',
            page: 1,
            per_page: 30,
          }),
        })
      );
    });

    it('switches mode to hybrid when q is non-empty (after debounce)', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();

      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));
      mockGet.mockClear();
      mockGet.mockResolvedValue(searchEnvelope([PKG_A]));

      const input = screen.getByTestId('package-filter-q');
      fireEvent.change(input, { target: { value: 'nginx' } });

      // Advance debounce timer (300ms)
      act(() => { jest.advanceTimersByTime(300); });

      await waitFor(() => expect(mockGet).toHaveBeenCalled());
      expect(mockGet).toHaveBeenCalledWith(
        '/system/packages',
        expect.objectContaining({
          params: expect.objectContaining({
            q: 'nginx',
            mode: 'hybrid',
          }),
        })
      );
    });

    it('does not refetch until the 300ms debounce elapses', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();

      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));
      mockGet.mockClear();

      const input = screen.getByTestId('package-filter-q');
      fireEvent.change(input, { target: { value: 'n' } });
      act(() => { jest.advanceTimersByTime(100); });
      fireEvent.change(input, { target: { value: 'ng' } });
      act(() => { jest.advanceTimersByTime(100); });
      // 200ms elapsed, debounce not yet fired
      expect(mockGet).not.toHaveBeenCalled();

      act(() => { jest.advanceTimersByTime(200); });
      await waitFor(() => expect(mockGet).toHaveBeenCalled());
    });

    it('includes license filter in GET params when set', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();

      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));
      mockGet.mockClear();
      mockGet.mockResolvedValue(searchEnvelope([]));

      const licenseInput = screen.getByTestId('package-filter-license');
      fireEvent.change(licenseInput, { target: { value: 'MIT' } });

      // License is not debounced — it goes through serverFilterKey on change
      await waitFor(() => expect(mockGet).toHaveBeenCalled());
      expect(mockGet).toHaveBeenCalledWith(
        '/system/packages',
        expect.objectContaining({
          params: expect.objectContaining({ license: 'MIT' }),
        })
      );
    });
  });

  // ============================================================
  // Browse mode — Create module button
  // ============================================================

  describe('browse mode — create module button', () => {
    it('does not show create-module buttons when canCreateModule is false', async () => {
      mockGet.mockResolvedValue(searchEnvelope([PKG_A]));
      renderBrowser({ canCreateModule: false });

      await waitFor(() => screen.getByTestId('package-row-pkg-a'));
      expect(screen.queryByTestId('package-create-module-pkg-a')).not.toBeInTheDocument();
    });

    it('shows create-module button when canCreateModule is true', async () => {
      mockGet.mockResolvedValue(searchEnvelope([PKG_A]));
      renderBrowser({ canCreateModule: true });

      await waitFor(() => expect(screen.getByTestId('package-create-module-pkg-a')).toBeInTheDocument());
    });

    it('calls onCreateModule with the package name when create button is clicked', async () => {
      mockGet.mockResolvedValue(searchEnvelope([PKG_A]));
      const onCreateModule = jest.fn();
      renderBrowser({ canCreateModule: true, onCreateModule });

      const btn = await waitFor(() => screen.getByTestId('package-create-module-pkg-a'));
      fireEvent.click(btn);

      expect(onCreateModule).toHaveBeenCalledWith('nginx');
    });
  });

  // ============================================================
  // Browse mode — Load more
  // ============================================================

  describe('browse mode — load more', () => {
    it('fetches page 2 when Load more is clicked', async () => {
      mockGet.mockResolvedValueOnce(
        searchEnvelope([PKG_A], { total: 61, page: 1, per_page: 30, next_page: 2 })
      );
      renderBrowser();

      const loadMoreBtn = await waitFor(() => screen.getByTestId('package-browser-load-more'));
      mockGet.mockResolvedValueOnce(searchEnvelope([PKG_B], { total: 61, page: 2, per_page: 30, next_page: null }));
      fireEvent.click(loadMoreBtn);

      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
      expect(mockGet).toHaveBeenNthCalledWith(
        2,
        '/system/packages',
        expect.objectContaining({
          params: expect.objectContaining({ page: 2, per_page: 30 }),
        })
      );
    });

    it('appends results after loading page 2', async () => {
      mockGet.mockResolvedValueOnce(
        searchEnvelope([PKG_A], { total: 61, page: 1, per_page: 30, next_page: 2 })
      );
      renderBrowser();

      const loadMoreBtn = await waitFor(() => screen.getByTestId('package-browser-load-more'));
      mockGet.mockResolvedValueOnce(searchEnvelope([PKG_B], { total: 61, page: 2, per_page: 30, next_page: null }));
      fireEvent.click(loadMoreBtn);

      await waitFor(() => screen.getByTestId('package-row-pkg-b'));
      expect(screen.getByTestId('package-row-pkg-a')).toBeInTheDocument();
      expect(screen.getByTestId('package-row-pkg-b')).toBeInTheDocument();
    });
  });

  // ============================================================
  // Discover mode — states
  // ============================================================

  describe('discover mode', () => {
    function switchToDiscover() {
      const discoverTab = screen.getByTestId('package-filter-mode-discover');
      fireEvent.click(discoverTab);
    }

    it('shows idle hint message in discover mode before submitting', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      switchToDiscover();

      expect(screen.getByText(/describe a capability above/i)).toBeInTheDocument();
    });

    it('shows loading state while discover is in flight', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      switchToDiscover();

      // Never resolves
      mockPost.mockReturnValue(new Promise(() => {}));
      const textarea = screen.getByTestId('package-discover-intent');
      fireEvent.change(textarea, { target: { value: 'web server' } });
      fireEvent.click(screen.getByTestId('package-discover-submit'));

      expect(screen.getByText(/embedding intent and searching/i)).toBeInTheDocument();
    });

    it('renders discover results with similarity badge and reason', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      switchToDiscover();

      const discoverResult: PackageDiscoverResult = {
        intent: 'web server',
        seed_count: 10,
        confidence: 'high',
        results: [
          {
            id: 'pkg-d',
            name: 'apache2',
            version: '2.4.59',
            architecture: 'amd64',
            summary: 'Apache HTTP server',
            package_repository_id: 'repo-1',
            package_id: 'pkg-d',
            similarity: 0.92,
            reason: 'Widely used HTTP/1.1 compliant web server',
            provides_names: [],
          },
        ],
      };

      mockPost.mockResolvedValue(discoverEnvelope(discoverResult));
      const textarea = screen.getByTestId('package-discover-intent');
      fireEvent.change(textarea, { target: { value: 'web server' } });
      fireEvent.click(screen.getByTestId('package-discover-submit'));

      await waitFor(() => expect(screen.getByTestId('package-discover-list')).toBeInTheDocument());
      expect(screen.getByText('apache2')).toBeInTheDocument();
      expect(screen.getByText('92% match')).toBeInTheDocument();
      expect(screen.getByText('Widely used HTTP/1.1 compliant web server')).toBeInTheDocument();
    });

    it('shows confidence and result count in header when discover completes', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      switchToDiscover();

      const discoverResult: PackageDiscoverResult = {
        intent: 'distributed cache',
        seed_count: 5,
        confidence: 'medium',
        results: [
          {
            id: 'pkg-e',
            name: 'redis',
            version: '7.0.0',
            architecture: 'amd64',
            package_repository_id: 'repo-1',
            package_id: 'pkg-e',
            similarity: 0.75,
            reason: 'In-memory data store',
          },
        ],
      };

      mockPost.mockResolvedValue(discoverEnvelope(discoverResult));
      const textarea = screen.getByTestId('package-discover-intent');
      fireEvent.change(textarea, { target: { value: 'distributed cache' } });
      fireEvent.click(screen.getByTestId('package-discover-submit'));

      await waitFor(() => expect(screen.getByTestId('package-discover-confidence')).toBeInTheDocument());
      expect(screen.getByTestId('package-discover-confidence')).toHaveTextContent('medium');
      expect(screen.getByTestId('package-discover-confidence')).toHaveTextContent('1 results');
    });

    it('shows error message when discover fails', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      switchToDiscover();

      mockPost.mockRejectedValue(new Error('Network timeout'));
      const textarea = screen.getByTestId('package-discover-intent');
      fireEvent.change(textarea, { target: { value: 'web server' } });
      fireEvent.click(screen.getByTestId('package-discover-submit'));

      await waitFor(() => expect(screen.getByTestId('package-discover-error')).toBeInTheDocument());
      expect(screen.getByTestId('package-discover-error')).toHaveTextContent('Network timeout');
    });

    it('shows no-semantic-matches message when discover returns empty results', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      switchToDiscover();

      const discoverResult: PackageDiscoverResult = {
        intent: 'obscure thing',
        seed_count: 0,
        confidence: 'low',
        results: [],
      };

      mockPost.mockResolvedValue(discoverEnvelope(discoverResult));
      const textarea = screen.getByTestId('package-discover-intent');
      fireEvent.change(textarea, { target: { value: 'obscure thing' } });
      fireEvent.click(screen.getByTestId('package-discover-submit'));

      await waitFor(() =>
        expect(screen.getByText(/no semantic matches/i)).toBeInTheDocument()
      );
    });

    it('calls POST /system/packages/discover with correct payload', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      switchToDiscover();

      const discoverResult: PackageDiscoverResult = {
        intent: 'web server',
        seed_count: 0,
        confidence: 'low',
        results: [],
      };

      mockPost.mockResolvedValue(discoverEnvelope(discoverResult));
      const textarea = screen.getByTestId('package-discover-intent');
      fireEvent.change(textarea, { target: { value: 'web server' } });
      fireEvent.click(screen.getByTestId('package-discover-submit'));

      await waitFor(() => expect(mockPost).toHaveBeenCalled());
      expect(mockPost).toHaveBeenCalledWith(
        '/system/packages/discover',
        expect.objectContaining({
          intent: 'web server',
          repository_ids: ['repo-1'],
          top_k: 50,
        })
      );
    });

    it('does not submit discover when intent is empty or whitespace', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      switchToDiscover();

      // Button should be disabled when intent is empty
      const submitBtn = screen.getByTestId('package-discover-submit');
      expect(submitBtn).toBeDisabled();

      // Whitespace also should not enable
      const textarea = screen.getByTestId('package-discover-intent');
      fireEvent.change(textarea, { target: { value: '   ' } });
      expect(submitBtn).toBeDisabled();

      expect(mockPost).not.toHaveBeenCalled();
    });

    it('submit button is enabled when intent has non-whitespace content', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      switchToDiscover();

      const textarea = screen.getByTestId('package-discover-intent');
      fireEvent.change(textarea, { target: { value: 'web server' } });

      expect(screen.getByTestId('package-discover-submit')).not.toBeDisabled();
    });
  });

  // ============================================================
  // Mode toggle — tab behaviour
  // ============================================================

  describe('mode toggle', () => {
    it('renders Browse tab selected by default', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();

      const browseTab = screen.getByTestId('package-filter-mode-browse');
      expect(browseTab).toHaveAttribute('aria-selected', 'true');

      const discoverTab = screen.getByTestId('package-filter-mode-discover');
      expect(discoverTab).toHaveAttribute('aria-selected', 'false');
    });

    it('switches to discover mode when Discover tab is clicked', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      fireEvent.click(screen.getByTestId('package-filter-mode-discover'));

      expect(screen.getByTestId('package-filter-mode-discover')).toHaveAttribute('aria-selected', 'true');
      expect(screen.getByTestId('package-filter-mode-browse')).toHaveAttribute('aria-selected', 'false');
      expect(screen.getByTestId('package-discover-intent')).toBeInTheDocument();
    });

    it('shows q search input only in browse mode', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      expect(screen.getByTestId('package-filter-q')).toBeInTheDocument();

      fireEvent.click(screen.getByTestId('package-filter-mode-discover'));
      expect(screen.queryByTestId('package-filter-q')).not.toBeInTheDocument();
    });

    it('hides section filter and provides filter in discover mode', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      // In browse mode sections and provides are present
      expect(screen.getByTestId('package-filter-sections-wrap')).toBeInTheDocument();
      expect(screen.getByTestId('package-filter-provides')).toBeInTheDocument();

      fireEvent.click(screen.getByTestId('package-filter-mode-discover'));

      expect(screen.queryByTestId('package-filter-sections-wrap')).not.toBeInTheDocument();
      expect(screen.queryByTestId('package-filter-provides')).not.toBeInTheDocument();
    });

    it('keeps license filter visible in discover mode', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();
      await waitFor(() => expect(mockGet).toHaveBeenCalled());

      fireEvent.click(screen.getByTestId('package-filter-mode-discover'));
      expect(screen.getByTestId('package-filter-license')).toBeInTheDocument();
    });
  });

  // ============================================================
  // Repository header
  // ============================================================

  describe('repository header', () => {
    it('shows the repository name in the section header', async () => {
      mockGet.mockResolvedValue(searchEnvelope([]));
      renderBrowser();

      expect(screen.getByText(/packages in ubuntu-noble/i)).toBeInTheDocument();
    });
  });

  // ============================================================
  // Error handling
  // ============================================================

  describe('error handling', () => {
    it('shows addNotification error when search fetch fails', async () => {
      mockGet.mockRejectedValue(new Error('Server error'));
      renderBrowser();

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error' })
        )
      );
    });
  });
});
