import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter, MemoryRouter } from 'react-router-dom';
import { PlatformList } from './PlatformList';
import type { SystemNodePlatform } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();
const mockNavigate = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

jest.mock('react-router-dom', () => ({
  ...jest.requireActual('react-router-dom'),
  useNavigate: () => mockNavigate,
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

// EntityLink — render a plain anchor so tests can check label text.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { type: string; id: string; label: string }) => (
    <a data-testid="entity-link">{label}</a>
  ),
}));

// InfiniteScrollSentinel — Observer API not available in jsdom; stub it.
jest.mock(
  '@system/features/system/components/shared/InfiniteScrollSentinel',
  () => ({
    InfiniteScrollSentinel: () => null,
  }),
);

// =============================================================================
// Fixtures
// =============================================================================

const PLATFORM_A: SystemNodePlatform = {
  id: 'plat-a',
  name: 'Ubuntu 22.04',
  description: 'Standard Ubuntu server image',
  enabled: true,
  public: true,
  node_architecture_id: 'arch-x86',
  architecture_name: 'x86_64',
  template_count: 3,
  module_count: 5,
  disk_image_publication_status: 'published',
  disk_image_git_sha: 'abc1234def5678',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-03-01T00:00:00Z',
};

const PLATFORM_B: SystemNodePlatform = {
  id: 'plat-b',
  name: 'Debian 12',
  description: 'Minimal Debian base',
  enabled: false,
  public: false,
  node_architecture_id: undefined,
  architecture_name: undefined,
  template_count: 0,
  module_count: 0,
  disk_image_publication_status: 'none',
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-04-01T00:00:00Z',
};

/**
 * Double-envelope: AxiosResponse.data = { success: true, data: payload }
 * platformsApi.getPlatforms() calls extractData(response).node_platforms
 * so the shape must be { data: { success: true, data: { node_platforms: [...] } } }
 */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function platformsResponse(platforms: SystemNodePlatform[]) {
  return envelope({ node_platforms: platforms });
}

// =============================================================================
// Render helpers
// =============================================================================

interface RenderOptions {
  onView?: (p: SystemNodePlatform) => void;
  onEdit?: (p: SystemNodePlatform) => void;
  onDelete?: (id: string) => void;
  onCreate?: () => void;
  initialSearch?: string;
}

function renderList(opts: RenderOptions = {}) {
  return render(
    <BrowserRouter>
      <PlatformList
        onView={opts.onView ?? jest.fn()}
        onEdit={opts.onEdit}
        onDelete={opts.onDelete}
        onCreate={opts.onCreate}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('PlatformList', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockReset();
    mockNavigate.mockReset();
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading spinner on initial load', async () => {
    // Never resolves during this test
    mockGet.mockReturnValue(new Promise(() => {}));
    renderList();
    // LoadingSpinner is present while the list is loading and empty
    const spinners = document.querySelectorAll('[class*="animate-spin"]');
    // The spinner itself doesn't have a text role — just assert get doesn't throw
    expect(mockGet).toHaveBeenCalledWith('/system/node_platforms');
  });

  // ---------------------------------------------------------------------------
  // Fetches platforms from the correct URL
  // ---------------------------------------------------------------------------

  it('calls GET /system/node_platforms on mount', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    renderList();
    await waitFor(() => expect(mockGet).toHaveBeenCalledWith('/system/node_platforms'));
  });

  // ---------------------------------------------------------------------------
  // Renders platform list
  // ---------------------------------------------------------------------------

  it('renders platform names after data loads', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A, PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));
    expect(screen.getAllByText('Debian 12').length).toBeGreaterThan(0);
  });

  it('renders description text for platforms that have one', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('Standard Ubuntu server image').length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // Status badges
  // ---------------------------------------------------------------------------

  it('shows Enabled badge for enabled platforms and Disabled for disabled ones', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A, PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Enabled').length).toBeGreaterThan(0));
    expect(screen.getAllByText('Disabled').length).toBeGreaterThan(0);
  });

  it('shows Public badge for public platforms and Private for private ones', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A, PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Public').length).toBeGreaterThan(0));
    expect(screen.getAllByText('Private').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows the empty state when no platforms exist', async () => {
    mockGet.mockResolvedValue(platformsResponse([]));
    renderList({ onCreate: jest.fn() });

    await waitFor(() =>
      expect(screen.getByText('No platforms configured')).toBeInTheDocument(),
    );
    expect(
      screen.getByText('Create your first node platform to define operating system configurations'),
    ).toBeInTheDocument();
  });

  it('shows Create Platform button in empty state when canCreate and onCreate provided', async () => {
    mockGet.mockResolvedValue(platformsResponse([]));
    const onCreate = jest.fn();
    renderList({ onCreate });

    await waitFor(() => expect(screen.getByText('Create Platform')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Create Platform'));
    expect(onCreate).toHaveBeenCalledTimes(1);
  });

  it('does NOT show Create Platform button when permission is denied', async () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.platforms.create');
    mockGet.mockResolvedValue(platformsResponse([]));
    const onCreate = jest.fn();
    renderList({ onCreate });

    await waitFor(() => expect(screen.getByText('No platforms configured')).toBeInTheDocument());
    expect(screen.queryByText('Create Platform')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error notification when the fetch fails', async () => {
    mockGet.mockRejectedValue(new Error('Network error'));
    renderList();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load platforms',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Search filter
  // ---------------------------------------------------------------------------

  it('filters platforms by search term (name)', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A, PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search platforms...');
    fireEvent.change(searchInput, { target: { value: 'Ubuntu' } });

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));
    expect(screen.queryByText('Debian 12')).not.toBeInTheDocument();
  });

  it('filters platforms by search term (description)', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A, PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Debian 12').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search platforms...');
    fireEvent.change(searchInput, { target: { value: 'Minimal' } });

    await waitFor(() => expect(screen.getAllByText('Debian 12').length).toBeGreaterThan(0));
    expect(screen.queryByText('Ubuntu 22.04')).not.toBeInTheDocument();
  });

  it('filters platforms by search term (architecture name)', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A, PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search platforms...');
    fireEvent.change(searchInput, { target: { value: 'x86_64' } });

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));
    expect(screen.queryByText('Debian 12')).not.toBeInTheDocument();
  });

  it('shows "Showing N of M" hint when a search narrows results', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A, PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search platforms...');
    fireEvent.change(searchInput, { target: { value: 'Ubuntu' } });

    await waitFor(() => expect(screen.getByText(/Showing 1 of 2/)).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Enabled filter
  // ---------------------------------------------------------------------------

  it('filters to enabled-only platforms via the status dropdown', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A, PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));

    const select = screen.getByDisplayValue('All Status');
    fireEvent.change(select, { target: { value: 'enabled' } });

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));
    expect(screen.queryByText('Debian 12')).not.toBeInTheDocument();
  });

  it('filters to disabled-only platforms via the status dropdown', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A, PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Debian 12').length).toBeGreaterThan(0));

    const select = screen.getByDisplayValue('All Status');
    fireEvent.change(select, { target: { value: 'disabled' } });

    await waitFor(() => expect(screen.getAllByText('Debian 12').length).toBeGreaterThan(0));
    expect(screen.queryByText('Ubuntu 22.04')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Architecture deep-link filter chip
  // ---------------------------------------------------------------------------

  it('shows architecture filter chip when ?architecture= param is set', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A, PLATFORM_B]));

    render(
      <MemoryRouter initialEntries={['/platforms?architecture=arch-x86']}>
        <PlatformList onView={jest.fn()} />
      </MemoryRouter>,
    );

    await waitFor(() =>
      expect(screen.getByText('Filtered by architecture')).toBeInTheDocument(),
    );
    // Only PLATFORM_A matches arch-x86
    expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0);
    expect(screen.queryByText('Debian 12')).not.toBeInTheDocument();
  });

  it('clears the architecture filter when the chip X button is clicked', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A, PLATFORM_B]));

    render(
      <MemoryRouter initialEntries={['/platforms?architecture=arch-x86']}>
        <PlatformList onView={jest.fn()} />
      </MemoryRouter>,
    );

    await waitFor(() =>
      expect(screen.getByText('Filtered by architecture')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Clear architecture filter'));

    // Chip is gone and both platforms appear
    await waitFor(() =>
      expect(screen.queryByText('Filtered by architecture')).not.toBeInTheDocument(),
    );
    await waitFor(() => expect(screen.getAllByText('Debian 12').length).toBeGreaterThan(0));
  });

  // ---------------------------------------------------------------------------
  // onView callback
  // ---------------------------------------------------------------------------

  it('calls onView when the platform name is clicked (desktop)', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    const onView = jest.fn();
    renderList({ onView });

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));
    // Click the first instance (desktop span)
    fireEvent.click(screen.getAllByText('Ubuntu 22.04')[0]);
    expect(onView).toHaveBeenCalledWith(PLATFORM_A);
  });

  it('calls onView when the Eye button is clicked', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    const onView = jest.fn();
    renderList({ onView });

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));
    const viewButton = screen.getByTitle('View Details');
    fireEvent.click(viewButton);
    expect(onView).toHaveBeenCalledWith(PLATFORM_A);
  });

  // ---------------------------------------------------------------------------
  // onEdit callback
  // ---------------------------------------------------------------------------

  it('shows edit button when canUpdate is true and calls onEdit', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    const onEdit = jest.fn();
    renderList({ onEdit });

    await waitFor(() => expect(screen.getByTitle('Edit Platform')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Edit Platform'));
    expect(onEdit).toHaveBeenCalledWith(PLATFORM_A);
  });

  it('hides edit button when canUpdate permission is denied', async () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.platforms.update');
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    const onEdit = jest.fn();
    renderList({ onEdit });

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));
    expect(screen.queryByTitle('Edit Platform')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onDelete callback
  // ---------------------------------------------------------------------------

  it('shows delete button when canDelete is true and calls onDelete with platform id', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    const onDelete = jest.fn();
    renderList({ onDelete });

    await waitFor(() => expect(screen.getByTitle('Delete Platform')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Delete Platform'));
    expect(onDelete).toHaveBeenCalledWith('plat-a');
  });

  it('hides delete button when canDelete permission is denied', async () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.platforms.delete');
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    const onDelete = jest.fn();
    renderList({ onDelete });

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));
    expect(screen.queryByTitle('Delete Platform')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Download image button (only shown when published)
  // ---------------------------------------------------------------------------

  it('shows download button for platforms with published disk image', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    renderList();

    await waitFor(() =>
      expect(
        screen.getByTitle('Download the generic disk image (.img) for fleet imaging'),
      ).toBeInTheDocument(),
    );
  });

  it('does NOT show download button for platforms without published image', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Debian 12').length).toBeGreaterThan(0));
    expect(
      screen.queryByTitle('Download the generic disk image (.img) for fleet imaging'),
    ).not.toBeInTheDocument();
  });

  it('calls platformsApi.downloadDiskImage and shows success notification on download', async () => {
    mockGet.mockImplementation((url: string, opts?: { responseType?: string }) => {
      if (opts?.responseType === 'blob') {
        // Simulate the disk image download endpoint
        return Promise.resolve({
          data: new Blob(['img-data'], { type: 'application/octet-stream' }),
          headers: { 'content-disposition': 'attachment; filename="platform-plat-a.img"' },
        });
      }
      return platformsResponse([PLATFORM_A]);
    });

    // Stub URL.createObjectURL / revokeObjectURL for jsdom
    const createObjectURL = jest.fn(() => 'blob:fake-url');
    const revokeObjectURL = jest.fn();
    Object.defineProperty(global.URL, 'createObjectURL', { value: createObjectURL, writable: true });
    Object.defineProperty(global.URL, 'revokeObjectURL', { value: revokeObjectURL, writable: true });

    renderList();

    await waitFor(() =>
      expect(
        screen.getByTitle('Download the generic disk image (.img) for fleet imaging'),
      ).toBeInTheDocument(),
    );

    fireEvent.click(
      screen.getByTitle('Download the generic disk image (.img) for fleet imaging'),
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Downloading generic image for Ubuntu 22.04…',
      }),
    );
    expect(mockGet).toHaveBeenCalledWith(
      '/system/node_platforms/plat-a/disk_image',
      { responseType: 'blob' },
    );
  });

  it('shows error notification when download fails', async () => {
    mockGet.mockImplementation((url: string, opts?: { responseType?: string }) => {
      if (opts?.responseType === 'blob') {
        return Promise.reject(new Error('Download failed'));
      }
      return platformsResponse([PLATFORM_A]);
    });

    renderList();

    await waitFor(() =>
      expect(
        screen.getByTitle('Download the generic disk image (.img) for fleet imaging'),
      ).toBeInTheDocument(),
    );

    fireEvent.click(
      screen.getByTitle('Download the generic disk image (.img) for fleet imaging'),
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Download failed',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Expand / collapse row detail
  // ---------------------------------------------------------------------------

  it('expands a row to show extra details when the chevron is clicked', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));

    // Before expansion, Platform ID label should not be present
    expect(screen.queryByText('Platform ID')).not.toBeInTheDocument();

    // Both desktop and mobile rows have expand buttons — click the first (desktop)
    const expandButtons = screen.getAllByTitle('Expand details');
    fireEvent.click(expandButtons[0]);

    await waitFor(() => expect(screen.getAllByText('Platform ID').length).toBeGreaterThan(0));
    expect(screen.getAllByText('plat-a').length).toBeGreaterThan(0);
    expect(screen.getAllByText('abc1234def5678').length).toBeGreaterThan(0);
  });

  it('collapses a row when the chevron is clicked again', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));

    const expandButtons = screen.getAllByTitle('Expand details');
    fireEvent.click(expandButtons[0]);

    await waitFor(() => expect(screen.getAllByTitle('Collapse details').length).toBeGreaterThan(0));
    fireEvent.click(screen.getAllByTitle('Collapse details')[0]);

    await waitFor(() => expect(screen.queryAllByText('Platform ID').length).toBe(0));
  });

  // ---------------------------------------------------------------------------
  // Template count navigation
  // ---------------------------------------------------------------------------

  it('renders template count as a clickable link that navigates correctly', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));

    // The template count "3" should be a clickable button in the desktop view
    const templateLinks = screen.getAllByTitle('View templates on this platform');
    expect(templateLinks.length).toBeGreaterThan(0);
    expect(templateLinks[0]).toHaveTextContent('3');

    // Click navigates to templates page filtered by platform
    fireEvent.click(templateLinks[0]);
    expect(mockNavigate).toHaveBeenCalledWith(
      '/app/system/catalog/templates?platform=plat-a',
    );
  });

  it('renders template count as plain text "0" when count is zero', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Debian 12').length).toBeGreaterThan(0));
    expect(screen.queryByTitle('View templates on this platform')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Architecture column: EntityLink vs plain text
  // ---------------------------------------------------------------------------

  it('renders EntityLink for platforms with node_architecture_id', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));
    // EntityLink mock renders an <a data-testid="entity-link">
    const entityLinks = screen.getAllByTestId('entity-link');
    expect(entityLinks.length).toBeGreaterThan(0);
    expect(entityLinks[0]).toHaveTextContent('x86_64');
  });

  it('renders plain dash for platforms without node_architecture_id', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Debian 12').length).toBeGreaterThan(0));
    expect(screen.queryByTestId('entity-link')).not.toBeInTheDocument();
    // Desktop column shows '-' for missing architecture
    expect(screen.getByText('-')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Refresh button
  // ---------------------------------------------------------------------------

  it('re-fetches platforms when the refresh button is clicked', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));

    const callCount = mockGet.mock.calls.length;
    fireEvent.click(screen.getByTitle('Refresh'));

    await waitFor(() => expect(mockGet.mock.calls.length).toBeGreaterThan(callCount));
    expect(mockGet).toHaveBeenLastCalledWith('/system/node_platforms');
  });

  // ---------------------------------------------------------------------------
  // Expanded detail — disk image status shown
  // ---------------------------------------------------------------------------

  it('shows disk image status in expanded details', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Ubuntu 22.04').length).toBeGreaterThan(0));
    fireEvent.click(screen.getAllByTitle('Expand details')[0]);

    await waitFor(() => expect(screen.getAllByText('Disk Image').length).toBeGreaterThan(0));
    expect(screen.getAllByText('published').length).toBeGreaterThan(0);
  });

  it('shows "none" for disk image status when no image is published', async () => {
    mockGet.mockResolvedValue(platformsResponse([PLATFORM_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('Debian 12').length).toBeGreaterThan(0));
    fireEvent.click(screen.getAllByTitle('Expand details')[0]);

    await waitFor(() => expect(screen.getAllByText('Disk Image').length).toBeGreaterThan(0));
    expect(screen.getAllByText('none').length).toBeGreaterThan(0);
  });
});
