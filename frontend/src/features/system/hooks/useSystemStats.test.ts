import { renderHook, act, waitFor } from '@testing-library/react';
import { useSystemStats, useSystemResourceCounts, emptyStats } from './useSystemStats';
import type { SystemOverviewStats, SystemRecentActivity } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGetOverviewStats = jest.fn();
const mockGetRecentActivity = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getOverviewStats: (...args: unknown[]) => mockGetOverviewStats(...args),
    getRecentActivity: (...args: unknown[]) => mockGetRecentActivity(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

function makeStats(overrides: Partial<SystemOverviewStats> = {}): SystemOverviewStats {
  return {
    nodes: { total: 3, enabled: 2, disabled: 1 },
    instances: { total: 5, running: 3, stopped: 2, pending: 0 },
    templates: { total: 2, public: 1, private: 1 },
    platforms: { total: 1, enabled: 1 },
    providers: { total: 2, enabled: 2, types: ['qemu', 'proxmox'] },
    regions: { total: 4 },
    modules: {
      total: 6,
      enabled: 5,
      by_variety: { config: 2, instance: 3, subscription: 1 },
    },
    operations: { total: 10, pending: 1, running: 2, completed: 6, failed: 1 },
    puppet: { modules: 3, resources: 12, assignments: 8 },
    volumes: { total: 2, total_size_gb: 100 },
    networks: { total: 1 },
    ...overrides,
  };
}

function makeActivity(count = 2): SystemRecentActivity[] {
  return Array.from({ length: count }, (_, i) => ({
    id: `act-${i}`,
    type: 'operation' as const,
    action: `command_${i}`,
    description: `Operation ${i}`,
    status: 'complete',
    entity_name: 'System',
    entity_id: `entity-${i}`,
    initiated_by: 'admin',
    timestamp: '2026-01-01T00:00:00Z',
  }));
}

// =============================================================================
// Tests
// =============================================================================

describe('useSystemStats', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    jest.useFakeTimers();
    mockGetOverviewStats.mockResolvedValue(makeStats());
    mockGetRecentActivity.mockResolvedValue(makeActivity());
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  // ---------------------------------------------------------------------------
  // Initial state
  // ---------------------------------------------------------------------------

  it('starts with null stats, empty activity, loading=false, initialized=false', () => {
    mockGetOverviewStats.mockReturnValue(new Promise(() => {})); // never resolves
    mockGetRecentActivity.mockReturnValue(new Promise(() => {}));

    const { result } = renderHook(() => useSystemStats({ autoFetch: false }));

    expect(result.current.stats).toBeNull();
    expect(result.current.recentActivity).toEqual([]);
    expect(result.current.loading).toBe(false);
    expect(result.current.initialized).toBe(false);
    expect(result.current.error).toBeNull();
  });

  // ---------------------------------------------------------------------------
  // autoFetch = true (default)
  // ---------------------------------------------------------------------------

  it('fetches stats and activity on mount when autoFetch is true', async () => {
    const stats = makeStats();
    const activity = makeActivity(3);
    mockGetOverviewStats.mockResolvedValue(stats);
    mockGetRecentActivity.mockResolvedValue(activity);

    const { result } = renderHook(() => useSystemStats());

    await waitFor(() => expect(result.current.initialized).toBe(true));

    expect(result.current.stats).toEqual(stats);
    expect(result.current.recentActivity).toEqual(activity);
    expect(result.current.loading).toBe(false);
    expect(result.current.error).toBeNull();

    expect(mockGetOverviewStats).toHaveBeenCalledTimes(1);
    expect(mockGetRecentActivity).toHaveBeenCalledWith(10); // default activityLimit
  });

  it('does NOT fetch on mount when autoFetch is false', () => {
    const { result } = renderHook(() => useSystemStats({ autoFetch: false }));

    expect(result.current.loading).toBe(false);
    expect(mockGetOverviewStats).not.toHaveBeenCalled();
    expect(mockGetRecentActivity).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('sets loading=true while fetch is in-flight and false after resolution', async () => {
    let resolveStats!: (v: SystemOverviewStats) => void;
    mockGetOverviewStats.mockReturnValue(
      new Promise<SystemOverviewStats>((res) => { resolveStats = res; })
    );
    mockGetRecentActivity.mockResolvedValue([]);

    const { result } = renderHook(() => useSystemStats());

    // loading should be true during the fetch
    expect(result.current.loading).toBe(true);

    await act(async () => {
      resolveStats(makeStats());
    });

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.initialized).toBe(true);
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('sets error when getOverviewStats rejects', async () => {
    const boom = new Error('stats unavailable');
    mockGetOverviewStats.mockRejectedValue(boom);
    mockGetRecentActivity.mockResolvedValue([]);

    const { result } = renderHook(() => useSystemStats());

    await waitFor(() => expect(result.current.initialized).toBe(true));

    expect(result.current.error).toEqual(boom);
    expect(result.current.stats).toBeNull();
  });

  it('wraps non-Error rejections in an Error object', async () => {
    mockGetOverviewStats.mockRejectedValue('raw string error');
    mockGetRecentActivity.mockResolvedValue([]);

    const { result } = renderHook(() => useSystemStats());

    await waitFor(() => expect(result.current.initialized).toBe(true));

    expect(result.current.error).toBeInstanceOf(Error);
    expect(result.current.error?.message).toBe('Failed to fetch stats');
  });

  it('does NOT set error state when only activity fetch fails', async () => {
    const stats = makeStats();
    mockGetOverviewStats.mockResolvedValue(stats);
    mockGetRecentActivity.mockRejectedValue(new Error('activity unavailable'));

    const { result } = renderHook(() => useSystemStats());

    await waitFor(() => expect(result.current.initialized).toBe(true));

    // Activity errors are non-critical — error stays null, stats still populated
    expect(result.current.error).toBeNull();
    expect(result.current.stats).toEqual(stats);
    // Activity remains empty because the fetch failed
    expect(result.current.recentActivity).toEqual([]);
  });

  it('clears error on a successful refresh after a prior failure', async () => {
    const boom = new Error('first attempt failed');
    mockGetOverviewStats.mockRejectedValueOnce(boom).mockResolvedValue(makeStats());
    mockGetRecentActivity.mockResolvedValue([]);

    const { result } = renderHook(() => useSystemStats());

    await waitFor(() => expect(result.current.error).toEqual(boom));

    await act(async () => {
      await result.current.refresh();
    });

    expect(result.current.error).toBeNull();
    expect(result.current.stats).not.toBeNull();
  });

  // ---------------------------------------------------------------------------
  // Manual refresh
  // ---------------------------------------------------------------------------

  it('refresh() fetches both stats and activity again', async () => {
    const stats1 = makeStats({ nodes: { total: 1, enabled: 1, disabled: 0 } });
    const stats2 = makeStats({ nodes: { total: 5, enabled: 4, disabled: 1 } });
    const activity2 = makeActivity(4);

    mockGetOverviewStats
      .mockResolvedValueOnce(stats1)
      .mockResolvedValueOnce(stats2);
    mockGetRecentActivity
      .mockResolvedValueOnce([])
      .mockResolvedValueOnce(activity2);

    const { result } = renderHook(() => useSystemStats());

    await waitFor(() => expect(result.current.initialized).toBe(true));
    expect(result.current.stats?.nodes.total).toBe(1);

    await act(async () => {
      await result.current.refresh();
    });

    expect(result.current.stats?.nodes.total).toBe(5);
    expect(result.current.recentActivity).toEqual(activity2);
    expect(mockGetOverviewStats).toHaveBeenCalledTimes(2);
    expect(mockGetRecentActivity).toHaveBeenCalledTimes(2);
  });

  it('refreshStats() updates only stats, not activity', async () => {
    const initialActivity = makeActivity(2);
    const updatedStats = makeStats({ nodes: { total: 9, enabled: 9, disabled: 0 } });

    mockGetOverviewStats.mockResolvedValueOnce(makeStats()).mockResolvedValueOnce(updatedStats);
    mockGetRecentActivity.mockResolvedValue(initialActivity);

    const { result } = renderHook(() => useSystemStats());
    await waitFor(() => expect(result.current.initialized).toBe(true));

    const activityBefore = result.current.recentActivity;

    await act(async () => {
      await result.current.refreshStats();
    });

    expect(result.current.stats?.nodes.total).toBe(9);
    // Activity is unchanged — refreshStats does not call getRecentActivity again
    expect(mockGetRecentActivity).toHaveBeenCalledTimes(1);
    expect(result.current.recentActivity).toBe(activityBefore);
  });

  it('refreshActivity() updates only activity, not stats', async () => {
    const updatedActivity = makeActivity(5);

    mockGetOverviewStats.mockResolvedValue(makeStats());
    mockGetRecentActivity
      .mockResolvedValueOnce(makeActivity(1))
      .mockResolvedValueOnce(updatedActivity);

    const { result } = renderHook(() => useSystemStats());
    await waitFor(() => expect(result.current.initialized).toBe(true));

    const statsBefore = result.current.stats;

    await act(async () => {
      await result.current.refreshActivity();
    });

    expect(result.current.recentActivity).toEqual(updatedActivity);
    // Stats unchanged — refreshActivity does not call getOverviewStats again
    expect(mockGetOverviewStats).toHaveBeenCalledTimes(1);
    expect(result.current.stats).toBe(statsBefore);
  });

  // ---------------------------------------------------------------------------
  // activityLimit option
  // ---------------------------------------------------------------------------

  it('passes activityLimit option to getRecentActivity', async () => {
    mockGetOverviewStats.mockResolvedValue(makeStats());
    mockGetRecentActivity.mockResolvedValue([]);

    const { result } = renderHook(() => useSystemStats({ activityLimit: 5 }));

    await waitFor(() => expect(result.current.initialized).toBe(true));

    expect(mockGetRecentActivity).toHaveBeenCalledWith(5);
  });

  it('defaults activityLimit to 10', async () => {
    mockGetOverviewStats.mockResolvedValue(makeStats());
    mockGetRecentActivity.mockResolvedValue([]);

    const { result } = renderHook(() => useSystemStats());

    await waitFor(() => expect(result.current.initialized).toBe(true));

    expect(mockGetRecentActivity).toHaveBeenCalledWith(10);
  });

  // ---------------------------------------------------------------------------
  // Polling
  // ---------------------------------------------------------------------------

  it('polls refresh every pollInterval ms when pollInterval > 0', async () => {
    mockGetOverviewStats.mockResolvedValue(makeStats());
    mockGetRecentActivity.mockResolvedValue([]);

    const { result } = renderHook(() => useSystemStats({ pollInterval: 30000 }));

    await waitFor(() => expect(result.current.initialized).toBe(true));

    const callCountAfterMount = mockGetOverviewStats.mock.calls.length;

    // Advance time by exactly one interval
    await act(async () => {
      jest.advanceTimersByTime(30000);
    });

    await waitFor(() =>
      expect(mockGetOverviewStats.mock.calls.length).toBeGreaterThan(callCountAfterMount)
    );
  });

  it('does NOT poll when pollInterval is 0 (default)', async () => {
    mockGetOverviewStats.mockResolvedValue(makeStats());
    mockGetRecentActivity.mockResolvedValue([]);

    renderHook(() => useSystemStats({ pollInterval: 0 }));

    await act(async () => {
      jest.advanceTimersByTime(60000);
    });

    // Only the initial fetch — no polling
    expect(mockGetOverviewStats).toHaveBeenCalledTimes(1);
  });

  it('clears the polling interval on unmount', async () => {
    mockGetOverviewStats.mockResolvedValue(makeStats());
    mockGetRecentActivity.mockResolvedValue([]);

    const { result, unmount } = renderHook(() =>
      useSystemStats({ pollInterval: 5000 })
    );

    await waitFor(() => expect(result.current.initialized).toBe(true));

    const callsBeforeUnmount = mockGetOverviewStats.mock.calls.length;

    unmount();

    // After unmount, advancing time should NOT trigger additional calls
    await act(async () => {
      jest.advanceTimersByTime(30000);
    });

    expect(mockGetOverviewStats.mock.calls.length).toBe(callsBeforeUnmount);
  });
});

// =============================================================================
// useSystemResourceCounts
// =============================================================================

describe('useSystemResourceCounts', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetRecentActivity.mockResolvedValue([]);
  });

  it('returns zero counts when stats is null (loading state)', () => {
    mockGetOverviewStats.mockReturnValue(new Promise(() => {}));

    const { result } = renderHook(() => useSystemResourceCounts());

    expect(result.current.nodes).toBe(0);
    expect(result.current.instances).toBe(0);
    expect(result.current.templates).toBe(0);
    expect(result.current.providers).toBe(0);
    expect(result.current.modules).toBe(0);
    expect(result.current.operations).toBe(0);
    expect(result.current.activeOperations).toBe(0);
    expect(result.current.loading).toBe(true);
  });

  it('returns correct counts from loaded stats', async () => {
    const stats = makeStats();
    mockGetOverviewStats.mockResolvedValue(stats);

    const { result } = renderHook(() => useSystemResourceCounts());

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.nodes).toBe(stats.nodes.total);
    expect(result.current.instances).toBe(stats.instances.total);
    expect(result.current.templates).toBe(stats.templates.total);
    expect(result.current.providers).toBe(stats.providers.total);
    expect(result.current.modules).toBe(stats.modules.total);
    expect(result.current.operations).toBe(stats.operations.total);
    // activeOperations = pending + running
    expect(result.current.activeOperations).toBe(
      stats.operations.pending + stats.operations.running
    );
  });

  it('exposes error and refresh from the underlying hook', async () => {
    const boom = new Error('stats failed');
    mockGetOverviewStats.mockRejectedValue(boom);

    const { result } = renderHook(() => useSystemResourceCounts());

    await waitFor(() => expect(result.current.error).toEqual(boom));
    expect(typeof result.current.refresh).toBe('function');
  });
});

// =============================================================================
// emptyStats constant
// =============================================================================

describe('emptyStats', () => {
  it('has zero totals for all top-level stat categories', () => {
    expect(emptyStats.nodes.total).toBe(0);
    expect(emptyStats.instances.total).toBe(0);
    expect(emptyStats.templates.total).toBe(0);
    expect(emptyStats.platforms.total).toBe(0);
    expect(emptyStats.providers.total).toBe(0);
    expect(emptyStats.regions.total).toBe(0);
    expect(emptyStats.modules.total).toBe(0);
    expect(emptyStats.operations.total).toBe(0);
    expect(emptyStats.puppet.modules).toBe(0);
    expect(emptyStats.volumes.total).toBe(0);
    expect(emptyStats.networks.total).toBe(0);
  });

  it('has empty providers.types array', () => {
    expect(emptyStats.providers.types).toEqual([]);
  });

  it('has zeroed module variety breakdown', () => {
    expect(emptyStats.modules.by_variety).toEqual({
      config: 0,
      instance: 0,
      subscription: 0,
    });
  });
});
