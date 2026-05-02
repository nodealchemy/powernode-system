import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { Dispatch, SetStateAction } from 'react';
import { useNotifications } from '@/shared/hooks/useNotifications';
import type { PaginationMeta } from '@system/features/system/services/api/types';

/**
 * Identity contract every list-resource must satisfy. UUIDv7 ids are
 * standard across the System extension, so id is always a string.
 */
export interface Identifiable {
  id: string;
}

// ============================================================
// Client-side resource list (full collection in memory + client filter)
// ============================================================

export interface UseResourceListOptions<T extends Identifiable, F = Record<string, unknown>> {
  /** How to load the full list. Called on mount and on `refresh()`. */
  fetcher: () => Promise<T[]>;
  /** Initial filter state. */
  initialFilters: F;
  /** Returns true if `item` should be included given current filters. */
  filterFn: (item: T, filters: F) => boolean;
  /** Notification message shown if `fetcher` rejects. */
  errorMessage?: string;
  /** Auto-load on mount. Default true. Set false if WebSocket pushes the
   *  initial state and you don't need the REST round-trip. */
  autoLoad?: boolean;
}

export interface UseResourceListReturn<T extends Identifiable, F> {
  items: T[];
  filteredItems: T[];
  loading: boolean;
  refreshing: boolean;
  filters: F;
  setFilters: Dispatch<SetStateAction<F>>;
  refresh: () => void;
  upsertItem: (item: T) => void;
  removeItem: (id: string) => void;
  patchItem: (id: string, patch: Partial<T>) => void;
  setItems: Dispatch<SetStateAction<T[]>>;
  dropdownOpen: string | null;
  setDropdownOpen: Dispatch<SetStateAction<string | null>>;
}

/**
 * Shared list-state machinery for System resource pages whose collections
 * fit comfortably in memory (the catalog endpoints — providers, scripts,
 * platforms, architectures, modules, puppet modules, operations).
 *
 * For paginated lists where the server slices the data per page, use
 * `usePaginatedResourceList` instead.
 *
 * @example
 * ```tsx
 * const list = useResourceList<SystemTask, OperationFilters>({
 *   fetcher: () => systemApi.getTasks().then(d => d.tasks),
 *   initialFilters: { search: '', status: 'all' },
 *   filterFn: (op, f) => matchesSearchAndStatus(op, f),
 *   errorMessage: 'Failed to load operations',
 * });
 *
 * useSystemWebSocket({
 *   onOperationUpdate: (op) => list.upsertItem(op as SystemTask),
 *   onOperationProgress: (p) => list.patchItem(p.operation_id, {
 *     status: p.status, progress: p.progress
 *   }),
 * });
 * ```
 */
export function useResourceList<T extends Identifiable, F = Record<string, unknown>>(
  options: UseResourceListOptions<T, F>
): UseResourceListReturn<T, F> {
  const { fetcher, initialFilters, filterFn, errorMessage = 'Failed to load list', autoLoad = true } = options;

  const { addNotification } = useNotifications();
  const [items, setItems] = useState<T[]>([]);
  const [loading, setLoading] = useState<boolean>(autoLoad);
  const [refreshing, setRefreshing] = useState<boolean>(false);
  const [filters, setFilters] = useState<F>(initialFilters);
  const [dropdownOpen, setDropdownOpen] = useState<string | null>(null);

  // Stable refs for fetcher/filterFn so we don't refetch on every parent
  // render that creates a new closure.
  const fetcherRef = useRef(fetcher);
  const filterFnRef = useRef(filterFn);
  useEffect(() => { fetcherRef.current = fetcher; }, [fetcher]);
  useEffect(() => { filterFnRef.current = filterFn; }, [filterFn]);

  const fetchOnce = useCallback(async () => {
    try {
      const data = await fetcherRef.current();
      setItems(data);
    } catch {
      addNotification({ type: 'error', message: errorMessage });
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [addNotification, errorMessage]);

  useEffect(() => {
    if (autoLoad) {
      fetchOnce();
    }
  }, [autoLoad, fetchOnce]);

  const refresh = useCallback(() => {
    setRefreshing(true);
    fetchOnce();
  }, [fetchOnce]);

  // Click-outside-row-dropdown — every list does this exact effect.
  useEffect(() => {
    if (dropdownOpen === null) return;
    const close = () => setDropdownOpen(null);
    document.addEventListener('click', close);
    return () => document.removeEventListener('click', close);
  }, [dropdownOpen]);

  const upsertItem = useCallback((item: T) => {
    setItems(prev => {
      const idx = prev.findIndex(p => p.id === item.id);
      if (idx === -1) return [...prev, item];
      const next = prev.slice();
      next[idx] = { ...prev[idx], ...item };
      return next;
    });
  }, []);

  const removeItem = useCallback((id: string) => {
    setItems(prev => prev.filter(p => p.id !== id));
  }, []);

  const patchItem = useCallback((id: string, patch: Partial<T>) => {
    setItems(prev => {
      const idx = prev.findIndex(p => p.id === id);
      if (idx === -1) return prev;
      const next = prev.slice();
      next[idx] = { ...prev[idx], ...patch };
      return next;
    });
  }, []);

  const filteredItems = useMemo(
    () => items.filter(item => filterFnRef.current(item, filters)),
    [items, filters]
  );

  return {
    items,
    filteredItems,
    loading,
    refreshing,
    filters,
    setFilters,
    refresh,
    upsertItem,
    removeItem,
    patchItem,
    setItems,
    dropdownOpen,
    setDropdownOpen,
  };
}

// ============================================================
// Server-paginated resource list
// ============================================================

export interface PaginatedFetcherInput<F> {
  page: number;
  per_page: number;
  filters: F;
}

export interface PaginatedFetcherOutput<T> {
  items: T[];
  meta: PaginationMeta;
}

export interface UsePaginatedResourceListOptions<T extends Identifiable, F = Record<string, unknown>> {
  /** How to load a single page. Called on mount, on filter change, on
   *  page change, and on `refresh()`. */
  fetcher: (input: PaginatedFetcherInput<F>) => Promise<PaginatedFetcherOutput<T>>;
  initialFilters: F;
  /** Initial page number (1-based). Default 1. */
  initialPage?: number;
  /** Server page size hint. Default 20. */
  perPage?: number;
  /** Notification message shown if `fetcher` rejects. */
  errorMessage?: string;
  /** Optional client-side filter applied AFTER the server-side fetch.
   *  Useful when some filters are post-fetch (a free-text search, say) but
   *  others are server-side (status, region). Default: no extra filtering. */
  clientFilterFn?: (item: T, filters: F) => boolean;
  /** Refetch from server when filters change. Default true. */
  refetchOnFilterChange?: boolean;
  /**
   * Returns a stable key for the *server-bound* subset of filters. The hook
   * watches changes to this key and refetches only when it changes — so a
   * client-side filter (e.g. a free-text search) can update without firing
   * an HTTP round-trip on every keystroke.
   *
   * Default `JSON.stringify(filters)` watches everything (preserves current
   * behavior). Override with e.g. `(f) => JSON.stringify({ enabled: f.enabled })`
   * to refetch only on `enabled` changes.
   */
  serverFilterKey?: (filters: F) => string;
}

export interface UsePaginatedResourceListReturn<T extends Identifiable, F>
  extends UseResourceListReturn<T, F> {
  page: number;
  setPage: (page: number) => void;
  pagination: PaginationMeta;
  perPage: number;
  setPerPage: (perPage: number) => void;
}

/**
 * Shared list-state machinery for System resource pages whose backend
 * paginates server-side (NodeList, TemplateList, NetworkList, VolumeList).
 *
 * The fetcher is called with `{ page, per_page, filters }` and returns
 * `{ items, meta }`. The hook owns page + per_page state and refetches
 * automatically when filters change.
 *
 * @example
 * ```tsx
 * const list = usePaginatedResourceList<SystemNode, NodeFilters>({
 *   fetcher: ({ page, per_page, filters }) =>
 *     systemApi.getNodes({ page, per_page, enabled: filters.enabled === 'all' ? undefined
 *                                                  : filters.enabled === 'enabled' })
 *       .then(d => ({ items: d.nodes, meta: d.meta })),
 *   initialFilters: { search: '', enabled: 'all' },
 *   clientFilterFn: (n, f) => f.search ? n.name.includes(f.search) : true,
 *   errorMessage: 'Failed to load nodes',
 * });
 * ```
 */
export function usePaginatedResourceList<T extends Identifiable, F = Record<string, unknown>>(
  options: UsePaginatedResourceListOptions<T, F>
): UsePaginatedResourceListReturn<T, F> {
  const {
    fetcher,
    initialFilters,
    initialPage = 1,
    perPage: initialPerPage = 20,
    errorMessage = 'Failed to load list',
    clientFilterFn,
    refetchOnFilterChange = true,
    serverFilterKey,
  } = options;

  const { addNotification } = useNotifications();
  const [items, setItems] = useState<T[]>([]);
  const [loading, setLoading] = useState<boolean>(true);
  const [refreshing, setRefreshing] = useState<boolean>(false);
  const [filters, setFiltersState] = useState<F>(initialFilters);
  const [page, setPageState] = useState<number>(initialPage);
  const [perPage, setPerPageState] = useState<number>(initialPerPage);
  const [pagination, setPagination] = useState<PaginationMeta>({
    current_page: initialPage,
    per_page: initialPerPage,
    total_count: 0,
    total_pages: 1,
    next_page: null,
    prev_page: null,
  });
  const [dropdownOpen, setDropdownOpen] = useState<string | null>(null);

  const fetcherRef = useRef(fetcher);
  const clientFilterRef = useRef(clientFilterFn);
  useEffect(() => { fetcherRef.current = fetcher; }, [fetcher]);
  useEffect(() => { clientFilterRef.current = clientFilterFn; }, [clientFilterFn]);

  const doFetch = useCallback(async (
    pageArg: number,
    filtersArg: F,
    perPageArg: number
  ) => {
    try {
      const result = await fetcherRef.current({ page: pageArg, per_page: perPageArg, filters: filtersArg });
      setItems(result.items);
      setPagination(result.meta);
    } catch {
      addNotification({ type: 'error', message: errorMessage });
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [addNotification, errorMessage]);

  // Initial load + page/per_page changes always refetch.
  useEffect(() => {
    setLoading(true);
    doFetch(page, filters, perPage);
  // We deliberately don't include `filters` here — those have their own
  // refetch effect below, gated by `refetchOnFilterChange`.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page, perPage, doFetch]);

  // Filter changes: only refetch when explicitly enabled, AND only when
  // the server-bound filter subset (per `serverFilterKey`) has changed.
  // This prevents per-keystroke refetches on client-only filters like
  // free-text search.
  const serverKey = useMemo(
    () => (serverFilterKey ? serverFilterKey(filters) : JSON.stringify(filters)),
    [filters, serverFilterKey]
  );

  useEffect(() => {
    if (!refetchOnFilterChange) return;
    setLoading(true);
    // Reset to first page when server-bound filters change — otherwise you
    // can land on a page number that doesn't exist for the new filter set.
    setPageState(1);
    doFetch(1, filters, perPage);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverKey, refetchOnFilterChange]);

  const refresh = useCallback(() => {
    setRefreshing(true);
    doFetch(page, filters, perPage);
  }, [doFetch, page, filters, perPage]);

  const setPage = useCallback((next: number) => {
    setPageState(Math.max(1, next));
  }, []);

  const setPerPage = useCallback((next: number) => {
    setPerPageState(Math.max(1, next));
    setPageState(1);
  }, []);

  const setFilters: Dispatch<SetStateAction<F>> = useCallback((value) => {
    setFiltersState(value as F);
  }, []);

  // Click-outside-row-dropdown.
  useEffect(() => {
    if (dropdownOpen === null) return;
    const close = () => setDropdownOpen(null);
    document.addEventListener('click', close);
    return () => document.removeEventListener('click', close);
  }, [dropdownOpen]);

  const upsertItem = useCallback((item: T) => {
    setItems(prev => {
      const idx = prev.findIndex(p => p.id === item.id);
      if (idx === -1) return [...prev, item];
      const next = prev.slice();
      next[idx] = { ...prev[idx], ...item };
      return next;
    });
  }, []);

  const removeItem = useCallback((id: string) => {
    setItems(prev => prev.filter(p => p.id !== id));
  }, []);

  const patchItem = useCallback((id: string, patch: Partial<T>) => {
    setItems(prev => {
      const idx = prev.findIndex(p => p.id === id);
      if (idx === -1) return prev;
      const next = prev.slice();
      next[idx] = { ...prev[idx], ...patch };
      return next;
    });
  }, []);

  const filteredItems = useMemo(() => {
    if (!clientFilterRef.current) return items;
    return items.filter(item => clientFilterRef.current!(item, filters));
  }, [items, filters]);

  return {
    items,
    filteredItems,
    loading,
    refreshing,
    filters,
    setFilters,
    refresh,
    upsertItem,
    removeItem,
    patchItem,
    setItems,
    dropdownOpen,
    setDropdownOpen,
    page,
    setPage,
    pagination,
    perPage,
    setPerPage,
  };
}

// ============================================================
// Infinite-scroll resource list (server-paginated, accumulates pages)
// ============================================================

export interface UseInfiniteResourceListOptions<T extends Identifiable, F = Record<string, unknown>> {
  /** How to load a single page. Called for page 1 on mount and on each
   *  `loadMore()`. */
  fetcher: (input: PaginatedFetcherInput<F>) => Promise<PaginatedFetcherOutput<T>>;
  initialFilters: F;
  /** Server page size hint. Default 20. */
  perPage?: number;
  /** Notification message shown if `fetcher` rejects. */
  errorMessage?: string;
  /** Optional client-side filter applied AFTER pages are fetched. */
  clientFilterFn?: (item: T, filters: F) => boolean;
  /**
   * Returns a stable key for the *server-bound* subset of filters. When
   * this key changes, the accumulator is reset to page 1 and a fresh
   * fetch begins. Default `JSON.stringify(filters)` (any change resets).
   */
  serverFilterKey?: (filters: F) => string;
}

export interface UseInfiniteResourceListReturn<T extends Identifiable, F>
  extends Omit<UseResourceListReturn<T, F>, 'loading' | 'refresh' | 'refreshing'> {
  /** True for the first page load (list is empty). Different from
   *  `loadingMore`, which is true while paging deeper. */
  loading: boolean;
  /** True while loading the next page (list stays visible). */
  loadingMore: boolean;
  /** Whether more pages exist. False once `meta.next_page` is null. */
  hasMore: boolean;
  /** Total count from the most recent meta block. */
  totalCount: number;
  /** Trigger the next page fetch. No-op when `hasMore === false` or a
   *  fetch is already in flight. */
  loadMore: () => void;
  /** Reset to page 1 and refetch. */
  refresh: () => void;
  refreshing: boolean;
}

/**
 * Server-paginated list with infinite-scroll semantics: each call to
 * `loadMore` fetches the next page and *appends* to the existing items.
 * Filter changes (via `serverFilterKey`) reset the accumulator and start
 * over from page 1.
 *
 * Pair with `<InfiniteScrollSentinel>` rendered inside the list container.
 *
 * @example
 * ```tsx
 * const list = useInfiniteResourceList<SystemNode, NodeFilters>({
 *   fetcher: ({ page, per_page, filters }) =>
 *     systemApi.getNodes({ page, per_page,
 *       enabled: filters.enabled === 'all' ? undefined : filters.enabled === 'enabled' })
 *       .then(d => ({ items: d.nodes, meta: d.meta })),
 *   initialFilters: { search: '', enabled: 'all' },
 *   serverFilterKey: f => JSON.stringify({ enabled: f.enabled }),
 *   clientFilterFn: (n, f) => f.search ? n.name.includes(f.search) : true,
 * });
 *
 * <InfiniteScrollSentinel
 *   onIntersect={list.loadMore}
 *   enabled={list.hasMore && !list.loadingMore}
 * />
 * ```
 */
export function useInfiniteResourceList<T extends Identifiable, F = Record<string, unknown>>(
  options: UseInfiniteResourceListOptions<T, F>
): UseInfiniteResourceListReturn<T, F> {
  const {
    fetcher,
    initialFilters,
    perPage: initialPerPage = 20,
    errorMessage = 'Failed to load list',
    clientFilterFn,
    serverFilterKey,
  } = options;

  const { addNotification } = useNotifications();
  const [items, setItems] = useState<T[]>([]);
  const [loading, setLoading] = useState<boolean>(true);
  const [loadingMore, setLoadingMore] = useState<boolean>(false);
  const [refreshing, setRefreshing] = useState<boolean>(false);
  const [filters, setFiltersState] = useState<F>(initialFilters);
  const [hasMore, setHasMore] = useState<boolean>(true);
  const [totalCount, setTotalCount] = useState<number>(0);
  const [page, setPage] = useState<number>(1);
  const [dropdownOpen, setDropdownOpen] = useState<string | null>(null);

  const fetcherRef = useRef(fetcher);
  const clientFilterRef = useRef(clientFilterFn);
  useEffect(() => { fetcherRef.current = fetcher; }, [fetcher]);
  useEffect(() => { clientFilterRef.current = clientFilterFn; }, [clientFilterFn]);

  // Track the in-flight fetch's filter generation so a filter change
  // racing with a page fetch can't append stale data into the new
  // accumulator.
  const generationRef = useRef<number>(0);

  const fetchPage = useCallback(async (
    pageArg: number,
    filtersArg: F,
    perPageArg: number,
    mode: 'replace' | 'append',
    generation: number
  ) => {
    try {
      const result = await fetcherRef.current({ page: pageArg, per_page: perPageArg, filters: filtersArg });
      // If a newer filter generation has started while we were waiting,
      // discard this result.
      if (generation !== generationRef.current) return;

      setItems(prev => mode === 'replace' ? result.items : [...prev, ...result.items]);
      setTotalCount(result.meta.total_count);
      setHasMore(result.meta.next_page !== null);
    } catch {
      if (generation !== generationRef.current) return;
      addNotification({ type: 'error', message: errorMessage });
    } finally {
      if (generation === generationRef.current) {
        setLoading(false);
        setLoadingMore(false);
        setRefreshing(false);
      }
    }
  }, [addNotification, errorMessage]);

  // Initial load + filter-change reset.
  const serverKey = useMemo(
    () => (serverFilterKey ? serverFilterKey(filters) : JSON.stringify(filters)),
    [filters, serverFilterKey]
  );

  useEffect(() => {
    generationRef.current += 1;
    const gen = generationRef.current;
    setLoading(true);
    setItems([]);
    setPage(1);
    setHasMore(true);
    fetchPage(1, filters, initialPerPage, 'replace', gen);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverKey]);

  const loadMore = useCallback(() => {
    if (!hasMore || loadingMore || loading) return;
    setLoadingMore(true);
    const nextPage = page + 1;
    setPage(nextPage);
    fetchPage(nextPage, filters, initialPerPage, 'append', generationRef.current);
  }, [hasMore, loadingMore, loading, page, filters, initialPerPage, fetchPage]);

  const refresh = useCallback(() => {
    generationRef.current += 1;
    const gen = generationRef.current;
    setRefreshing(true);
    setItems([]);
    setPage(1);
    setHasMore(true);
    fetchPage(1, filters, initialPerPage, 'replace', gen);
  }, [filters, initialPerPage, fetchPage]);

  const setFilters: Dispatch<SetStateAction<F>> = useCallback((value) => {
    setFiltersState(value as F);
  }, []);

  // Click-outside-row-dropdown.
  useEffect(() => {
    if (dropdownOpen === null) return;
    const close = () => setDropdownOpen(null);
    document.addEventListener('click', close);
    return () => document.removeEventListener('click', close);
  }, [dropdownOpen]);

  const upsertItem = useCallback((item: T) => {
    setItems(prev => {
      const idx = prev.findIndex(p => p.id === item.id);
      if (idx === -1) return [...prev, item];
      const next = prev.slice();
      next[idx] = { ...prev[idx], ...item };
      return next;
    });
  }, []);

  const removeItem = useCallback((id: string) => {
    setItems(prev => prev.filter(p => p.id !== id));
  }, []);

  const patchItem = useCallback((id: string, patch: Partial<T>) => {
    setItems(prev => {
      const idx = prev.findIndex(p => p.id === id);
      if (idx === -1) return prev;
      const next = prev.slice();
      next[idx] = { ...prev[idx], ...patch };
      return next;
    });
  }, []);

  const filteredItems = useMemo(() => {
    if (!clientFilterRef.current) return items;
    return items.filter(item => clientFilterRef.current!(item, filters));
  }, [items, filters]);

  return {
    items,
    filteredItems,
    loading,
    loadingMore,
    refreshing,
    filters,
    setFilters,
    refresh,
    loadMore,
    hasMore,
    totalCount,
    upsertItem,
    removeItem,
    patchItem,
    setItems,
    dropdownOpen,
    setDropdownOpen,
  };
}

export default useResourceList;
