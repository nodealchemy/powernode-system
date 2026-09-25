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
    renderAt(`${BASE}/peers`);
    expect(screen.getByTestId('platform-overview-cards')).toBeInTheDocument();
  });

  // ── Tab nav bar ─────────────────────────────────────────────────────────────

  const TAB_LINKS: Array<[string, string]> = [
    ['Peer Liveness', `${BASE}/peers`],
    ['Migrations', `${BASE}/migrations`],
    ['Scaling', `${BASE}/scaling`],
    ['Deploy', `${BASE}/deploy`],
    ['Service Discovery', `${BASE}/discovery`],
  ];

  it('renders the five tabs, each linking to its sub-path', () => {
    renderAt(`${BASE}/peers`);
    for (const [label, href] of TAB_LINKS) {
      expect(screen.getByRole('link', { name: label })).toHaveAttribute('href', href);
    }
  });

  it.each(TAB_LINKS)('marks %s active on its own path, and no other tab', (label, href) => {
    renderAt(href);
    for (const [other] of TAB_LINKS) {
      const link = screen.getByRole('link', { name: other });
      if (other === label) {
        expect(link.className).toContain('border-theme-info-border');
      } else {
        expect(link.className).toContain('border-transparent');
      }
    }
  });

  // fc-47: platform subsystem health is on /app/status. Services (offerings
  // and subscriptions) and Children each have one home, on Service Delivery;
  // this hub no longer repeats them.
  it('has no Health, Services or Children tab', () => {
    renderAt(`${BASE}/peers`);
    for (const name of [/^health$/i, /^services$/i, /^children$/i]) {
      expect(screen.queryByRole('link', { name })).not.toBeInTheDocument();
    }
  });

  it.each(['services', 'children', 'health'])('falls back to Peer Liveness at the old /%s path', (segment) => {
    renderAt(`${BASE}/${segment}`);
    expect(screen.getByRole('link', { name: 'Peer Liveness' }).className).toContain('border-theme-info-border');
    expect(screen.getByTestId('peer-liveness-monitor')).toBeInTheDocument();
  });

  // ── Route → panel dispatch ───────────────────────────────────────────────────

  it('renders PeerLivenessMonitor and a link to the canonical peer-management surface for /peers route when system.peers.read is held', () => {
    renderAt(`${BASE}/peers`);
    expect(screen.getByTestId('peer-liveness-monitor')).toBeInTheDocument();
    // fc-35: PeersPanel (invite/revoke) was deleted as a duplicate of
    // PeerControlPanel on ServiceDeliveryPage, which is now canonical.
    expect(screen.getByRole('link', { name: /service delivery.*federation peers/i })).toHaveAttribute(
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

  it('renders DeployPlatformPanel for /deploy route', () => {
    renderAt(`${BASE}/deploy`);
    expect(screen.getByTestId('deploy-platform-panel')).toBeInTheDocument();
  });

  // ── Panel isolation ──────────────────────────────────────────────────────────

  it('does not render the Peer Liveness content when on the /migrations route', () => {
    renderAt(`${BASE}/migrations`);
    expect(screen.queryByTestId('peer-liveness-monitor')).not.toBeInTheDocument();
    expect(screen.queryByTestId('scaling-panel')).not.toBeInTheDocument();
  });

  // ── All tabs visible regardless of permissions ───────────────────────────────

  it('shows all five tabs without permission gating (best-effort model)', () => {
    mockHasPermission = jest.fn(() => false);
    renderAt(`${BASE}/migrations`);
    // The component comment states permissions are best-effort — all tabs are
    // rendered unconditionally and panels surface forbidden API responses.
    for (const [label] of TAB_LINKS) {
      expect(screen.getByRole('link', { name: label })).toBeInTheDocument();
    }
  });
});
