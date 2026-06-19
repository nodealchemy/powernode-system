import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { PlatformOverviewCards } from './PlatformOverviewCards';

// =============================================================================
// Mocks
//
// PlatformOverviewCards calls `platformApi.overview()`, which internally uses
// `apiClient.get`. We mock the entire platformApi facade so we control what
// `overview()` resolves/rejects with, without going through the HTTP layer.
// =============================================================================

const mockOverview = jest.fn();

jest.mock('@system/features/system/services/api/platformApi', () => ({
  platformApi: {
    overview: (...args: unknown[]) => mockOverview(...args),
  },
}));

// =============================================================================
// Helpers / Fixtures
// =============================================================================

/** Build a full PlatformOverview shape for happy-path tests. */
function makeOverview(overrides: Partial<{
  peersCount: number;
  peersByStatus: Record<string, number>;
  childrenCount: number;
  childrenByStatus: Record<string, number>;
  offeringsCount: number;
  subscriptionsCount: number;
  migrationsCount: number;
  migrationsByStatus: Record<string, number>;
  certificatesCount: number;
  certificatesByStatus: Record<string, number>;
  nearExpiry: number;
}> = {}) {
  const {
    peersCount = 4,
    peersByStatus = { active: 3, enrolled: 1 },
    childrenCount = 2,
    childrenByStatus = { active: 2 },
    offeringsCount = 5,
    subscriptionsCount = 12,
    migrationsCount = 1,
    migrationsByStatus = { pending: 1 },
    certificatesCount = 7,
    certificatesByStatus = { valid: 7 },
    nearExpiry = 0,
  } = overrides;

  return {
    peers: { count: peersCount, by_status: peersByStatus, last_handshake_at: null },
    children: { count: childrenCount, by_status: childrenByStatus },
    services: { offerings: offeringsCount, subscriptions: subscriptionsCount },
    migrations: { count: migrationsCount, by_status: migrationsByStatus },
    certificates: {
      count: certificatesCount,
      by_status: certificatesByStatus,
      near_expiry: nearExpiry,
    },
    generated_at: '2026-06-05T00:00:00Z',
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('PlatformOverviewCards', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    mockOverview.mockReset();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('renders five skeleton cards while the API call is pending', () => {
    // never-resolving promise keeps loading state visible
    mockOverview.mockReturnValue(new Promise(() => {}));

    render(<PlatformOverviewCards />);

    // Five skeleton divs with animate-pulse class
    const skeletons = document.querySelectorAll('.animate-pulse');
    expect(skeletons).toHaveLength(5);
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('renders an error banner when the API call rejects with an Error', async () => {
    mockOverview.mockRejectedValue(new Error('Network timeout'));

    render(<PlatformOverviewCards />);

    await waitFor(() =>
      expect(screen.getByText(/overview failed to load:/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/network timeout/i)).toBeInTheDocument();
  });

  it('renders a generic error message when a non-Error is thrown', async () => {
    mockOverview.mockRejectedValue('some string error');

    render(<PlatformOverviewCards />);

    await waitFor(() =>
      expect(screen.getByText(/failed to load overview/i)).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Happy path — all five cards rendered
  // ---------------------------------------------------------------------------

  it('renders all five card labels after the overview resolves', async () => {
    mockOverview.mockResolvedValue(makeOverview());

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Peers')).toBeInTheDocument());
    expect(screen.getByText('Children')).toBeInTheDocument();
    expect(screen.getByText('Services')).toBeInTheDocument();
    expect(screen.getByText('Migrations')).toBeInTheDocument();
    expect(screen.getByText('Certificates')).toBeInTheDocument();
  });

  it('calls platformApi.overview exactly once on mount', async () => {
    mockOverview.mockResolvedValue(makeOverview());

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Peers')).toBeInTheDocument());
    expect(mockOverview).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Peers card
  // ---------------------------------------------------------------------------

  it('displays the peers count as the primary value', async () => {
    mockOverview.mockResolvedValue(
      makeOverview({ peersCount: 42, childrenCount: 0, migrationsCount: 0, certificatesCount: 0 }),
    );

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Peers')).toBeInTheDocument());
    // 42 is a unique value — only the Peers card will show it
    expect(screen.getByText('42')).toBeInTheDocument();
  });

  it('renders peers by_status detail with active · enrolled · degraded order', async () => {
    mockOverview.mockResolvedValue(
      makeOverview({ peersByStatus: { active: 3, enrolled: 1, degraded: 1 } }),
    );

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Peers')).toBeInTheDocument());
    expect(screen.getByText('3 active · 1 enrolled · 1 degraded')).toBeInTheDocument();
  });

  it('renders "none" for peers detail when by_status has all zeros', async () => {
    mockOverview.mockResolvedValue(
      makeOverview({ peersByStatus: { active: 0, enrolled: 0 } }),
    );

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Peers')).toBeInTheDocument());
    // The statusDetail function returns "none" when all counts are 0
    const nones = screen.getAllByText('none');
    expect(nones.length).toBeGreaterThan(0);
  });

  it('renders "—" for peers detail when by_status is undefined', async () => {
    const overview = makeOverview();
    // Explicitly remove by_status
    const overviewWithoutStatus = {
      ...overview,
      peers: { count: 2, by_status: undefined as unknown as Record<string, number>, last_handshake_at: null },
    };
    mockOverview.mockResolvedValue(overviewWithoutStatus);

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Peers')).toBeInTheDocument());
    const dashes = screen.getAllByText('—');
    expect(dashes.length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Children card
  // ---------------------------------------------------------------------------

  it('displays the children count as the primary value', async () => {
    mockOverview.mockResolvedValue(makeOverview({ childrenCount: 9 }));

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Children')).toBeInTheDocument());
    expect(screen.getByText('9')).toBeInTheDocument();
  });

  it('renders children detail with active · enrolled · proposed order', async () => {
    mockOverview.mockResolvedValue(
      makeOverview({
        childrenByStatus: { enrolled: 2, active: 5, proposed: 1 },
      }),
    );

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Children')).toBeInTheDocument());
    // active comes first per the order array, then enrolled, then proposed
    expect(screen.getByText('5 active · 2 enrolled · 1 proposed')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Services card
  // ---------------------------------------------------------------------------

  it('displays services as "offerings / subscriptions" format', async () => {
    mockOverview.mockResolvedValue(
      makeOverview({ offeringsCount: 5, subscriptionsCount: 12 }),
    );

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Services')).toBeInTheDocument());
    expect(screen.getByText('5 / 12')).toBeInTheDocument();
    expect(screen.getByText('offerings / subscriptions')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Migrations card
  // ---------------------------------------------------------------------------

  it('displays the migrations count as the primary value', async () => {
    mockOverview.mockResolvedValue(makeOverview({ migrationsCount: 3 }));

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Migrations')).toBeInTheDocument());
    expect(screen.getByText('3')).toBeInTheDocument();
  });

  it('renders migrations detail with pending · applying · applied order', async () => {
    mockOverview.mockResolvedValue(
      makeOverview({
        migrationsByStatus: { applying: 1, pending: 2, applied: 4 },
      }),
    );

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Migrations')).toBeInTheDocument());
    expect(screen.getByText('2 pending · 1 applying · 4 applied')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Certificates card — no near_expiry
  // ---------------------------------------------------------------------------

  it('displays the certificates count as the primary value', async () => {
    mockOverview.mockResolvedValue(makeOverview({ certificatesCount: 7 }));

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Certificates')).toBeInTheDocument());
    expect(screen.getByText('7')).toBeInTheDocument();
  });

  it('renders certificates detail via statusDetail when near_expiry is 0', async () => {
    mockOverview.mockResolvedValue(
      makeOverview({
        certificatesCount: 7,
        certificatesByStatus: { valid: 7, failed: 0 },
        nearExpiry: 0,
      }),
    );

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Certificates')).toBeInTheDocument());
    // near_expiry === 0, so statusDetail is used; failed=0 is filtered out
    expect(screen.getByText('7 valid')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Certificates card — near_expiry warning path
  // ---------------------------------------------------------------------------

  it('renders "X expiring soon" when near_expiry > 0', async () => {
    mockOverview.mockResolvedValue(
      makeOverview({
        certificatesCount: 10,
        nearExpiry: 3,
      }),
    );

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Certificates')).toBeInTheDocument());
    expect(screen.getByText('3 expiring soon')).toBeInTheDocument();
  });

  it('applies the warning color class when near_expiry > 0', async () => {
    mockOverview.mockResolvedValue(
      makeOverview({ nearExpiry: 2 }),
    );

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('2 expiring soon')).toBeInTheDocument());
    const detail = screen.getByText('2 expiring soon');
    expect(detail.className).toContain('text-theme-warning-fg');
  });

  it('does NOT apply the warning color class when near_expiry is 0', async () => {
    mockOverview.mockResolvedValue(
      makeOverview({ nearExpiry: 0, certificatesByStatus: { valid: 5 } }),
    );

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Certificates')).toBeInTheDocument());
    const detail = screen.getByText('5 valid');
    expect(detail.className).not.toContain('text-theme-warning-fg');
    expect(detail.className).toContain('text-theme-tertiary');
  });

  // ---------------------------------------------------------------------------
  // statusDetail — extra keys not in the order array are appended
  // ---------------------------------------------------------------------------

  it('appends unknown status keys after the known ordered ones', async () => {
    mockOverview.mockResolvedValue(
      makeOverview({
        migrationsByStatus: { pending: 1, applying: 1, applied: 2, error: 1 },
      }),
    );

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(screen.getByText('Migrations')).toBeInTheDocument());
    // Known order: pending · applying · applied, then extra key: error
    expect(
      screen.getByText('1 pending · 1 applying · 2 applied · 1 error'),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Auto-refresh: setInterval fires every 30 s
  // ---------------------------------------------------------------------------

  it('re-fetches the overview after 30 seconds', async () => {
    mockOverview.mockResolvedValue(makeOverview());

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(mockOverview).toHaveBeenCalledTimes(1));

    // Advance timers by 30 000ms to trigger the interval
    jest.advanceTimersByTime(30_000);

    await waitFor(() => expect(mockOverview).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // API endpoint verified via platformApi mock — confirms the component
  // delegates to platformApi.overview() with no additional arguments.
  // ---------------------------------------------------------------------------

  it('calls platformApi.overview() with no arguments on mount', async () => {
    mockOverview.mockResolvedValue(makeOverview());

    render(<PlatformOverviewCards />);

    await waitFor(() => expect(mockOverview).toHaveBeenCalled());
    expect(mockOverview).toHaveBeenCalledWith();
  });
});
