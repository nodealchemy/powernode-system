import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ModuleBuildsPage } from './ModuleBuildsPage';

const renderPage = () => render(<BrowserRouter><ModuleBuildsPage /></BrowserRouter>);

// =============================================================================
// Permission mock — mutated per-test so we can exercise the read gate.
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
// Stub ModuleBuildsTab — its own internals are covered by
// ModuleBuildsTab.test.tsx; here we only need to confirm the page wires
// permission gating, breadcrumbs and the onActionsReady → page-actions
// bridge correctly.
// =============================================================================

jest.mock('@system/features/system/components/operations/ModuleBuildsTab', () => {
  // jest.mock factories can't close over out-of-scope variables (including a
  // top-level `React` import) — require it locally instead.
  const ReactLocal = require('react');
  return {
    ModuleBuildsTab: ({ onActionsReady }: { onActionsReady?: (h: { refresh: () => void } | null) => void }) => {
      ReactLocal.useEffect(() => {
        onActionsReady?.({ refresh: jest.fn() });
        return () => onActionsReady?.(null);
      }, [onActionsReady]);
      return ReactLocal.createElement('div', { 'data-testid': 'module-builds-tab' }, 'Module Builds Tab');
    },
  };
});

// =============================================================================
// Tests
// =============================================================================

describe('ModuleBuildsPage', () => {
  beforeEach(() => {
    mockHasPermission = () => true;
  });

  it('renders the ModuleBuildsTab when the operator can read module builds', async () => {
    renderPage();

    await waitFor(() => expect(screen.getByTestId('module-builds-tab')).toBeInTheDocument());
  });

  it('shows a permission-denied message instead of the tab when read is not granted', () => {
    mockHasPermission = (permission) => permission !== 'system.module_builds.read';

    renderPage();

    expect(screen.getByText(/don.t have permission to view module build batches/i)).toBeInTheDocument();
    expect(screen.queryByTestId('module-builds-tab')).not.toBeInTheDocument();
  });

  it('renders breadcrumbs through DevOps and CI/CD to Module Builds', () => {
    // The first breadcrumb ("Dashboard") is rendered as a Home icon without
    // its label (PageContainer's SharedBreadcrumbs convention) — assert on
    // the labels that stay text instead.
    renderPage();

    expect(screen.getByText('DevOps')).toBeInTheDocument();
    expect(screen.getByText('CI/CD')).toBeInTheDocument();
    expect(screen.getAllByText('Module Builds').length).toBeGreaterThan(0);
  });

  it('exposes a Refresh page action once the tab reports its handle', async () => {
    renderPage();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /refresh/i })).toBeInTheDocument(),
    );
  });
});
