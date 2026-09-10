import { apiClient } from '@/shared/services/apiClient';
import {
  extractData,
  extractGated,
  isPendingApproval,
  defaultMeta,
} from '@system/features/system/services/api/helpers';
import type { Deleted, Gated } from '@system/features/system/services/api/helpers';
import type {
  ApiEnvelope,
  PaginationMeta,
} from '@system/features/system/services/api/types';

// =============================================================================
// Types
// =============================================================================

/**
 * Pool summary shape returned by `InstancePool#to_summary`. Mirrors the
 * Slice 7 backend payload at `GET /api/v1/system/instance_pools`.
 */
export interface InstancePoolSummary {
  id: string;
  name: string;
  status: 'active' | 'paused' | 'draining' | 'archived';
  lifecycle_class: 'ephemeral' | 'spot';
  target_size: number;
  min_size: number;
  max_size: number;
  ready_count: number;
  warming_count: number;
  claimed_count: number;
  errored_count: number;
  deficit: number;
  last_replenished_at: string | null;
  /**
   * Optional template id — when the payload hydrates it, the template cell
   * becomes a clickable `EntityLink` to the template detail surface. Absent in
   * the base `to_summary` payload, in which case the link degrades to text.
   */
  node_template_id?: string;
  /** Optional template name — only set when the detail endpoint hydrates it. */
  node_template_name?: string;
  /** Optional description — only set when the detail endpoint hydrates it. */
  description?: string;
}

export interface InstancePoolListResponse {
  pools: InstancePoolSummary[];
  count: number;
}

export interface CreatePoolPayload {
  name: string;
  description?: string;
  node_template_id: string;
  target_size: number;
  min_size: number;
  max_size: number;
  lifecycle_class: 'ephemeral' | 'spot';
}

// PATCH payload — mirrors the controller's `update_params` permit list
// (description, sizing, status, placement). All fields optional: the edit form
// sends only what changed. Name + template + lifecycle_class are immutable
// post-create (not in the permit list), so they are intentionally absent.
export interface UpdatePoolPayload {
  description?: string;
  target_size?: number;
  min_size?: number;
  max_size?: number;
  status?: InstancePoolSummary['status'];
  provider_region_id?: string;
  provider_instance_type_id?: string;
}

export interface InstancePoolListFilters {
  search: string;
  status: 'all' | 'active' | 'paused' | 'draining' | 'archived';
}

// =============================================================================
// Inline API client
//
// The existing `systemApi` aggregator doesn't expose instance-pool helpers
// yet. We follow the same envelope-extraction pattern (apiClient + helpers)
// rather than inventing new fetch logic. The helpers come from
// `@system/features/system/services/api/helpers` so envelope handling stays
// identical to nodes/templates/etc.
// =============================================================================

/**
 * Per-phase tallies from `InstancePoolService#recycle_stale_members!`. Left
 * open-ended on purpose: the service adds phases over time and an unknown key
 * should still be reported rather than dropped.
 */
export type RecycleResult = Record<string, number>;

/**
 * Human-readable summary of a recycle sweep. Only non-zero phases are named —
 * a sweep over a healthy pool returns every counter at zero and the operator
 * needs to be told nothing was stale, not handed a wall of zeros.
 */
export function summariseRecycle(result: RecycleResult, poolName: string): string {
  const moved = Object.entries(result).filter(
    ([, count]) => typeof count === 'number' && count > 0,
  );
  if (moved.length === 0) {
    return `No stale members to recycle in "${poolName}"`;
  }
  const parts = moved.map(
    ([phase, count]) => `${count} ${phase.replace(/_/g, ' ')}`,
  );
  return `Recycled stale members of "${poolName}": ${parts.join(', ')}`;
}

export const instancePoolsApi = {
  list: async (params?: {
    status?: string;
  }): Promise<{ pools: InstancePoolSummary[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<ApiEnvelope<InstancePoolListResponse>>(
      '/system/instance_pools',
      { params },
    );
    const data = extractData(response);
    const pools = data.pools ?? [];
    return { pools, meta: defaultMeta(pools.length) };
  },

  get: async (id: string): Promise<InstancePoolSummary> => {
    const response = await apiClient.get<
      ApiEnvelope<{ pool: InstancePoolSummary }>
    >(`/system/instance_pools/${id}`);
    return extractData(response).pool;
  },

  // Gated since IMP-24daa05e7a22 (system.instance_pool_create): committing
  // capacity is an operator decision, so POST answers 202 `{pending: true,
  // ...}` with NO `pool` key whenever the policy parks. IMP-067f39468350 —
  // this read `extractData(response).pool` and handed the caller `undefined`
  // on that branch: the list upserted a member-less object and threw while
  // rendering, which the caller's catch reported as "Failed to create pool"
  // for an operation that had parked correctly. Same `extractGated` seam the
  // PATCH below already uses.
  create: async (
    data: CreatePoolPayload,
  ): Promise<Gated<InstancePoolSummary>> => {
    const response = await apiClient.post<
      ApiEnvelope<{ pool: InstancePoolSummary }>
    >('/system/instance_pools', { pool: data });
    return extractGated(response, (d) => d.pool);
  },

  // Gated since IMP-24daa05e7a22: a target_size/max_size INCREASE and the
  // transition to `archived` route through Ai::AutonomyGate, so this PATCH
  // can answer 202 `{pending: true, ...}` with NO `pool` key. Axios resolves
  // 2xx normally, so the pre-gate `extractData(response).pool` returned
  // `undefined` on that branch and the caller's upsert threw — an operation
  // that successfully parked an approval rendered as "Failed to update pool".
  // `extractGated` is the same seam every gated SDWAN mutation uses.
  update: async (
    id: string,
    data: UpdatePoolPayload,
  ): Promise<Gated<InstancePoolSummary>> => {
    const response = await apiClient.patch<
      ApiEnvelope<{ pool: InstancePoolSummary }>
    >(`/system/instance_pools/${id}`, { pool: data });
    return extractGated(response, (d) => d.pool);
  },

  replenish: async (id: string): Promise<InstancePoolSummary> => {
    const response = await apiClient.post<
      ApiEnvelope<{ pool: InstancePoolSummary }>
    >(`/system/instance_pools/${id}/replenish`);
    return extractData(response).pool;
  },

  drain: async (id: string): Promise<InstancePoolSummary> => {
    const response = await apiClient.post<
      ApiEnvelope<{ pool: InstancePoolSummary }>
    >(`/system/instance_pools/${id}/drain`);
    return extractData(response).pool;
  },

  // The reaper runs this on its own tick; the operator-facing button exists so
  // a stuck member can be swept now rather than at the next pass. The counters
  // are InstancePoolService#recycle_stale_members!'s per-phase tallies.
  recycleStale: async (
    id: string,
  ): Promise<{ pool: InstancePoolSummary; recycle_result: RecycleResult }> => {
    const response = await apiClient.post<
      ApiEnvelope<{ pool: InstancePoolSummary; recycle_result: RecycleResult }>
    >(`/system/instance_pools/${id}/recycle_stale`);
    const data = extractData(response);
    return { pool: data.pool, recycle_result: data.recycle_result ?? {} };
  },

  // Gated too (system.instance_pool_delete). This DISCARDED the response, so
  // a parked 202 was indistinguishable from a completed deletion: the caller
  // dropped the row from the list and toasted success while the pool was
  // still active and its replenish tick still spending.
  //
  // The pool is DESTROYED, not archived — the executor calls `destroy!`. The
  // body was typed as `{ pool: InstancePoolSummary }`, which the server could
  // not send: rendering a summary of the destroyed row is what made this
  // endpoint answer 404 for a deletion that succeeded (IMP-4de09f201a0f). The
  // body now carries the destroyed row's identity, and the caller still needs
  // only to know it happened.
  destroy: async (id: string): Promise<Gated<Deleted>> => {
    const response = await apiClient.delete<
      ApiEnvelope<{ deleted: boolean; id: string; name: string }>
    >(`/system/instance_pools/${id}`);
    return extractGated(response, () => ({ deleted: true }) as Deleted);
  },
};

export { isPendingApproval };

// =============================================================================
// Status pill helpers — validated theme tokens only.
// =============================================================================

export function lifecyclePillClasses(
  lifecycleClass: InstancePoolSummary['lifecycle_class'],
): string {
  return lifecycleClass === 'spot'
    ? 'bg-theme-warning-bg text-theme-warning-fg'
    : 'bg-theme-interactive-primary/10 text-theme-interactive-primary';
}
