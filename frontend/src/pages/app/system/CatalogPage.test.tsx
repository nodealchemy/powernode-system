import React from 'react';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import CatalogPage from './CatalogPage';

// =============================================================================
// Mocks
//
// CatalogPage is a pure routing + permission hub. It renders tab links and
// delegates content to the eight *Tab child components. We mock every child
// tab and the permission / breadcrumb hooks so we can exercise:
//   - Visible tab set (permission filter)
//   - Active tab detection (URL path)
//   - Per-tab page-action wiring (onActionsReady callbacks)
//   - No-permission empty state
// =============================================================================

// Variable must be "mock"-prefixed so Jest's module factory can reference it.
let mockHasPermissionFn: (p: string) => boolean = () => true;

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (p: string) => mockHasPermissionFn(p),
  }),
}));

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: jest.fn(),
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

// ---------------------------------------------------------------------------
// Capture the onActionsReady callbacks that CatalogPage passes to each tab.
// Tests can call these directly (wrapped in act()) to simulate a tab telling
// the hub it is ready with an action handle.
// ---------------------------------------------------------------------------

type TemplatesHandle = { openCreate: () => void };
type ModulesHandle = { openCreate: () => void; openCreateCategory: () => void };
type SingleHandle = { openCreate: () => void };

let capturedTemplatesReady: ((h: TemplatesHandle | null) => void) | undefined;
let capturedModulesReady: ((h: ModulesHandle | null) => void) | undefined;
let capturedPackageRepoReady: ((h: SingleHandle | null) => void) | undefined;
let capturedPuppetReady: ((h: SingleHandle | null) => void) | undefined;
let capturedScriptsReady: ((h: SingleHandle | null) => void) | undefined;
let capturedArchitecturesReady: ((h: SingleHandle | null) => void) | undefined;
let capturedPlatformsReady: ((h: SingleHandle | null) => void) | undefined;

jest.mock('@system/features/system/components/catalog', () => ({
  TemplatesTab: ({ onActionsReady }: { onActionsReady?: (h: TemplatesHandle | null) => void }) => {
    capturedTemplatesReady = onActionsReady;
    return <div data-testid="tab-templates" />;
  },
  ModulesTab: ({ onActionsReady }: { onActionsReady?: (h: ModulesHandle | null) => void }) => {
    capturedModulesReady = onActionsReady;
    return <div data-testid="tab-modules" />;
  },
  PackageRepositoriesTab: ({ onActionsReady }: { onActionsReady?: (h: SingleHandle | null) => void }) => {
    capturedPackageRepoReady = onActionsReady;
    return <div data-testid="tab-package-repositories" />;
  },
  PuppetModulesTab: ({ onActionsReady }: { onActionsReady?: (h: SingleHandle | null) => void }) => {
    capturedPuppetReady = onActionsReady;
    return <div data-testid="tab-puppet-modules" />;
  },
  ScriptsTab: ({ onActionsReady }: { onActionsReady?: (h: SingleHandle | null) => void }) => {
    capturedScriptsReady = onActionsReady;
    return <div data-testid="tab-scripts" />;
  },
  ArchitecturesTab: ({ onActionsReady }: { onActionsReady?: (h: SingleHandle | null) => void }) => {
    capturedArchitecturesReady = onActionsReady;
    return <div data-testid="tab-architectures" />;
  },
  PlatformsTab: ({ onActionsReady }: { onActionsReady?: (h: SingleHandle | null) => void }) => {
    capturedPlatformsReady = onActionsReady;
    return <div data-testid="tab-platforms" />;
  },
  MarketplaceTab: () => <div data-testid="tab-marketplace" />,
}));

// =============================================================================
// Render helpers
// =============================================================================

/**
 * Render CatalogPage inside a MemoryRouter with Routes so the component can
 * use <Routes> + <Route> internally and the URL is controllable.
 *
 * CatalogPage is mounted at `/app/system/catalog/*` to mirror the production
 * router. All child <Route path="…"> elements are relative to that base.
 */
function renderPage(initialPath = '/app/system/catalog') {
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route path="/app/system/catalog/*" element={<CatalogPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

// Call a captured onActionsReady callback inside act() so React flushes state.
function fireActionsReady<T>(cb: ((h: T | null) => void) | undefined, handle: T | null): void {
  act(() => {
    cb?.(handle);
  });
}

// =============================================================================
// Tests
// =============================================================================

describe('CatalogPage', () => {
  beforeEach(() => {
    mockHasPermissionFn = () => true;
    capturedTemplatesReady = undefined;
    capturedModulesReady = undefined;
    capturedPackageRepoReady = undefined;
    capturedPuppetReady = undefined;
    capturedScriptsReady = undefined;
    capturedArchitecturesReady = undefined;
    capturedPlatformsReady = undefined;
  });

  // ---------------------------------------------------------------------------
  // No-permission empty state
  // ---------------------------------------------------------------------------

  it('shows the no-permission message when the user lacks all read permissions', () => {
    mockHasPermissionFn =() => false;

    renderPage();

    expect(
      screen.getByText(/you don.t have permission to view any catalog resources/i),
    ).toBeInTheDocument();
    // Tab nav should not be rendered
    expect(screen.queryByRole('link', { name: /templates/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Full permission — all tabs visible
  // ---------------------------------------------------------------------------

  it('renders all 8 tab links when the user has all read permissions', () => {
    renderPage();

    expect(screen.getByRole('link', { name: /^templates$/i })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /^modules$/i })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /^package repositories$/i })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /^puppet modules$/i })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /^scripts$/i })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /^architectures$/i })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /^platforms$/i })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /^marketplace$/i })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Permission filtering — only permitted tabs appear
  // ---------------------------------------------------------------------------

  it('hides tabs for which the user lacks the read permission', () => {
    mockHasPermissionFn =(p) =>
      !['system.puppet.read', 'system.scripts.read', 'system.marketplace.read'].includes(p);

    renderPage('/app/system/catalog/templates');

    expect(screen.getByRole('link', { name: /^templates$/i })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /^modules$/i })).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: /^puppet modules$/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: /^scripts$/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: /^marketplace$/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Active tab detection — path → active styling
  // ---------------------------------------------------------------------------

  it('marks the templates tab link as active when the URL ends in /templates', () => {
    renderPage('/app/system/catalog/templates');

    const link = screen.getByRole('link', { name: /^templates$/i });
    // Active tabs get a focus border class; inactive get transparent border
    expect(link.className).toContain('border-theme-focus');
  });

  it('marks the modules tab link as active when the URL ends in /modules', () => {
    renderPage('/app/system/catalog/modules');

    const link = screen.getByRole('link', { name: /^modules$/i });
    expect(link.className).toContain('border-theme-focus');
  });

  it('marks the architectures tab link as active when the URL ends in /architectures', () => {
    renderPage('/app/system/catalog/architectures');

    const link = screen.getByRole('link', { name: /^architectures$/i });
    expect(link.className).toContain('border-theme-focus');
  });

  it('marks inactive tab links with a transparent border class', () => {
    renderPage('/app/system/catalog/templates');

    const modulesLink = screen.getByRole('link', { name: /^modules$/i });
    expect(modulesLink.className).toContain('border-transparent');
  });

  // ---------------------------------------------------------------------------
  // Tab link hrefs — each points at the correct sub-path
  // ---------------------------------------------------------------------------

  it('builds correct hrefs for every tab link', () => {
    renderPage('/app/system/catalog/templates');

    const cases: [string, string][] = [
      ['templates', '/app/system/catalog/templates'],
      ['modules', '/app/system/catalog/modules'],
      ['package repositories', '/app/system/catalog/package-repositories'],
      ['puppet modules', '/app/system/catalog/puppet-modules'],
      ['scripts', '/app/system/catalog/scripts'],
      ['architectures', '/app/system/catalog/architectures'],
      ['platforms', '/app/system/catalog/platforms'],
      ['marketplace', '/app/system/catalog/marketplace'],
    ];

    for (const [name, href] of cases) {
      const link = screen.getByRole('link', { name: new RegExp(`^${name}$`, 'i') });
      expect(link).toHaveAttribute('href', href);
    }
  });

  // ---------------------------------------------------------------------------
  // Routed tab content — correct sentinel rendered per URL
  // ---------------------------------------------------------------------------

  it('renders the TemplatesTab sentinel when at /templates', () => {
    renderPage('/app/system/catalog/templates');
    expect(screen.getByTestId('tab-templates')).toBeInTheDocument();
  });

  it('renders the ModulesTab sentinel when at /modules', () => {
    renderPage('/app/system/catalog/modules');
    expect(screen.getByTestId('tab-modules')).toBeInTheDocument();
  });

  it('renders the PackageRepositoriesTab sentinel when at /package-repositories', () => {
    renderPage('/app/system/catalog/package-repositories');
    expect(screen.getByTestId('tab-package-repositories')).toBeInTheDocument();
  });

  it('renders the PuppetModulesTab sentinel when at /puppet-modules', () => {
    renderPage('/app/system/catalog/puppet-modules');
    expect(screen.getByTestId('tab-puppet-modules')).toBeInTheDocument();
  });

  it('renders the ScriptsTab sentinel when at /scripts', () => {
    renderPage('/app/system/catalog/scripts');
    expect(screen.getByTestId('tab-scripts')).toBeInTheDocument();
  });

  it('renders the ArchitecturesTab sentinel when at /architectures', () => {
    renderPage('/app/system/catalog/architectures');
    expect(screen.getByTestId('tab-architectures')).toBeInTheDocument();
  });

  it('renders the PlatformsTab sentinel when at /platforms', () => {
    renderPage('/app/system/catalog/platforms');
    expect(screen.getByTestId('tab-platforms')).toBeInTheDocument();
  });

  it('renders the MarketplaceTab sentinel when at /marketplace', () => {
    renderPage('/app/system/catalog/marketplace');
    expect(screen.getByTestId('tab-marketplace')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Page title
  // ---------------------------------------------------------------------------

  it('renders the "Catalog" page heading', () => {
    renderPage('/app/system/catalog/templates');

    expect(screen.getByRole('heading', { name: /^catalog$/i })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Page actions — no action buttons before onActionsReady fires
  // ---------------------------------------------------------------------------

  it('renders no Create action button before any tab fires onActionsReady', () => {
    renderPage('/app/system/catalog/templates');

    // PageContainer renders actions as <button aria-label="…">
    expect(screen.queryByRole('button', { name: /create template/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /create module/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Page actions — "Create Template" button wired when TemplatesTab is active
  // ---------------------------------------------------------------------------

  it('shows "Create Template" when TemplatesTab fires onActionsReady and templates tab is active', () => {
    renderPage('/app/system/catalog/templates');

    const openCreate = jest.fn();
    fireActionsReady(capturedTemplatesReady, { openCreate });

    expect(screen.getByRole('button', { name: /create template/i })).toBeInTheDocument();
  });

  it('calls TemplatesTab openCreate when the Create Template button is clicked', () => {
    renderPage('/app/system/catalog/templates');

    const openCreate = jest.fn();
    fireActionsReady(capturedTemplatesReady, { openCreate });

    fireEvent.click(screen.getByRole('button', { name: /create template/i }));

    expect(openCreate).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Page actions — Modules tab has two buttons
  // ---------------------------------------------------------------------------

  it('shows "Create Module" and "New Category" when ModulesTab fires onActionsReady and modules tab is active', () => {
    renderPage('/app/system/catalog/modules');

    const openCreate = jest.fn();
    const openCreateCategory = jest.fn();
    fireActionsReady(capturedModulesReady, { openCreate, openCreateCategory });

    expect(screen.getByRole('button', { name: /create module/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /new category/i })).toBeInTheDocument();
  });

  it('calls openCreate when Create Module is clicked', () => {
    renderPage('/app/system/catalog/modules');

    const openCreate = jest.fn();
    const openCreateCategory = jest.fn();
    fireActionsReady(capturedModulesReady, { openCreate, openCreateCategory });

    fireEvent.click(screen.getByRole('button', { name: /create module/i }));

    expect(openCreate).toHaveBeenCalledTimes(1);
    expect(openCreateCategory).not.toHaveBeenCalled();
  });

  it('calls openCreateCategory when New Category is clicked', () => {
    renderPage('/app/system/catalog/modules');

    const openCreate = jest.fn();
    const openCreateCategory = jest.fn();
    fireActionsReady(capturedModulesReady, { openCreate, openCreateCategory });

    fireEvent.click(screen.getByRole('button', { name: /new category/i }));

    expect(openCreateCategory).toHaveBeenCalledTimes(1);
    expect(openCreate).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Page actions — Package Repositories tab
  // ---------------------------------------------------------------------------

  it('shows "Add Repository" when PackageRepositoriesTab fires onActionsReady and that tab is active', () => {
    renderPage('/app/system/catalog/package-repositories');

    const openCreate = jest.fn();
    fireActionsReady(capturedPackageRepoReady, { openCreate });

    expect(screen.getByRole('button', { name: /add repository/i })).toBeInTheDocument();
  });

  it('calls openCreate when Add Repository is clicked', () => {
    renderPage('/app/system/catalog/package-repositories');

    const openCreate = jest.fn();
    fireActionsReady(capturedPackageRepoReady, { openCreate });

    fireEvent.click(screen.getByRole('button', { name: /add repository/i }));

    expect(openCreate).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Page actions — Puppet Modules tab
  // ---------------------------------------------------------------------------

  it('shows "Add Puppet Module" when PuppetModulesTab fires onActionsReady and that tab is active', () => {
    renderPage('/app/system/catalog/puppet-modules');

    const openCreate = jest.fn();
    fireActionsReady(capturedPuppetReady, { openCreate });

    expect(screen.getByRole('button', { name: /add puppet module/i })).toBeInTheDocument();
  });

  it('calls openCreate when Add Puppet Module is clicked', () => {
    renderPage('/app/system/catalog/puppet-modules');

    const openCreate = jest.fn();
    fireActionsReady(capturedPuppetReady, { openCreate });

    fireEvent.click(screen.getByRole('button', { name: /add puppet module/i }));

    expect(openCreate).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Page actions — Scripts tab
  // ---------------------------------------------------------------------------

  it('shows "Create Script" when ScriptsTab fires onActionsReady and that tab is active', () => {
    renderPage('/app/system/catalog/scripts');

    const openCreate = jest.fn();
    fireActionsReady(capturedScriptsReady, { openCreate });

    expect(screen.getByRole('button', { name: /create script/i })).toBeInTheDocument();
  });

  it('calls openCreate when Create Script is clicked', () => {
    renderPage('/app/system/catalog/scripts');

    const openCreate = jest.fn();
    fireActionsReady(capturedScriptsReady, { openCreate });

    fireEvent.click(screen.getByRole('button', { name: /create script/i }));

    expect(openCreate).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Page actions — Architectures tab
  // ---------------------------------------------------------------------------

  it('shows "Create Architecture" when ArchitecturesTab fires onActionsReady and that tab is active', () => {
    renderPage('/app/system/catalog/architectures');

    const openCreate = jest.fn();
    fireActionsReady(capturedArchitecturesReady, { openCreate });

    expect(screen.getByRole('button', { name: /create architecture/i })).toBeInTheDocument();
  });

  it('calls openCreate when Create Architecture is clicked', () => {
    renderPage('/app/system/catalog/architectures');

    const openCreate = jest.fn();
    fireActionsReady(capturedArchitecturesReady, { openCreate });

    fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

    expect(openCreate).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Page actions — Platforms tab
  // ---------------------------------------------------------------------------

  it('shows "Create Platform" when PlatformsTab fires onActionsReady and that tab is active', () => {
    renderPage('/app/system/catalog/platforms');

    const openCreate = jest.fn();
    fireActionsReady(capturedPlatformsReady, { openCreate });

    expect(screen.getByRole('button', { name: /create platform/i })).toBeInTheDocument();
  });

  it('calls openCreate when Create Platform is clicked', () => {
    renderPage('/app/system/catalog/platforms');

    const openCreate = jest.fn();
    fireActionsReady(capturedPlatformsReady, { openCreate });

    fireEvent.click(screen.getByRole('button', { name: /create platform/i }));

    expect(openCreate).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Marketplace has no page action
  // ---------------------------------------------------------------------------

  it('shows no page action button when the marketplace tab is active', () => {
    renderPage('/app/system/catalog/marketplace');

    // MarketplaceTab has no onActionsReady; no action buttons should appear
    expect(screen.queryByRole('button', { name: /create|add|new category/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Actions suppressed when user lacks create permission
  // ---------------------------------------------------------------------------

  it('does not show "Create Template" when user lacks system.templates.create', () => {
    mockHasPermissionFn =(p) => p !== 'system.templates.create';

    renderPage('/app/system/catalog/templates');

    const openCreate = jest.fn();
    fireActionsReady(capturedTemplatesReady, { openCreate });

    expect(screen.queryByRole('button', { name: /create template/i })).not.toBeInTheDocument();
  });

  it('does not show "Create Module" or "New Category" when user lacks system.modules.create', () => {
    mockHasPermissionFn =(p) => p !== 'system.modules.create';

    renderPage('/app/system/catalog/modules');

    const openCreate = jest.fn();
    const openCreateCategory = jest.fn();
    fireActionsReady(capturedModulesReady, { openCreate, openCreateCategory });

    expect(screen.queryByRole('button', { name: /create module/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /new category/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Actions not shown for wrong active tab
  // ---------------------------------------------------------------------------

  it('does not show the Templates create action when the active tab is modules', () => {
    renderPage('/app/system/catalog/modules');

    const openCreate = jest.fn();
    fireActionsReady(capturedTemplatesReady, { openCreate });

    // TemplatesTab fired its callback, but modules is the active tab —
    // the Templates button must not appear
    expect(screen.queryByRole('button', { name: /create template/i })).not.toBeInTheDocument();
  });

  it('does not show the Modules create actions when the active tab is templates', () => {
    renderPage('/app/system/catalog/templates');

    const openCreate = jest.fn();
    const openCreateCategory = jest.fn();
    fireActionsReady(capturedModulesReady, { openCreate, openCreateCategory });

    expect(screen.queryByRole('button', { name: /create module/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /new category/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onActionsReady cleared when tab unmounts (null call)
  // ---------------------------------------------------------------------------

  it('removes the create action when the active tab fires onActionsReady(null)', () => {
    renderPage('/app/system/catalog/templates');

    const openCreate = jest.fn();
    fireActionsReady(capturedTemplatesReady, { openCreate });

    // Button should be visible
    expect(screen.getByRole('button', { name: /create template/i })).toBeInTheDocument();

    // Tab signals unmount / removal
    fireActionsReady(capturedTemplatesReady, null);

    expect(screen.queryByRole('button', { name: /create template/i })).not.toBeInTheDocument();
  });
});
