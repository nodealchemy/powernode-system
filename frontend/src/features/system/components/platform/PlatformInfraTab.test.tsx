import React from 'react';
import { render, screen } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import { PlatformInfraTab } from './PlatformInfraTab';

// =============================================================================
// Mocks
//
// PlatformInfraTab is a pure routing/navigation shell — it renders a tab
// nav bar and delegates rendering to child panels via React Router <Routes>.
// We stub every child panel so each test exercises only the shell behaviour
// (tab rendering, active-tab detection, route → panel dispatch, fallback
// redirects) without triggering child API calls.
// =============================================================================

// Configurable so both-arms tests can prove the C10 review FIX-1 gates on
// PeerLivenessMonitor / NetworkVipPicker actually gate something (they are
// real JSX checks inside PeersTab/DiscoveryTab, independent of the
// best-effort tab strip).
let mockHasPermission = jest.fn(() => true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: (...args: unknown[]) => mockHasPermission(...args) }),
}));

jest.mock('./PlatformOverviewCards', () => ({
  PlatformOverviewCards: () => <div data-testid="platform-overview-cards" />,
}));

jest.mock('./PeerLivenessMonitor', () => ({
  PeerLivenessMonitor: () => <div data-testid="peer-liveness-monitor" />,
}));

jest.mock('./NetworkVipPicker', () => ({
  NetworkVipPicker: () => <div data-testid="network-vip-picker" />,
}));

jest.mock('./HealthPanel', () => ({
  HealthPanel: () => <div data-testid="health-panel" />,
}));

jest.mock('./ScalingPanel', () => ({
  ScalingPanel: () => <div data-testid="scaling-panel" />,
}));

jest.mock('./MigrationsPanel', () => ({
  MigrationsPanel: () => <div data-testid="migrations-panel" />,
}));

jest.mock('./MigrationChainsPanel', () => ({
  MigrationChainsPanel: () => <div data-testid="migration-chains-panel" />,
}));

jest.mock('./StorageMigrationsPanel', () => ({
  StorageMigrationsPanel: () => <div data-testid="storage-migrations-panel" />,
}));

jest.mock('./DeployPlatformPanel', () => ({
  DeployPlatformPanel: () => <div data-testid="deploy-platform-panel" />,
  default: () => <div data-testid="deploy-platform-panel" />,
}));

jest.mock('@system/features/system/components/federation/ChildrenPanel', () => ({
  ChildrenPanel: () => <div data-testid="children-panel" />,
}));

jest.mock('@system/features/system/components/federation/ServiceOfferingsPanel', () => ({
  ServiceOfferingsPanel: () => <div data-testid="service-offerings-panel" />,
}));

jest.mock('@system/features/system/components/federation/ServiceSubscriptionsPanel', () => ({
  ServiceSubscriptionsPanel: () => <div data-testid="service-subscriptions-panel" />,
}));

// =============================================================================
// Helpers
// =============================================================================

const BASE = '/app/system/compute/platform';

/**
 * Render PlatformInfraTab inside a MemoryRouter that simulates the parent
 * route nesting. The component uses relative <Routes> internally so we must
 * wrap it in a parent route that strips the base path prefix.
 */
function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        {/* The shell that hosts PlatformInfraTab in the real app */}
        <Route path={`${BASE}/*`} element={<PlatformInfraTab />} />
        {/* Catch the root-redirect landing */}
        <Route path="*" element={<div data-testid="redirect-catch" />} />
      </Routes>
    </MemoryRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('PlatformInfraTab', () => {
  beforeEach(() => {
    mockHasPermission = jest.fn(() => true);
  });


  // ── Overview cards ──────────────────────────────────────────────────────────

  it('always renders the PlatformOverviewCards header', () => {
    renderAt(`${BASE}/services`);
    expect(screen.getByTestId('platform-overview-cards')).toBeInTheDocument();
  });

  // ── Tab nav bar ─────────────────────────────────────────────────────────────

  it('renders all 8 tab labels in the nav bar', () => {
    renderAt(`${BASE}/services`);
    const expectedLabels = ['Services', 'Peers', 'Children', 'Migrations', 'Scaling', 'Health', 'Deploy', 'Service Discovery'];
    for (const label of expectedLabels) {
      expect(screen.getByRole('link', { name: new RegExp(label, 'i') })).toBeInTheDocument();
    }
  });

  it('each tab link points to its correct sub-path', () => {
    renderAt(`${BASE}/services`);

    const expectations: Array<[string, string]> = [
      ['Services', `${BASE}/services`],
      ['Peers', `${BASE}/peers`],
      ['Children', `${BASE}/children`],
      ['Migrations', `${BASE}/migrations`],
      ['Scaling', `${BASE}/scaling`],
      ['Health', `${BASE}/health`],
      ['Deploy', `${BASE}/deploy`],
      ['Service Discovery', `${BASE}/discovery`],
    ];

    for (const [label, href] of expectations) {
      const link = screen.getByRole('link', { name: new RegExp(label, 'i') });
      expect(link).toHaveAttribute('href', href);
    }
  });

  // ── Active tab styling ───────────────────────────────────────────────────────

  it('marks the Services tab as active when the URL ends with /services', () => {
    renderAt(`${BASE}/services`);
    const link = screen.getByRole('link', { name: /services/i });
    expect(link.className).toContain('border-theme-info-border');
  });

  it('marks the Peers tab as active when the URL ends with /peers', () => {
    renderAt(`${BASE}/peers`);
    // Exact match: the /peers panel itself now also links to "...→ Peers"
    // (the canonical management surface), which a loose /peers/i would match too.
    const link = screen.getByRole('link', { name: 'Peers' });
    expect(link.className).toContain('border-theme-info-border');
  });

  it('marks the Children tab as active when the URL ends with /children', () => {
    renderAt(`${BASE}/children`);
    const link = screen.getByRole('link', { name: /children/i });
    expect(link.className).toContain('border-theme-info-border');
  });

  it('marks the Migrations tab as active when the URL ends with /migrations', () => {
    renderAt(`${BASE}/migrations`);
    const link = screen.getByRole('link', { name: /migrations/i });
    expect(link.className).toContain('border-theme-info-border');
  });

  it('marks the Scaling tab as active when the URL ends with /scaling', () => {
    renderAt(`${BASE}/scaling`);
    const link = screen.getByRole('link', { name: /scaling/i });
    expect(link.className).toContain('border-theme-info-border');
  });

  it('marks the Health tab as active when the URL ends with /health', () => {
    renderAt(`${BASE}/health`);
    const link = screen.getByRole('link', { name: /health/i });
    expect(link.className).toContain('border-theme-info-border');
  });

  it('marks the Deploy tab as active when the URL ends with /deploy', () => {
    renderAt(`${BASE}/deploy`);
    const link = screen.getByRole('link', { name: /deploy/i });
    expect(link.className).toContain('border-theme-info-border');
  });

  it('marks the Service Discovery tab as active when the URL ends with /discovery', () => {
    renderAt(`${BASE}/discovery`);
    const link = screen.getByRole('link', { name: /service discovery/i });
    expect(link.className).toContain('border-theme-info-border');
  });

  it('does not mark inactive tabs with the active border class', () => {
    renderAt(`${BASE}/services`);
    const inactiveTabs = ['Peers', 'Children', 'Migrations', 'Scaling', 'Health', 'Deploy', 'Service Discovery'];
    for (const label of inactiveTabs) {
      const link = screen.getByRole('link', { name: new RegExp(label, 'i') });
      expect(link.className).not.toContain('border-theme-info-border');
      expect(link.className).toContain('border-transparent');
    }
  });

  // ── Route → panel dispatch ───────────────────────────────────────────────────

  it('renders ServiceOfferingsPanel and ServiceSubscriptionsPanel for /services route', () => {
    renderAt(`${BASE}/services`);
    expect(screen.getByTestId('service-offerings-panel')).toBeInTheDocument();
    expect(screen.getByTestId('service-subscriptions-panel')).toBeInTheDocument();
  });

  it('renders PeerLivenessMonitor and a link to the canonical peer-management surface for /peers route when system.peers.read is held', () => {
    renderAt(`${BASE}/peers`);
    expect(screen.getByTestId('peer-liveness-monitor')).toBeInTheDocument();
    // fc-35: PeersPanel (invite/revoke) was deleted as a duplicate of
    // PeerControlPanel on ServiceDeliveryPage, which is now canonical.
    expect(screen.getByRole('link', { name: /service delivery.*peers/i })).toHaveAttribute(
      'href',
      '/app/system/service-delivery/peers'
    );
  });

  it('hides both PeerLivenessMonitor and the link-out without system.peers.read (review fix, fc-35)', () => {
    mockHasPermission = jest.fn((perm: string) => perm !== 'system.peers.read');
    renderAt(`${BASE}/peers`);
    expect(screen.queryByTestId('peer-liveness-monitor')).not.toBeInTheDocument();
    // Review fix: the link-out used to render unconditionally regardless of
    // this permission, which was a dead end for anyone without it — its own
    // destination (ServiceDeliveryPage's Peers tab) requires system.peers.read
    // too. Now gated on the same permission as the liveness monitor above it.
    expect(screen.queryByRole('link', { name: /service delivery.*peers/i })).not.toBeInTheDocument();
  });

  it('renders NetworkVipPicker for /discovery route when system.sdwan.vips.manage is held', () => {
    renderAt(`${BASE}/discovery`);
    expect(screen.getByTestId('network-vip-picker')).toBeInTheDocument();
  });

  it('hides NetworkVipPicker without system.sdwan.vips.manage (C10 review FIX-1)', () => {
    mockHasPermission = jest.fn((perm: string) => perm !== 'system.sdwan.vips.manage');
    renderAt(`${BASE}/discovery`);
    expect(screen.queryByTestId('network-vip-picker')).not.toBeInTheDocument();
  });

  it('renders ChildrenPanel for /children route', () => {
    renderAt(`${BASE}/children`);
    expect(screen.getByTestId('children-panel')).toBeInTheDocument();
  });

  it('renders the three migration panels for the /migrations route', () => {
    renderAt(`${BASE}/migrations`);
    expect(screen.getByTestId('migrations-panel')).toBeInTheDocument();
    // Multi-hop chains (IMP-ffc2de6bd175) had six operator endpoints and no
    // surface at all, so a stalled chain was invisible from the console.
    expect(screen.getByTestId('migration-chains-panel')).toBeInTheDocument();
    expect(screen.getByTestId('storage-migrations-panel')).toBeInTheDocument();
  });

  it('renders ScalingPanel for /scaling route', () => {
    renderAt(`${BASE}/scaling`);
    expect(screen.getByTestId('scaling-panel')).toBeInTheDocument();
  });

  it('renders HealthPanel for /health route', () => {
    renderAt(`${BASE}/health`);
    expect(screen.getByTestId('health-panel')).toBeInTheDocument();
  });

  it('renders DeployPlatformPanel for /deploy route', () => {
    renderAt(`${BASE}/deploy`);
    expect(screen.getByTestId('deploy-platform-panel')).toBeInTheDocument();
  });

  // ── Fallback / redirect ──────────────────────────────────────────────────────

  it('redirects an unknown sub-path back to /services (the first tab)', () => {
    renderAt(`${BASE}/unknown-route`);
    // After the redirect, Services tab should be active and its panels rendered.
    expect(screen.getByTestId('service-offerings-panel')).toBeInTheDocument();
    const servicesLink = screen.getByRole('link', { name: /services/i });
    expect(servicesLink.className).toContain('border-theme-info-border');
  });

  // ── Panel isolation ──────────────────────────────────────────────────────────

  it('does not render the Peers tab content when on the /services route', () => {
    renderAt(`${BASE}/services`);
    expect(screen.queryByRole('link', { name: /service delivery.*peers/i })).not.toBeInTheDocument();
  });

  it('does not render HealthPanel when on the /peers route', () => {
    renderAt(`${BASE}/peers`);
    expect(screen.queryByTestId('health-panel')).not.toBeInTheDocument();
  });

  it('does not render ScalingPanel when on the /migrations route', () => {
    renderAt(`${BASE}/migrations`);
    expect(screen.queryByTestId('scaling-panel')).not.toBeInTheDocument();
  });

  // ── All tabs visible regardless of permissions ───────────────────────────────

  it('shows all 8 tabs without permission gating (best-effort model)', () => {
    renderAt(`${BASE}/services`);
    // The component comment states permissions are best-effort — all tabs are
    // rendered unconditionally and panels surface forbidden API responses.
    const links = screen.getAllByRole('link');
    const tabLinks = links.filter((l) =>
      /services|peers|children|migrations|scaling|health|deploy|service discovery/i.test(l.textContent ?? ''),
    );
    // 8 distinct tab links should always be present
    const tabKeys = new Set(tabLinks.map((l) => l.getAttribute('href')));
    expect(tabKeys.size).toBe(8);
  });
});
