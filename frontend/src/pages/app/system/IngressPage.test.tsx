import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { IngressPage } from './IngressPage';

// =============================================================================
// Permission mock — mutated per-test so we can exercise gating scenarios.
// =============================================================================

let mockHasPermission = (_permission: string): boolean => true;

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (permission: string) => mockHasPermission(permission),
  }),
}));

// =============================================================================
// Breadcrumb context — required by PageContainer.
// =============================================================================

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
// Notifications hook — required by the child ExposeServicePanel.
// =============================================================================

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// =============================================================================
// Stub child panels — the page is a tab hub; unit testing the panels
// separately (IngressRoutesPanel.test + ExposeServicePanel.test) covers
// their internals. Here we just need to confirm the hub mounts the right
// panel for each route and gates them with permissions.
// =============================================================================

jest.mock(
  '@system/features/system/components/ingress/IngressRoutesPanel',
  () => ({
    IngressRoutesPanel: () => <div data-testid="ingress-routes-panel">Routes Panel</div>,
  }),
);

jest.mock(
  '@system/features/system/components/ingress/ExposeServicePanel',
  () => ({
    ExposeServicePanel: () => <div data-testid="expose-service-panel">Expose Panel</div>,
  }),
);

// =============================================================================
// Helpers
// =============================================================================

/**
 * Render IngressPage at a specific path within the /app/system/ingress subtree.
 * The page uses relative <Routes> whose path segments are resolved against the
 * matched parent route — so we mount IngressPage under a wildcard route that
 * mirrors the real app's routing tree.
 */
function renderAt(initialPath: string = '/app/system/ingress') {
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route path="/app/system/ingress/*" element={<IngressPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('IngressPage', () => {
  beforeEach(() => {
    mockHasPermission = () => true;
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Page structure
  // ---------------------------------------------------------------------------

  it('renders the page title "Ingress"', () => {
    renderAt('/app/system/ingress/routes');
    expect(screen.getByText('Ingress')).toBeInTheDocument();
  });

  it('renders the page description for the full-access case', () => {
    renderAt('/app/system/ingress/routes');
    expect(
      screen.getByText(/derived from issued certificates.*approval-gated wizard/i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tab bar
  // ---------------------------------------------------------------------------

  it('renders both tab links when the user has both permissions', () => {
    renderAt('/app/system/ingress/routes');
    expect(screen.getByRole('link', { name: /routes/i })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /expose service/i })).toBeInTheDocument();
  });

  it('renders only the Routes tab when manage permission is absent', () => {
    mockHasPermission = (p: string) => p === 'system.ingress.read';
    renderAt('/app/system/ingress/routes');

    expect(screen.getByRole('link', { name: /routes/i })).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: /expose service/i })).not.toBeInTheDocument();
  });

  it('renders only the Expose Service tab when read permission is absent', () => {
    mockHasPermission = (p: string) => p === 'system.ingress.manage';
    renderAt('/app/system/ingress/expose');

    expect(screen.queryByRole('link', { name: /routes/i })).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: /expose service/i })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // No-permission empty state
  // ---------------------------------------------------------------------------

  it('renders the no-permission empty state when the user has neither permission', () => {
    mockHasPermission = () => false;
    renderAt('/app/system/ingress');

    expect(screen.getByText(/don't have permission to view any ingress resources/i)).toBeInTheDocument();
    expect(screen.getByText('system.ingress.read')).toBeInTheDocument();
    expect(screen.getByText('system.ingress.manage')).toBeInTheDocument();

    // Neither tab nor route panels should appear.
    expect(screen.queryByRole('link', { name: /routes/i })).not.toBeInTheDocument();
    expect(screen.queryByTestId('ingress-routes-panel')).not.toBeInTheDocument();
    expect(screen.queryByTestId('expose-service-panel')).not.toBeInTheDocument();
  });

  it('renders the no-permission page title and description for the denied case', () => {
    mockHasPermission = () => false;
    renderAt('/app/system/ingress');
    expect(screen.getByText('Ingress')).toBeInTheDocument();
    expect(
      screen.getByText(/Public ingress routes derived from issued certificates\./i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Routing — correct panel for each tab path
  // ---------------------------------------------------------------------------

  it('mounts IngressRoutesPanel when the path is /routes', async () => {
    renderAt('/app/system/ingress/routes');
    await waitFor(() =>
      expect(screen.getByTestId('ingress-routes-panel')).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('expose-service-panel')).not.toBeInTheDocument();
  });

  it('mounts ExposeServicePanel when the path is /expose', async () => {
    renderAt('/app/system/ingress/expose');
    await waitFor(() =>
      expect(screen.getByTestId('expose-service-panel')).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('ingress-routes-panel')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Default / redirect behaviour
  // ---------------------------------------------------------------------------

  it('redirects the bare base path to the first accessible tab (routes)', async () => {
    // Both tabs accessible; first is "routes".
    renderAt('/app/system/ingress');
    await waitFor(() =>
      expect(screen.getByTestId('ingress-routes-panel')).toBeInTheDocument(),
    );
  });

  it('redirects to expose when only the manage permission is held', async () => {
    mockHasPermission = (p: string) => p === 'system.ingress.manage';
    renderAt('/app/system/ingress');
    await waitFor(() =>
      expect(screen.getByTestId('expose-service-panel')).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('ingress-routes-panel')).not.toBeInTheDocument();
  });
});
