import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ModuleList } from './ModuleList';
import type { SystemNodeModule, SystemNodeModuleCategory } from '@system/features/system/types/system.types';

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
  EntityLink: ({ label }: { type: string; id: string; label: string; className?: string }) => (
    <a data-testid="entity-link">{label}</a>
  ),
}));

// =============================================================================
// Helpers
// =============================================================================

/**
 * Double-envelope for getModules (paginated):
 * AxiosResponse.data = { success: true, data: { node_modules: [...] }, meta }
 * meta lives at the body ROOT (not inside data).
 */
function modulesEnvelope(modules: SystemNodeModule[]) {
  return {
    data: {
      success: true,
      data: { node_modules: modules },
      meta: {
        current_page: 1,
        per_page: modules.length || 20,
        total_count: modules.length,
        total_pages: 1,
        next_page: null,
        prev_page: null,
      },
    },
  };
}

/**
 * Double-envelope for getModuleCategories (non-paginated):
 * AxiosResponse.data = { success: true, data: { node_module_categories: [...] } }
 */
function categoriesEnvelope(categories: SystemNodeModuleCategory[]) {
  return {
    data: {
      success: true,
      data: { node_module_categories: categories },
    },
  };
}

// =============================================================================
// Fixtures
// =============================================================================

const MODULE_A: SystemNodeModule = {
  id: 'mod-aaa',
  name: 'nginx-base',
  description: 'Base nginx configuration',
  variety: 'config',
  enabled: true,
  public: true,
  priority: 10,
  mask: [],
  file_spec: [],
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const MODULE_B: SystemNodeModule = {
  id: 'mod-bbb',
  name: 'postgres-instance',
  description: 'PostgreSQL instance module',
  variety: 'instance',
  enabled: false,
  public: false,
  priority: 0,
  mask: [],
  file_spec: ['data/postgres/**'],
  config: {},
  category_id: 'cat-1',
  category_name: 'Databases',
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-02T00:00:00Z',
};

const MODULE_C: SystemNodeModule = {
  id: 'mod-ccc',
  name: 'monitoring-sub',
  variety: 'subscription',
  enabled: true,
  public: false,
  priority: 5,
  mask: [],
  file_spec: [],
  config: {},
  lock_spec: true,
  reboot_required: true,
  protected_spec: ['/etc/monitor-secret'],
  dependant: true,
  parent_module_id: 'mod-aaa',
  parent_module_name: 'nginx-base',
  dependents_count: 2,
  created_at: '2026-03-01T00:00:00Z',
  updated_at: '2026-03-02T00:00:00Z',
};

const CATEGORY_A: SystemNodeModuleCategory = {
  id: 'cat-1',
  name: 'Databases',
  depth: 0,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const CATEGORY_B: SystemNodeModuleCategory = {
  id: 'cat-2',
  name: 'Networking',
  depth: 1,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Render helper
// =============================================================================

interface RenderOpts {
  onView?: jest.Mock;
  onEdit?: jest.Mock;
  onDelete?: jest.Mock;
  onCreate?: jest.Mock;
  onCategoryCreate?: jest.Mock;
  onCategoryEdit?: jest.Mock;
  onCategoryDelete?: jest.Mock;
}

function renderModuleList(opts: RenderOpts = {}) {
  const {
    onView = jest.fn(),
    onEdit = jest.fn(),
    onDelete = jest.fn(),
    onCreate = jest.fn(),
    onCategoryCreate = jest.fn(),
    onCategoryEdit = jest.fn(),
    onCategoryDelete = jest.fn(),
  } = opts;

  return render(
    <BrowserRouter>
      <ModuleList
        onView={onView}
        onEdit={onEdit}
        onDelete={onDelete}
        onCreate={onCreate}
        onCategoryCreate={onCategoryCreate}
        onCategoryEdit={onCategoryEdit}
        onCategoryDelete={onCategoryDelete}
      />
    </BrowserRouter>,
  );
}

// Helper: set up default mock responses for both API calls
function mockBothApis(
  modules: SystemNodeModule[] = [],
  categories: SystemNodeModuleCategory[] = [],
) {
  mockGet.mockImplementation((url: string) => {
    if (url === '/system/node_modules') return Promise.resolve(modulesEnvelope(modules));
    if (url === '/system/node_module_categories') return Promise.resolve(categoriesEnvelope(categories));
    return Promise.reject(new Error(`Unexpected GET: ${url}`));
  });
}

// =============================================================================
// Tests
// =============================================================================

describe('ModuleList', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows no module rows while loading', () => {
    mockGet.mockReturnValue(new Promise(() => {}));
    renderModuleList();
    expect(screen.queryByText('nginx-base')).not.toBeInTheDocument();
    expect(screen.queryByText('postgres-instance')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('renders the empty state when no modules are returned', async () => {
    mockBothApis([], []);
    renderModuleList();

    await waitFor(() =>
      expect(screen.getByText('No modules configured')).toBeInTheDocument(),
    );
    expect(
      screen.getByText('Create modules to define node configuration packages'),
    ).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /create module/i })).toBeInTheDocument();
  });

  it('calls onCreate when the empty-state Create Module button is clicked', async () => {
    const onCreate = jest.fn();
    mockBothApis([], []);
    renderModuleList({ onCreate });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /create module/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /create module/i }));
    expect(onCreate).toHaveBeenCalledTimes(1);
  });

  it('hides the Create Module button when user lacks create permission', async () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.modules.create');
    mockBothApis([], []);
    renderModuleList({ onCreate: jest.fn() });

    await waitFor(() =>
      expect(screen.getByText('No modules configured')).toBeInTheDocument(),
    );
    expect(screen.queryByRole('button', { name: /create module/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // API calls — correct URLs
  // ---------------------------------------------------------------------------

  it('fetches modules from /system/node_modules and categories from /system/node_module_categories', async () => {
    mockBothApis([MODULE_A], [CATEGORY_A]);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    expect(mockGet).toHaveBeenCalledWith('/system/node_modules', expect.anything());
    expect(mockGet).toHaveBeenCalledWith('/system/node_module_categories');
  });

  // ---------------------------------------------------------------------------
  // Renders modules correctly
  // ---------------------------------------------------------------------------

  it('renders module names and variety badges for each module', async () => {
    mockBothApis([MODULE_A, MODULE_B], [CATEGORY_A]);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));
    expect(screen.getAllByText('postgres-instance').length).toBeGreaterThan(0);

    // Variety badges
    expect(screen.getAllByText('Config').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Instance').length).toBeGreaterThan(0);
  });

  it('renders visibility and status badges', async () => {
    mockBothApis([MODULE_A, MODULE_B], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));
    // MODULE_A: public + enabled
    expect(screen.getAllByText('Public').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Enabled').length).toBeGreaterThan(0);
    // MODULE_B: private + disabled
    expect(screen.getAllByText('Private').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Disabled').length).toBeGreaterThan(0);
  });

  it('shows priority P-number badge next to the module name when priority > 0', async () => {
    mockBothApis([MODULE_A], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));
    expect(screen.getAllByText('P10').length).toBeGreaterThan(0);
  });

  it('does not show priority badge when priority is 0', async () => {
    mockBothApis([MODULE_B], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('postgres-instance').length).toBeGreaterThan(0));
    // P0 should not appear
    expect(screen.queryByText('P0')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Flag icons for lock_spec / reboot_required / protected_spec
  // ---------------------------------------------------------------------------

  it('renders lock icon for modules with lock_spec', async () => {
    mockBothApis([MODULE_C], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('monitoring-sub').length).toBeGreaterThan(0));
    expect(screen.getAllByLabelText('Spec locked').length).toBeGreaterThan(0);
  });

  it('renders power icon for modules with reboot_required', async () => {
    mockBothApis([MODULE_C], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('monitoring-sub').length).toBeGreaterThan(0));
    const rebootIcons = screen.getAllByLabelText(/reboot required/i);
    expect(rebootIcons.length).toBeGreaterThan(0);
  });

  it('renders shield icon for modules with protected_spec entries', async () => {
    mockBothApis([MODULE_C], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('monitoring-sub').length).toBeGreaterThan(0));
    expect(screen.getAllByLabelText('Declares protected_spec').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Dependant module display
  // ---------------------------------------------------------------------------

  it('renders "dependant of" label and parent module EntityLink for dependant modules', async () => {
    mockBothApis([MODULE_C], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('monitoring-sub').length).toBeGreaterThan(0));
    expect(screen.getAllByText(/dependant of/i).length).toBeGreaterThan(0);
    // EntityLink renders parent module name
    const links = screen.getAllByTestId('entity-link');
    const parentLinks = links.filter(el => el.textContent === 'nginx-base');
    expect(parentLinks.length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Category sidebar
  // ---------------------------------------------------------------------------

  it('renders the Categories sidebar with All Categories option', async () => {
    mockBothApis([MODULE_A], [CATEGORY_A]);
    renderModuleList();

    await waitFor(() => expect(screen.getByText('Categories')).toBeInTheDocument());
    expect(screen.getByText('All Categories')).toBeInTheDocument();
  });

  it('renders category names in the sidebar', async () => {
    mockBothApis([MODULE_A, MODULE_B], [CATEGORY_A, CATEGORY_B]);
    renderModuleList();

    // Category buttons appear in the sidebar; use role=button scoped to name matching
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^Databases/ })).toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: /^Networking/ })).toBeInTheDocument();
  });

  it('shows module count per category in the sidebar', async () => {
    // MODULE_B has category_id: 'cat-1'
    mockBothApis([MODULE_A, MODULE_B], [CATEGORY_A]);
    renderModuleList();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^Databases/ })).toBeInTheDocument(),
    );
    // The Databases button text includes the count (1) as a child span
    const dbButton = screen.getByRole('button', { name: /^Databases/ });
    expect(dbButton.textContent).toContain('1');
  });

  it('shows "No categories defined" placeholder when category list is empty', async () => {
    mockBothApis([MODULE_A], []);
    renderModuleList();

    await waitFor(() => expect(screen.getByText('No categories defined')).toBeInTheDocument());
  });

  it('filters modules by category when a category button is clicked', async () => {
    mockBothApis([MODULE_A, MODULE_B], [CATEGORY_A]);
    renderModuleList();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^Databases/ })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /^Databases/ }));

    // After filter: only MODULE_B has category_id: 'cat-1'
    await waitFor(() => expect(screen.queryByText('nginx-base')).not.toBeInTheDocument());
    expect(screen.getAllByText('postgres-instance').length).toBeGreaterThan(0);
  });

  it('shows all modules when All Categories is clicked after a category filter', async () => {
    mockBothApis([MODULE_A, MODULE_B], [CATEGORY_A]);
    renderModuleList();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^Databases/ })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /^Databases/ }));
    await waitFor(() => expect(screen.queryByText('nginx-base')).not.toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /^All Categories/ }));
    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));
    expect(screen.getAllByText('postgres-instance').length).toBeGreaterThan(0);
  });

  it('hides the category sidebar when the FolderTree toggle button is clicked', async () => {
    mockBothApis([MODULE_A], [CATEGORY_A]);
    renderModuleList();

    // Wait for data to load — the filter row (which has the toggle) only renders when items exist
    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));
    // Click the toggle button (title: "Hide categories")
    const hideBtn = screen.getByTitle('Hide categories');
    fireEvent.click(hideBtn);

    await waitFor(() => expect(screen.queryByText('Categories')).not.toBeInTheDocument());
  });

  it('shows the Add Category button in the sidebar when user has create permission', async () => {
    mockBothApis([MODULE_A], []);
    renderModuleList();

    await waitFor(() => expect(screen.getByText('Categories')).toBeInTheDocument());
    expect(screen.getByTitle('Add Category')).toBeInTheDocument();
  });

  it('calls onCategoryCreate when Add Category button is clicked', async () => {
    const onCategoryCreate = jest.fn();
    mockBothApis([MODULE_A], []);
    renderModuleList({ onCategoryCreate });

    await waitFor(() => expect(screen.getByTitle('Add Category')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Add Category'));
    expect(onCategoryCreate).toHaveBeenCalledTimes(1);
  });

  it('hides the Add Category button when user lacks create permission', async () => {
    mockHasPermission.mockImplementation(
      (perm: string) => perm !== 'system.modules.create',
    );
    mockBothApis([MODULE_A], []);
    renderModuleList();

    await waitFor(() => expect(screen.getByText('Categories')).toBeInTheDocument());
    expect(screen.queryByTitle('Add Category')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Category row actions (edit / delete)
  // ---------------------------------------------------------------------------

  it('calls onCategoryEdit when the edit icon is clicked on a category (with update permission)', async () => {
    const onCategoryEdit = jest.fn();
    // MODULE_B has category_id: 'cat-1', so count > 0 → delete hidden
    // Use CATEGORY_B (no modules assigned) so count = 0 → delete would show
    mockBothApis([MODULE_A], [CATEGORY_A]);
    renderModuleList({ onCategoryEdit });

    await waitFor(() => expect(screen.getByText('Databases')).toBeInTheDocument());
    // Edit button is revealed on hover — it has title "Edit category"
    const editBtn = screen.getByTitle('Edit category');
    fireEvent.click(editBtn);
    expect(onCategoryEdit).toHaveBeenCalledWith(CATEGORY_A);
  });

  it('calls onCategoryDelete when the delete icon is clicked on an empty category', async () => {
    const onCategoryDelete = jest.fn();
    // CATEGORY_B has no modules (count = 0) → delete button should show
    mockBothApis([MODULE_A], [CATEGORY_B]);
    renderModuleList({ onCategoryDelete });

    await waitFor(() => expect(screen.getByText('Networking')).toBeInTheDocument());
    const deleteBtn = screen.getByTitle('Delete category');
    fireEvent.click(deleteBtn);
    expect(onCategoryDelete).toHaveBeenCalledWith('cat-2');
  });

  it('hides the delete category button for categories that have modules', async () => {
    // MODULE_B has category_id: 'cat-1' (count = 1) → delete should NOT show
    mockBothApis([MODULE_B], [CATEGORY_A]);
    renderModuleList();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^Databases/ })).toBeInTheDocument(),
    );
    expect(screen.queryByTitle('Delete category')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Search filter
  // ---------------------------------------------------------------------------

  it('filters modules by name via the search input', async () => {
    mockBothApis([MODULE_A, MODULE_B], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search modules...');
    fireEvent.change(searchInput, { target: { value: 'nginx' } });

    await waitFor(() => expect(screen.queryByText('postgres-instance')).not.toBeInTheDocument());
    expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0);
  });

  it('filters modules by description via the search input', async () => {
    mockBothApis([MODULE_A, MODULE_B], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search modules...');
    fireEvent.change(searchInput, { target: { value: 'PostgreSQL' } });

    await waitFor(() => expect(screen.queryByText('nginx-base')).not.toBeInTheDocument());
    expect(screen.getAllByText('postgres-instance').length).toBeGreaterThan(0);
  });

  it('filters modules by parent module name via the search input', async () => {
    mockBothApis([MODULE_A, MODULE_C], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    // MODULE_C has parent_module_name = 'nginx-base' — searching "nginx" should include it
    const searchInput = screen.getByPlaceholderText('Search modules...');
    fireEvent.change(searchInput, { target: { value: 'nginx' } });

    // Both MODULE_A (name match) and MODULE_C (parent_module_name match) stay
    await waitFor(() => expect(screen.getAllByText('monitoring-sub').length).toBeGreaterThan(0));
    expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0);
  });

  it('clears the search filter showing all modules again', async () => {
    mockBothApis([MODULE_A, MODULE_B], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    const searchInput = screen.getByPlaceholderText('Search modules...');
    fireEvent.change(searchInput, { target: { value: 'nginx' } });
    await waitFor(() => expect(screen.queryByText('postgres-instance')).not.toBeInTheDocument());

    fireEvent.change(searchInput, { target: { value: '' } });
    await waitFor(() => expect(screen.getAllByText('postgres-instance').length).toBeGreaterThan(0));
  });

  // ---------------------------------------------------------------------------
  // Variety (type) filter
  // ---------------------------------------------------------------------------

  it('filters modules by variety when the type dropdown is changed', async () => {
    mockBothApis([MODULE_A, MODULE_B, MODULE_C], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    const typeSelect = screen.getByDisplayValue('All Types');
    fireEvent.change(typeSelect, { target: { value: 'instance' } });

    await waitFor(() => expect(screen.queryByText('nginx-base')).not.toBeInTheDocument());
    expect(screen.getAllByText('postgres-instance').length).toBeGreaterThan(0);
    expect(screen.queryByText('monitoring-sub')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Enabled/disabled filter
  // ---------------------------------------------------------------------------

  it('filters to only enabled modules when the status dropdown is set to Enabled', async () => {
    mockBothApis([MODULE_A, MODULE_B], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    const statusSelect = screen.getByDisplayValue('All Status');
    fireEvent.change(statusSelect, { target: { value: 'enabled' } });

    await waitFor(() => expect(screen.queryByText('postgres-instance')).not.toBeInTheDocument());
    expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0);
  });

  it('filters to only disabled modules when the status dropdown is set to Disabled', async () => {
    mockBothApis([MODULE_A, MODULE_B], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    const statusSelect = screen.getByDisplayValue('All Status');
    fireEvent.change(statusSelect, { target: { value: 'disabled' } });

    await waitFor(() => expect(screen.queryByText('nginx-base')).not.toBeInTheDocument());
    expect(screen.getAllByText('postgres-instance').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Row actions — View / Edit / Delete
  // ---------------------------------------------------------------------------

  it('calls onView when the View Details button is clicked', async () => {
    const onView = jest.fn();
    mockBothApis([MODULE_A], []);
    renderModuleList({ onView });

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    const viewButtons = screen.getAllByTitle('View Details');
    fireEvent.click(viewButtons[0]);
    expect(onView).toHaveBeenCalledWith(MODULE_A);
  });

  it('calls onView when the module name text is clicked', async () => {
    const onView = jest.fn();
    mockBothApis([MODULE_A], []);
    renderModuleList({ onView });

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));
    // Click the first occurrence (desktop table name)
    fireEvent.click(screen.getAllByText('nginx-base')[0]);
    expect(onView).toHaveBeenCalledWith(MODULE_A);
  });

  it('calls onEdit when the Edit button is clicked (user has update permission)', async () => {
    const onEdit = jest.fn();
    mockBothApis([MODULE_A], []);
    renderModuleList({ onEdit });

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    const editButtons = screen.getAllByTitle('Edit Module');
    fireEvent.click(editButtons[0]);
    expect(onEdit).toHaveBeenCalledWith(MODULE_A);
  });

  it('hides the Edit button when user lacks update permission', async () => {
    mockHasPermission.mockImplementation(
      (perm: string) => perm !== 'system.modules.update',
    );
    mockBothApis([MODULE_A], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));
    expect(screen.queryByTitle('Edit Module')).not.toBeInTheDocument();
  });

  it('calls onDelete when the Delete button is clicked (user has delete permission)', async () => {
    const onDelete = jest.fn();
    mockBothApis([MODULE_A], []);
    renderModuleList({ onDelete });

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    const deleteButtons = screen.getAllByTitle('Delete Module');
    fireEvent.click(deleteButtons[0]);
    expect(onDelete).toHaveBeenCalledWith('mod-aaa');
  });

  it('hides the Delete button when user lacks delete permission', async () => {
    mockHasPermission.mockImplementation(
      (perm: string) => perm !== 'system.modules.delete',
    );
    mockBothApis([MODULE_A], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));
    expect(screen.queryByTitle('Delete Module')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse
  // ---------------------------------------------------------------------------

  it('expands a row to show detailed info when the chevron button is clicked', async () => {
    mockBothApis([MODULE_A], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    const expandButtons = screen.getAllByTitle('Expand details');
    fireEvent.click(expandButtons[0]);

    await waitFor(() => {
      // Expanded row shows "Type" label section
      expect(screen.getAllByText('Type').length).toBeGreaterThan(0);
      // Shows description label
      expect(screen.getAllByText('Status').length).toBeGreaterThan(0);
    });
  });

  it('collapses an expanded row when the chevron button is clicked again', async () => {
    mockBothApis([MODULE_A], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByTitle('Expand details').length).toBeGreaterThan(0));

    // Expand
    fireEvent.click(screen.getAllByTitle('Expand details')[0]);
    await waitFor(() => expect(screen.getAllByTitle('Collapse details').length).toBeGreaterThan(0));

    // Collapse
    fireEvent.click(screen.getAllByTitle('Collapse details')[0]);
    await waitFor(() => expect(screen.getAllByTitle('Expand details').length).toBeGreaterThan(0));
  });

  it('shows spec footprint counts in expanded view', async () => {
    const moduleWithSpec: SystemNodeModule = {
      ...MODULE_A,
      file_spec: ['src/**', 'lib/**'],
      package_spec: ['nginx', 'curl'],
      mask: ['/etc/nginx/blocked'],
    };
    mockBothApis([moduleWithSpec], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));
    fireEvent.click(screen.getAllByTitle('Expand details')[0]);

    // Desktop + mobile both render expanded rows — use getAllByText
    await waitFor(() => {
      expect(screen.getAllByText(/file_spec: 2/).length).toBeGreaterThan(0);
      expect(screen.getAllByText(/package_spec: 2/).length).toBeGreaterThan(0);
      expect(screen.getAllByText(/mask: 1/).length).toBeGreaterThan(0);
    });
  });

  it('shows protected_spec badge in expanded view when protected_spec is non-empty', async () => {
    mockBothApis([MODULE_C], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('monitoring-sub').length).toBeGreaterThan(0));
    fireEvent.click(screen.getAllByTitle('Expand details')[0]);

    await waitFor(() =>
      expect(screen.getAllByText(/protected_spec: 1/).length).toBeGreaterThan(0),
    );
  });

  it('shows latest version info in expanded view', async () => {
    const moduleWithVersion: SystemNodeModule = {
      ...MODULE_A,
      latest_version: {
        id: 'ver-1',
        version_number: '1.2.3',
        promotion_state: 'live',
        oci_digest: 'sha256:abc123',
        blessed_at: '2026-01-15T00:00:00Z',
        live_at: '2026-01-16T00:00:00Z',
        created_at: '2026-01-14T00:00:00Z',
      },
    };
    mockBothApis([moduleWithVersion], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));
    fireEvent.click(screen.getAllByTitle('Expand details')[0]);

    // Both desktop and mobile render "Latest Version" label
    await waitFor(() => {
      expect(screen.getAllByText('Latest Version').length).toBeGreaterThan(0);
      expect(screen.getAllByText('1.2.3').length).toBeGreaterThan(0);
      expect(screen.getAllByText('live').length).toBeGreaterThan(0);
    });
  });

  it('shows dependents count as a link in expanded view', async () => {
    mockBothApis([MODULE_C], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('monitoring-sub').length).toBeGreaterThan(0));
    fireEvent.click(screen.getAllByTitle('Expand details')[0]);

    await waitFor(() =>
      expect(screen.getAllByText(/2 modules depend on this/i).length).toBeGreaterThan(0),
    );
  });

  it('shows lifecycle flags in expanded view', async () => {
    mockBothApis([MODULE_C], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('monitoring-sub').length).toBeGreaterThan(0));
    fireEvent.click(screen.getAllByTitle('Expand details')[0]);

    await waitFor(() =>
      expect(screen.getAllByText(/reboot required on attach\/detach/i).length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText(/spec locked/).length).toBeGreaterThan(0);
  });

  it('shows Module ID in expanded view', async () => {
    mockBothApis([MODULE_A], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));
    fireEvent.click(screen.getAllByTitle('Expand details')[0]);

    // Desktop + mobile both render mod-aaa in title attr
    await waitFor(() =>
      expect(screen.getAllByTitle('mod-aaa').length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error notification when the API call fails', async () => {
    mockGet.mockRejectedValue(new Error('Network error'));
    renderModuleList();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Failed to load modules' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Multiple row expansions
  // ---------------------------------------------------------------------------

  it('allows multiple rows to be expanded simultaneously', async () => {
    mockBothApis([MODULE_A, MODULE_B], []);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('nginx-base').length).toBeGreaterThan(0));

    const expandButtons = screen.getAllByTitle('Expand details');
    // Expand both rows
    fireEvent.click(expandButtons[0]);
    fireEvent.click(expandButtons[1]);

    await waitFor(() =>
      expect(screen.getAllByTitle('Collapse details').length).toBeGreaterThanOrEqual(2),
    );
  });

  // ---------------------------------------------------------------------------
  // Category EntityLink in module rows
  // ---------------------------------------------------------------------------

  it('renders an EntityLink for the module category when category_id is set', async () => {
    mockBothApis([MODULE_B], [CATEGORY_A]);
    renderModuleList();

    await waitFor(() => expect(screen.getAllByText('postgres-instance').length).toBeGreaterThan(0));
    // EntityLink renders "Databases" label
    const links = screen.getAllByTestId('entity-link');
    const catLinks = links.filter(el => el.textContent === 'Databases');
    expect(catLinks.length).toBeGreaterThan(0);
  });
});
