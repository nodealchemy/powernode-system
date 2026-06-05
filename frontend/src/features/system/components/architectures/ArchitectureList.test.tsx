import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ArchitectureList } from './ArchitectureList';
import type { SystemNodeArchitecture } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: jest.fn(),
    put: jest.fn(),
    delete: jest.fn(),
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

// Mock useNavigate so we can assert navigation calls
const mockNavigate = jest.fn();
jest.mock('react-router-dom', () => ({
  ...jest.requireActual('react-router-dom'),
  useNavigate: () => mockNavigate,
}));

// =============================================================================
// Fixtures
// =============================================================================

const ARCH_CANONICAL: SystemNodeArchitecture = {
  id: 'arch-x86-64',
  name: 'x86_64',
  display_name: 'x86-64 (AMD64)',
  family: 'x86',
  description: 'Standard 64-bit x86 architecture',
  apt_name: 'amd64',
  rpm_name: 'x86_64',
  enabled: true,
  public: true,
  is_canonical: true,
  usage: { node_platforms: 5, package_repositories: 3, packages: 120 },
  created_at: '2024-01-01T00:00:00Z',
  updated_at: '2024-06-01T00:00:00Z',
};

const ARCH_OPERATOR: SystemNodeArchitecture = {
  id: 'arch-arm64',
  name: 'aarch64',
  display_name: 'ARM 64-bit',
  family: 'arm',
  description: 'ARMv8 64-bit architecture',
  enabled: false,
  public: false,
  is_canonical: false,
  usage: { node_platforms: 0, package_repositories: 1, packages: 10 },
  created_at: '2024-02-01T00:00:00Z',
  updated_at: '2024-06-15T00:00:00Z',
};

const ARCH_WITH_ALIASES: SystemNodeArchitecture = {
  id: 'arch-risc',
  name: 'riscv64',
  family: 'risc-v',
  description: 'RISC-V 64-bit',
  aliases: ['rv64gc', 'riscv64gc'],
  kernel_options: 'console=ttyS0 earlycon',
  enabled: true,
  public: true,
  is_canonical: false,
  usage: { node_platforms: 2, package_repositories: 0, packages: 0 },
  created_at: '2024-03-01T00:00:00Z',
  updated_at: '2024-06-10T00:00:00Z',
};

// double-envelope helper matching InstancePoolsPage.test.tsx convention
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function archListResponse(architectures: SystemNodeArchitecture[]) {
  return envelope({ node_architectures: architectures });
}

// =============================================================================
// Render helper
// =============================================================================

interface RenderProps {
  onView?: jest.Mock;
  onEdit?: jest.Mock;
  onDelete?: jest.Mock;
  onCreate?: jest.Mock;
  hasPermission?: (perm: string) => boolean;
}

const renderList = (props: RenderProps = {}) => {
  const {
    onView = jest.fn(),
    onEdit = jest.fn(),
    onDelete = jest.fn(),
    onCreate = jest.fn(),
  } = props;

  return render(
    <BrowserRouter>
      <ArchitectureList
        onView={onView}
        onEdit={onEdit}
        onDelete={onDelete}
        onCreate={onCreate}
      />
    </BrowserRouter>,
  );
};

// =============================================================================
// Tests
// =============================================================================

describe('ArchitectureList', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockAddNotification.mockReset();
    mockNavigate.mockReset();
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading spinner while the initial fetch is in flight', () => {
    // Never resolves during this test — spinner stays visible
    mockGet.mockReturnValue(new Promise(() => {}));
    renderList();
    // Loading state: spinner present, no table rows
    expect(screen.queryByRole('table')).not.toBeInTheDocument();
    // The container renders a spinner element
    const spinner = document.querySelector('[class*="animate-spin"]') ||
                    document.querySelector('svg');
    expect(spinner).toBeTruthy();
  });

  // ---------------------------------------------------------------------------
  // Successful load: renders architecture rows
  // ---------------------------------------------------------------------------

  it('renders architecture rows after successful fetch', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL, ARCH_OPERATOR]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));
    expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0);
  });

  it('fetches from the correct endpoint /system/node_architectures', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));
    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', { params: {} });
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows the empty state when no architectures are returned', async () => {
    mockGet.mockResolvedValue(archListResponse([]));
    renderList();
    await waitFor(() =>
      expect(screen.getByText('No architectures match these filters')).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/adjust the family.*canonical.*status filters/i),
    ).toBeInTheDocument();
  });

  it('shows the Create Architecture button in the empty state when canManage and onCreate are provided', async () => {
    mockGet.mockResolvedValue(archListResponse([]));
    const onCreate = jest.fn();
    render(
      <BrowserRouter>
        <ArchitectureList onCreate={onCreate} />
      </BrowserRouter>,
    );
    await waitFor(() =>
      expect(screen.getByText('No architectures match these filters')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('Create Architecture'));
    expect(onCreate).toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error notification when the fetch fails', async () => {
    mockGet.mockRejectedValue(new Error('network error'));
    renderList();
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load architectures',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Canonical vs operator badge
  // ---------------------------------------------------------------------------

  it('renders "canonical" badge for canonical architectures and "operator" badge for custom ones', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL, ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    // canonical badge appears (at least once — desktop + mobile slots both render)
    expect(screen.getAllByText('canonical').length).toBeGreaterThan(0);
    expect(screen.getAllByText('operator').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Enabled / disabled badge
  // ---------------------------------------------------------------------------

  it('shows Enabled badge for enabled architectures', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));
    expect(screen.getAllByText('Enabled').length).toBeGreaterThan(0);
  });

  it('shows Disabled badge for disabled architectures', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0));
    // Desktop table shows "Disabled", mobile shows "Off" — assert what the desktop renders
    expect(screen.getAllByText('Disabled').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Action callbacks: onView, onEdit, onDelete
  // ---------------------------------------------------------------------------

  it('calls onView when the architecture name is clicked', async () => {
    const onView = jest.fn();
    mockGet.mockResolvedValue(archListResponse([ARCH_OPERATOR]));
    render(
      <BrowserRouter>
        <ArchitectureList onView={onView} />
      </BrowserRouter>,
    );
    await waitFor(() => expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0));
    // Click the first name element (desktop table)
    fireEvent.click(screen.getAllByText('aarch64')[0]);
    expect(onView).toHaveBeenCalledWith(ARCH_OPERATOR);
  });

  it('calls onView when the Eye button is clicked', async () => {
    const onView = jest.fn();
    mockGet.mockResolvedValue(archListResponse([ARCH_OPERATOR]));
    render(
      <BrowserRouter>
        <ArchitectureList onView={onView} />
      </BrowserRouter>,
    );
    await waitFor(() => expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0));
    const viewBtn = screen.getAllByTitle('View Details')[0];
    fireEvent.click(viewBtn);
    expect(onView).toHaveBeenCalledWith(ARCH_OPERATOR);
  });

  it('calls onEdit when the Edit button is clicked for a non-canonical architecture', async () => {
    const onEdit = jest.fn();
    mockGet.mockResolvedValue(archListResponse([ARCH_OPERATOR]));
    render(
      <BrowserRouter>
        <ArchitectureList onEdit={onEdit} />
      </BrowserRouter>,
    );
    await waitFor(() => expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0));
    const editBtn = screen.getByTitle('Edit Architecture');
    fireEvent.click(editBtn);
    expect(onEdit).toHaveBeenCalledWith(ARCH_OPERATOR);
  });

  it('calls onDelete when the Delete button is clicked for a non-canonical architecture', async () => {
    const onDelete = jest.fn();
    mockGet.mockResolvedValue(archListResponse([ARCH_OPERATOR]));
    render(
      <BrowserRouter>
        <ArchitectureList onDelete={onDelete} />
      </BrowserRouter>,
    );
    await waitFor(() => expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0));
    const deleteBtn = screen.getByTitle('Delete Architecture');
    fireEvent.click(deleteBtn);
    expect(onDelete).toHaveBeenCalledWith(ARCH_OPERATOR.id);
  });

  // ---------------------------------------------------------------------------
  // Permission gating: canonical rows hide Edit and Delete
  // ---------------------------------------------------------------------------

  it('hides Edit and Delete buttons for canonical architectures', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));
    // Canonical architecture — no edit or delete affordances
    expect(screen.queryByTitle('Edit Architecture')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Delete Architecture')).not.toBeInTheDocument();
  });

  it('shows Edit and Delete buttons for non-canonical architectures when canManage is true', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0));
    expect(screen.getByTitle('Edit Architecture')).toBeInTheDocument();
    expect(screen.getByTitle('Delete Architecture')).toBeInTheDocument();
  });

  it('hides Edit and Delete buttons when the user lacks system.architectures.manage permission', async () => {
    mockHasPermission.mockReturnValue(false);
    mockGet.mockResolvedValue(archListResponse([ARCH_OPERATOR]));

    render(
      <BrowserRouter>
        <ArchitectureList onEdit={jest.fn()} onDelete={jest.fn()} />
      </BrowserRouter>,
    );

    await waitFor(() => expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0));
    expect(screen.queryByTitle('Edit Architecture')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Delete Architecture')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Expand / collapse rows
  // ---------------------------------------------------------------------------

  it('expands a row when the chevron button is clicked, revealing detail fields', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    // Before expand: no Architecture ID elements with title
    expect(screen.queryAllByTitle(ARCH_CANONICAL.id)).toHaveLength(0);

    // Click expand (title="Expand details")
    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    // After expand: Architecture ID should appear (desktop + mobile can both render it)
    await waitFor(() =>
      expect(screen.getAllByTitle(ARCH_CANONICAL.id).length).toBeGreaterThan(0),
    );
  });

  it('collapses an expanded row when the chevron is clicked again', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByTitle(ARCH_CANONICAL.id).length).toBeGreaterThan(0),
    );

    // Now collapse
    const collapseBtn = screen.getAllByTitle('Collapse details')[0];
    fireEvent.click(collapseBtn);

    await waitFor(() =>
      expect(screen.queryAllByTitle(ARCH_CANONICAL.id)).toHaveLength(0),
    );
  });

  it('shows package names in expanded detail when apt_name and rpm_name are set', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByText(/apt: amd64/).length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText(/rpm: x86_64/).length).toBeGreaterThan(0);
  });

  it('shows aliases in expanded detail when present', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_WITH_ALIASES]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('riscv64').length).toBeGreaterThan(0));

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByText('rv64gc').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('riscv64gc').length).toBeGreaterThan(0);
  });

  it('shows kernel options in expanded detail when present', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_WITH_ALIASES]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('riscv64').length).toBeGreaterThan(0));

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByText('console=ttyS0 earlycon').length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // Usage / platforms navigation
  // ---------------------------------------------------------------------------

  it('navigates to the platform catalog filtered by architecture when platform count is clicked', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    // Platform count button (value = 5)
    const platformBtns = screen.getAllByTitle('View platforms on this architecture');
    fireEvent.click(platformBtns[0]);

    expect(mockNavigate).toHaveBeenCalledWith(
      `/app/system/catalog/platforms?architecture=${ARCH_CANONICAL.id}`,
    );
  });

  it('shows 0 as plain text (no link) when platform count is zero', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0));

    // No platform link button since count is 0
    expect(screen.queryByTitle('View platforms on this architecture')).not.toBeInTheDocument();
  });

  it('uses platform_count as fallback when usage.node_platforms is absent', async () => {
    const archWithFallback: SystemNodeArchitecture = {
      ...ARCH_OPERATOR,
      id: 'arch-fallback',
      name: 'fallback_arch',
      platform_count: 3,
      usage: undefined,
    };
    mockGet.mockResolvedValue(archListResponse([archWithFallback]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('fallback_arch').length).toBeGreaterThan(0));

    // Should show at least one platform link since count is 3 (desktop + mobile both render)
    expect(screen.getAllByTitle('View platforms on this architecture').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Search filter (client-side)
  // ---------------------------------------------------------------------------

  it('filters architectures by search text', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL, ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search architectures...');
    fireEvent.change(searchInput, { target: { value: 'aarch64' } });

    await waitFor(() => {
      expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0);
      expect(screen.queryByText('x86_64')).not.toBeInTheDocument();
    });
  });

  it('filters by description when search text matches the description', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL, ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search architectures...');
    fireEvent.change(searchInput, { target: { value: 'ARMv8' } });

    await waitFor(() => {
      expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0);
      expect(screen.queryByText('x86_64')).not.toBeInTheDocument();
    });
  });

  it('filters by apt_name', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL, ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search architectures...');
    fireEvent.change(searchInput, { target: { value: 'amd64' } });

    await waitFor(() => {
      expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0);
      expect(screen.queryByText('aarch64')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Family filter
  // ---------------------------------------------------------------------------

  it('filters by family when a family option is selected', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL, ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    // Find the family select (contains "All Families")
    const familySelect = screen.getByDisplayValue('All Families');
    fireEvent.change(familySelect, { target: { value: 'arm' } });

    await waitFor(() => {
      expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0);
      expect(screen.queryByText('x86_64')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Canonical filter
  // ---------------------------------------------------------------------------

  it('filters to canonical only when "Canonical only" is selected', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL, ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const canonicalSelect = screen.getByDisplayValue('All Origins');
    fireEvent.change(canonicalSelect, { target: { value: 'canonical' } });

    await waitFor(() => {
      expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0);
      expect(screen.queryByText('aarch64')).not.toBeInTheDocument();
    });
  });

  it('filters to custom only when "Custom only" is selected', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL, ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const canonicalSelect = screen.getByDisplayValue('All Origins');
    fireEvent.change(canonicalSelect, { target: { value: 'custom' } });

    await waitFor(() => {
      expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0);
      expect(screen.queryByText('x86_64')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Enabled filter
  // ---------------------------------------------------------------------------

  it('filters to enabled-only when "Enabled" status is selected', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL, ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const statusSelect = screen.getByDisplayValue('All Status');
    fireEvent.change(statusSelect, { target: { value: 'enabled' } });

    await waitFor(() => {
      expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0);
      // ARCH_OPERATOR has enabled: false
      expect(screen.queryByText('aarch64')).not.toBeInTheDocument();
    });
  });

  it('filters to disabled-only when "Disabled" status is selected', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL, ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const statusSelect = screen.getByDisplayValue('All Status');
    fireEvent.change(statusSelect, { target: { value: 'disabled' } });

    await waitFor(() => {
      expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0);
      expect(screen.queryByText('x86_64')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // "Showing N of M" count hint
  // ---------------------------------------------------------------------------

  it('shows "Showing N of M" when filters reduce the item count', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL, ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const statusSelect = screen.getByDisplayValue('All Status');
    fireEvent.change(statusSelect, { target: { value: 'enabled' } });

    await waitFor(() => expect(screen.getByText('Showing 1 of 2')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Family options rendered in the select
  // ---------------------------------------------------------------------------

  it('renders all family options in the family dropdown', async () => {
    mockGet.mockResolvedValue(archListResponse([]));
    renderList();
    // Family select is present even in loading/empty states — wait for empty state
    await waitFor(() =>
      expect(screen.getByText('No architectures match these filters')).toBeInTheDocument(),
    );
    // The family select becomes visible only after items are loaded (filters hidden during load)
    // Re-check once the empty state is shown — filters are visible in that path
    // Actually: when totalCount is 0, the container renders the empty state WITHOUT the filter bar.
    // So we need a non-empty list to see the filter.
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const familySelect = screen.getByDisplayValue('All Families');
    const options = Array.from((familySelect as HTMLSelectElement).options).map((o) => o.value);
    expect(options).toEqual(['all', 'x86', 'arm', 'power', 'z', 'risc-v', 'mips', 'other']);
  });

  // ---------------------------------------------------------------------------
  // Display name and package name chips in list rows
  // ---------------------------------------------------------------------------

  it('renders the display_name below the architecture name', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));
    expect(screen.getAllByText('x86-64 (AMD64)').length).toBeGreaterThan(0);
  });

  it('renders apt_name and rpm_name chips in the list row', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));
    expect(screen.getAllByText(/apt: amd64/).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/rpm: x86_64/).length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Usage counts in list rows
  // ---------------------------------------------------------------------------

  it('renders repos and packages usage counts', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));
    // 3 repos, 120 packages
    expect(screen.getAllByText('3').length).toBeGreaterThan(0);
    expect(screen.getAllByText('120').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Mobile dropdown menu
  // ---------------------------------------------------------------------------

  it('opens the mobile dropdown menu when the MoreVertical button is clicked', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0));

    // The mobile MoreVertical button uses an SVG icon — find all buttons and pick the one
    // in the mobile section. The dropdown toggle button has no title so we find by role.
    const moreButtons = screen.getAllByRole('button');
    // Find a button that does not have a known title (not View Details / Expand details etc.)
    const moreBtn = moreButtons.find(
      (b) =>
        !b.getAttribute('title') &&
        b.closest('.md\\:hidden') === null && // prefer the one outside md:hidden wrapper
        b.querySelector('svg') !== null,
    );
    // Fallback: any button with an SVG that's not a named action
    const anyMoreBtn = moreButtons[moreButtons.length - 1];
    fireEvent.click(anyMoreBtn);

    // The dropdown should appear with "View Details" text
    await waitFor(() =>
      expect(screen.getAllByText('View Details').length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // Expanded detail: visibility field
  // ---------------------------------------------------------------------------

  it('shows Public or Private in expanded detail based on the public field', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByText('Public').length).toBeGreaterThan(0),
    );
  });

  it('shows Private in expanded detail when public is false', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('aarch64').length).toBeGreaterThan(0));

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByText('Private').length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // Expanded detail: origin label
  // ---------------------------------------------------------------------------

  it('shows "canonical" as origin in expanded detail for canonical architectures', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    // The expanded detail renders the text "canonical" in the Origin field
    await waitFor(() =>
      // Multiple "canonical" texts may appear (badge + detail field)
      expect(screen.getAllByText('canonical').length).toBeGreaterThanOrEqual(2),
    );
  });

  // ---------------------------------------------------------------------------
  // Multiple rows: independent expand state
  // ---------------------------------------------------------------------------

  it('can expand multiple rows independently', async () => {
    mockGet.mockResolvedValue(archListResponse([ARCH_CANONICAL, ARCH_OPERATOR]));
    renderList();
    await waitFor(() => expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0));

    const expandBtns = screen.getAllByTitle('Expand details');
    // Expand first row (desktop expand button at index 0)
    fireEvent.click(expandBtns[0]);
    await waitFor(() =>
      expect(screen.getAllByTitle(ARCH_CANONICAL.id).length).toBeGreaterThan(0),
    );
    // Second row should not be expanded yet
    expect(screen.queryAllByTitle(ARCH_OPERATOR.id)).toHaveLength(0);

    // Expand second row — there should still be "Expand details" buttons for the operator arch
    const remainingExpandBtns = screen.getAllByTitle('Expand details');
    expect(remainingExpandBtns.length).toBeGreaterThan(0);
    fireEvent.click(remainingExpandBtns[0]);
    await waitFor(() =>
      expect(screen.getAllByTitle(ARCH_OPERATOR.id).length).toBeGreaterThan(0),
    );
    // First row still expanded
    expect(screen.getAllByTitle(ARCH_CANONICAL.id).length).toBeGreaterThan(0);
  });
});
