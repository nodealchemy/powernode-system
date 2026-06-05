import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { HealthPanel } from './HealthPanel';

// =============================================================================
// Mocks
//
// HealthPanel calls platformHealthApi.show() which in turn calls
// apiClient.get('/system/platform/health'). We mock the api facade directly
// so we can control what the component receives.
// =============================================================================

const mockShow = jest.fn();

jest.mock(
  '@system/features/system/services/api/platformHealthApi',
  () => ({
    platformHealthApi: {
      show: (...args: unknown[]) => mockShow(...args),
    },
  }),
);

// =============================================================================
// Fixtures
// =============================================================================

const GENERATED_AT = '2026-06-05T12:00:00.000Z';

const HEALTHY_HEALTH = {
  generated_at: GENERATED_AT,
  rails: {
    status: 'ok' as const,
    uptime_human: '3d 4h',
    rails_env: 'production',
    ruby_version: '3.3.0',
    db_connected: true,
  },
  worker: {
    status: 'ok' as const,
    stats: {
      processed: 12345,
      failed: 2,
      enqueued: 5,
      retry_size: 1,
      processes: 4,
    },
    last_seen_at: '2026-06-05T11:55:00.000Z',
  },
  redis: {
    status: 'ok' as const,
    cache_store: 'redis_cache_store',
    probe_at: '2026-06-05T11:59:00.000Z',
  },
  postgres: {
    status: 'ok' as const,
    database: 'powernode_production',
    size_human: '4.2 GB',
    active_connections: 12,
  },
  acme: {
    status: 'ok' as const,
    count: 3,
    by_status: { valid: 3 },
    expiring_within_30d: 0,
    expiring_within_7d: 0,
    nearest_expiry_at: '2026-09-01T00:00:00.000Z',
  },
  sdwan: {
    status: 'ok' as const,
    networks_count: 2,
    virtual_ips: { count: 5, assigned: 3 },
    bgp: { total: 4, established: 4 },
  },
  federation: {
    status: 'ok' as const,
    total: 2,
    active: 2,
    degraded: 0,
    suspended: 0,
    heartbeat_stale: 0,
    last_handshake_at: '2026-06-05T11:50:00.000Z',
  },
};

const DEGRADED_HEALTH = {
  ...HEALTHY_HEALTH,
  worker: {
    status: 'degraded' as const,
    stats: { processes: 1, failed: 100 },
    error: 'Worker queue backlogged',
    last_seen_at: null,
  },
  redis: {
    status: 'down' as const,
    error: 'Connection refused',
    cache_store: undefined,
  },
  federation: {
    status: 'unknown' as const,
    total: 0,
    active: 0,
    degraded: 0,
    suspended: 0,
    heartbeat_stale: 3,
    last_handshake_at: null,
  },
};

// =============================================================================
// Tests
// =============================================================================

describe('HealthPanel', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    mockShow.mockReset();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('renders skeleton placeholders while the first fetch is in flight', () => {
    // Never resolves — stays loading
    mockShow.mockReturnValue(new Promise(() => {}));

    render(<HealthPanel />);

    // 7 skeleton cards should be rendered
    const skeletons = document.querySelectorAll('.animate-pulse');
    expect(skeletons.length).toBe(7);
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('renders an error message when the API rejects', async () => {
    mockShow.mockRejectedValue(new Error('Network error'));

    render(<HealthPanel />);

    await act(async () => {
      await Promise.resolve();
    });

    await waitFor(() =>
      expect(screen.getByText('Network error')).toBeInTheDocument(),
    );
  });

  it('renders a generic error message for non-Error rejections', async () => {
    mockShow.mockRejectedValue('something-bad');

    render(<HealthPanel />);

    await act(async () => {
      await Promise.resolve();
    });

    await waitFor(() =>
      expect(screen.getByText('Failed to load health')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Successful render
  // ---------------------------------------------------------------------------

  it('renders all 7 subsystem card labels on success', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => {
      await Promise.resolve();
    });

    await waitFor(() =>
      expect(screen.getByText('Rails API')).toBeInTheDocument(),
    );

    const labels = [
      'Rails API',
      'Worker Pool',
      'Redis',
      'Postgres',
      'ACME / Traefik',
      'SDWAN',
      'Federation',
    ];
    for (const label of labels) {
      expect(screen.getByText(label)).toBeInTheDocument();
    }
  });

  it('calls platformHealthApi.show on mount', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => {
      await Promise.resolve();
    });

    expect(mockShow).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Rails card content
  // ---------------------------------------------------------------------------

  it('renders Rails uptime in the primary stat position', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() => expect(screen.getByText('Rails API')).toBeInTheDocument());

    // uptime_human appears as the primary value (large text) and in the detail row
    expect(screen.getAllByText('3d 4h').length).toBeGreaterThanOrEqual(2);
  });

  it('renders Rails env details in the detail section', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() => expect(screen.getByText('Rails API')).toBeInTheDocument());

    expect(screen.getByText('production')).toBeInTheDocument();
    expect(screen.getByText('3.3.0')).toBeInTheDocument();
    // "db · connected" — match the whole text node content
    expect(screen.getByText(/connected/)).toBeInTheDocument();
  });

  it('shows "disconnected" when db_connected is false', async () => {
    mockShow.mockResolvedValue({
      ...HEALTHY_HEALTH,
      rails: { ...HEALTHY_HEALTH.rails, db_connected: false },
    });

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText(/disconnected/)).toBeInTheDocument(),
    );
  });

  it('renders a Rails error when rails.error is set', async () => {
    mockShow.mockResolvedValue({
      ...HEALTHY_HEALTH,
      rails: { ...HEALTHY_HEALTH.rails, error: 'Boot failed' },
    });

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('Boot failed')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Worker card content
  // ---------------------------------------------------------------------------

  it('renders worker process count in primary position', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('Worker Pool')).toBeInTheDocument(),
    );

    expect(screen.getByText('4 live')).toBeInTheDocument();
  });

  it('renders worker processed count formatted with locale separators', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('Worker Pool')).toBeInTheDocument(),
    );

    expect(screen.getByText('12,345')).toBeInTheDocument();
  });

  it('renders worker error when present', async () => {
    mockShow.mockResolvedValue(DEGRADED_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('Worker queue backlogged')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Redis card content
  // ---------------------------------------------------------------------------

  it('renders the redis cache_store label', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() => expect(screen.getByText('Redis')).toBeInTheDocument());

    expect(screen.getByText('redis_cache_store')).toBeInTheDocument();
  });

  it('renders redis error when status is down', async () => {
    mockShow.mockResolvedValue(DEGRADED_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('Connection refused')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Postgres card content
  // ---------------------------------------------------------------------------

  it('renders postgres database name and size', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('Postgres')).toBeInTheDocument(),
    );

    expect(screen.getByText('powernode_production')).toBeInTheDocument();
    expect(screen.getByText('4.2 GB')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // ACME card content
  // ---------------------------------------------------------------------------

  it('renders cert count with correct pluralization (plural)', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('ACME / Traefik')).toBeInTheDocument(),
    );

    expect(screen.getByText('3 certs')).toBeInTheDocument();
  });

  it('renders singular "cert" when count is 1', async () => {
    mockShow.mockResolvedValue({
      ...HEALTHY_HEALTH,
      acme: { ...HEALTHY_HEALTH.acme, count: 1, by_status: { valid: 1 } },
    });

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('1 cert')).toBeInTheDocument(),
    );
  });

  it('renders "0 certs" when acme.count is 0', async () => {
    mockShow.mockResolvedValue({
      ...HEALTHY_HEALTH,
      acme: {
        status: 'ok' as const,
        count: 0,
        expiring_within_30d: 0,
        expiring_within_7d: 0,
      },
    });

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('0 certs')).toBeInTheDocument(),
    );
  });

  it('shows expiry warning when expiring_within_30d > 0', async () => {
    mockShow.mockResolvedValue({
      ...HEALTHY_HEALTH,
      acme: {
        ...HEALTHY_HEALTH.acme,
        expiring_within_30d: 2,
        expiring_within_7d: 0,
      },
    });

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText(/2 expiring/)).toBeInTheDocument(),
    );
  });

  it('shows danger warning when expiring_within_7d > 0', async () => {
    mockShow.mockResolvedValue({
      ...HEALTHY_HEALTH,
      acme: {
        ...HEALTHY_HEALTH.acme,
        expiring_within_30d: 1,
        expiring_within_7d: 1,
      },
    });

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() => {
      expect(screen.getByText(/1 expiring <7d/)).toBeInTheDocument();
    });
  });

  it('renders by_status key breakdown', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('ACME / Traefik')).toBeInTheDocument(),
    );

    // The by_status entry renders "valid · 3" as a mixed div+span text.
    // Match with a regex against the full text content of the element.
    expect(screen.getByText(/valid\s*·/)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // SDWAN card content
  // ---------------------------------------------------------------------------

  it('renders SDWAN network count in primary position', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() => expect(screen.getByText('SDWAN')).toBeInTheDocument());

    expect(screen.getByText('2 networks')).toBeInTheDocument();
  });

  it('renders SDWAN VIP and BGP info', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() => expect(screen.getByText('SDWAN')).toBeInTheDocument());

    expect(screen.getByText(/3 assigned/)).toBeInTheDocument();
    expect(screen.getByText(/4\/4 established/)).toBeInTheDocument();
  });

  it('renders "0 networks" when networks_count is 0', async () => {
    mockShow.mockResolvedValue({
      ...HEALTHY_HEALTH,
      sdwan: {
        status: 'ok' as const,
        networks_count: 0,
        virtual_ips: { count: 0, assigned: 0 },
        bgp: { total: 0, established: 0 },
      },
    });

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('0 networks')).toBeInTheDocument(),
    );
  });

  it('renders sdwan error when present', async () => {
    mockShow.mockResolvedValue({
      ...HEALTHY_HEALTH,
      sdwan: {
        ...HEALTHY_HEALTH.sdwan,
        error: 'SDWAN peer unreachable',
      },
    });

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('SDWAN peer unreachable')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Federation card content
  // ---------------------------------------------------------------------------

  it('renders federation peer count with correct pluralization (plural)', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('Federation')).toBeInTheDocument(),
    );

    expect(screen.getByText('2 peers')).toBeInTheDocument();
  });

  it('renders singular "peer" when total is 1', async () => {
    mockShow.mockResolvedValue({
      ...HEALTHY_HEALTH,
      federation: {
        ...HEALTHY_HEALTH.federation,
        total: 1,
        active: 1,
      },
    });

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('1 peer')).toBeInTheDocument(),
    );
  });

  it('renders "0 peers" when federation.total is 0', async () => {
    mockShow.mockResolvedValue(DEGRADED_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('0 peers')).toBeInTheDocument(),
    );
  });

  it('shows stale heartbeat warning when heartbeat_stale > 0', async () => {
    mockShow.mockResolvedValue(DEGRADED_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText(/3 stale heartbeat/)).toBeInTheDocument(),
    );
  });

  it('renders federation error when present', async () => {
    mockShow.mockResolvedValue({
      ...HEALTHY_HEALTH,
      federation: {
        ...HEALTHY_HEALTH.federation,
        error: 'TLS handshake failed',
      },
    });

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('TLS handshake failed')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Status pills
  // ---------------------------------------------------------------------------

  it('renders status pills for each subsystem', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() => expect(screen.getByText('Rails API')).toBeInTheDocument());

    // All 7 cards are 'ok' — the StatusPill renders text "ok" plus the redis
    // primary text also says "ok". We verify at least 7.
    const okPills = screen.getAllByText('ok');
    expect(okPills.length).toBeGreaterThanOrEqual(7);
  });

  it('renders "degraded", "down", and "unknown" pills for degraded health', async () => {
    mockShow.mockResolvedValue(DEGRADED_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('Worker Pool')).toBeInTheDocument(),
    );

    // Multiple status pills — use getAllByText
    const degradedPills = screen.getAllByText('degraded');
    expect(degradedPills.length).toBeGreaterThanOrEqual(1);

    const downPills = screen.getAllByText('down');
    expect(downPills.length).toBeGreaterThanOrEqual(1);

    const unknownPills = screen.getAllByText('unknown');
    expect(unknownPills.length).toBeGreaterThanOrEqual(1);
  });

  // ---------------------------------------------------------------------------
  // Refresh button
  // ---------------------------------------------------------------------------

  it('renders the generated_at timestamp footer and refresh button', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByTitle('Refresh')).toBeInTheDocument(),
    );

    expect(screen.getByText(/refreshes every 30s/)).toBeInTheDocument();
  });

  it('calls platformHealthApi.show again when refresh button is clicked', async () => {
    // First call: returns healthy health
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    // Wait for first load to complete and cards to appear
    await waitFor(() => expect(screen.getByTitle('Refresh')).toBeInTheDocument());
    expect(mockShow).toHaveBeenCalledTimes(1);

    // Setup second call
    mockShow.mockResolvedValue(HEALTHY_HEALTH);
    fireEvent.click(screen.getByTitle('Refresh'));

    await act(async () => { await Promise.resolve(); });

    expect(mockShow).toHaveBeenCalledTimes(2);
  });

  // ---------------------------------------------------------------------------
  // Auto-refresh interval
  // ---------------------------------------------------------------------------

  it('auto-refreshes after 30 seconds', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });
    await waitFor(() => expect(mockShow).toHaveBeenCalledTimes(1));

    await act(async () => {
      jest.advanceTimersByTime(30_000);
      await Promise.resolve();
    });

    expect(mockShow).toHaveBeenCalledTimes(2);
  });

  it('clears the auto-refresh interval on unmount', async () => {
    mockShow.mockResolvedValue(HEALTHY_HEALTH);

    const { unmount } = render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });
    await waitFor(() => expect(mockShow).toHaveBeenCalledTimes(1));

    unmount();

    // Advance past the 30s boundary — no additional calls should happen
    act(() => { jest.advanceTimersByTime(60_000); });

    expect(mockShow).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Stale data — keeps showing old data while re-fetching
  // ---------------------------------------------------------------------------

  it('keeps showing old health data while a refresh is in flight', async () => {
    mockShow.mockResolvedValueOnce(HEALTHY_HEALTH);

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('Rails API')).toBeInTheDocument(),
    );

    // Block the next fetch
    mockShow.mockReturnValue(new Promise(() => {}));

    fireEvent.click(screen.getByTitle('Refresh'));

    // Cards should still be visible (not replaced by skeletons)
    expect(screen.getByText('Rails API')).toBeInTheDocument();
    expect(screen.getAllByText('3d 4h').length).toBeGreaterThanOrEqual(1);
  });

  // ---------------------------------------------------------------------------
  // Optional field fallbacks (—)
  // ---------------------------------------------------------------------------

  it('renders em-dashes for missing optional Rails fields', async () => {
    mockShow.mockResolvedValue({
      ...HEALTHY_HEALTH,
      rails: { status: 'ok' as const, db_connected: true },
    });

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('Rails API')).toBeInTheDocument(),
    );

    // uptime_human is used in both primary and detail, both will be '—'
    // rails_env and ruby_version also absent → '—' placeholders
    const dashes = screen.getAllByText('—');
    expect(dashes.length).toBeGreaterThanOrEqual(3);
  });

  it('renders em-dash for missing postgres size_human', async () => {
    mockShow.mockResolvedValue({
      ...HEALTHY_HEALTH,
      postgres: { status: 'ok' as const },
    });

    render(<HealthPanel />);

    await act(async () => { await Promise.resolve(); });

    await waitFor(() =>
      expect(screen.getByText('Postgres')).toBeInTheDocument(),
    );

    // primary text for postgres card should be '—'
    expect(screen.getAllByText('—').length).toBeGreaterThan(0);
  });
});
