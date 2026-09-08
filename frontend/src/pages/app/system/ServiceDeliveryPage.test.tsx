import React from 'react';
import { render, screen } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import ServiceDeliveryPage from './ServiceDeliveryPage';

// =============================================================================
// Mocks
//
// The page is a thin path-tab orchestrator over four tab components, each of
// which talks to `apiClient` for federated service-delivery data. We stub the
// tab components to sentinel markers so the test isolates the page's own
// concerns: permission-gated tab visibility, the active-tab highlight, and the
// `/app/system/service-delivery/<tab>` link targets (the load-bearing change
// in the FederationHubPage → ServiceDeliveryPage rename).
// =============================================================================

jest.mock('@system/features/system/components/federation_hub/OfferingsTab', () => ({
  OfferingsTab: () => <div data-testid="offerings-tab">offerings</div>,
}));
jest.mock('@system/features/system/components/federation_hub/SubscriptionsTab', () => ({
  SubscriptionsTab: () => <div data-testid="subscriptions-tab">subscriptions</div>,
}));
jest.mock('@system/features/system/components/federation_hub/CatalogBrowserTab', () => ({
  CatalogBrowserTab: () => <div data-testid="catalog-tab">catalog</div>,
}));
jest.mock('@system/features/system/components/federation_hub/ChildrenTab', () => ({
  ChildrenTab: () => <div data-testid="children-tab">children</div>,
}));

const mockHasPermission = jest.fn();
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (perm: string) => mockHasPermission(perm),
  }),
}));

// PageContainer reads breadcrumbs from BreadcrumbContext; stub it so the page
// renders without a real BreadcrumbProvider wrapper (mirrors FederationHubPage.test).
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
// Tests
// =============================================================================

// ServiceDeliveryPage owns nested relative tab routes, so it must mount under
// the /app/system/service-delivery/* splat register.ts gives it — otherwise the
// nested routes resolve against "/" and the tab body never mounts.
const renderAt = (path: string) =>
  render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/app/system/service-delivery/*" element={<ServiceDeliveryPage />} />
      </Routes>
    </MemoryRouter>,
  );

describe('ServiceDeliveryPage', () => {
  beforeEach(() => {
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
  });

  it('renders the four tab links under the /app/system/service-delivery path', () => {
    renderAt('/app/system/service-delivery/offerings');

    const offerings = screen.getByRole('link', { name: /Offerings/i });
    const subscriptions = screen.getByRole('link', { name: /Subscriptions/i });
    const catalog = screen.getByRole('link', { name: /Catalog Browser/i });
    const children = screen.getByRole('link', { name: /Children/i });

    expect(offerings).toHaveAttribute('href', '/app/system/service-delivery/offerings');
    expect(subscriptions).toHaveAttribute('href', '/app/system/service-delivery/subscriptions');
    expect(catalog).toHaveAttribute('href', '/app/system/service-delivery/catalog');
    expect(children).toHaveAttribute('href', '/app/system/service-delivery/children');
  });

  it('marks the active tab from the /service-delivery/<tab> path segment', () => {
    renderAt('/app/system/service-delivery/subscriptions');

    // The active tab carries PathTabs' accent border; siblings stay transparent.
    expect(screen.getByRole('link', { name: /Subscriptions/i }).className).toContain(
      'border-theme-info-border',
    );
    expect(screen.getByRole('link', { name: /Offerings/i }).className).toContain(
      'border-transparent',
    );
    expect(screen.getByRole('link', { name: /Offerings/i }).className).not.toContain(
      'border-theme-info-border',
    );

    // The matched tab's body renders.
    expect(screen.getByTestId('subscriptions-tab')).toBeInTheDocument();
  });

  it('hides tabs the operator lacks permission for', () => {
    // Grant everything except the children tab.
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.children.read');

    renderAt('/app/system/service-delivery/offerings');

    expect(screen.getByRole('link', { name: /Offerings/i })).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: /Children/i })).not.toBeInTheDocument();
  });

  it('shows the permission-denied empty state when no tabs are visible', () => {
    mockHasPermission.mockReturnValue(false);

    renderAt('/app/system/service-delivery');

    expect(
      screen.getByText(/don't have permission to view service delivery/i),
    ).toBeInTheDocument();
    expect(screen.queryByRole('link')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // IMP-d725a6bad253 — shared PathTabs scaffold
  //
  // Every system hub must render its tab strip through the shared
  // `PathTabs` component so the active-tab treatment is identical across
  // hubs an operator moves between in one session. These assertions pin
  // PathTabs' own markup (nav layout + active-link classes); a hand-rolled
  // <nav> fails them.
  // ---------------------------------------------------------------------------

  it('renders the tab strip through the shared PathTabs scaffold', () => {
    renderAt('/app/system/service-delivery/subscriptions');

    const active = screen.getByRole('link', { name: /Subscriptions/i });
    // PathTabs' active-link classes.
    expect(active.className).toContain('border-theme-info-border');
    expect(active.className).toContain('font-medium');
    expect(active.className).toContain('inline-flex');

    // PathTabs' nav layout. `flex-wrap` + `gap-1` is the shared strip's
    // signature: no hub's hand-rolled <nav> carried both.
    const nav = active.closest('nav');
    expect(nav).not.toBeNull();
    expect(nav?.className).toContain('flex-wrap');
    expect(nav?.className).toContain('items-center');
    expect(nav?.className).toContain('gap-1');
  });
});
