import type { AxiosResponse } from 'axios';
import type { PaginationMeta } from './types';

// API envelope unwrapping.
//
// Backend wraps payloads in `{ success: true, data: <payload>, meta?: ... }`.
// AxiosResponse<T> exposes the body as `response.data`, so the actual payload
// is `response.data.data` (when wrapped). Pagination metadata lives at the
// *root* of the body (`response.data.meta`) — NOT inside data — which is what
// makes the distinction load-bearing.
//
// Pre-fix code did `extractData(response).meta` and silently got `undefined`
// because meta isn't inside data. The result was that NodeList's pagination
// computed `result.meta?.total_pages || 1`, which evaluated to `1` always.

/** Extract the data payload from a wrapped or bare API response. */
export function extractData<T = unknown>(
  response: AxiosResponse<{ data?: T; success?: boolean } & Partial<T>>
): T {
  const body = response.data as { data?: T } & T;
  return (body.data !== undefined ? body.data : body) as T;
}

/**
 * Extract a paginated envelope, returning the data payload merged with the
 * meta block. The data payload retains its resource-named key (e.g.,
 * `{ nodes: [...] }`) and `meta` is added at the same level — so callers
 * read `result.nodes` and `result.meta.total_pages` naturally.
 *
 * @example
 *   const r = await apiClient.get<PaginatedEnvelope<{ nodes: SystemNode[] }>>('/system/nodes');
 *   return extractPaginated(r);  // { nodes: SystemNode[], meta: PaginationMeta }
 */
export function extractPaginated<T extends Record<string, unknown>>(
  response: AxiosResponse<{ data?: T; meta?: PaginationMeta }>
): T & { meta: PaginationMeta } {
  const data = (response.data?.data ?? {}) as T;
  // Item count is the sum of all array fields in `data`. Most paginated
  // endpoints have one collection key, but this generalizes if multiple
  // collections appear.
  const itemCount = Object.values(data).reduce<number>(
    (sum, v) => sum + (Array.isArray(v) ? v.length : 0),
    0
  );
  const meta = response.data?.meta ?? defaultMeta(itemCount);
  return { ...data, meta };
}

/** Synthesize a meta block for endpoints that don't paginate but still
 *  return collections (e.g., the bare-array catalog endpoints). */
export function defaultMeta(count: number): PaginationMeta {
  return {
    current_page: 1,
    per_page: count,
    total_count: count,
    total_pages: 1,
    next_page: null,
    prev_page: null,
  };
}
