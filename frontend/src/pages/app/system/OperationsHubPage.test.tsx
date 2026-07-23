import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import OperationsHubPage from './OperationsHubPage';

// =============================================================================
// Mocks
//
// OperationsHubPage is a routing hub — it renders tab components via React
// Router <Route>s and passes onActionsReady callbacks to GitopsTab, CveTab,
// CiWorkersTab, and CiWebhooksTab. We stub all heavy child components so the
// hub's own logic (tab visibility, permission gating, active-tab detection,
// header action wiring) can be tested in isolation.
// =============================================================================

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

// ---------------------------------------------------------------------------
// Child tab stubs.  Each stub calls onActionsReady (if provided) so the hub
// can wire header action buttons.
//
// Note: jest.mock() factories cannot reference out-of-scope variables unless
// they are prefixed with "mock" (case insensitive). We use that convention for
// the action handles and use require('react').useEffect inside the factory.
// ---------------------------------------------------------------------------

const mockGitopsOpenCreate = jest.fn();
const mockCveRefresh = jest.fn();
const mockCiWorkersOpenCreate = jest.fn();
const mockCiWebhooksOpenCreate = jest.fn();
const mockModuleBuildsRefresh = jest.fn();
const mockAgentPeersRefresh = jest.fn();

jest.mock('@system/features/system/components/operations', () => {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { useEffect } = require('react');
  return {
    FleetTab: () => {
      return require('react').createElement('div', { 'data-testid': 'fleet-tab' }, 'FleetTab');
    },
    TasksTab: () =>
      require('react').createElement('div', { 'data-testid': 'tasks-tab' }, 'TasksTab'),
    GitopsTab: (props: { onActionsReady?: (h: { openCreate: () => void } | null) => void }) => {
      useEffect(() => {
        props.onActionsReady?.({ openCreate: mockGitopsOpenCreate });
        return () => props.onActionsReady?.(null);
      }, []);
      return require('react').createElement('div', { 'data-testid': 'gitops-tab' }, 'GitopsTab');
    },
    CveTab: (props: { onActionsReady?: (h: { refresh: () => void } | null) => void }) => {
      useEffect(() => {
        props.onActionsReady?.({ refresh: mockCveRefresh });
        return () => props.onActionsReady?.(null);
      }, []);
      return require('react').createElement('div', { 'data-testid': 'cve-tab' }, 'CveTab');
    },
    CiWorkersTab: (props: {
      onActionsReady?: (h: { openCreate: () => void } | null) => void;
    }) => {
      useEffect(() => {
        props.onActionsReady?.({ openCreate: mockCiWorkersOpenCreate });
        return () => props.onActionsReady?.(null);
      }, []);
      return require('react').createElement(
        'div',
        { 'data-testid': 'ci-workers-tab' },
        'CiWorkersTab',
      );
    },
    CiWebhooksTab: (props: {
      onActionsReady?: (h: { openCreate: () => void } | null) => void;
    }) => {
      useEffect(() => {
        props.onActionsReady?.({ openCreate: mockCiWebhooksOpenCreate });
        return () => props.onActionsReady?.(null);
      }, []);
      return require('react').createElement(
        'div',
        { 'data-testid': 'ci-webhooks-tab' },
        'CiWebhooksTab',
      );
    },
    ModuleBuildsTab: (props: { onActionsReady?: (h: { refresh: () => void } | null) => void }) => {
      useEffect(() => {
        props.onActionsReady?.({ refresh: mockModuleBuildsRefresh });
        return () => props.onActionsReady?.(null);
      }, []);
      return require('react').createElement(
        'div',
        { 'data-testid': 'module-builds-tab' },
        'ModuleBuildsTab',
      );
    },
    AgentPeersTab: (props: { onActionsReady?: (h: { refresh: () => void } | null) => void }) => {
      useEffect(() => {
        props.onActionsReady?.({ refresh: mockAgentPeersRefresh });
        return () => props.onActionsReady?.(null);
      }, []);
      return require('react').createElement(
        'div',
        { 'data-testid': 'agent-peers-tab' },
        'AgentPeersTab',
      );
    },
  };
});

// SystemSettingsPanel is a heavy modal with its own hooks. Stub it.
// We capture onClose so tests can invoke it to assert the panel closes.
let capturedSettingsOnClose: (() => void) | null = null;
jest.mock('@system/features/system/components/settings/SystemSettingsPanel', () => ({
  SystemSettingsPanel: ({
    isOpen,
    onClose,
  }: {
    isOpen: boolean;
    onClose: () => void;
  }) => {
    capturedSettingsOnClose = onClose;
    return isOpen
      ? require('react').createElement('div', { 'data-testid': 'settings-panel' }, 'SystemSettingsPanel')
      : null;
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/**
 * Render OperationsHubPage inside a MemoryRouter at the given path.
 * The hub is mounted at /app/system/operations/*  so we nest it under a
 * wildcard route to satisfy react-router's <Routes> usage inside the component.
 */
const renderPage = (initialPath = '/app/system/operations/fleet') =>
  render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route path="/app/system/operations/*" element={<OperationsHubPage />} />
      </Routes>
    </MemoryRouter>,
  );

// All visible permissions by default; override per test as needed.
const ALL_PERMISSIONS = [
  'system.fleet.autonomy',
  'system.tasks.read',
  'system.gitops.read',
  'system.cve.read',
  'system.ci_workers.read',
  'system.disk_image_webhooks.read',
  'system.gitops.write',
  'system.ci_workers.create',
  'system.disk_image_webhooks.create',
  'system.infra_tasks.read',
  'system.module_builds.read',
];

// =============================================================================
// Tests
// =============================================================================

describe('OperationsHubPage', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    capturedSettingsOnClose = null;
    mockHasPermission.mockImplementation((perm: string) => ALL_PERMISSIONS.includes(perm));
  });

  // ---------------------------------------------------------------------------
  // Basic rendering
  // ---------------------------------------------------------------------------

  it('renders the page title "Operations"', () => {
    renderPage();
    // The title appears as an h1 in PageContainer
    expect(screen.getByRole('heading', { name: 'Operations', level: 1 })).toBeInTheDocument();
  });

  it('renders all 7 tab links when user has all permissions', () => {
    renderPage();
    expect(screen.getByRole('link', { name: 'Fleet' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Tasks' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'GitOps' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'CVE' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'CI Workers' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'CI Webhooks' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Module Builds' })).toBeInTheDocument();
  });

  it('renders FleetTab at the /fleet path', () => {
    renderPage('/app/system/operations/fleet');
    expect(screen.getByTestId('fleet-tab')).toBeInTheDocument();
  });

  it('renders TasksTab at the /tasks path', () => {
    renderPage('/app/system/operations/tasks');
    expect(screen.getByTestId('tasks-tab')).toBeInTheDocument();
  });

  it('renders GitopsTab at the /gitops path', () => {
    renderPage('/app/system/operations/gitops');
    expect(screen.getByTestId('gitops-tab')).toBeInTheDocument();
  });

  it('renders CveTab at the /cve path', () => {
    renderPage('/app/system/operations/cve');
    expect(screen.getByTestId('cve-tab')).toBeInTheDocument();
  });

  it('renders CiWorkersTab at the /ci-workers path', () => {
    renderPage('/app/system/operations/ci-workers');
    expect(screen.getByTestId('ci-workers-tab')).toBeInTheDocument();
  });

  it('renders CiWebhooksTab at the /ci-webhooks path', () => {
    renderPage('/app/system/operations/ci-webhooks');
    expect(screen.getByTestId('ci-webhooks-tab')).toBeInTheDocument();
  });

  it('renders ModuleBuildsTab at the /module-builds path', () => {
    renderPage('/app/system/operations/module-builds');
    expect(screen.getByTestId('module-builds-tab')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Active tab detection
  // ---------------------------------------------------------------------------

  it('marks the Fleet tab link as active (border-theme-focus class) on /fleet', () => {
    renderPage('/app/system/operations/fleet');
    const fleetLink = screen.getByRole('link', { name: 'Fleet' });
    expect(fleetLink.className).toContain('border-theme-focus');
  });

  it('marks the Tasks tab link as active on /tasks', () => {
    renderPage('/app/system/operations/tasks');
    const tasksLink = screen.getByRole('link', { name: 'Tasks' });
    expect(tasksLink.className).toContain('border-theme-focus');
  });

  it('marks the GitOps tab link as active on /gitops', () => {
    renderPage('/app/system/operations/gitops');
    const gitopsLink = screen.getByRole('link', { name: 'GitOps' });
    expect(gitopsLink.className).toContain('border-theme-focus');
  });

  it('marks the CVE tab link as active on /cve', () => {
    renderPage('/app/system/operations/cve');
    const cveLink = screen.getByRole('link', { name: 'CVE' });
    expect(cveLink.className).toContain('border-theme-focus');
  });

  it('marks the CI Workers tab link as active on /ci-workers', () => {
    renderPage('/app/system/operations/ci-workers');
    const link = screen.getByRole('link', { name: 'CI Workers' });
    expect(link.className).toContain('border-theme-focus');
  });

  it('marks the CI Webhooks tab link as active on /ci-webhooks', () => {
    renderPage('/app/system/operations/ci-webhooks');
    const link = screen.getByRole('link', { name: 'CI Webhooks' });
    expect(link.className).toContain('border-theme-focus');
  });

  it('marks the Module Builds tab link as active on /module-builds', () => {
    renderPage('/app/system/operations/module-builds');
    const link = screen.getByRole('link', { name: 'Module Builds' });
    expect(link.className).toContain('border-theme-focus');
  });

  it('inactive tab links have border-transparent class', () => {
    renderPage('/app/system/operations/fleet');
    const tasksLink = screen.getByRole('link', { name: 'Tasks' });
    expect(tasksLink.className).toContain('border-transparent');
  });

  // ---------------------------------------------------------------------------
  // Permission gating — tab visibility
  // ---------------------------------------------------------------------------

  it('hides Fleet tab when system.fleet.autonomy permission is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) => perm !== 'system.fleet.autonomy' && ALL_PERMISSIONS.includes(perm),
    );
    renderPage('/app/system/operations/tasks');
    expect(screen.queryByRole('link', { name: 'Fleet' })).not.toBeInTheDocument();
  });

  it('hides Tasks tab when system.tasks.read permission is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) => perm !== 'system.tasks.read' && ALL_PERMISSIONS.includes(perm),
    );
    renderPage('/app/system/operations/fleet');
    expect(screen.queryByRole('link', { name: 'Tasks' })).not.toBeInTheDocument();
  });

  it('hides GitOps tab when system.gitops.read permission is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) => perm !== 'system.gitops.read' && ALL_PERMISSIONS.includes(perm),
    );
    renderPage('/app/system/operations/fleet');
    expect(screen.queryByRole('link', { name: 'GitOps' })).not.toBeInTheDocument();
  });

  it('hides CVE tab when system.cve.read permission is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) => perm !== 'system.cve.read' && ALL_PERMISSIONS.includes(perm),
    );
    renderPage('/app/system/operations/fleet');
    expect(screen.queryByRole('link', { name: 'CVE' })).not.toBeInTheDocument();
  });

  it('hides CI Workers tab when system.ci_workers.read permission is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) => perm !== 'system.ci_workers.read' && ALL_PERMISSIONS.includes(perm),
    );
    renderPage('/app/system/operations/fleet');
    expect(screen.queryByRole('link', { name: 'CI Workers' })).not.toBeInTheDocument();
  });

  it('hides CI Webhooks tab when system.disk_image_webhooks.read permission is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.disk_image_webhooks.read' && ALL_PERMISSIONS.includes(perm),
    );
    renderPage('/app/system/operations/fleet');
    expect(screen.queryByRole('link', { name: 'CI Webhooks' })).not.toBeInTheDocument();
  });

  it('hides Module Builds tab when system.module_builds.read permission is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.module_builds.read' && ALL_PERMISSIONS.includes(perm),
    );
    renderPage('/app/system/operations/fleet');
    expect(screen.queryByRole('link', { name: 'Module Builds' })).not.toBeInTheDocument();
  });

  it('shows the no-permission message when user has no tab permissions at all', () => {
    mockHasPermission.mockReturnValue(false);
    renderPage('/app/system/operations/fleet');
    expect(
      screen.getByText(/you don.*t have permission to view any operations resources/i),
    ).toBeInTheDocument();
  });

  it('does not render the tab nav when user has no tab permissions', () => {
    mockHasPermission.mockReturnValue(false);
    renderPage('/app/system/operations/fleet');
    expect(screen.queryByRole('link', { name: 'Fleet' })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Settings button (system.infra_tasks.read permission gates it)
  // ---------------------------------------------------------------------------

  it('renders the Settings action button when system.infra_tasks.read is granted', () => {
    renderPage();
    expect(screen.getByRole('button', { name: /settings/i })).toBeInTheDocument();
  });

  it('does not render the Settings action button when system.infra_tasks.read is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.infra_tasks.read' && ALL_PERMISSIONS.includes(perm),
    );
    renderPage();
    expect(screen.queryByRole('button', { name: /settings/i })).not.toBeInTheDocument();
  });

  it('opens the SystemSettingsPanel when Settings is clicked', async () => {
    renderPage();
    expect(screen.queryByTestId('settings-panel')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /settings/i }));
    await waitFor(() =>
      expect(screen.getByTestId('settings-panel')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Header action — GitOps "New repository" button
  // ---------------------------------------------------------------------------

  it('shows "New repository" action button on the gitops tab when write permission is granted', async () => {
    renderPage('/app/system/operations/gitops');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /new repository/i })).toBeInTheDocument(),
    );
  });

  it('does not show "New repository" button on gitops tab when system.gitops.write is absent', async () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.gitops.write' && ALL_PERMISSIONS.includes(perm),
    );
    renderPage('/app/system/operations/gitops');
    await waitFor(() => expect(screen.getByTestId('gitops-tab')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /new repository/i })).not.toBeInTheDocument();
  });

  it('calls gitopsActions.openCreate when "New repository" is clicked', async () => {
    renderPage('/app/system/operations/gitops');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /new repository/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /new repository/i }));
    expect(mockGitopsOpenCreate).toHaveBeenCalledTimes(1);
  });

  it('does not show "New repository" button on a non-gitops tab', () => {
    renderPage('/app/system/operations/fleet');
    expect(screen.queryByRole('button', { name: /new repository/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Header action — CVE "Refresh" button
  // ---------------------------------------------------------------------------

  it('shows "Refresh" action button on the cve tab', async () => {
    renderPage('/app/system/operations/cve');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /refresh/i })).toBeInTheDocument(),
    );
  });

  it('calls cveActions.refresh when "Refresh" is clicked', async () => {
    renderPage('/app/system/operations/cve');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /refresh/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /refresh/i }));
    expect(mockCveRefresh).toHaveBeenCalledTimes(1);
  });

  it('does not show "Refresh" button on a non-cve tab', () => {
    renderPage('/app/system/operations/fleet');
    expect(screen.queryByRole('button', { name: /refresh/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Header action — CI Workers "New CI worker" button
  // ---------------------------------------------------------------------------

  it('shows "New CI worker" action button on the ci-workers tab', async () => {
    renderPage('/app/system/operations/ci-workers');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /new ci worker/i })).toBeInTheDocument(),
    );
  });

  it('does not show "New CI worker" button when system.ci_workers.create is absent', async () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.ci_workers.create' && ALL_PERMISSIONS.includes(perm),
    );
    renderPage('/app/system/operations/ci-workers');
    await waitFor(() => expect(screen.getByTestId('ci-workers-tab')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /new ci worker/i })).not.toBeInTheDocument();
  });

  it('calls ciWorkersActions.openCreate when "New CI worker" is clicked', async () => {
    renderPage('/app/system/operations/ci-workers');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /new ci worker/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /new ci worker/i }));
    expect(mockCiWorkersOpenCreate).toHaveBeenCalledTimes(1);
  });

  it('does not show "New CI worker" button on a non-ci-workers tab', () => {
    renderPage('/app/system/operations/fleet');
    expect(screen.queryByRole('button', { name: /new ci worker/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Header action — CI Webhooks "New webhook" button
  // ---------------------------------------------------------------------------

  it('shows "New webhook" action button on the ci-webhooks tab', async () => {
    renderPage('/app/system/operations/ci-webhooks');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /new webhook/i })).toBeInTheDocument(),
    );
  });

  it('does not show "New webhook" button when system.disk_image_webhooks.create is absent', async () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.disk_image_webhooks.create' && ALL_PERMISSIONS.includes(perm),
    );
    renderPage('/app/system/operations/ci-webhooks');
    await waitFor(() => expect(screen.getByTestId('ci-webhooks-tab')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /new webhook/i })).not.toBeInTheDocument();
  });

  it('calls ciWebhooksActions.openCreate when "New webhook" is clicked', async () => {
    renderPage('/app/system/operations/ci-webhooks');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /new webhook/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /new webhook/i }));
    expect(mockCiWebhooksOpenCreate).toHaveBeenCalledTimes(1);
  });

  it('does not show "New webhook" button on a non-ci-webhooks tab', () => {
    renderPage('/app/system/operations/fleet');
    expect(screen.queryByRole('button', { name: /new webhook/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Header action — Module Builds "Refresh" button
  // ---------------------------------------------------------------------------

  it('shows "Refresh" action button on the module-builds tab', async () => {
    renderPage('/app/system/operations/module-builds');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /refresh/i })).toBeInTheDocument(),
    );
  });

  it('calls moduleBuildsActions.refresh when "Refresh" is clicked on the module-builds tab', async () => {
    renderPage('/app/system/operations/module-builds');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /refresh/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /refresh/i }));
    expect(mockModuleBuildsRefresh).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // No action button for fleet and tasks tabs
  // ---------------------------------------------------------------------------

  it('shows only the Settings button (no tab-specific action) on the fleet tab', () => {
    renderPage('/app/system/operations/fleet');
    // Settings should be present; no tab-specific Create/Refresh buttons
    expect(screen.getByRole('button', { name: /settings/i })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /new/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /refresh/i })).not.toBeInTheDocument();
  });

  it('shows only the Settings button (no tab-specific action) on the tasks tab', () => {
    renderPage('/app/system/operations/tasks');
    expect(screen.getByRole('button', { name: /settings/i })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /new/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /refresh/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tab link hrefs
  // ---------------------------------------------------------------------------

  it('tab links point to the correct BASE_PATH sub-paths', () => {
    renderPage('/app/system/operations/fleet');

    expect(screen.getByRole('link', { name: 'Fleet' })).toHaveAttribute(
      'href',
      '/app/system/operations/fleet',
    );
    expect(screen.getByRole('link', { name: 'Tasks' })).toHaveAttribute(
      'href',
      '/app/system/operations/tasks',
    );
    expect(screen.getByRole('link', { name: 'GitOps' })).toHaveAttribute(
      'href',
      '/app/system/operations/gitops',
    );
    expect(screen.getByRole('link', { name: 'CVE' })).toHaveAttribute(
      'href',
      '/app/system/operations/cve',
    );
    expect(screen.getByRole('link', { name: 'CI Workers' })).toHaveAttribute(
      'href',
      '/app/system/operations/ci-workers',
    );
    expect(screen.getByRole('link', { name: 'CI Webhooks' })).toHaveAttribute(
      'href',
      '/app/system/operations/ci-webhooks',
    );
    expect(screen.getByRole('link', { name: 'Module Builds' })).toHaveAttribute(
      'href',
      '/app/system/operations/module-builds',
    );
  });

  // ---------------------------------------------------------------------------
  // Default redirect — index route sends to the first visible tab
  // ---------------------------------------------------------------------------

  it('redirects from the base /operations/ path to the first visible tab (fleet)', () => {
    renderPage('/app/system/operations/');
    // After redirect, FleetTab should be rendered.
    expect(screen.getByTestId('fleet-tab')).toBeInTheDocument();
  });

  it('redirects to the first visible tab when only tasks permission is held', () => {
    mockHasPermission.mockImplementation((perm: string) => perm === 'system.tasks.read');
    renderPage('/app/system/operations/');
    expect(screen.getByTestId('tasks-tab')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Settings panel closes on onClose
  // ---------------------------------------------------------------------------

  it('closes the SystemSettingsPanel when onClose is called', async () => {
    renderPage();
    fireEvent.click(screen.getByRole('button', { name: /settings/i }));

    await waitFor(() =>
      expect(screen.getByTestId('settings-panel')).toBeInTheDocument(),
    );

    // The module-level capturedSettingsOnClose is set by the mock when the
    // panel renders. Invoke it to simulate the panel requesting close.
    act(() => {
      capturedSettingsOnClose?.();
    });

    await waitFor(() =>
      expect(screen.queryByTestId('settings-panel')).not.toBeInTheDocument(),
    );
  });
});
