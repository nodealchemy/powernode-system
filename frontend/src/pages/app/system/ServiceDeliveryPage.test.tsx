import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
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
jest.mock('@system/features/system/components/federation_hub/FulfillmentTab', () => ({
  FulfillmentTab: () => <div data-testid="fulfillment-tab">fulfillment</div>,
}));
// Merged in from FederationHubPage (fe-dupes.md §10 item 16).
jest.mock('@system/features/system/components/platform/PeerControlPanel', () => ({
  PeerControlPanel: () => <div data-testid="peer-control-panel">peer control</div>,
}));
jest.mock('@system/features/system/components/sdwan/FederationGovernancePanel', () => ({
  FederationGovernancePanel: () => <div data-testid="governance-panel">governance</div>,
}));
jest.mock('@system/features/system/components/concierge/ConciergePanel', () => ({
  ConciergePanel: ({ open }: { open: boolean }) =>
    open ? <div data-testid="concierge-panel">concierge</div> : null,
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

  it('renders the six tab links under the /app/system/service-delivery path', () => {
    renderAt('/app/system/service-delivery/offerings');

    const offerings = screen.getByRole('link', { name: /Offerings/i });
    const subscriptions = screen.getByRole('link', { name: /Subscriptions/i });
    const catalog = screen.getByRole('link', { name: /Catalog Browser/i });
    const children = screen.getByRole('link', { name: /Children/i });
    const peers = screen.getByRole('link', { name: /Peers/i });

    expect(offerings).toHaveAttribute('href', '/app/system/service-delivery/offerings');
    expect(subscriptions).toHaveAttribute('href', '/app/system/service-delivery/subscriptions');
    expect(catalog).toHaveAttribute('href', '/app/system/service-delivery/catalog');
    expect(children).toHaveAttribute('href', '/app/system/service-delivery/children');
    expect(peers).toHaveAttribute('href', '/app/system/service-delivery/peers');
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

  // ---------------------------------------------------------------------------
  // fe-dupes.md §10 item 16 — FederationHubPage merge
  //
  // FederationHubPage's federation control surfaces (peer control, governance
  // findings) and its "Ask Concierge" action moved here. Its non-federation
  // content (peer liveness, topology, OVN isolation, service discovery) moved
  // to ComputePage's Platform tab instead — see PlatformInfraTab.test.tsx.
  // ---------------------------------------------------------------------------

  it('renders PeerControlPanel and FederationGovernancePanel on the Peers tab', () => {
    renderAt('/app/system/service-delivery/peers');

    expect(screen.getByTestId('service-delivery-peers-tab')).toBeInTheDocument();
    expect(screen.getByTestId('peer-control-panel')).toBeInTheDocument();
    expect(screen.getByTestId('governance-panel')).toBeInTheDocument();
  });

  it('hides the governance section without system.sdwan.federation.read', () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.sdwan.federation.read');

    renderAt('/app/system/service-delivery/peers');

    expect(screen.getByTestId('peer-control-panel')).toBeInTheDocument();
    expect(screen.queryByTestId('governance-panel')).not.toBeInTheDocument();
  });

  it('shows an "Ask Concierge" page action when the operator can manage federation', () => {
    renderAt('/app/system/service-delivery/offerings');

    expect(screen.getByRole('button', { name: /Ask Concierge/i })).toBeInTheDocument();
  });

  it('hides the "Ask Concierge" action without system.sdwan.federation.manage', () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.sdwan.federation.manage');

    renderAt('/app/system/service-delivery/offerings');

    expect(screen.queryByRole('button', { name: /Ask Concierge/i })).not.toBeInTheDocument();
  });

  it('opens the concierge panel from the page action', () => {
    renderAt('/app/system/service-delivery/offerings');

    expect(screen.queryByTestId('concierge-panel')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /Ask Concierge/i }));
    expect(screen.getByTestId('concierge-panel')).toBeInTheDocument();
  });
});
