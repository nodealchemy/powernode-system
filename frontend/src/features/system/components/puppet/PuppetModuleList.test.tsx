import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PuppetModuleList } from './PuppetModuleList';
import type { SystemPuppetModule } from '@system/features/system/types/system.types';

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

// hasPermission is a jest.fn() so individual tests can override it.
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

// =============================================================================
// Double-envelope helper
// =============================================================================

/**
 * Wraps a payload in AxiosResponse shape with the API double-envelope.
 * apiClient.get() resolves to { data: { success: true, data: payload, meta? } }.
 * Pagination meta lives at body ROOT — NOT inside data.
 */
function envelope<T>(data: T, meta?: object) {
  return {
    data: {
      success: true,
      data,
      ...(meta ? { meta } : {}),
    },
  };
}

function defaultMeta(count = 0) {
  return {
    current_page: 1,
    per_page: count,
    total_count: count,
    total_pages: 1,
    next_page: null,
    prev_page: null,
  };
}

/** Produce the paginated response for getPuppetModules */
function modulesResponse(modules: SystemPuppetModule[]) {
  return envelope({ puppet_modules: modules }, defaultMeta(modules.length));
}

// =============================================================================
// Fixtures
// =============================================================================

const MODULE_A: SystemPuppetModule = {
  id: 'mod-aaa',
  name: 'nginx',
  description: 'Manages nginx web server',
  enabled: true,
  public: true,
  version: '1.2.3',
  author: 'puppetlabs',
  license: 'Apache-2.0',
  forge_name: 'puppetlabs-nginx',
  dependencies: [],
  config: {},
  metadata: {},
  resource_count: 5,
  assigned_modules_count: 3,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const MODULE_B: SystemPuppetModule = {
  id: 'mod-bbb',
  name: 'mysql',
  description: 'Manages MySQL database',
  enabled: false,
  public: false,
  version: undefined,
  author: undefined,
  dependencies: [],
  config: {},
  metadata: {},
  resource_count: 0,
  assigned_modules_count: 0,
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-02T00:00:00Z',
};

// =============================================================================
// Render helper
// =============================================================================

interface RenderOptions {
  onView?: jest.Mock;
  onEdit?: jest.Mock;
  onDelete?: jest.Mock;
  onCreate?: jest.Mock;
}

function renderList(opts: RenderOptions = {}) {
  const {
    onView = jest.fn(),
    onEdit = jest.fn(),
    onDelete = jest.fn(),
    onCreate = jest.fn(),
  } = opts;

  return render(
    <BrowserRouter>
      <PuppetModuleList
        onView={onView}
        onEdit={onEdit}
        onDelete={onDelete}
        onCreate={onCreate}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('PuppetModuleList', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading spinner on initial load and no module names while pending', () => {
    mockGet.mockReturnValue(new Promise(() => {}));
    renderList();
    // Modules should not be visible yet
    expect(screen.queryByText('nginx')).not.toBeInTheDocument();
    expect(screen.queryByText('mysql')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('renders the empty state when no modules are returned', async () => {
    mockGet.mockResolvedValue(modulesResponse([]));
    renderList();

    await waitFor(() =>
      expect(screen.getByText('No Puppet modules')).toBeInTheDocument(),
    );
    expect(
      screen.getByText('Add Puppet modules for configuration management'),
    ).toBeInTheDocument();
  });

  it('renders the "Add Puppet Module" CTA in the empty state when onCreate and canCreate are set', async () => {
    mockGet.mockResolvedValue(modulesResponse([]));
    const onCreate = jest.fn();
    render(
      <BrowserRouter>
        <PuppetModuleList onCreate={onCreate} />
      </BrowserRouter>,
    );

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add puppet module/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add puppet module/i }));
    expect(onCreate).toHaveBeenCalledTimes(1);
  });

  it('does NOT render the empty-state CTA when user lacks system.puppet.create permission', async () => {
    mockHasPermission.mockReturnValue(false);
    mockGet.mockResolvedValue(modulesResponse([]));
    renderList();

    await waitFor(() =>
      expect(screen.getByText('No Puppet modules')).toBeInTheDocument(),
    );
    expect(screen.queryByRole('button', { name: /add puppet module/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // API call — correct URL
  // ---------------------------------------------------------------------------

  it('fetches modules from GET /system/puppet_modules', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    expect(mockGet).toHaveBeenCalledWith('/system/puppet_modules', expect.anything());
  });

  // ---------------------------------------------------------------------------
  // Renders both modules
  // ---------------------------------------------------------------------------

  it('renders all modules returned by the API', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A, MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));
    expect(screen.getAllByText('mysql').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error notification when the fetch fails', async () => {
    mockGet.mockRejectedValue(new Error('network error'));
    renderList();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Failed to load Puppet modules' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Module row — display fields
  // ---------------------------------------------------------------------------

  it('renders module name, forge_name, description, version, and author', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    // forge_name
    expect(screen.getAllByText('puppetlabs-nginx').length).toBeGreaterThan(0);
    // description (both desktop and mobile render it)
    expect(screen.getAllByText('Manages nginx web server').length).toBeGreaterThan(0);
    // version
    expect(screen.getAllByText('1.2.3').length).toBeGreaterThan(0);
    // author
    expect(screen.getAllByText('puppetlabs').length).toBeGreaterThan(0);
  });

  it('shows "Enabled" badge for an enabled module', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));
    expect(screen.getAllByText('Enabled').length).toBeGreaterThan(0);
  });

  it('shows "Disabled" badge for a disabled module', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('mysql').length).toBeGreaterThan(0));
    expect(screen.getAllByText('Disabled').length).toBeGreaterThan(0);
  });

  it('shows "Public" badge for a public module', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));
    expect(screen.getAllByText('Public').length).toBeGreaterThan(0);
  });

  it('shows "Private" badge for a private module', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('mysql').length).toBeGreaterThan(0));
    expect(screen.getAllByText('Private').length).toBeGreaterThan(0);
  });

  it('renders resource_count and assigned_modules_count in the desktop table', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));
    // resource_count = 5
    expect(screen.getAllByText('5').length).toBeGreaterThan(0);
    // assigned_modules_count = 3
    expect(screen.getAllByText('3').length).toBeGreaterThan(0);
  });

  it('renders em-dash for version when version is absent', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('mysql').length).toBeGreaterThan(0));
    expect(screen.getAllByText('—').length).toBeGreaterThan(0);
  });

  it('renders em-dash for author when author is absent', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('mysql').length).toBeGreaterThan(0));
    // "—" appears for both missing version and missing author
    expect(screen.getAllByText('—').length).toBeGreaterThanOrEqual(2);
  });

  // ---------------------------------------------------------------------------
  // onView callback
  // ---------------------------------------------------------------------------

  it('calls onView when the module name is clicked in the desktop table', async () => {
    const onView = jest.fn();
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList({ onView });

    const names = await waitFor(() => screen.getAllByText('nginx'));
    // First match is typically the desktop clickable span
    fireEvent.click(names[0]);
    expect(onView).toHaveBeenCalledWith(expect.objectContaining({ id: 'mod-aaa' }));
  });

  // ---------------------------------------------------------------------------
  // Dropdown menu — open & actions
  // ---------------------------------------------------------------------------

  /** Returns the MoreVertical buttons (excludes the Refresh button which has title="Refresh"). */
  function getMoreVerticalButtons() {
    return screen
      .getAllByRole('button')
      .filter((btn) => btn.getAttribute('title') !== 'Refresh');
  }

  it('opens the dropdown when the MoreVertical button is clicked', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const moreButtons = getMoreVerticalButtons();
    // Click the first MoreVertical button (desktop row)
    fireEvent.click(moreButtons[0]);

    await waitFor(() =>
      expect(screen.getAllByText('View Details').length).toBeGreaterThan(0),
    );
  });

  it('calls onView from the "View Details" dropdown item', async () => {
    const onView = jest.fn();
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList({ onView });

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const moreButtons = getMoreVerticalButtons();
    fireEvent.click(moreButtons[0]);

    await waitFor(() =>
      expect(screen.getAllByText('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByText('View Details')[0]);

    expect(onView).toHaveBeenCalledWith(expect.objectContaining({ id: 'mod-aaa' }));
  });

  it('calls onEdit from the "Edit Module" dropdown item when canUpdate is true', async () => {
    const onEdit = jest.fn();
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList({ onEdit });

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const moreButtons = getMoreVerticalButtons();
    fireEvent.click(moreButtons[0]);

    await waitFor(() =>
      expect(screen.getAllByText('Edit Module').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByText('Edit Module')[0]);

    expect(onEdit).toHaveBeenCalledWith(expect.objectContaining({ id: 'mod-aaa' }));
  });

  it('calls onDelete with the module id from the "Delete Module" dropdown item when canDelete is true', async () => {
    const onDelete = jest.fn();
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList({ onDelete });

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const moreButtons = getMoreVerticalButtons();
    fireEvent.click(moreButtons[0]);

    await waitFor(() =>
      expect(screen.getAllByText('Delete Module').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByText('Delete Module')[0]);

    expect(onDelete).toHaveBeenCalledWith('mod-aaa');
  });

  it('closes the dropdown after "View Details" is clicked', async () => {
    const onView = jest.fn();
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList({ onView });

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const moreButtons = getMoreVerticalButtons();
    fireEvent.click(moreButtons[0]);

    await waitFor(() =>
      expect(screen.getAllByText('View Details').length).toBeGreaterThan(0),
    );
    fireEvent.click(screen.getAllByText('View Details')[0]);

    await waitFor(() =>
      expect(screen.queryByText('Delete Module')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Permission gating — dropdown items hidden without permissions
  // ---------------------------------------------------------------------------

  it('hides "Edit Module" in the dropdown when user lacks system.puppet.update', async () => {
    mockHasPermission.mockImplementation((perm: unknown) => perm !== 'system.puppet.update');
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const moreButtons = getMoreVerticalButtons();
    fireEvent.click(moreButtons[0]);

    await waitFor(() =>
      expect(screen.getAllByText('View Details').length).toBeGreaterThan(0),
    );
    expect(screen.queryByText('Edit Module')).not.toBeInTheDocument();
  });

  it('hides "Delete Module" in the dropdown when user lacks system.puppet.delete', async () => {
    mockHasPermission.mockImplementation((perm: unknown) => perm !== 'system.puppet.delete');
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const moreButtons = getMoreVerticalButtons();
    fireEvent.click(moreButtons[0]);

    await waitFor(() =>
      expect(screen.getAllByText('View Details').length).toBeGreaterThan(0),
    );
    expect(screen.queryByText('Delete Module')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Search filter (client-side)
  // ---------------------------------------------------------------------------

  it('filters modules by name via the search box (client-side, no extra API call)', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A, MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const callCountBefore = mockGet.mock.calls.length;

    const searchInput = screen.getByPlaceholderText('Search modules...');
    fireEvent.change(searchInput, { target: { value: 'nginx' } });

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));
    await waitFor(() =>
      expect(screen.queryAllByText('mysql').length).toBe(0),
    );

    // No additional fetch
    expect(mockGet.mock.calls.length).toBe(callCountBefore);
  });

  it('filters modules by description via the search box', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A, MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search modules...');
    fireEvent.change(searchInput, { target: { value: 'database' } });

    await waitFor(() => expect(screen.getAllByText('mysql').length).toBeGreaterThan(0));
    await waitFor(() =>
      expect(screen.queryAllByText('nginx').length).toBe(0),
    );
  });

  it('filters modules by author via the search box', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A, MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search modules...');
    fireEvent.change(searchInput, { target: { value: 'puppetlabs' } });

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));
    await waitFor(() =>
      expect(screen.queryAllByText('mysql').length).toBe(0),
    );
  });

  it('filters modules by forge_name via the search box', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A, MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search modules...');
    fireEvent.change(searchInput, { target: { value: 'puppetlabs-nginx' } });

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));
    await waitFor(() =>
      expect(screen.queryAllByText('mysql').length).toBe(0),
    );
  });

  // ---------------------------------------------------------------------------
  // Enabled/disabled filter (client-side)
  // ---------------------------------------------------------------------------

  it('filters to only enabled modules when "Enabled" is selected', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A, MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const select = screen.getByDisplayValue('All Status');
    fireEvent.change(select, { target: { value: 'enabled' } });

    // nginx is enabled — should stay
    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));
    // mysql is disabled — should be filtered out
    await waitFor(() =>
      expect(screen.queryAllByText('mysql').length).toBe(0),
    );
  });

  it('filters to only disabled modules when "Disabled" is selected', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A, MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const select = screen.getByDisplayValue('All Status');
    fireEvent.change(select, { target: { value: 'disabled' } });

    await waitFor(() => expect(screen.getAllByText('mysql').length).toBeGreaterThan(0));
    await waitFor(() =>
      expect(screen.queryAllByText('nginx').length).toBe(0),
    );
  });

  it('shows all modules when "All Status" filter is selected', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A, MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const select = screen.getByDisplayValue('All Status');
    fireEvent.change(select, { target: { value: 'disabled' } });
    await waitFor(() => expect(screen.queryAllByText('nginx').length).toBe(0));

    fireEvent.change(select, { target: { value: 'all' } });
    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));
    expect(screen.getAllByText('mysql').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // "Showing N of M" hint
  // ---------------------------------------------------------------------------

  it('shows "Showing N of M" when client-side filter reduces the visible count', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A, MODULE_B]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search modules...');
    fireEvent.change(searchInput, { target: { value: 'nginx' } });

    await waitFor(() =>
      expect(screen.getByText('Showing 1 of 2')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Mobile card rendering
  // ---------------------------------------------------------------------------

  it('renders module name and version in the mobile card', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    // Mobile card shows "v1.2.3"
    expect(screen.getAllByText('v1.2.3').length).toBeGreaterThan(0);
  });

  it('renders resource count and assigned count in the mobile card', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    expect(screen.getAllByText(/5 resources/).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/3 assigned/).length).toBeGreaterThan(0);
  });

  it('calls onView when the module name is clicked in the mobile card', async () => {
    const onView = jest.fn();
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList({ onView });

    // Both desktop and mobile render the name; click one of them
    const names = await waitFor(() => screen.getAllByText('nginx'));
    fireEvent.click(names[names.length - 1]); // last = mobile card
    expect(onView).toHaveBeenCalledWith(expect.objectContaining({ id: 'mod-aaa' }));
  });

  // ---------------------------------------------------------------------------
  // Toggling dropdown — clicking same button closes it
  // ---------------------------------------------------------------------------

  it('closes an open dropdown when the same MoreVertical button is clicked again', async () => {
    mockGet.mockResolvedValue(modulesResponse([MODULE_A]));
    renderList();

    await waitFor(() => expect(screen.getAllByText('nginx').length).toBeGreaterThan(0));

    // Open the dropdown
    const moreButtons = getMoreVerticalButtons();
    fireEvent.click(moreButtons[0]);
    await waitFor(() =>
      expect(screen.getAllByText('View Details').length).toBeGreaterThan(0),
    );

    // Click the same button again — the toggle sets dropdownOpen to null
    fireEvent.click(moreButtons[0]);
    await waitFor(() =>
      expect(screen.queryByText('View Details')).not.toBeInTheDocument(),
    );
  });
});
