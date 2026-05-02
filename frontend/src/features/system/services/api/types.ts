// Shared API envelope types.
//
// The Powernode backend's `render_success` / `render_error` concern produces
// responses in two canonical shapes:
//
//   Success: { success: true, data: <payload>, meta?: <PaginationMeta>, message?: string }
//   Error:   { success: false, error: string, code?: string, details?: object }
//
// Where <payload> is *either* the keyword-argument splat (e.g.,
// `render_success(nodes: [...], meta: ...)` becomes `{ data: { nodes: [...] } }`)
// or a positional/explicit data: hash. Pagination metadata sits at the
// response root — *not* inside data — which is the latent shape bug the
// audit's M1 finding flagged.
//
// These types make the envelope contract explicit so callers can't
// accidentally reach for `data.meta` (always undefined) instead of
// `meta` (the actual metadata field).

/** Canonical pagination metadata returned by the Paginatable concern. */
export interface PaginationMeta {
  current_page: number;
  per_page: number;
  total_count: number;
  total_pages: number;
  next_page: number | null;
  prev_page: number | null;
}

/** Single-record success envelope. */
export interface ApiEnvelope<T> {
  success: true;
  data: T;
  message?: string;
}

/** Paginated success envelope — `meta` is always present alongside data. */
export interface PaginatedEnvelope<T> {
  success: true;
  data: T;
  meta: PaginationMeta;
}

/** Error envelope. */
export interface ApiErrorEnvelope {
  success: false;
  error: string;
  code?: string;
  details?: Record<string, unknown>;
}

/** Standard params for paginated endpoints. */
export interface PaginationParams {
  page?: number;
  per_page?: number;
}

/** Result shape that resource lists consume — items + meta. */
export interface PaginatedResult<T> {
  items: T[];
  meta: PaginationMeta;
}
