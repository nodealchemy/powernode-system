import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { TemplateComposerPage } from './TemplateComposerPage';

// =============================================================================
// Mocks
// =============================================================================

const mockGetModules = jest.fn();
const mockComposePreview = jest.fn();
const mockCreateTemplate = jest.fn();
const mockAssignModuleToTemplate = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getModules: (...args: unknown[]) => mockGetModules(...args),
    composePreview: (...args: unknown[]) => mockComposePreview(...args),
    createTemplate: (...args: unknown[]) => mockCreateTemplate(...args),
    assignModuleToTemplate: (...args: unknown[]) => mockAssignModuleToTemplate(...args),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => true,
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

const MODULE_A = {
  id: 'mod-a',
  name: 'nginx',
  variety: 'instance' as const,
  enabled: true,
  public: true,
  priority: 10,
  mask: [],
  file_spec: [],
  config: {},
  node_platform_id: 'plat-1',
  node_platform_name: 'ubuntu-22.04',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const MODULE_B = {
  id: 'mod-b',
  name: 'postgres',
  variety: 'instance' as const,
  enabled: true,
  public: true,
  priority: 20,
  mask: [],
  file_spec: [],
  config: {},
  node_platform_id: 'plat-1',
  node_platform_name: 'ubuntu-22.04',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const MODULE_C = {
  id: 'mod-c',
  name: 'redis',
  variety: 'config' as const,
  enabled: true,
  public: true,
  priority: 5,
  mask: [],
  file_spec: [],
  config: {},
  node_platform_id: 'plat-2',
  node_platform_name: 'debian-12',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PREVIEW_NO_CONFLICTS = {
  modules: [],
  conflicts: [],
  footprint: {
    module_count: 2,
    estimated_package_count: 42,
    architectures: ['x86_64'],
  },
  dependency_graph: { nodes: [], edges: [] },
};

const PREVIEW_WITH_CONFLICT = {
  modules: [],
  conflicts: [
    {
      kind: 'instance_variety_collision',
      detail: 'nginx and postgres both claim /etc/app.conf',
      module_ids: ['mod-a', 'mod-b'],
    },
  ],
  footprint: {
    module_count: 2,
    estimated_package_count: 42,
    architectures: ['x86_64'],
  },
  dependency_graph: { nodes: [], edges: [] },
};

const TEMPLATE_SAVED = {
  id: 'tpl-new',
  name: 'web-tier-prod',
  enabled: true,
  public: false,
  config: {},
  created_at: '2026-06-05T00:00:00Z',
  updated_at: '2026-06-05T00:00:00Z',
};

// systemApi.getModules resolves directly (no envelope — the facade unwraps for us)
function modulesResponse(modules: typeof MODULE_A[]) {
  return Promise.resolve({
    modules,
    meta: {
      current_page: 1,
      per_page: 200,
      total_count: modules.length,
      total_pages: 1,
      next_page: null,
      prev_page: null,
    },
  });
}

// =============================================================================
// Helper
// =============================================================================

const renderPage = () =>
  render(
    <BrowserRouter>
      <TemplateComposerPage />
    </BrowserRouter>
  );

/** Returns the <ul> inside the Composition section */
function getCompositionList(): HTMLElement {
  // The Composition section contains a heading "Composition" — walk up to
  // the containing <section> then find the ul inside it.
  const heading = screen.getByText('Composition');
  const section = heading.closest('section') as HTMLElement;
  const ul = section.querySelector('ul');
  if (!ul) throw new Error('Composition <ul> not found');
  return ul;
}

/** Finds the <ul> inside the Module Catalog section */
function getCatalogList(): HTMLElement {
  const heading = screen.getByText('Module Catalog');
  const section = heading.closest('section') as HTMLElement;
  const ul = section.querySelector('ul');
  if (!ul) throw new Error('Catalog <ul> not found');
  return ul;
}

// =============================================================================
// Tests
// =============================================================================

describe('TemplateComposerPage', () => {
  beforeEach(() => {
    mockGetModules.mockReset();
    mockComposePreview.mockReset();
    mockCreateTemplate.mockReset();
    mockAssignModuleToTemplate.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render + loading states
  // ---------------------------------------------------------------------------

  it('renders the page header and two panels', async () => {
    mockGetModules.mockReturnValue(modulesResponse([]));
    renderPage();

    expect(screen.getByText('Template Composer')).toBeInTheDocument();
    expect(screen.getByText('Module Catalog')).toBeInTheDocument();
    expect(screen.getByText('Composition')).toBeInTheDocument();
  });

  it('shows loading state while catalog is fetching', async () => {
    let resolve: (v: unknown) => void;
    mockGetModules.mockReturnValue(
      new Promise((res) => { resolve = res; })
    );
    renderPage();

    expect(screen.getByText('Loading catalog…')).toBeInTheDocument();

    // Resolve and ensure loading disappears
    resolve!(await modulesResponse([]));
    await waitFor(() =>
      expect(screen.queryByText('Loading catalog…')).not.toBeInTheDocument()
    );
  });

  it('shows empty catalog message when no modules returned', async () => {
    mockGetModules.mockReturnValue(modulesResponse([]));
    renderPage();

    await waitFor(() =>
      expect(screen.getByText('No modules match.')).toBeInTheDocument()
    );
  });

  it('shows catalog items once loaded', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A, MODULE_B]));
    renderPage();

    await waitFor(() =>
      expect(screen.getByText('nginx')).toBeInTheDocument()
    );
    expect(screen.getByText('postgres')).toBeInTheDocument();
  });

  it('fetches catalog with per_page=200', async () => {
    mockGetModules.mockReturnValue(modulesResponse([]));
    renderPage();

    await waitFor(() =>
      expect(mockGetModules).toHaveBeenCalledWith({ per_page: 200 })
    );
  });

  it('shows error notification when catalog load fails', async () => {
    mockGetModules.mockRejectedValue(new Error('Network error'));
    renderPage();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load module catalog',
      })
    );
  });

  // ---------------------------------------------------------------------------
  // Composition canvas — empty state
  // ---------------------------------------------------------------------------

  it('shows empty composition message when no modules selected', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
    expect(
      screen.getByText('Add modules from the catalog to begin composing a template.')
    ).toBeInTheDocument();
  });

  it('shows "0 module(s)" counter when canvas is empty', async () => {
    mockGetModules.mockReturnValue(modulesResponse([]));
    renderPage();

    await waitFor(() =>
      expect(screen.getByText(/0 module\(s\)/)).toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // Save button initial state
  // ---------------------------------------------------------------------------

  it('disables Save button when no modules selected', async () => {
    mockGetModules.mockReturnValue(modulesResponse([]));
    renderPage();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save as template/i })).toBeDisabled()
    );
  });

  // ---------------------------------------------------------------------------
  // Search / filter
  // ---------------------------------------------------------------------------

  it('filters catalog by module name', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A, MODULE_B]));
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());

    const search = screen.getByPlaceholderText('Search modules...');
    fireEvent.change(search, { target: { value: 'post' } });

    expect(screen.queryByText('nginx')).not.toBeInTheDocument();
    expect(screen.getByText('postgres')).toBeInTheDocument();
  });

  it('filters catalog by variety', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A, MODULE_B, MODULE_C]));
    renderPage();

    await waitFor(() => expect(screen.getByText('redis')).toBeInTheDocument());

    const search = screen.getByPlaceholderText('Search modules...');
    fireEvent.change(search, { target: { value: 'config' } });

    // MODULE_C has variety='config'
    expect(screen.getByText('redis')).toBeInTheDocument();
    expect(screen.queryByText('nginx')).not.toBeInTheDocument();
    expect(screen.queryByText('postgres')).not.toBeInTheDocument();
  });

  it('shows "No modules match." when search finds nothing', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());

    const search = screen.getByPlaceholderText('Search modules...');
    fireEvent.change(search, { target: { value: 'zzznomatch' } });

    expect(screen.getByText('No modules match.')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Adding a module
  // ---------------------------------------------------------------------------

  it('moves module from catalog to composition on Add click', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());

    // Click the Add button in the catalog panel
    const addButtons = screen.getAllByRole('button', { name: /add/i });
    fireEvent.click(addButtons[0]);

    await waitFor(() =>
      expect(screen.getByText('1 module(s)')).toBeInTheDocument()
    );

    // Module no longer appears in catalog list
    await waitFor(() =>
      expect(
        screen.queryByText('Add modules from the catalog to begin composing a template.')
      ).not.toBeInTheDocument()
    );
  });

  it('calls composePreview with the added module id', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());

    const addButtons = screen.getAllByRole('button', { name: /add/i });
    fireEvent.click(addButtons[0]);

    await waitFor(() =>
      expect(mockComposePreview).toHaveBeenCalledWith(['mod-a'])
    );
  });

  it('shows "previewing…" indicator while compose preview is in flight', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    let resolvePreview: (v: unknown) => void;
    mockComposePreview.mockReturnValue(
      new Promise((res) => { resolvePreview = res; })
    );
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());

    const addButtons = screen.getAllByRole('button', { name: /add/i });
    fireEvent.click(addButtons[0]);

    await waitFor(() =>
      expect(screen.getByText(/previewing…/)).toBeInTheDocument()
    );

    resolvePreview!(PREVIEW_NO_CONFLICTS);
    await waitFor(() =>
      expect(screen.queryByText(/previewing…/)).not.toBeInTheDocument()
    );
  });

  it('shows error notification when composePreview fails', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockRejectedValue(new Error('preview error'));
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());

    const addButtons = screen.getAllByRole('button', { name: /add/i });
    fireEvent.click(addButtons[0]);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Compose preview failed',
      })
    );
  });

  it('hides module from catalog once added', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A, MODULE_B]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getAllByRole('button', { name: /add/i }).length).toBe(2));

    // Add nginx
    const addButtons = screen.getAllByRole('button', { name: /add/i });
    fireEvent.click(addButtons[0]);

    // Only one Add button remains (postgres)
    await waitFor(() =>
      expect(screen.getAllByRole('button', { name: /add/i }).length).toBe(1)
    );
  });

  // ---------------------------------------------------------------------------
  // Removing a module
  // ---------------------------------------------------------------------------

  it('removes module from composition when X button is clicked', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());

    // Add module
    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);
    await waitFor(() => expect(screen.getByText('1 module(s)')).toBeInTheDocument());

    // Remove it — the last button in the composition row is the X (remove) button
    const compositionList = getCompositionList();
    const rows = compositionList.querySelectorAll('li');
    const btnsinRow = rows[0].querySelectorAll('button');
    fireEvent.click(btnsinRow[btnsinRow.length - 1]);

    await waitFor(() =>
      expect(screen.getByText('0 module(s)')).toBeInTheDocument()
    );
  });

  it('calls composePreview with empty array after removing the last module', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());

    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);
    await waitFor(() => expect(mockComposePreview).toHaveBeenCalledWith(['mod-a']));

    mockComposePreview.mockClear();

    const compositionList = getCompositionList();
    const rows = compositionList.querySelectorAll('li');
    const btnsInRow = rows[0].querySelectorAll('button');
    fireEvent.click(btnsInRow[btnsInRow.length - 1]);

    // With empty modules, composePreview is NOT called (early return sets preview to null)
    await waitFor(() => expect(screen.getByText('0 module(s)')).toBeInTheDocument());
    expect(mockComposePreview).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Module ordering — move up / move down
  // ---------------------------------------------------------------------------

  it('reorders modules with move-up / move-down buttons', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A, MODULE_B]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getAllByRole('button', { name: /add/i }).length).toBe(2));

    // Add A then B
    const addBtns = () => screen.getAllByRole('button', { name: /add/i });
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('1 module(s)')).toBeInTheDocument());
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('2 module(s)')).toBeInTheDocument());

    // Composition order: [nginx, postgres] — verify by ordinal labels
    // Move-up on the second item (postgres) should swap to [postgres, nginx]
    // The composition list items each have 3 buttons: up, down, remove
    const compositionList = getCompositionList();
    const rows = compositionList.querySelectorAll('li');
    expect(rows.length).toBe(2);

    // Second row = postgres, click its up button (first button in row)
    const secondRowBtns = rows[1].querySelectorAll('button');
    fireEvent.click(secondRowBtns[0]); // move up

    // After swap: postgres is first, nginx is second
    await waitFor(() => {
      const updatedList = getCompositionList();
      const updatedRows = updatedList.querySelectorAll('li');
      const firstModuleName = updatedRows[0].querySelector('.font-medium.text-sm')?.textContent;
      expect(firstModuleName).toBe('postgres');
    });
  });

  it('calls composePreview with the reordered ids after move', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A, MODULE_B]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getAllByRole('button', { name: /add/i }).length).toBe(2));

    const addBtns = () => screen.getAllByRole('button', { name: /add/i });
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('1 module(s)')).toBeInTheDocument());
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('2 module(s)')).toBeInTheDocument());

    mockComposePreview.mockClear();
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);

    const compositionList = getCompositionList();
    const rows = compositionList.querySelectorAll('li');
    // Move postgres (2nd row) up
    const secondRowBtns = rows[1].querySelectorAll('button');
    fireEvent.click(secondRowBtns[0]);

    await waitFor(() =>
      expect(mockComposePreview).toHaveBeenCalledWith(['mod-b', 'mod-a'])
    );
  });

  it('disables up button for the first item', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A, MODULE_B]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getAllByRole('button', { name: /add/i }).length).toBe(2));

    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);
    await waitFor(() => expect(screen.getByText('1 module(s)')).toBeInTheDocument());

    const compositionList = getCompositionList();
    const rows = compositionList.querySelectorAll('li');
    const firstRowBtns = rows[0].querySelectorAll('button');
    // Up button is index 0
    expect(firstRowBtns[0]).toBeDisabled();
  });

  it('disables down button for the last item', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);
    await waitFor(() => expect(screen.getByText('1 module(s)')).toBeInTheDocument());

    const compositionList = getCompositionList();
    const rows = compositionList.querySelectorAll('li');
    const firstRowBtns = rows[0].querySelectorAll('button');
    // Down button is index 1
    expect(firstRowBtns[1]).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Footprint panel
  // ---------------------------------------------------------------------------

  it('shows default footprint message before any modules are added', async () => {
    mockGetModules.mockReturnValue(modulesResponse([]));
    renderPage();

    await waitFor(() =>
      expect(
        screen.getByText('Footprint will appear once you add modules.')
      ).toBeInTheDocument()
    );
  });

  it('renders footprint data after preview resolves', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);

    await waitFor(() =>
      expect(screen.getByText('Footprint')).toBeInTheDocument()
    );
    // module_count = 2, estimated_package_count = 42
    expect(screen.getByText('2')).toBeInTheDocument();
    expect(screen.getByText('42')).toBeInTheDocument();
    expect(screen.getByText('x86_64')).toBeInTheDocument();
  });

  it('renders "—" for architectures when array is empty', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue({
      ...PREVIEW_NO_CONFLICTS,
      footprint: { module_count: 1, estimated_package_count: 5, architectures: [] },
    });
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);

    await waitFor(() =>
      expect(screen.getByText('Footprint')).toBeInTheDocument()
    );
    expect(screen.getByText('—')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Conflict panel
  // ---------------------------------------------------------------------------

  it('shows "No conflicts detected." before any composition', async () => {
    mockGetModules.mockReturnValue(modulesResponse([]));
    renderPage();

    await waitFor(() =>
      expect(screen.getByText('No conflicts detected.')).toBeInTheDocument()
    );
  });

  it('shows "No conflicts detected." when preview returns no conflicts', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);

    await waitFor(() =>
      expect(screen.getByText('No conflicts detected.')).toBeInTheDocument()
    );
  });

  it('renders conflict badges and details when preview returns conflicts', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A, MODULE_B]));
    mockComposePreview.mockResolvedValue(PREVIEW_WITH_CONFLICT);
    renderPage();

    await waitFor(() => expect(screen.getAllByRole('button', { name: /add/i }).length).toBe(2));

    const addBtns = () => screen.getAllByRole('button', { name: /add/i });
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('1 module(s)')).toBeInTheDocument());
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('2 module(s)')).toBeInTheDocument());

    await waitFor(() =>
      expect(screen.getByText('Conflicts (1)')).toBeInTheDocument()
    );
    expect(screen.getByText('instance_variety_collision')).toBeInTheDocument();
    expect(
      screen.getByText('nginx and postgres both claim /etc/app.conf')
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Save as Template button gating
  // ---------------------------------------------------------------------------

  it('enables Save button when modules are selected and no conflicts', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save as template/i })).not.toBeDisabled()
    );
  });

  it('disables Save button when there are conflicts', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A, MODULE_B]));
    mockComposePreview.mockResolvedValue(PREVIEW_WITH_CONFLICT);
    renderPage();

    await waitFor(() => expect(screen.getAllByRole('button', { name: /add/i }).length).toBe(2));

    const addBtns = () => screen.getAllByRole('button', { name: /add/i });
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('1 module(s)')).toBeInTheDocument());
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('2 module(s)')).toBeInTheDocument());

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save as template/i })).toBeDisabled()
    );
  });

  // ---------------------------------------------------------------------------
  // Save Template Modal — open / close
  // ---------------------------------------------------------------------------

  it('opens SaveTemplateModal when Save button is clicked', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save as template/i })).not.toBeDisabled()
    );
    fireEvent.click(screen.getByRole('button', { name: /save as template/i }));

    // Modal opens — the modal heading is an h2
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /save as template/i })).toBeInTheDocument()
    );
    // Modal body contains the name input
    expect(screen.getByPlaceholderText('e.g., web-tier-prod')).toBeInTheDocument();
  });

  it('closes modal when Cancel button is clicked', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save as template/i })).not.toBeDisabled()
    );
    fireEvent.click(screen.getByRole('button', { name: /save as template/i }));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /save as template/i })).toBeInTheDocument()
    );

    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }));
    await waitFor(() =>
      expect(screen.queryByPlaceholderText('e.g., web-tier-prod')).not.toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // Save Template Modal — validation
  // ---------------------------------------------------------------------------

  it('keeps Save Template button disabled until a name is entered', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save as template/i })).not.toBeDisabled()
    );
    fireEvent.click(screen.getByRole('button', { name: /save as template/i }));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /save as template/i })).toBeInTheDocument()
    );

    // With empty name the Save Template button is disabled — no API call possible
    expect(screen.getByRole('button', { name: /^save template$/i })).toBeDisabled();
    expect(mockCreateTemplate).not.toHaveBeenCalled();

    // Typing a name enables the button
    fireEvent.change(screen.getByPlaceholderText('e.g., web-tier-prod'), {
      target: { value: 'my-tpl' },
    });
    expect(screen.getByRole('button', { name: /^save template$/i })).not.toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Save Template Modal — successful save flow
  // ---------------------------------------------------------------------------

  it('calls createTemplate with correct payload and clears composition on success', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    mockCreateTemplate.mockResolvedValue(TEMPLATE_SAVED);
    mockAssignModuleToTemplate.mockResolvedValue({ id: 'assign-1', node_template_id: 'tpl-new', node_module_id: 'mod-a', enabled: true, priority: 0 });
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save as template/i })).not.toBeDisabled()
    );
    fireEvent.click(screen.getByRole('button', { name: /save as template/i }));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /save as template/i })).toBeInTheDocument()
    );

    fireEvent.change(screen.getByPlaceholderText('e.g., web-tier-prod'), {
      target: { value: 'web-tier-prod' },
    });

    fireEvent.click(screen.getByRole('button', { name: /^save template$/i }));

    await waitFor(() =>
      expect(mockCreateTemplate).toHaveBeenCalledWith({
        name: 'web-tier-prod',
        description: undefined,
        node_platform_id: 'plat-1',
        enabled: true,
      })
    );

    await waitFor(() =>
      expect(mockAssignModuleToTemplate).toHaveBeenCalledWith('tpl-new', 'mod-a')
    );

    // Modal closes after save — the name input disappears
    await waitFor(() =>
      expect(screen.queryByPlaceholderText('e.g., web-tier-prod')).not.toBeInTheDocument()
    );

    // Success notification
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Template web-tier-prod created',
      })
    );

    // Composition resets
    await waitFor(() =>
      expect(screen.getByText('0 module(s)')).toBeInTheDocument()
    );
  });

  it('shows warning notification when module assignment partially fails', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A, MODULE_B]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    mockCreateTemplate.mockResolvedValue(TEMPLATE_SAVED);
    // First assignment succeeds, second fails
    mockAssignModuleToTemplate
      .mockResolvedValueOnce({ id: 'a1', node_template_id: 'tpl-new', node_module_id: 'mod-a', enabled: true, priority: 0 })
      .mockRejectedValueOnce(new Error('assign failed'));
    renderPage();

    await waitFor(() => expect(screen.getAllByRole('button', { name: /add/i }).length).toBe(2));

    const addBtns = () => screen.getAllByRole('button', { name: /add/i });
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('1 module(s)')).toBeInTheDocument());
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('2 module(s)')).toBeInTheDocument());

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save as template/i })).not.toBeDisabled()
    );
    fireEvent.click(screen.getByRole('button', { name: /save as template/i }));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /save as template/i })).toBeInTheDocument()
    );

    fireEvent.change(screen.getByPlaceholderText('e.g., web-tier-prod'), {
      target: { value: 'web-tier-prod' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^save template$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'warning' })
      )
    );
  });

  // ---------------------------------------------------------------------------
  // Platform selector in modal (multi-platform modules)
  // ---------------------------------------------------------------------------

  it('shows platform selector when modules span multiple platforms', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A, MODULE_C])); // plat-1, plat-2
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getAllByRole('button', { name: /add/i }).length).toBe(2));

    const addBtns = () => screen.getAllByRole('button', { name: /add/i });
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('1 module(s)')).toBeInTheDocument());
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('2 module(s)')).toBeInTheDocument());

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save as template/i })).not.toBeDisabled()
    );
    fireEvent.click(screen.getByRole('button', { name: /save as template/i }));

    await waitFor(() =>
      expect(
        screen.getByText('Modules span multiple platforms; pick the target.')
      ).toBeInTheDocument()
    );
  });

  it('does NOT show platform selector when all modules share one platform', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A, MODULE_B])); // both plat-1
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    renderPage();

    await waitFor(() => expect(screen.getAllByRole('button', { name: /add/i }).length).toBe(2));

    const addBtns = () => screen.getAllByRole('button', { name: /add/i });
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('1 module(s)')).toBeInTheDocument());
    fireEvent.click(addBtns()[0]);
    await waitFor(() => expect(screen.getByText('2 module(s)')).toBeInTheDocument());

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save as template/i })).not.toBeDisabled()
    );
    fireEvent.click(screen.getByRole('button', { name: /save as template/i }));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /save as template/i })).toBeInTheDocument()
    );

    expect(
      screen.queryByText('Modules span multiple platforms; pick the target.')
    ).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Post-save state reset
  // ---------------------------------------------------------------------------

  it('resets composition and preview after successful save', async () => {
    mockGetModules.mockReturnValue(modulesResponse([MODULE_A]));
    mockComposePreview.mockResolvedValue(PREVIEW_NO_CONFLICTS);
    mockCreateTemplate.mockResolvedValue(TEMPLATE_SAVED);
    mockAssignModuleToTemplate.mockResolvedValue({ id: 'a1', node_template_id: 'tpl-new', node_module_id: 'mod-a', enabled: true, priority: 0 });
    renderPage();

    await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
    fireEvent.click(screen.getAllByRole('button', { name: /add/i })[0]);
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save as template/i })).not.toBeDisabled()
    );
    fireEvent.click(screen.getByRole('button', { name: /save as template/i }));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /save as template/i })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByPlaceholderText('e.g., web-tier-prod'), {
      target: { value: 'my-template' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^save template$/i }));

    // After save: footprint panel shows the default message again
    await waitFor(() =>
      expect(
        screen.getByText('Footprint will appear once you add modules.')
      ).toBeInTheDocument()
    );

    // Composition is empty
    expect(screen.getByText('0 module(s)')).toBeInTheDocument();

    // Save button is disabled again
    expect(screen.getByRole('button', { name: /save as template/i })).toBeDisabled();
  });
});
