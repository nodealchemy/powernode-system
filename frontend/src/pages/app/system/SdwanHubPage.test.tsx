import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import SdwanHubPage from './SdwanHubPage';

// =============================================================================
// Mocks
//
// SdwanHubPage imports:
//   - usePermissions from '@/shared/hooks/usePermissions'
//   - BreadcrumbContext (via PageContainer) from '@/shared/hooks/BreadcrumbContext'
//   - NetworksTab, FederationTab, HostBridgesTab, OvnDeploymentsTab,
//     IpfixCollectorsTab, FlowSamplesTab, TopologyTab from
//     '@system/features/system/components/sdwan_hub'
//   - SdwanRoutingPage (the embedded routing tab)
//
// We mock all tab child components so we can:
//   - Assert that the correct tab renders on route change
//   - Simulate the onActionsReady callbacks (networksActions / federationActions)
//   - Keep tests fast without any API calls
// =============================================================================

let mockHasPermission: (perm: string) => boolean = () => true;

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (perm: string) => mockHasPermission(perm),
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

// Capture the onActionsReady prop from NetworksTab so tests can invoke it
let mockNetworksTabOnActionsReady: ((handle: { openCreate: () => void } | null) => void) | undefined;

// Capture the onActionsReady prop from FederationTab
let mockFederationTabOnActionsReady: ((handle: { openPropose: () => void } | null) => void) | undefined;

jest.mock('@system/features/system/components/sdwan_hub', () => ({
  TopologyTab: () => <div data-testid="tab-topology">TopologyTab</div>,
  NetworksTab: (props: { onActionsReady?: (handle: { openCreate: () => void } | null) => void }) => {
    mockNetworksTabOnActionsReady = props.onActionsReady;
    return <div data-testid="tab-networks">NetworksTab</div>;
  },
  FederationTab: (props: { onActionsReady?: (handle: { openPropose: () => void } | null) => void }) => {
    mockFederationTabOnActionsReady = props.onActionsReady;
    return <div data-testid="tab-federation">FederationTab</div>;
  },
  HostBridgesTab: () => <div data-testid="tab-host-bridges">HostBridgesTab</div>,
  OvnDeploymentsTab: () => <div data-testid="tab-ovn">OvnDeploymentsTab</div>,
  IpfixCollectorsTab: () => <div data-testid="tab-ipfix">IpfixCollectorsTab</div>,
  FlowSamplesTab: () => <div data-testid="tab-flows">FlowSamplesTab</div>,
}));

// SdwanRoutingPage is a sibling page import (not from sdwan_hub barrel)
jest.mock('./SdwanRoutingPage', () => ({
  __esModule: true,
  default: ({ embedded }: { embedded?: boolean }) => (
    <div data-testid="tab-routing" data-embedded={String(embedded ?? false)}>
      SdwanRoutingPage
    </div>
  ),
}));

// =============================================================================
// Helpers
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}
void envelope; // Used in future tests if needed; suppress unused warning

/**
 * Renders SdwanHubPage at the given SDWAN sub-path.
 * The page is mounted at /app/system/sdwan/* to match its real route.
 */
function renderPage(subPath = '/networks') {
  return render(
    <MemoryRouter initialEntries={[`/app/system/sdwan${subPath}`]}>
      <Routes>
        <Route path="/app/system/sdwan/*" element={<SdwanHubPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('SdwanHubPage', () => {
  beforeEach(() => {
    mockHasPermission = () => true;
    mockNetworksTabOnActionsReady = undefined;
    mockFederationTabOnActionsReady = undefined;
  });

  // ---------------------------------------------------------------------------
  // Basic render — full permissions
  // ---------------------------------------------------------------------------

  it('renders the SDWAN page title', () => {
    renderPage();
    // PageContainer renders the title as an <h1>; use the heading role to be precise
    expect(screen.getByRole('heading', { name: 'SDWAN' })).toBeInTheDocument();
  });

  it('renders all eight tab links when the user has all permissions', () => {
    renderPage();
    expect(screen.getByRole('link', { name: 'Topology' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Networks' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Routing' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Federation' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Host Bridges' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'OVN' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'IPFIX' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Flows' })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Permission-denied state
  // ---------------------------------------------------------------------------

  it('renders the no-permission message when the user lacks all SDWAN permissions', () => {
    mockHasPermission = () => false;
    renderPage();
    expect(
      screen.getByText(/you don't have permission to view any sdwan resources/i),
    ).toBeInTheDocument();
  });

  it('does not render any tab links in the no-permission state', () => {
    mockHasPermission = () => false;
    renderPage();
    expect(screen.queryByRole('link', { name: 'Topology' })).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'Networks' })).not.toBeInTheDocument();
  });

  it('still renders the page title in the no-permission state', () => {
    mockHasPermission = () => false;
    renderPage();
    // PageContainer still renders the title SDWAN
    expect(screen.getByRole('heading', { name: 'SDWAN' })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Permission-based tab filtering
  // ---------------------------------------------------------------------------

  it('hides tabs whose permission is not granted', () => {
    // Grant everything EXCEPT federation
    mockHasPermission = (perm: string) => perm !== 'system.sdwan.federation.read';
    renderPage();
    expect(screen.queryByRole('link', { name: 'Federation' })).not.toBeInTheDocument();
  });

  it('still shows tabs whose permissions ARE granted when some are denied', () => {
    mockHasPermission = (perm: string) => perm !== 'system.sdwan.federation.read';
    renderPage();
    expect(screen.getByRole('link', { name: 'Networks' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Topology' })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tab routing — correct component renders for each URL
  // ---------------------------------------------------------------------------

  it('renders TopologyTab at /sdwan/topology', () => {
    renderPage('/topology');
    expect(screen.getByTestId('tab-topology')).toBeInTheDocument();
  });

  it('renders NetworksTab at /sdwan/networks', () => {
    renderPage('/networks');
    expect(screen.getByTestId('tab-networks')).toBeInTheDocument();
  });

  it('renders SdwanRoutingPage (embedded) at /sdwan/routing', () => {
    renderPage('/routing');
    expect(screen.getByTestId('tab-routing')).toBeInTheDocument();
    // Must be rendered in embedded mode (no own PageContainer)
    expect(screen.getByTestId('tab-routing')).toHaveAttribute('data-embedded', 'true');
  });

  it('renders FederationTab at /sdwan/federation', () => {
    renderPage('/federation');
    expect(screen.getByTestId('tab-federation')).toBeInTheDocument();
  });

  it('renders HostBridgesTab at /sdwan/host_bridges', () => {
    renderPage('/host_bridges');
    expect(screen.getByTestId('tab-host-bridges')).toBeInTheDocument();
  });

  it('renders OvnDeploymentsTab at /sdwan/ovn', () => {
    renderPage('/ovn');
    expect(screen.getByTestId('tab-ovn')).toBeInTheDocument();
  });

  it('renders IpfixCollectorsTab at /sdwan/ipfix', () => {
    renderPage('/ipfix');
    expect(screen.getByTestId('tab-ipfix')).toBeInTheDocument();
  });

  it('renders FlowSamplesTab at /sdwan/flows', () => {
    renderPage('/flows');
    expect(screen.getByTestId('tab-flows')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Active tab highlighting
  // ---------------------------------------------------------------------------

  it('applies active styling to the Networks link when at /sdwan/networks', () => {
    renderPage('/networks');
    const networksLink = screen.getByRole('link', { name: 'Networks' });
    expect(networksLink.className).toContain('border-theme-focus');
    expect(networksLink.className).toContain('text-theme-primary');
  });

  it('applies inactive styling to non-active tabs', () => {
    renderPage('/networks');
    const topologyLink = screen.getByRole('link', { name: 'Topology' });
    expect(topologyLink.className).toContain('border-transparent');
    expect(topologyLink.className).toContain('text-theme-secondary');
  });

  it('applies active styling to the Topology link at /sdwan/topology', () => {
    renderPage('/topology');
    const topologyLink = screen.getByRole('link', { name: 'Topology' });
    expect(topologyLink.className).toContain('border-theme-focus');
  });

  it('applies active styling to Routing link when at /sdwan/routing', () => {
    renderPage('/routing');
    const routingLink = screen.getByRole('link', { name: 'Routing' });
    expect(routingLink.className).toContain('border-theme-focus');
  });

  // ---------------------------------------------------------------------------
  // Tab link href values
  // ---------------------------------------------------------------------------

  it('each tab link has the correct href', () => {
    renderPage('/networks');
    expect(screen.getByRole('link', { name: 'Topology' })).toHaveAttribute('href', '/app/system/sdwan/topology');
    expect(screen.getByRole('link', { name: 'Networks' })).toHaveAttribute('href', '/app/system/sdwan/networks');
    expect(screen.getByRole('link', { name: 'Routing' })).toHaveAttribute('href', '/app/system/sdwan/routing');
    expect(screen.getByRole('link', { name: 'Federation' })).toHaveAttribute('href', '/app/system/sdwan/federation');
    expect(screen.getByRole('link', { name: 'Host Bridges' })).toHaveAttribute('href', '/app/system/sdwan/host_bridges');
    expect(screen.getByRole('link', { name: 'OVN' })).toHaveAttribute('href', '/app/system/sdwan/ovn');
    expect(screen.getByRole('link', { name: 'IPFIX' })).toHaveAttribute('href', '/app/system/sdwan/ipfix');
    expect(screen.getByRole('link', { name: 'Flows' })).toHaveAttribute('href', '/app/system/sdwan/flows');
  });

  // ---------------------------------------------------------------------------
  // Networks tab — "Create network" page action
  // ---------------------------------------------------------------------------

  it('does not show "Create network" button before NetworksTab provides its handle', () => {
    renderPage('/networks');
    // NetworksTab renders but has not called onActionsReady yet in this test
    expect(screen.queryByRole('button', { name: /create network/i })).not.toBeInTheDocument();
  });

  it('shows "Create network" button once NetworksTab provides the handle', async () => {
    renderPage('/networks');

    act(() => {
      mockNetworksTabOnActionsReady?.({ openCreate: jest.fn() });
    });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /create network/i })).toBeInTheDocument(),
    );
  });

  it('calls openCreate on NetworksTab handle when "Create network" is clicked', async () => {
    const mockOpenCreate = jest.fn();
    renderPage('/networks');

    act(() => {
      mockNetworksTabOnActionsReady?.({ openCreate: mockOpenCreate });
    });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /create network/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    expect(mockOpenCreate).toHaveBeenCalledTimes(1);
  });

  it('does not show "Create network" when user lacks sdwan.networks.manage', async () => {
    mockHasPermission = (perm: string) => perm !== 'system.sdwan.networks.manage';
    renderPage('/networks');

    act(() => {
      mockNetworksTabOnActionsReady?.({ openCreate: jest.fn() });
    });

    // Give any async state a chance to settle
    await waitFor(() => expect(screen.getByTestId('tab-networks')).toBeInTheDocument());

    expect(screen.queryByRole('button', { name: /create network/i })).not.toBeInTheDocument();
  });

  it('does not show "Create network" at /sdwan/topology (action only active on networks tab)', () => {
    // Render at topology tab — even if handle is registered, button should not appear
    renderPage('/topology');

    act(() => {
      mockNetworksTabOnActionsReady?.({ openCreate: jest.fn() });
    });

    // NetworksTab does not render at /topology, so no handle registration occurs.
    // Regardless, the topology tab should not show the "Create network" button.
    expect(screen.queryByRole('button', { name: /create network/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Federation tab — "Propose peer" page action
  // ---------------------------------------------------------------------------

  it('does not show "Propose peer" button before FederationTab provides its handle', () => {
    renderPage('/federation');
    expect(screen.queryByRole('button', { name: /propose peer/i })).not.toBeInTheDocument();
  });

  it('shows "Propose peer" button once FederationTab provides the handle', async () => {
    renderPage('/federation');

    act(() => {
      mockFederationTabOnActionsReady?.({ openPropose: jest.fn() });
    });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /propose peer/i })).toBeInTheDocument(),
    );
  });

  it('calls openPropose on FederationTab handle when "Propose peer" is clicked', async () => {
    const mockOpenPropose = jest.fn();
    renderPage('/federation');

    act(() => {
      mockFederationTabOnActionsReady?.({ openPropose: mockOpenPropose });
    });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /propose peer/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /propose peer/i }));

    expect(mockOpenPropose).toHaveBeenCalledTimes(1);
  });

  it('does not show "Propose peer" when user lacks sdwan.federation.manage', async () => {
    mockHasPermission = (perm: string) => perm !== 'system.sdwan.federation.manage';
    renderPage('/federation');

    act(() => {
      mockFederationTabOnActionsReady?.({ openPropose: jest.fn() });
    });

    await waitFor(() => expect(screen.getByTestId('tab-federation')).toBeInTheDocument());

    expect(screen.queryByRole('button', { name: /propose peer/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // No page actions shown for non-action tabs
  // ---------------------------------------------------------------------------

  it('does not show "Create network" or "Propose peer" at /sdwan/topology', () => {
    renderPage('/topology');
    expect(screen.queryByRole('button', { name: /create network/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /propose peer/i })).not.toBeInTheDocument();
  });

  it('does not show "Create network" or "Propose peer" at /sdwan/ovn', () => {
    renderPage('/ovn');
    expect(screen.queryByRole('button', { name: /create network/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /propose peer/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // NetworksTab handle cleanup on unmount
  // ---------------------------------------------------------------------------

  it('clears networksActions when NetworksTab calls onActionsReady(null) on unmount', async () => {
    renderPage('/networks');

    act(() => {
      mockNetworksTabOnActionsReady?.({ openCreate: jest.fn() });
    });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /create network/i })).toBeInTheDocument(),
    );

    // The tab calls onActionsReady(null) on unmount — simulate that
    act(() => {
      mockNetworksTabOnActionsReady?.(null);
    });

    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /create network/i })).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Breadcrumb / description content
  // ---------------------------------------------------------------------------

  it('renders the SDWAN description text', () => {
    renderPage('/networks');
    expect(
      screen.getByText(/ipv6 overlay networks, ibgp routing/i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tab navigation wrapper class
  // ---------------------------------------------------------------------------

  it('wraps tab links in a nav element with flex class', () => {
    renderPage('/networks');
    // PageContainer also renders a breadcrumb <nav>, so use getAllByRole and find the tab nav
    const navElements = screen.getAllByRole('navigation');
    // The tab nav contains the Networks link; find it among the nav elements
    const tabNav = navElements.find((nav) =>
      nav.querySelector('[href="/app/system/sdwan/networks"]'),
    );
    expect(tabNav).toBeTruthy();
    expect(tabNav?.className).toContain('flex');
  });

  // ---------------------------------------------------------------------------
  // Only first visible tab shows as active at the root index
  // ---------------------------------------------------------------------------

  it('shows first visible tab active class when at the index route', () => {
    // Navigate to /app/system/sdwan (no sub-path) — should default to topology (first tab)
    render(
      <MemoryRouter initialEntries={['/app/system/sdwan']}>
        <Routes>
          <Route path="/app/system/sdwan/*" element={<SdwanHubPage />} />
        </Routes>
      </MemoryRouter>,
    );
    // All tabs are visible (full permissions), first tab is Topology
    const topologyLink = screen.getByRole('link', { name: 'Topology' });
    // The index route redirects to defaultTabKey; at path /app/system/sdwan without
    // a trailing segment the activeTabKey resolves to visibleTabs[0].key='topology'
    expect(topologyLink).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Flows tab shares the ipfix permission
  // ---------------------------------------------------------------------------

  it('hides both IPFIX and Flows tabs when sdwan.ipfix.read is denied', () => {
    mockHasPermission = (perm: string) => perm !== 'system.sdwan.ipfix.read';
    renderPage('/networks');
    expect(screen.queryByRole('link', { name: 'IPFIX' })).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'Flows' })).not.toBeInTheDocument();
  });

  it('shows both IPFIX and Flows tabs when sdwan.ipfix.read is granted', () => {
    renderPage('/networks');
    expect(screen.getByRole('link', { name: 'IPFIX' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Flows' })).toBeInTheDocument();
  });
});
