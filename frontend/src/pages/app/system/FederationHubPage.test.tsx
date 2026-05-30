import React from 'react';
import { render, screen } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import FederationHubPage from './FederationHubPage';

// =============================================================================
// Mocks
//
// FederationHubPage is a thin Monitor|Control path-tab orchestrator that
// composes ~9 existing federation / SDWAN / service-delivery surfaces, each of
// which talks to apiClient or the WebSocket manager. We stub every composed
// child to a sentinel marker so the test isolates the hub's own concerns:
//   - permission-gated top-level tab visibility (Monitor needs
//     system.peers.read; Control needs sdwan.federation.manage)
//   - the /app/system/federation/<tab> link targets + active-tab highlight
//   - per-section permission gating inside each tab
//   - the permission-denied empty state when neither tab is visible
// =============================================================================

jest.mock('@system/features/system/components/platform/PeerLivenessMonitor', () => ({
  PeerLivenessMonitor: () => <div data-testid="peer-liveness-monitor">liveness</div>,
}));
jest.mock('@system/features/system/components/platform/PeerControlPanel', () => ({
  PeerControlPanel: () => <div data-testid="peer-control-panel">control</div>,
}));
jest.mock('@system/features/system/components/platform/NetworkVipPicker', () => ({
  NetworkVipPicker: () => <div data-testid="network-vip-picker">vips</div>,
}));
jest.mock('@system/features/system/components/network/SystemTopology', () => ({
  SystemTopology: () => <div data-testid="system-topology">topology</div>,
}));
jest.mock('@system/features/system/components/sdwan_hub/OvnDeploymentsTab', () => ({
  OvnDeploymentsTab: () => <div data-testid="ovn-tab">ovn</div>,
}));
jest.mock('@system/features/system/components/sdwan/FederationGovernancePanel', () => ({
  FederationGovernancePanel: () => <div data-testid="governance-panel">governance</div>,
}));
jest.mock('@system/features/system/components/federation/ServiceSubscriptionsPanel', () => ({
  ServiceSubscriptionsPanel: () => <div data-testid="subscriptions-panel">subscriptions</div>,
}));
jest.mock('@system/features/system/components/federation/ServiceOfferingsPanel', () => ({
  ServiceOfferingsPanel: () => <div data-testid="offerings-panel">offerings</div>,
}));
jest.mock('@system/features/system/components/federation/ServiceOfferingEditorModal', () => ({
  ServiceOfferingEditorModal: () => <div data-testid="offering-editor" />,
}));
jest.mock('@system/features/system/components/federation_hub/CatalogBrowserTab', () => ({
  CatalogBrowserTab: () => <div data-testid="catalog-tab">catalog</div>,
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

// The hub owns nested relative routes (<Route path="monitor"> …), so it must
// mount under the same /app/system/federation/* splat register.ts gives it —
// otherwise the nested routes resolve against "/" and the tab body never mounts.
const renderAt = (path: string) =>
  render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/app/system/federation/*" element={<FederationHubPage />} />
      </Routes>
    </MemoryRouter>,
  );

describe('FederationHubPage', () => {
  beforeEach(() => {
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
  });

  it('renders the Monitor + Control tab links under /app/system/federation', () => {
    renderAt('/app/system/federation/monitor');

    const monitor = screen.getByRole('link', { name: /Monitor/i });
    const control = screen.getByRole('link', { name: /Control/i });

    expect(monitor).toHaveAttribute('href', '/app/system/federation/monitor');
    expect(control).toHaveAttribute('href', '/app/system/federation/control');
  });

  it('marks the active tab from the /federation/<tab> path segment', () => {
    renderAt('/app/system/federation/control');

    // PathTabs marks the active tab with border-theme-info + text-theme-primary.
    expect(screen.getByRole('link', { name: /Control/i }).className).toContain('border-theme-info');
    expect(screen.getByRole('link', { name: /Monitor/i }).className).not.toContain(
      'border-theme-info',
    );

    // The Control tab body renders (peer control panel sentinel).
    expect(screen.getByTestId('federation-control-tab')).toBeInTheDocument();
    expect(screen.getByTestId('peer-control-panel')).toBeInTheDocument();
  });

  it('renders the Monitor tab body with its composed read-only surfaces', () => {
    renderAt('/app/system/federation/monitor');

    expect(screen.getByTestId('federation-monitor-tab')).toBeInTheDocument();
    expect(screen.getByTestId('peer-liveness-monitor')).toBeInTheDocument();
    expect(screen.getByTestId('system-topology')).toBeInTheDocument();
    expect(screen.getByTestId('ovn-tab')).toBeInTheDocument();
  });

  it('hides the Control tab when the operator lacks sdwan.federation.manage', () => {
    // Grant everything except federation management → Monitor only.
    mockHasPermission.mockImplementation((perm: string) => perm !== 'sdwan.federation.manage');

    renderAt('/app/system/federation/monitor');

    expect(screen.getByRole('link', { name: /Monitor/i })).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: /Control/i })).not.toBeInTheDocument();
  });

  it('hides the Monitor tab when the operator lacks system.peers.read', () => {
    // Only federation management → Control only.
    mockHasPermission.mockImplementation((perm: string) => perm === 'sdwan.federation.manage');

    renderAt('/app/system/federation/control');

    expect(screen.getByRole('link', { name: /Control/i })).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: /Monitor/i })).not.toBeInTheDocument();
  });

  it('gates Monitor sub-sections on their own read permissions', () => {
    // Monitor visible (peers.read), but no OVN read → isolation section hidden.
    mockHasPermission.mockImplementation((perm: string) => perm !== 'sdwan.ovn.read');

    renderAt('/app/system/federation/monitor');

    expect(screen.getByTestId('peer-liveness-monitor')).toBeInTheDocument();
    expect(screen.queryByTestId('ovn-tab')).not.toBeInTheDocument();
  });

  it('shows the permission-denied empty state when neither tab is visible', () => {
    mockHasPermission.mockReturnValue(false);

    renderAt('/app/system/federation');

    expect(screen.getByText(/don't have permission to view the federation hub/i)).toBeInTheDocument();
    expect(screen.queryByRole('link')).not.toBeInTheDocument();
  });
});
