import React from 'react';
import { render, screen } from '@testing-library/react';
import { RoutingOverviewPanel } from './RoutingOverviewPanel';
import type { SdwanRoutingOverview } from '../../../types/sdwan.types';

// =============================================================================
// Fixtures
// =============================================================================

function makeData(overrides: Partial<SdwanRoutingOverview> = {}): SdwanRoutingOverview {
  return {
    account_bgp: {
      id: 'bgp-1',
      as_number: 4200000001,
      router_id_strategy: 'peer_overlay_ipv6_hash',
      default_local_pref: 100,
      enabled: true,
      created_at: '2026-01-01T00:00:00Z',
    },
    summary: {
      total_networks: 5,
      ibgp_networks: 3,
      static_networks: 2,
      established_sessions: 4,
      total_sessions: 4,
    },
    ...overrides,
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('RoutingOverviewPanel', () => {
  // ---------------------------------------------------------------------------
  // Tile: iBGP networks
  // ---------------------------------------------------------------------------

  it('renders the iBGP networks count', () => {
    render(<RoutingOverviewPanel data={makeData()} />);
    expect(screen.getByText('iBGP networks')).toBeInTheDocument();
    expect(screen.getByText('3')).toBeInTheDocument();
  });

  it('renders the static + total network hint line', () => {
    render(<RoutingOverviewPanel data={makeData()} />);
    expect(screen.getByTitle('2 static · 5 total')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tile: BGP sessions — session ratio logic
  // ---------------------------------------------------------------------------

  it('renders the BGP sessions count', () => {
    render(<RoutingOverviewPanel data={makeData()} />);
    expect(screen.getByText('BGP sessions')).toBeInTheDocument();
    expect(screen.getByText('4')).toBeInTheDocument();
  });

  it('shows the established count and percentage when sessions exist', () => {
    render(<RoutingOverviewPanel data={makeData()} />);
    // 4 established / 4 total = 100%
    expect(screen.getByTitle('4 established (100%)')).toBeInTheDocument();
  });

  it('shows "No agents reporting yet" when total_sessions is 0', () => {
    render(
      <RoutingOverviewPanel
        data={makeData({
          summary: {
            total_networks: 2,
            ibgp_networks: 2,
            static_networks: 0,
            established_sessions: 0,
            total_sessions: 0,
          },
        })}
      />,
    );
    expect(screen.getByTitle('No agents reporting yet')).toBeInTheDocument();
  });

  it('rounds the session percentage correctly (floor to int)', () => {
    render(
      <RoutingOverviewPanel
        data={makeData({
          summary: {
            total_networks: 4,
            ibgp_networks: 4,
            static_networks: 0,
            established_sessions: 3,
            total_sessions: 4,
          },
        })}
      />,
    );
    // 3/4 = 0.75 → Math.round = 75
    expect(screen.getByTitle('3 established (75%)')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // BGP sessions tone classes
  // ---------------------------------------------------------------------------

  it('applies success tone when all sessions are established', () => {
    render(
      <RoutingOverviewPanel
        data={makeData({
          summary: {
            total_networks: 2,
            ibgp_networks: 2,
            static_networks: 0,
            established_sessions: 3,
            total_sessions: 3,
          },
        })}
      />,
    );
    // value "3" in the BGP sessions tile should carry the success class
    const valueEl = screen.getByTitle('3 established (100%)').previousElementSibling as HTMLElement;
    expect(valueEl?.className).toContain('text-theme-success-fg');
  });

  it('applies warning tone when fewer than 80% of sessions are established', () => {
    render(
      <RoutingOverviewPanel
        data={makeData({
          summary: {
            total_networks: 10,
            ibgp_networks: 10,
            static_networks: 0,
            established_sessions: 6,
            total_sessions: 10,
          },
        })}
      />,
    );
    // 6/10 = 60% < 80 → warning
    const hint = screen.getByTitle('6 established (60%)');
    const valueEl = hint.previousElementSibling as HTMLElement;
    expect(valueEl?.className).toContain('text-theme-warning-fg');
  });

  it('applies default tone when sessions > 0 but ratio is at or above 80%', () => {
    render(
      <RoutingOverviewPanel
        data={makeData({
          summary: {
            total_networks: 5,
            ibgp_networks: 5,
            static_networks: 0,
            established_sessions: 4,
            total_sessions: 5,
          },
        })}
      />,
    );
    // 4/5 = 80% — not < 80, not all established → default
    const hint = screen.getByTitle('4 established (80%)');
    const valueEl = hint.previousElementSibling as HTMLElement;
    expect(valueEl?.className).toContain('text-theme-primary');
    expect(valueEl?.className).not.toContain('text-theme-success-fg');
    expect(valueEl?.className).not.toContain('text-theme-warning-fg');
  });

  it('applies default tone when total_sessions is 0', () => {
    const { container } = render(
      <RoutingOverviewPanel
        data={makeData({
          summary: {
            total_networks: 0,
            ibgp_networks: 0,
            static_networks: 0,
            established_sessions: 0,
            total_sessions: 0,
          },
        })}
      />,
    );
    // The "BGP sessions" tile value is "0"
    const sessionsTile = screen.getByText('BGP sessions').closest('div.flex');
    expect(sessionsTile).toBeTruthy();
    // No warning or success classes anywhere in the sessions tile value
    const valueEls = sessionsTile?.querySelectorAll('[class*="text-2xl"]');
    valueEls?.forEach((el) => {
      expect(el.className).not.toContain('text-theme-success-fg');
      expect(el.className).not.toContain('text-theme-warning-fg');
    });
  });

  // ---------------------------------------------------------------------------
  // Tile: AS number — with account_bgp present
  // ---------------------------------------------------------------------------

  it('renders the AS number as a string when account_bgp is set', () => {
    render(<RoutingOverviewPanel data={makeData()} />);
    expect(screen.getByText('AS number')).toBeInTheDocument();
    expect(screen.getByText('4200000001')).toBeInTheDocument();
  });

  it('shows the RFC 6996 hint when account_bgp is set', () => {
    render(<RoutingOverviewPanel data={makeData()} />);
    expect(screen.getByTitle('RFC 6996 4-byte private')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tile: AS number — without account_bgp
  // ---------------------------------------------------------------------------

  it('renders "—" for AS number when account_bgp is null', () => {
    render(<RoutingOverviewPanel data={makeData({ account_bgp: null })} />);
    // Both AS number tile and router-ID tile render "—"
    const dashes = screen.getAllByText('—');
    expect(dashes.length).toBeGreaterThanOrEqual(2);
  });

  it('shows "Allocate to enable iBGP" hint when account_bgp is null', () => {
    render(<RoutingOverviewPanel data={makeData({ account_bgp: null })} />);
    expect(screen.getByTitle('Allocate to enable iBGP')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tile: Router-ID strategy — with account_bgp present
  // ---------------------------------------------------------------------------

  it('renders the router_id_strategy value', () => {
    render(<RoutingOverviewPanel data={makeData()} />);
    expect(screen.getByText('Router-ID strategy')).toBeInTheDocument();
    // peer_overlay_ipv6_hash is a long string (>10 chars) — renders in text-base
    expect(screen.getByText('peer_overlay_ipv6_hash')).toBeInTheDocument();
  });

  it('applies text-base size class for long router_id_strategy values', () => {
    render(<RoutingOverviewPanel data={makeData()} />);
    // "peer_overlay_ipv6_hash" length is 22 > 10 → isLongString = true → text-base
    const valueEl = screen.getByTitle('peer_overlay_ipv6_hash');
    expect(valueEl.className).toContain('text-base');
    expect(valueEl.className).not.toContain('text-2xl');
  });

  it('applies text-2xl size class for the short "explicit" strategy value', () => {
    render(
      <RoutingOverviewPanel
        data={makeData({
          account_bgp: {
            id: 'bgp-2',
            as_number: 4200000002,
            router_id_strategy: 'explicit',
            default_local_pref: 100,
            enabled: true,
          },
        })}
      />,
    );
    // "explicit" length is 8 ≤ 10 → isLongString = false → text-2xl
    const valueEl = screen.getByTitle('explicit');
    expect(valueEl.className).toContain('text-2xl');
    expect(valueEl.className).not.toContain('text-base');
  });

  it('shows the overlay /128 hint for the router-ID tile regardless of strategy', () => {
    render(<RoutingOverviewPanel data={makeData()} />);
    expect(screen.getByTitle("Derived from each peer's overlay /128")).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tile: Router-ID strategy — without account_bgp
  // ---------------------------------------------------------------------------

  it('renders "—" for router_id_strategy when account_bgp is null', () => {
    render(<RoutingOverviewPanel data={makeData({ account_bgp: null })} />);
    // "—" is short (1 char) → text-2xl
    const dashEls = screen.getAllByTitle('—');
    // Two tiles both show "—" (AS number and router-ID strategy)
    expect(dashEls.length).toBe(2);
    dashEls.forEach((el) => {
      expect(el.className).toContain('text-2xl');
    });
  });

  // ---------------------------------------------------------------------------
  // Grid layout rendering
  // ---------------------------------------------------------------------------

  it('renders exactly four stat tiles', () => {
    const { container } = render(<RoutingOverviewPanel data={makeData()} />);
    // Each tile is a `div.flex` inside the grid
    const grid = container.firstChild as HTMLElement;
    expect(grid.children.length).toBe(4);
  });

  it('renders all four tile labels', () => {
    render(<RoutingOverviewPanel data={makeData()} />);
    expect(screen.getByText('iBGP networks')).toBeInTheDocument();
    expect(screen.getByText('BGP sessions')).toBeInTheDocument();
    expect(screen.getByText('AS number')).toBeInTheDocument();
    expect(screen.getByText('Router-ID strategy')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // sessionRatio edge: established > total (defensive — should not happen but
  // the formula must not divide by zero)
  // ---------------------------------------------------------------------------

  it('computes 0% session ratio when total_sessions is 0 (no division by zero)', () => {
    // This variant also ensures the hint path is "No agents reporting yet"
    render(
      <RoutingOverviewPanel
        data={makeData({
          summary: {
            total_networks: 1,
            ibgp_networks: 1,
            static_networks: 0,
            established_sessions: 0,
            total_sessions: 0,
          },
        })}
      />,
    );
    // Should not throw and should render the zero-sessions hint
    expect(screen.getByTitle('No agents reporting yet')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Text-size branch: numeric values always use text-2xl
  // ---------------------------------------------------------------------------

  it('applies text-2xl size class for numeric ibgp_networks value', () => {
    render(<RoutingOverviewPanel data={makeData()} />);
    // ibgp_networks = 3 → value "3" displayed
    const valueEl = screen.getByTitle('3');
    expect(valueEl.className).toContain('text-2xl');
  });
});
