import { act, renderHook, waitFor } from '@testing-library/react';
import {
  useResourceList,
  usePaginatedResourceList,
  useInfiniteResourceList,
} from './useResourceList';
import type {
  Identifiable,
  PaginatedFetcherOutput,
} from './useResourceList';
import type { PaginationMeta } from '@system/features/system/services/api/types';

// =============================================================================
// Mocks
// =============================================================================

const mockAddNotification = jest.fn();

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// =============================================================================
// Fixtures
// =============================================================================

interface TestItem extends Identifiable {
  id: string;
  name: string;
  status: string;
}

interface TestFilters {
  search: string;
  status: string;
}

const ITEM_A: TestItem = { id: 'id-a', name: 'Alpha', status: 'active' };
const ITEM_B: TestItem = { id: 'id-b', name: 'Beta', status: 'inactive' };
const ITEM_C: TestItem = { id: 'id-c', name: 'Gamma', status: 'active' };

const DEFAULT_FILTERS: TestFilters = { search: '', status: 'all' };

function makeMeta(overrides: Partial<PaginationMeta> = {}): PaginationMeta {
  return {
    current_page: 1,
    per_page: 20,
    total_count: 0,
    total_pages: 1,
    next_page: null,
    prev_page: null,
    ...overrides,
  };
}

function filterFn(item: TestItem, filters: TestFilters): boolean {
  const matchSearch = filters.search === '' || item.name.toLowerCase().includes(filters.search.toLowerCase());
  const matchStatus = filters.status === 'all' || item.status === filters.status;
  return matchSearch && matchStatus;
}

// =============================================================================
// Structural-failure guard helpers
// =============================================================================
//
// Axios-shaped rejection: `err.response.status`. `getErrorStatus` in the
// hook module also accepts a bare `err.status`, but axios (what the real
// apiClient throws) always nests it under `.response`, so that's what these
// fixtures model.
function httpError(status: number, message = `HTTP ${status}`): Error & { response: { status: number } } {
  return Object.assign(new Error(message), { response: { status } });
}

// Fake timers only fake Date.now()/setTimeout — native Promise microtasks
// still flush on their own. The guard logic never uses setTimeout (it just
// compares Date.now() to a stored deadline), so a few microtask ticks after
// each trigger is enough to let a fetch's single `await` settle.
async function flushMicrotasks(times = 3): Promise<void> {
  // eslint-disable-next-line no-await-in-loop
  for (let i = 0; i < times; i++) {
    // eslint-disable-next-line no-await-in-loop
    await act(async () => {
      await Promise.resolve();
    });
  }
}

// =============================================================================
// useResourceList tests
// =============================================================================

describe('useResourceList', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
  });

  it('starts with loading=true when autoLoad=true (default)', () => {
    const fetcher = jest.fn().mockReturnValue(new Promise(() => {}));
    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    expect(result.current.loading).toBe(true);
    expect(result.current.items).toEqual([]);
  });

  it('starts with loading=false when autoLoad=false', () => {
    const fetcher = jest.fn();
    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
        autoLoad: false,
      })
    );

    expect(result.current.loading).toBe(false);
    expect(fetcher).not.toHaveBeenCalled();
  });

  it('loads items on mount and sets loading=false after resolve', async () => {
    const fetcher = jest.fn().mockResolvedValue([ITEM_A, ITEM_B]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.items).toEqual([ITEM_A, ITEM_B]);
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it('shows an error notification when fetcher rejects', async () => {
    const fetcher = jest.fn().mockRejectedValue(new Error('network failure'));

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
        errorMessage: 'Custom error message',
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'error',
      message: 'Custom error message',
    });
    expect(result.current.items).toEqual([]);
  });

  it('uses the default error message when errorMessage is not provided', async () => {
    const fetcher = jest.fn().mockRejectedValue(new Error('fail'));

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'error',
      message: 'Failed to load list',
    });
  });

  it('filteredItems reflects current filter state', async () => {
    const fetcher = jest.fn().mockResolvedValue([ITEM_A, ITEM_B, ITEM_C]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.filteredItems).toHaveLength(3);

    act(() => {
      result.current.setFilters({ search: '', status: 'active' });
    });

    expect(result.current.filteredItems).toHaveLength(2);
    expect(result.current.filteredItems.map(i => i.id)).toEqual(['id-a', 'id-c']);
  });

  it('filters by search text', async () => {
    const fetcher = jest.fn().mockResolvedValue([ITEM_A, ITEM_B, ITEM_C]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.setFilters({ search: 'Bet', status: 'all' });
    });

    expect(result.current.filteredItems).toHaveLength(1);
    expect(result.current.filteredItems[0].id).toBe('id-b');
  });

  it('refresh() sets refreshing=true, refetches, then sets refreshing=false', async () => {
    const fetcher = jest.fn().mockResolvedValue([ITEM_A]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    const updatedItems = [ITEM_A, ITEM_B];
    fetcher.mockResolvedValue(updatedItems);

    act(() => {
      result.current.refresh();
    });

    expect(result.current.refreshing).toBe(true);

    await waitFor(() => expect(result.current.refreshing).toBe(false));
    expect(result.current.items).toEqual(updatedItems);
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it('upsertItem adds a new item when id is not found', async () => {
    const fetcher = jest.fn().mockResolvedValue([ITEM_A]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.upsertItem(ITEM_B);
    });

    expect(result.current.items).toHaveLength(2);
    expect(result.current.items[1]).toEqual(ITEM_B);
  });

  it('upsertItem merges fields when id already exists', async () => {
    const fetcher = jest.fn().mockResolvedValue([ITEM_A, ITEM_B]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.upsertItem({ id: 'id-a', name: 'Alpha Updated', status: 'inactive' });
    });

    const updated = result.current.items.find(i => i.id === 'id-a');
    expect(updated?.name).toBe('Alpha Updated');
    expect(updated?.status).toBe('inactive');
    expect(result.current.items).toHaveLength(2);
  });

  it('removeItem removes the item with the given id', async () => {
    const fetcher = jest.fn().mockResolvedValue([ITEM_A, ITEM_B]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.removeItem('id-a');
    });

    expect(result.current.items).toHaveLength(1);
    expect(result.current.items[0].id).toBe('id-b');
  });

  it('removeItem is a no-op when id is not found', async () => {
    const fetcher = jest.fn().mockResolvedValue([ITEM_A]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.removeItem('nonexistent-id');
    });

    expect(result.current.items).toHaveLength(1);
  });

  it('patchItem merges a partial update by id', async () => {
    const fetcher = jest.fn().mockResolvedValue([ITEM_A, ITEM_B]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.patchItem('id-a', { status: 'inactive' });
    });

    const patched = result.current.items.find(i => i.id === 'id-a');
    expect(patched?.name).toBe('Alpha');
    expect(patched?.status).toBe('inactive');
  });

  it('patchItem is a no-op when id is not found', async () => {
    const fetcher = jest.fn().mockResolvedValue([ITEM_A]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    const originalItems = result.current.items;

    act(() => {
      result.current.patchItem('no-such-id', { status: 'inactive' });
    });

    expect(result.current.items).toEqual(originalItems);
  });

  it('dropdownOpen starts null; setDropdownOpen changes it', async () => {
    const fetcher = jest.fn().mockResolvedValue([]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.dropdownOpen).toBeNull();

    act(() => {
      result.current.setDropdownOpen('id-a');
    });

    expect(result.current.dropdownOpen).toBe('id-a');
  });

  it('a document click closes the open dropdown', async () => {
    const fetcher = jest.fn().mockResolvedValue([]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.setDropdownOpen('id-a');
    });

    expect(result.current.dropdownOpen).toBe('id-a');

    act(() => {
      document.dispatchEvent(new MouseEvent('click'));
    });

    expect(result.current.dropdownOpen).toBeNull();
  });

  it('setItems replaces the items array directly', async () => {
    const fetcher = jest.fn().mockResolvedValue([ITEM_A]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.setItems([ITEM_B, ITEM_C]);
    });

    expect(result.current.items).toEqual([ITEM_B, ITEM_C]);
  });
});

// =============================================================================
// Structural-failure guard: 401/403 stops polling, retryable failures back
// off + trip a circuit breaker, and a transient failure still recovers.
//
// RED-FIRST ORACLE: the fetcher CALL COUNT, not rendered state. A test
// asserting only "shows an error toast" passes against the pre-fix code —
// the toast was never the defect, the unbounded retrying was.
// =============================================================================

describe('useResourceList — structural-failure guard', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('stops issuing requests after a persistent 403, even under a fixed-cadence external poller', async () => {
    const fetcher = jest.fn().mockRejectedValue(httpError(403));

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(result.current.blocked).toBe(true);
    expect(result.current.error).toEqual({ status: 403, message: 'Failed to load list' });
    // The toast still fires (operator visibility) — but it is not the fix.
    expect(mockAddNotification).toHaveBeenCalledWith({ type: 'error', message: 'Failed to load list' });

    // Simulate PackageRepositoriesTab's own `setInterval(() => list.refresh(), 5000)`
    // hammering refresh() repeatedly, exactly as it does while the tab stays open.
    for (let i = 0; i < 15; i++) {
      // eslint-disable-next-line no-await-in-loop
      act(() => { result.current.refresh(); });
      // eslint-disable-next-line no-await-in-loop
      await flushMicrotasks();
    }

    // THE ORACLE: call count never rises past the first attempt.
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it('a 401 also stops polling immediately (not just 403)', async () => {
    const fetcher = jest.fn().mockRejectedValue(httpError(401));

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.blocked).toBe(true);

    act(() => { result.current.refresh(); });
    await flushMicrotasks();
    act(() => { result.current.refresh(); });
    await flushMicrotasks();

    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it('retry() clears the 403 block and resumes fetching', async () => {
    const fetcher = jest.fn().mockRejectedValue(httpError(403));

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.blocked).toBe(true);
    expect(fetcher).toHaveBeenCalledTimes(1);

    // Blocked — hammering refresh() does nothing.
    act(() => { result.current.refresh(); });
    await flushMicrotasks();
    expect(fetcher).toHaveBeenCalledTimes(1);

    // Operator fixes the underlying issue (e.g. re-authenticates) and hits
    // the retry affordance the hook exposes.
    fetcher.mockResolvedValue([ITEM_A]);
    act(() => { result.current.retry(); });
    // `retry()` clears `blocked` synchronously (before the fetch resolves),
    // so wait on the fetch's own outcome rather than racing that flag.
    await waitFor(() => expect(result.current.items).toEqual([ITEM_A]));

    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(result.current.blocked).toBe(false);
    expect(result.current.error).toBeNull();
  });

  it('applies exponential backoff for retryable (500) failures and opens a circuit breaker after repeated failures', async () => {
    jest.useFakeTimers();
    const fetcher = jest.fn().mockRejectedValue(httpError(500));

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    // Initial mount fetch: failure #1. Backoff window opens (~5s), breaker
    // not yet open (threshold is 5).
    await flushMicrotasks();
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(result.current.blocked).toBe(false);

    // Hammering refresh() at 0 elapsed time (fixed cadence, no backoff
    // respected by a naive caller) must NOT call the fetcher again — still
    // inside the backoff window.
    act(() => { result.current.refresh(); });
    await flushMicrotasks();
    expect(fetcher).toHaveBeenCalledTimes(1);

    // Advance through 4 more backoff windows (5s, 10s, 20s, 40s — each
    // capped by the 5-minute ceiling) to reach the circuit-breaker
    // threshold of 5 consecutive failures.
    for (let i = 0; i < 4; i++) {
      // eslint-disable-next-line no-await-in-loop
      act(() => { jest.advanceTimersByTime(6 * 60 * 1000); }); // jump well past any backoff window
      // eslint-disable-next-line no-await-in-loop
      act(() => { result.current.refresh(); });
      // eslint-disable-next-line no-await-in-loop
      await flushMicrotasks();
    }

    // 5 consecutive failures reached -> circuit breaker open.
    expect(fetcher).toHaveBeenCalledTimes(5);
    expect(result.current.blocked).toBe(true);

    // Further hammering, even well past any backoff window, does nothing —
    // the breaker requires an explicit retry(), same as the 401/403 case.
    act(() => { jest.advanceTimersByTime(60 * 60 * 1000); });
    act(() => { result.current.refresh(); });
    await flushMicrotasks();
    expect(fetcher).toHaveBeenCalledTimes(5);
  });

  it('NEGATIVE CASE: a transient failure followed by success still recovers (backoff does not break legitimate polling)', async () => {
    jest.useFakeTimers();
    const fetcher = jest.fn()
      .mockRejectedValueOnce(httpError(503))
      .mockResolvedValue([ITEM_A]);

    const { result } = renderHook(() =>
      useResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        filterFn,
      })
    );

    // Mount fetch fails once (transient 503).
    await flushMicrotasks();
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(result.current.blocked).toBe(false);
    expect(result.current.items).toEqual([]);

    // A poll landing inside the backoff window is correctly suppressed.
    act(() => { result.current.refresh(); });
    await flushMicrotasks();
    expect(fetcher).toHaveBeenCalledTimes(1);

    // Once the backoff window elapses, the next legitimate poll succeeds —
    // fixing the flood must not have broken normal recovery.
    act(() => { jest.advanceTimersByTime(6000); });
    act(() => { result.current.refresh(); });
    await flushMicrotasks();

    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(result.current.items).toEqual([ITEM_A]);
    expect(result.current.blocked).toBe(false);
    expect(result.current.error).toBeNull();

    // And normal polling continues working afterwards with no lingering
    // backoff — the failure counter was reset by the successful fetch.
    act(() => { result.current.refresh(); });
    await flushMicrotasks();
    expect(fetcher).toHaveBeenCalledTimes(3);
  });
});

describe('usePaginatedResourceList — structural-failure guard', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('stops issuing requests after a persistent 403 and exposes blocked/error', async () => {
    const fetcher = jest.fn().mockRejectedValue(httpError(403));

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    const callsAfterMount = fetcher.mock.calls.length;
    expect(result.current.blocked).toBe(true);
    expect(result.current.error).toEqual({ status: 403, message: 'Failed to load list' });

    for (let i = 0; i < 10; i++) {
      // eslint-disable-next-line no-await-in-loop
      act(() => { result.current.refresh(); });
      // eslint-disable-next-line no-await-in-loop
      await flushMicrotasks();
    }

    expect(fetcher.mock.calls.length).toBe(callsAfterMount);
  });

  it('a transient failure followed by success still recovers', async () => {
    jest.useFakeTimers();
    const fetcher = jest.fn()
      .mockRejectedValueOnce(httpError(500))
      .mockResolvedValue({ items: [ITEM_A], meta: makeMeta({ total_count: 1 }) });

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        // Isolate the page/perPage mount effect from the filter-change
        // effect (which also fires on mount — see the "TWO effects on
        // mount" note on the existing initialPage/perPage test below) so
        // this test observes exactly one fetch attempt per trigger.
        refetchOnFilterChange: false,
      })
    );

    await flushMicrotasks();
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(result.current.blocked).toBe(false);

    act(() => { jest.advanceTimersByTime(6000); });
    act(() => { result.current.refresh(); });
    await flushMicrotasks();

    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(result.current.items).toEqual([ITEM_A]);
    expect(result.current.blocked).toBe(false);
    jest.useRealTimers();
  });
});

describe('useInfiniteResourceList — structural-failure guard', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('stops issuing requests after a persistent 403 and exposes blocked/error', async () => {
    const fetcher = jest.fn().mockRejectedValue(httpError(403));

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    const callsAfterMount = fetcher.mock.calls.length;
    expect(result.current.blocked).toBe(true);
    expect(result.current.error).toEqual({ status: 403, message: 'Failed to load list' });

    for (let i = 0; i < 10; i++) {
      // eslint-disable-next-line no-await-in-loop
      act(() => { result.current.refresh(); });
      // eslint-disable-next-line no-await-in-loop
      await flushMicrotasks();
    }

    expect(fetcher.mock.calls.length).toBe(callsAfterMount);
  });

  it('a transient failure followed by success still recovers', async () => {
    jest.useFakeTimers();
    const fetcher = jest.fn()
      .mockRejectedValueOnce(httpError(500))
      .mockResolvedValue({ items: [ITEM_A], meta: makeMeta({ total_count: 1, next_page: null }) });

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await flushMicrotasks();
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(result.current.blocked).toBe(false);

    act(() => { jest.advanceTimersByTime(6000); });
    act(() => { result.current.refresh(); });
    await flushMicrotasks();

    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(result.current.items).toEqual([ITEM_A]);
    expect(result.current.blocked).toBe(false);
    jest.useRealTimers();
  });
});

// =============================================================================
// usePaginatedResourceList tests
// =============================================================================

describe('usePaginatedResourceList', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
  });

  function makePaginatedFetcher(items: TestItem[], metaOverrides: Partial<PaginationMeta> = {}) {
    return jest.fn().mockResolvedValue({
      items,
      meta: makeMeta({ total_count: items.length, ...metaOverrides }),
    } as PaginatedFetcherOutput<TestItem>);
  }

  it('starts with loading=true on mount', () => {
    const fetcher = jest.fn().mockReturnValue(new Promise(() => {}));
    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    expect(result.current.loading).toBe(true);
  });

  it('loads first page on mount with default page=1 and perPage=20', async () => {
    const fetcher = makePaginatedFetcher([ITEM_A, ITEM_B]);

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.items).toEqual([ITEM_A, ITEM_B]);
    expect(fetcher).toHaveBeenCalledWith({ page: 1, per_page: 20, filters: DEFAULT_FILTERS });
  });

  it('updates pagination meta from the fetcher result', async () => {
    const fetcher = makePaginatedFetcher([ITEM_A], {
      total_count: 42,
      total_pages: 3,
      next_page: 2,
    });

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.pagination.total_count).toBe(42);
    expect(result.current.pagination.total_pages).toBe(3);
    expect(result.current.pagination.next_page).toBe(2);
  });

  it('shows error notification when fetcher rejects', async () => {
    const fetcher = jest.fn().mockRejectedValue(new Error('server error'));

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        errorMessage: 'Paginated load failed',
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'error',
      message: 'Paginated load failed',
    });
  });

  it('setPage triggers a new fetch with the updated page number', async () => {
    const fetcher = makePaginatedFetcher([ITEM_A]);

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.setPage(2);
    });

    await waitFor(() =>
      expect(fetcher).toHaveBeenCalledWith({ page: 2, per_page: 20, filters: DEFAULT_FILTERS })
    );
  });

  it('setPage enforces minimum page of 1', async () => {
    const fetcher = makePaginatedFetcher([]);

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.setPage(0);
    });

    expect(result.current.page).toBe(1);
  });

  it('setPerPage triggers a refetch from page 1 with the new per_page', async () => {
    const fetcher = makePaginatedFetcher([ITEM_A]);

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.setPerPage(50);
    });

    await waitFor(() =>
      expect(fetcher).toHaveBeenCalledWith({ page: 1, per_page: 50, filters: DEFAULT_FILTERS })
    );
    expect(result.current.page).toBe(1);
  });

  it('filter changes reset to page 1 and trigger a new server fetch', async () => {
    const fetcher = makePaginatedFetcher([ITEM_A]);

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.setFilters({ search: 'Alpha', status: 'all' });
    });

    await waitFor(() =>
      expect(fetcher).toHaveBeenCalledWith({
        page: 1,
        per_page: 20,
        filters: { search: 'Alpha', status: 'all' },
      })
    );
  });

  it('refetchOnFilterChange=false suppresses server refetch on filter change', async () => {
    const fetcher = makePaginatedFetcher([ITEM_A]);

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        refetchOnFilterChange: false,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    const callsBefore = fetcher.mock.calls.length;

    act(() => {
      result.current.setFilters({ search: 'Alpha', status: 'all' });
    });

    // Let any potential async side-effects settle
    await new Promise(resolve => setTimeout(resolve, 50));
    expect(fetcher.mock.calls.length).toBe(callsBefore);
  });

  it('serverFilterKey only triggers refetch when the server subset changes', async () => {
    const fetcher = makePaginatedFetcher([ITEM_A]);
    // serverFilterKey ignores search, only watches status
    const serverFilterKey = (f: TestFilters) => JSON.stringify({ status: f.status });

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        serverFilterKey,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    const callsBefore = fetcher.mock.calls.length;

    // Changing only search should NOT refetch
    act(() => {
      result.current.setFilters({ search: 'Alpha', status: 'all' });
    });
    await new Promise(resolve => setTimeout(resolve, 50));
    expect(fetcher.mock.calls.length).toBe(callsBefore);

    // Changing status SHOULD refetch
    act(() => {
      result.current.setFilters({ search: 'Alpha', status: 'active' });
    });
    await waitFor(() =>
      expect(fetcher).toHaveBeenCalledWith({
        page: 1,
        per_page: 20,
        filters: { search: 'Alpha', status: 'active' },
      })
    );
  });

  it('clientFilterFn applies post-fetch client-side filtering', async () => {
    const fetcher = makePaginatedFetcher([ITEM_A, ITEM_B, ITEM_C]);
    const clientFilterFn = (item: TestItem, filters: TestFilters) =>
      filters.search === '' || item.name.toLowerCase().includes(filters.search.toLowerCase());

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        clientFilterFn,
        refetchOnFilterChange: false,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.filteredItems).toHaveLength(3);

    act(() => {
      result.current.setFilters({ search: 'Alpha', status: 'all' });
    });

    expect(result.current.filteredItems).toHaveLength(1);
    expect(result.current.filteredItems[0].id).toBe('id-a');
  });

  it('refresh() refetches current page without resetting to page 1', async () => {
    const fetcher = makePaginatedFetcher([ITEM_A]);

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.setPage(3);
    });
    await waitFor(() => expect(fetcher).toHaveBeenCalledWith({ page: 3, per_page: 20, filters: DEFAULT_FILTERS }));

    fetcher.mockResolvedValue({ items: [ITEM_B], meta: makeMeta() });

    act(() => {
      result.current.refresh();
    });

    expect(result.current.refreshing).toBe(true);
    await waitFor(() => expect(result.current.refreshing).toBe(false));
    expect(result.current.items).toEqual([ITEM_B]);
    // refresh uses current page (3), not reset to 1
    expect(fetcher).toHaveBeenLastCalledWith({ page: 3, per_page: 20, filters: DEFAULT_FILTERS });
  });

  it('upsertItem, removeItem, and patchItem work without refetching', async () => {
    const fetcher = makePaginatedFetcher([ITEM_A, ITEM_B]);

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    const callsBefore = fetcher.mock.calls.length;

    act(() => { result.current.upsertItem(ITEM_C); });
    expect(result.current.items).toHaveLength(3);

    act(() => { result.current.removeItem('id-c'); });
    expect(result.current.items).toHaveLength(2);

    act(() => { result.current.patchItem('id-a', { status: 'inactive' }); });
    expect(result.current.items.find(i => i.id === 'id-a')?.status).toBe('inactive');

    expect(fetcher.mock.calls.length).toBe(callsBefore);
  });

  it('dropdownOpen tracks state and closes on document click', async () => {
    const fetcher = makePaginatedFetcher([]);

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => { result.current.setDropdownOpen('id-a'); });
    expect(result.current.dropdownOpen).toBe('id-a');

    act(() => { document.dispatchEvent(new MouseEvent('click')); });
    expect(result.current.dropdownOpen).toBeNull();
  });

  it('initialPage and perPage options are respected for the initial fetch', async () => {
    const fetcher = makePaginatedFetcher([ITEM_A]);

    const { result } = renderHook(() =>
      usePaginatedResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        initialPage: 3,
        perPage: 50,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    // The hook fires TWO effects on mount: the page/perPage effect (page=3)
    // AND the serverKey filter effect (which resets to page=1). Both happen
    // on initial render. The fetcher is called with page=3 from the first
    // effect, but the filter effect also fires and issues a fetch with page=1.
    expect(fetcher).toHaveBeenCalledWith({ page: 3, per_page: 50, filters: DEFAULT_FILTERS });
    expect(result.current.perPage).toBe(50);
    // After mount, the filter effect resets the page to 1
    expect(result.current.page).toBe(1);
  });
});

// =============================================================================
// useInfiniteResourceList tests
// =============================================================================

describe('useInfiniteResourceList', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
  });

  function makeInfiniteFetcher(pages: { items: TestItem[]; meta: Partial<PaginationMeta> }[]) {
    let callCount = 0;
    return jest.fn().mockImplementation(() => {
      const page = pages[callCount] ?? pages[pages.length - 1];
      callCount++;
      return Promise.resolve({
        items: page.items,
        meta: makeMeta(page.meta),
      });
    });
  }

  it('starts with loading=true and empty items', () => {
    const fetcher = jest.fn().mockReturnValue(new Promise(() => {}));
    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    expect(result.current.loading).toBe(true);
    expect(result.current.items).toEqual([]);
    expect(result.current.loadingMore).toBe(false);
  });

  it('loads the first page on mount', async () => {
    const fetcher = jest.fn().mockResolvedValue({
      items: [ITEM_A, ITEM_B],
      meta: makeMeta({ total_count: 2, next_page: null }),
    });

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.items).toEqual([ITEM_A, ITEM_B]);
    expect(result.current.hasMore).toBe(false);
    expect(result.current.totalCount).toBe(2);
    expect(fetcher).toHaveBeenCalledWith({ page: 1, per_page: 20, filters: DEFAULT_FILTERS });
  });

  it('hasMore is true when next_page is not null', async () => {
    const fetcher = jest.fn().mockResolvedValue({
      items: [ITEM_A],
      meta: makeMeta({ next_page: 2, total_count: 3 }),
    });

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.hasMore).toBe(true);
  });

  it('loadMore appends next page items when hasMore=true', async () => {
    const fetcher = makeInfiniteFetcher([
      { items: [ITEM_A], meta: { next_page: 2, total_count: 2 } },
      { items: [ITEM_B], meta: { next_page: null, total_count: 2 } },
    ]);

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.items).toHaveLength(1);

    act(() => {
      result.current.loadMore();
    });

    await waitFor(() => expect(result.current.loadingMore).toBe(false));

    expect(result.current.items).toHaveLength(2);
    expect(result.current.items[0]).toEqual(ITEM_A);
    expect(result.current.items[1]).toEqual(ITEM_B);
    expect(result.current.hasMore).toBe(false);
  });

  it('loadMore is a no-op when hasMore=false', async () => {
    const fetcher = jest.fn().mockResolvedValue({
      items: [ITEM_A],
      meta: makeMeta({ next_page: null }),
    });

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    const callsBefore = fetcher.mock.calls.length;

    act(() => { result.current.loadMore(); });

    await new Promise(resolve => setTimeout(resolve, 50));
    expect(fetcher.mock.calls.length).toBe(callsBefore);
  });

  it('loadMore is a no-op when loading=true (first load in flight)', () => {
    const fetcher = jest.fn().mockReturnValue(new Promise(() => {}));

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    expect(result.current.loading).toBe(true);

    act(() => { result.current.loadMore(); });

    // Only the initial call from the mount effect, no extra loadMore call
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it('shows error notification when fetcher rejects', async () => {
    const fetcher = jest.fn().mockRejectedValue(new Error('fail'));

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        errorMessage: 'Infinite load failed',
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'error',
      message: 'Infinite load failed',
    });
  });

  it('filter change resets items to page 1 and starts fresh', async () => {
    const fetcher = makeInfiniteFetcher([
      { items: [ITEM_A, ITEM_B], meta: { next_page: null, total_count: 2 } },
      { items: [ITEM_C], meta: { next_page: null, total_count: 1 } },
    ]);

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.items).toHaveLength(2);

    act(() => {
      result.current.setFilters({ search: 'Gamma', status: 'all' });
    });

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.items).toHaveLength(1);
    expect(result.current.items[0]).toEqual(ITEM_C);
  });

  it('serverFilterKey only resets on server-bound filter changes', async () => {
    const fetcher = jest.fn().mockResolvedValue({
      items: [ITEM_A],
      meta: makeMeta({ next_page: null }),
    });
    const serverFilterKey = (f: TestFilters) => JSON.stringify({ status: f.status });

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        serverFilterKey,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    const callsBefore = fetcher.mock.calls.length;

    // Changing only the client-side filter (search) should not trigger a refetch
    act(() => {
      result.current.setFilters({ search: 'Alpha', status: 'all' });
    });

    await new Promise(resolve => setTimeout(resolve, 50));
    expect(fetcher.mock.calls.length).toBe(callsBefore);

    // Changing the server-side filter (status) should trigger a refetch
    act(() => {
      result.current.setFilters({ search: 'Alpha', status: 'active' });
    });

    await waitFor(() => expect(fetcher.mock.calls.length).toBeGreaterThan(callsBefore));
  });

  it('clientFilterFn applies post-fetch filtering without refetching', async () => {
    const fetcher = jest.fn().mockResolvedValue({
      items: [ITEM_A, ITEM_B, ITEM_C],
      meta: makeMeta({ next_page: null }),
    });
    const clientFilterFn = (item: TestItem, f: TestFilters) =>
      f.search === '' || item.name.toLowerCase().includes(f.search.toLowerCase());

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        clientFilterFn,
        serverFilterKey: () => 'fixed',
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.filteredItems).toHaveLength(3);

    const callsBefore = fetcher.mock.calls.length;

    act(() => {
      result.current.setFilters({ search: 'Gamma', status: 'all' });
    });

    // Server should not be called again (serverFilterKey is fixed)
    await new Promise(resolve => setTimeout(resolve, 50));
    expect(fetcher.mock.calls.length).toBe(callsBefore);

    expect(result.current.filteredItems).toHaveLength(1);
    expect(result.current.filteredItems[0].id).toBe('id-c');
  });

  it('refresh() resets to page 1 and replaces all items', async () => {
    const fetcher = makeInfiniteFetcher([
      { items: [ITEM_A, ITEM_B], meta: { next_page: null, total_count: 2 } },
      { items: [ITEM_C], meta: { next_page: null, total_count: 1 } },
    ]);

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.items).toHaveLength(2);

    act(() => { result.current.refresh(); });

    expect(result.current.refreshing).toBe(true);
    await waitFor(() => expect(result.current.refreshing).toBe(false));

    expect(result.current.items).toHaveLength(1);
    expect(result.current.items[0]).toEqual(ITEM_C);
  });

  it('upsertItem, removeItem, patchItem mutate items without fetching', async () => {
    const fetcher = jest.fn().mockResolvedValue({
      items: [ITEM_A, ITEM_B],
      meta: makeMeta({ next_page: null }),
    });

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    const callsBefore = fetcher.mock.calls.length;

    act(() => { result.current.upsertItem(ITEM_C); });
    expect(result.current.items).toHaveLength(3);

    act(() => { result.current.patchItem('id-a', { status: 'inactive' }); });
    expect(result.current.items.find(i => i.id === 'id-a')?.status).toBe('inactive');

    act(() => { result.current.removeItem('id-c'); });
    expect(result.current.items).toHaveLength(2);

    expect(fetcher.mock.calls.length).toBe(callsBefore);
  });

  it('dropdownOpen state tracks and closes on document click', async () => {
    const fetcher = jest.fn().mockResolvedValue({
      items: [],
      meta: makeMeta(),
    });

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => { result.current.setDropdownOpen('id-a'); });
    expect(result.current.dropdownOpen).toBe('id-a');

    act(() => { document.dispatchEvent(new MouseEvent('click')); });
    expect(result.current.dropdownOpen).toBeNull();
  });

  it('stale fetch result is discarded after a filter reset (generation guard)', async () => {
    // Simulate a slow first fetch that resolves AFTER the filter change reset
    let resolveSlowFetch!: (val: PaginatedFetcherOutput<TestItem>) => void;
    const slowFetch = new Promise<PaginatedFetcherOutput<TestItem>>(res => {
      resolveSlowFetch = res;
    });

    const fastFetchResult: PaginatedFetcherOutput<TestItem> = {
      items: [ITEM_C],
      meta: makeMeta({ total_count: 1, next_page: null }),
    };

    let callCount = 0;
    const fetcher = jest.fn().mockImplementation(() => {
      callCount++;
      if (callCount === 1) return slowFetch;
      return Promise.resolve(fastFetchResult);
    });

    const serverFilterKey = (f: TestFilters) => JSON.stringify({ status: f.status });

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        serverFilterKey,
      })
    );

    // Let the first fetch be dispatched but not resolved yet
    await new Promise(resolve => setTimeout(resolve, 10));
    expect(result.current.loading).toBe(true);

    // Change a server-bound filter — increments generation, dispatches second fetch
    act(() => {
      result.current.setFilters({ search: '', status: 'active' });
    });

    // Let the second (fast) fetch resolve
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.items).toEqual([ITEM_C]);

    // Now resolve the stale first fetch — it should be discarded
    act(() => {
      resolveSlowFetch({
        items: [ITEM_A, ITEM_B],
        meta: makeMeta({ total_count: 2, next_page: null }),
      });
    });

    await new Promise(resolve => setTimeout(resolve, 50));
    // Items should still be from the second (non-stale) fetch
    expect(result.current.items).toEqual([ITEM_C]);
  });

  it('perPage option sets the page size hint passed to fetcher', async () => {
    const fetcher = jest.fn().mockResolvedValue({
      items: [],
      meta: makeMeta(),
    });

    const { result } = renderHook(() =>
      useInfiniteResourceList<TestItem, TestFilters>({
        fetcher,
        initialFilters: DEFAULT_FILTERS,
        perPage: 10,
      })
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(fetcher).toHaveBeenCalledWith({ page: 1, per_page: 10, filters: DEFAULT_FILTERS });
  });
});
