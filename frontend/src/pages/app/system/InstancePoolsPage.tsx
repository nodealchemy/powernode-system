import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Boxes,
  Plus,
  RefreshCw,
  Droplet,
  Recycle,
  Trash2,
  Search,
  Filter,
  Pencil,
  ChevronDown,
  ChevronRight,
} from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import { EntityLink } from '@/shared/components/entity';
import { apiClient } from '@/shared/services/apiClient';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { logger } from '@/shared/utils/logger';
import { useInfiniteResourceList } from '@system/features/system/hooks/useResourceList';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import {
  extractData,
  extractGated,
  isPendingApproval,
  defaultMeta,
} from '@system/features/system/services/api/helpers';
import type { Deleted, Gated } from '@system/features/system/services/api/helpers';
import { pendingApprovalNotice } from '@system/features/system/utils/pendingApproval';
import type {
  ApiEnvelope,
  PaginationMeta,
} from '@system/features/system/services/api/types';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeTemplate } from '@system/features/system/types/system.types';
import { StatusBadge } from '@system/features/system/components/shared/StatusBadge';

// =============================================================================
// Types
// =============================================================================

/**
 * Pool summary shape returned by `InstancePool#to_summary`. Mirrors the
 * Slice 7 backend payload at `GET /api/v1/system/instance_pools`.
 */
interface InstancePoolSummary {
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

interface InstancePoolListResponse {
  pools: InstancePoolSummary[];
  count: number;
}

interface CreatePoolPayload {
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
interface UpdatePoolPayload {
  description?: string;
  target_size?: number;
  min_size?: number;
  max_size?: number;
  status?: InstancePoolSummary['status'];
  provider_region_id?: string;
  provider_instance_type_id?: string;
}

interface InstancePoolListFilters {
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
type RecycleResult = Record<string, number>;

/**
 * Human-readable summary of a recycle sweep. Only non-zero phases are named —
 * a sweep over a healthy pool returns every counter at zero and the operator
 * needs to be told nothing was stale, not handed a wall of zeros.
 */
function summariseRecycle(result: RecycleResult, poolName: string): string {
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

const instancePoolsApi = {
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

// =============================================================================
// Status pill helpers — validated theme tokens only.
// =============================================================================

function lifecyclePillClasses(
  lifecycleClass: InstancePoolSummary['lifecycle_class'],
): string {
  return lifecycleClass === 'spot'
    ? 'bg-theme-warning-bg text-theme-warning-fg'
    : 'bg-theme-interactive-primary/10 text-theme-interactive-primary';
}

// =============================================================================
// Page
// =============================================================================

const InstancePoolsPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();

  // Permissions mirror the controller's `authorize_read!` /
  // `authorize_write!` checks.
  const canRead = hasPermission('system.node_instances.read');
  const canCreate = hasPermission('system.instances.create');
  const canControl =
    hasPermission('system.instances.control') ||
    hasPermission('system.instances.create');

  const [showCreateModal, setShowCreateModal] = useState(false);
  const [editPool, setEditPool] = useState<InstancePoolSummary | null>(null);
  const [detailPool, setDetailPool] = useState<InstancePoolSummary | null>(
    null,
  );
  const [actioningPoolId, setActioningPoolId] = useState<string | null>(null);
  const [deletePool, setDeletePool] = useState<InstancePoolSummary | null>(
    null,
  );
  const [deleting, setDeleting] = useState(false);

  // Click-to-expand state — Set<id> so multiple rows can be open at once.
  // Mirrors the disclosure pattern in nodes/NodeList.tsx.
  const [expandedPoolIds, setExpandedPoolIds] = useState<Set<string>>(
    new Set(),
  );
  const toggleExpanded = useCallback((id: string) => {
    setExpandedPoolIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  }, []);

  const {
    items: pools,
    filteredItems: filteredPools,
    loading,
    loadingMore,
    refreshing,
    hasMore,
    totalCount,
    loadMore,
    filters,
    setFilters,
    refresh: handleRefresh,
    upsertItem,
    removeItem,
  } = useInfiniteResourceList<InstancePoolSummary, InstancePoolListFilters>({
    fetcher: ({ filters: f }) => {
      const params: { status?: string } = {};
      if (f.status !== 'all') params.status = f.status;
      return instancePoolsApi
        .list(params)
        .then((d) => ({ items: d.pools, meta: d.meta }));
    },
    initialFilters: { search: '', status: 'all' },
    perPage: 50,
    // `status` is server-side; `search` filters client-side (no per-keystroke
    // round-trip).
    serverFilterKey: (f) => JSON.stringify({ status: f.status }),
    clientFilterFn: (pool, f) => {
      if (!f.search) return true;
      const q = f.search.toLowerCase();
      return (
        pool.name.toLowerCase().includes(q) ||
        !!pool.description?.toLowerCase().includes(q) ||
        pool.lifecycle_class.toLowerCase().includes(q)
      );
    },
    errorMessage: 'Failed to load instance pools',
  });

  const handleAfterCreate = useCallback(
    (pool: InstancePoolSummary) => {
      upsertItem(pool);
      setShowCreateModal(false);
      addNotification({
        type: 'success',
        message: `Pool "${pool.name}" created successfully`,
      });
    },
    [upsertItem, addNotification],
  );

  const handleAfterEdit = useCallback(
    (pool: InstancePoolSummary) => {
      upsertItem(pool);
      setEditPool(null);
      addNotification({
        type: 'success',
        message: `Pool "${pool.name}" updated successfully`,
      });
    },
    [upsertItem, addNotification],
  );

  const handleViewPool = useCallback(async (pool: InstancePoolSummary) => {
    // Hydrate from the detail endpoint so we get the freshest counts +
    // any optional fields the summary omits.
    setDetailPool(pool);
    try {
      const fresh = await instancePoolsApi.get(pool.id);
      setDetailPool(fresh);
    } catch (err) {
      logger.warn('InstancePoolsPage: failed to refresh pool detail', {
        poolId: pool.id,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }, []);

  const handleReplenish = useCallback(
    async (pool: InstancePoolSummary) => {
      setActioningPoolId(pool.id);
      try {
        const updated = await instancePoolsApi.replenish(pool.id);
        upsertItem(updated);
        addNotification({
          type: 'success',
          message: `Replenish triggered for "${pool.name}"`,
        });
      } catch (err) {
        addNotification({
          type: 'error',
          message:
            err instanceof Error ? err.message : 'Failed to replenish pool',
        });
      } finally {
        setActioningPoolId(null);
      }
    },
    [upsertItem, addNotification],
  );

  const handleDrain = useCallback(
    async (pool: InstancePoolSummary) => {
      setActioningPoolId(pool.id);
      try {
        const updated = await instancePoolsApi.drain(pool.id);
        upsertItem(updated);
        addNotification({
          type: 'success',
          message: `Drain initiated for "${pool.name}"`,
        });
      } catch (err) {
        addNotification({
          type: 'error',
          message:
            err instanceof Error ? err.message : 'Failed to drain pool',
        });
      } finally {
        setActioningPoolId(null);
      }
    },
    [upsertItem, addNotification],
  );

  const handleRecycleStale = useCallback(
    async (pool: InstancePoolSummary) => {
      setActioningPoolId(pool.id);
      try {
        const { pool: updated, recycle_result } =
          await instancePoolsApi.recycleStale(pool.id);
        upsertItem(updated);
        addNotification({
          type: 'success',
          message: summariseRecycle(recycle_result, pool.name),
        });
      } catch (err) {
        addNotification({
          type: 'error',
          message:
            err instanceof Error
              ? err.message
              : 'Failed to recycle stale pool members',
        });
      } finally {
        setActioningPoolId(null);
      }
    },
    [upsertItem, addNotification],
  );

  const handleConfirmDelete = useCallback(async () => {
    if (!deletePool) return;
    setDeleting(true);
    try {
      const result = await instancePoolsApi.destroy(deletePool.id);
      // Nothing has been archived on the pending branch — never a success
      // toast, and above all never removeItem: dropping the row would tell
      // the operator a pool is gone while it is still active and its
      // replenish tick is still spending.
      if (isPendingApproval(result)) {
        addNotification(
          pendingApprovalNotice(`archiving pool "${deletePool.name}"`, result),
        );
        setDeletePool(null);
        return;
      }
      // Backend soft-archives — drop from the active list immediately.
      removeItem(deletePool.id);
      addNotification({
        type: 'success',
        message: `Pool "${deletePool.name}" archived`,
      });
      setDeletePool(null);
    } catch (err) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to archive pool',
      });
    } finally {
      setDeleting(false);
    }
  }, [deletePool, removeItem, addNotification]);

  const pageActions: PageAction[] = useMemo(() => {
    if (!canCreate) return [];
    return [
      {
        label: 'Create Pool',
        onClick: () => setShowCreateModal(true),
        variant: 'primary',
        icon: Plus,
      },
    ];
  }, [canCreate]);

  if (!canRead) {
    return (
      <PageContainer
        title="Instance Pools"
        breadcrumbs={[
          { label: 'System', href: '/app/system' },
          { label: 'Instance Pools' },
        ]}
      >
        <div className="p-6 text-sm text-theme-secondary">
          You don&apos;t have permission to view instance pools.
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer
      title="Instance Pools"
      description="Pre-warmed instance pools that hand out ready-to-use NodeInstances in <30s instead of the cold provision path. Configure target/min/max sizing — the reaper provisions and recycles to match."
      breadcrumbs={[
        { label: 'System', href: '/app/system' },
        { label: 'Instance Pools' },
      ]}
      actions={pageActions}
    >
      <ResponsiveListContainer
        loading={loading}
        refreshing={refreshing}
        totalCount={pools.length}
        filteredCount={filteredPools.length}
        onRefresh={handleRefresh}
        onLoadMore={loadMore}
        hasMore={hasMore}
        loadingMore={loadingMore}
        serverTotalCount={totalCount}
        emptyState={{
          icon: Boxes,
          title: 'No instance pools yet',
          description:
            'Create a pool to keep a warm fleet of NodeInstances ready for instant claim.',
          action:
            canCreate
              ? {
                  label: 'Create Pool',
                  onClick: () => setShowCreateModal(true),
                }
              : undefined,
        }}
      >
        <ResponsiveListContainer.Filters>
          <div className="flex-1">
            <div className="relative">
              <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
              <input
                type="text"
                placeholder="Search pools..."
                value={filters.search}
                onChange={(e) =>
                  setFilters({ ...filters, search: e.target.value })
                }
                aria-label="Search pools"
                className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
              />
            </div>
          </div>

          <div className="sm:w-48">
            <div className="relative">
              <Filter className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
              <select
                value={filters.status}
                onChange={(e) =>
                  setFilters({
                    ...filters,
                    status: e.target
                      .value as InstancePoolListFilters['status'],
                  })
                }
                aria-label="Filter by status"
                className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus appearance-none"
              >
                <option value="all">All statuses</option>
                <option value="active">Active</option>
                <option value="paused">Paused</option>
                <option value="draining">Draining</option>
                <option value="archived">Archived</option>
              </select>
            </div>
          </div>
        </ResponsiveListContainer.Filters>

        <ResponsiveListContainer.Desktop>
          <table className="w-full">
            <thead>
              <tr className="bg-theme-background border-b border-theme">
                <th className="w-8 py-3 px-2" />
                <th className="text-left py-3 px-4 font-medium text-theme-primary">
                  Pool
                </th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">
                  Status
                </th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">
                  Lifecycle
                </th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">
                  Sizing
                </th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">
                  Members
                </th>
                <th className="text-right py-3 px-4 font-medium text-theme-primary">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-theme">
              {filteredPools.map((pool) => {
                const isActioning = actioningPoolId === pool.id;
                const expanded = expandedPoolIds.has(pool.id);
                return (
                  <React.Fragment key={pool.id}>
                  <tr
                    className="hover:bg-theme-surface-hover transition-colors duration-200"
                    data-testid={`pool-row-${pool.id}`}
                  >
                    <td className="py-3 px-2 align-middle">
                      <button
                        type="button"
                        onClick={() => toggleExpanded(pool.id)}
                        className="p-1 text-theme-secondary hover:text-theme-primary rounded transition-colors"
                        title={expanded ? 'Collapse details' : 'Expand details'}
                        aria-label={
                          expanded
                            ? `Collapse ${pool.name} details`
                            : `Expand ${pool.name} details`
                        }
                      >
                        {expanded ? (
                          <ChevronDown className="w-4 h-4" />
                        ) : (
                          <ChevronRight className="w-4 h-4" />
                        )}
                      </button>
                    </td>
                    <td className="py-3 px-4">
                      <div className="flex items-center gap-2">
                        <Boxes className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                        <button
                          type="button"
                          onClick={() => handleViewPool(pool)}
                          className="font-medium text-theme-primary hover:text-theme-link text-left"
                        >
                          {pool.name}
                        </button>
                      </div>
                    </td>
                    <td className="py-3 px-4">
                      <StatusBadge status={pool.status} size="xs" />
                    </td>
                    <td className="py-3 px-4">
                      <span
                        className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${lifecyclePillClasses(
                          pool.lifecycle_class,
                        )}`}
                      >
                        {pool.lifecycle_class}
                      </span>
                    </td>
                    <td className="py-3 px-4 text-sm text-theme-secondary">
                      <div className="font-mono">
                        <span className="text-theme-primary font-medium">
                          {pool.target_size}
                        </span>
                        <span className="text-theme-tertiary"> target</span>
                        <span className="text-theme-tertiary"> · </span>
                        <span>{pool.min_size}</span>
                        <span className="text-theme-tertiary">–</span>
                        <span>{pool.max_size}</span>
                      </div>
                      {pool.deficit > 0 && (
                        <div className="text-xs text-theme-warning-fg mt-0.5">
                          deficit: {pool.deficit}
                        </div>
                      )}
                    </td>
                    <td className="py-3 px-4 text-sm text-theme-secondary">
                      <div className="font-mono">
                        <span className="text-theme-success-fg">
                          {pool.ready_count} ready
                        </span>
                        <span className="text-theme-tertiary"> · </span>
                        <span>{pool.warming_count} warming</span>
                        <span className="text-theme-tertiary"> · </span>
                        <span>{pool.claimed_count} claimed</span>
                      </div>
                      {pool.errored_count > 0 && (
                        <div className="text-xs text-theme-danger-fg mt-0.5">
                          {pool.errored_count} errored
                        </div>
                      )}
                    </td>
                    <td className="py-3 px-4">
                      <div className="flex items-center justify-end gap-2">
                        {canControl && (
                          <Button
                            variant="outline"
                            size="sm"
                            onClick={() => setEditPool(pool)}
                            disabled={
                              isActioning || pool.status === 'archived'
                            }
                            title="Edit pool"
                            aria-label={`Edit ${pool.name}`}
                          >
                            <Pencil className="w-4 h-4" />
                          </Button>
                        )}
                        {canControl && (
                          <Button
                            variant="outline"
                            size="sm"
                            onClick={() => handleReplenish(pool)}
                            /* Replenish is refused for every status but
                               'active' (InstancePoolService#replenish!), so
                               offering it on a paused/draining/archived pool
                               is an action that can only ever toast an
                               error. IMP-cb2da06a384b. */
                            disabled={isActioning || pool.status !== 'active'}
                            title="Replenish pool"
                            aria-label={`Replenish ${pool.name}`}
                          >
                            <RefreshCw
                              className={`w-4 h-4 ${
                                isActioning ? 'animate-spin' : ''
                              }`}
                            />
                          </Button>
                        )}
                        {canControl && (
                          <Button
                            variant="outline"
                            size="sm"
                            onClick={() => handleDrain(pool)}
                            disabled={
                              isActioning ||
                              pool.status === 'draining' ||
                              pool.status === 'archived'
                            }
                            title="Drain pool"
                            aria-label={`Drain ${pool.name}`}
                          >
                            <Droplet className="w-4 h-4" />
                          </Button>
                        )}
                        {canControl && (
                          <Button
                            variant="outline"
                            size="sm"
                            onClick={() => handleRecycleStale(pool)}
                            /* An archived pool has nothing left to sweep;
                               every other status can hold stale members. */
                            disabled={isActioning || pool.status === 'archived'}
                            title="Recycle stale members"
                            aria-label={`Recycle stale members of ${pool.name}`}
                          >
                            <Recycle className="w-4 h-4" />
                          </Button>
                        )}
                        {canControl && (
                          <Button
                            variant="outline"
                            size="sm"
                            onClick={() => setDeletePool(pool)}
                            disabled={
                              isActioning || pool.status === 'archived'
                            }
                            title="Delete pool"
                            aria-label={`Delete ${pool.name}`}
                          >
                            <Trash2 className="w-4 h-4" />
                          </Button>
                        )}
                      </div>
                    </td>
                  </tr>
                  {expanded && (
                    <tr className="bg-theme-background border-b border-theme">
                      <td />
                      <td colSpan={6} className="py-3 px-4">
                        <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
                          {pool.description && (
                            <div className="col-span-full">
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                                Description
                              </label>
                              <p className="text-theme-primary">
                                {pool.description}
                              </p>
                            </div>
                          )}
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                              Status
                            </label>
                            <p className="text-theme-primary">{pool.status}</p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                              Lifecycle class
                            </label>
                            <p className="text-theme-primary">
                              {pool.lifecycle_class}
                            </p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                              Template
                            </label>
                            <p className="text-theme-primary">
                              {pool.node_template_id ||
                              pool.node_template_name ? (
                                <EntityLink
                                  type="node_template"
                                  id={pool.node_template_id}
                                  label={
                                    pool.node_template_name ??
                                    pool.node_template_id
                                  }
                                />
                              ) : (
                                '—'
                              )}
                            </p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                              Sizing (min / target / max)
                            </label>
                            <p className="text-theme-primary font-mono text-xs">
                              {pool.min_size} / {pool.target_size} /{' '}
                              {pool.max_size}
                            </p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                              Deficit
                            </label>
                            <p
                              className={
                                pool.deficit > 0
                                  ? 'text-theme-warning-fg'
                                  : 'text-theme-primary'
                              }
                            >
                              {pool.deficit}
                            </p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                              Members (ready / warming / claimed / errored)
                            </label>
                            <p className="text-theme-primary font-mono text-xs">
                              <span className="text-theme-success-fg">
                                {pool.ready_count}
                              </span>{' '}
                              / {pool.warming_count} / {pool.claimed_count} /{' '}
                              <span
                                className={
                                  pool.errored_count > 0
                                    ? 'text-theme-danger-fg'
                                    : undefined
                                }
                              >
                                {pool.errored_count}
                              </span>
                            </p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                              Last replenished
                            </label>
                            <p className="text-theme-primary text-xs">
                              {pool.last_replenished_at
                                ? new Date(
                                    pool.last_replenished_at,
                                  ).toLocaleString()
                                : 'never'}
                            </p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                              Pool ID
                            </label>
                            <p
                              className="text-theme-primary font-mono text-xs truncate"
                              title={pool.id}
                            >
                              {pool.id}
                            </p>
                          </div>
                        </div>
                      </td>
                    </tr>
                  )}
                  </React.Fragment>
                );
              })}
            </tbody>
          </table>
        </ResponsiveListContainer.Desktop>

        <ResponsiveListContainer.Mobile>
          {filteredPools.map((pool) => {
            const isActioning = actioningPoolId === pool.id;
            const expanded = expandedPoolIds.has(pool.id);
            return (
              <div
                key={pool.id}
                className="p-4"
                data-testid={`pool-card-${pool.id}`}
              >
                <div className="flex items-start justify-between mb-3">
                  <div className="flex items-start gap-2 flex-1 min-w-0">
                    <button
                      type="button"
                      onClick={() => toggleExpanded(pool.id)}
                      className="p-1 -ml-1 mt-0.5 text-theme-secondary hover:text-theme-primary rounded transition-colors flex-shrink-0"
                      title={expanded ? 'Collapse details' : 'Expand details'}
                      aria-label={
                        expanded
                          ? `Collapse ${pool.name} details`
                          : `Expand ${pool.name} details`
                      }
                    >
                      {expanded ? (
                        <ChevronDown className="w-4 h-4" />
                      ) : (
                        <ChevronRight className="w-4 h-4" />
                      )}
                    </button>
                    <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 mb-1">
                      <Boxes className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                      <button
                        type="button"
                        onClick={() => handleViewPool(pool)}
                        className="font-medium text-theme-primary hover:text-theme-link truncate text-left"
                      >
                        {pool.name}
                      </button>
                    </div>
                    <div className="flex items-center gap-2 mt-1">
                      <StatusBadge status={pool.status} size="xs" />
                      <span
                        className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${lifecyclePillClasses(
                          pool.lifecycle_class,
                        )}`}
                      >
                        {pool.lifecycle_class}
                      </span>
                    </div>
                    </div>
                  </div>
                </div>

                <div className="grid grid-cols-2 gap-2 text-xs text-theme-secondary mb-3">
                  <div>
                    <span className="text-theme-tertiary">target:</span>{' '}
                    <span className="text-theme-primary font-medium">
                      {pool.target_size}
                    </span>
                  </div>
                  <div>
                    <span className="text-theme-tertiary">range:</span>{' '}
                    {pool.min_size}–{pool.max_size}
                  </div>
                  <div>
                    <span className="text-theme-tertiary">ready:</span>{' '}
                    <span className="text-theme-success-fg">
                      {pool.ready_count}
                    </span>
                  </div>
                  <div>
                    <span className="text-theme-tertiary">warming:</span>{' '}
                    {pool.warming_count}
                  </div>
                  <div>
                    <span className="text-theme-tertiary">claimed:</span>{' '}
                    {pool.claimed_count}
                  </div>
                  {pool.errored_count > 0 && (
                    <div>
                      <span className="text-theme-tertiary">errored:</span>{' '}
                      <span className="text-theme-danger-fg">
                        {pool.errored_count}
                      </span>
                    </div>
                  )}
                </div>

                {canControl && (
                  <div className="flex flex-wrap items-center gap-2">
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => setEditPool(pool)}
                      disabled={isActioning || pool.status === 'archived'}
                      aria-label={`Edit ${pool.name}`}
                    >
                      <Pencil className="w-4 h-4 mr-1" />
                      Edit
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => handleReplenish(pool)}
                      /* Active-only, same reason as the table-row button. */
                      disabled={isActioning || pool.status !== 'active'}
                      aria-label={`Replenish ${pool.name}`}
                    >
                      <RefreshCw
                        className={`w-4 h-4 mr-1 ${
                          isActioning ? 'animate-spin' : ''
                        }`}
                      />
                      Replenish
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => handleDrain(pool)}
                      disabled={
                        isActioning ||
                        pool.status === 'draining' ||
                        pool.status === 'archived'
                      }
                      aria-label={`Drain ${pool.name}`}
                    >
                      <Droplet className="w-4 h-4 mr-1" />
                      Drain
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => handleRecycleStale(pool)}
                      /* Archived-only exclusion, same as the table-row button. */
                      disabled={isActioning || pool.status === 'archived'}
                      aria-label={`Recycle stale members of ${pool.name}`}
                    >
                      <Recycle className="w-4 h-4 mr-1" />
                      Recycle stale
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => setDeletePool(pool)}
                      disabled={isActioning || pool.status === 'archived'}
                      aria-label={`Delete ${pool.name}`}
                    >
                      <Trash2 className="w-4 h-4 mr-1" />
                      Delete
                    </Button>
                  </div>
                )}

                {expanded && (
                  <div className="mt-3 pt-3 border-t border-theme grid grid-cols-2 gap-3 text-sm">
                    {pool.description && (
                      <div className="col-span-2">
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                          Description
                        </label>
                        <p className="text-theme-primary">
                          {pool.description}
                        </p>
                      </div>
                    )}
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                        Status
                      </label>
                      <p className="text-theme-primary">{pool.status}</p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                        Lifecycle class
                      </label>
                      <p className="text-theme-primary">
                        {pool.lifecycle_class}
                      </p>
                    </div>
                    <div className="col-span-2">
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                        Template
                      </label>
                      <p className="text-theme-primary">
                        {pool.node_template_id || pool.node_template_name ? (
                          <EntityLink
                            type="node_template"
                            id={pool.node_template_id}
                            label={
                              pool.node_template_name ?? pool.node_template_id
                            }
                          />
                        ) : (
                          '—'
                        )}
                      </p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                        Sizing (min/target/max)
                      </label>
                      <p className="text-theme-primary font-mono text-xs">
                        {pool.min_size} / {pool.target_size} / {pool.max_size}
                      </p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                        Deficit
                      </label>
                      <p
                        className={
                          pool.deficit > 0
                            ? 'text-theme-warning-fg'
                            : 'text-theme-primary'
                        }
                      >
                        {pool.deficit}
                      </p>
                    </div>
                    <div className="col-span-2">
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                        Last replenished
                      </label>
                      <p className="text-theme-primary text-xs">
                        {pool.last_replenished_at
                          ? new Date(
                              pool.last_replenished_at,
                            ).toLocaleString()
                          : 'never'}
                      </p>
                    </div>
                    <div className="col-span-2">
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                        Pool ID
                      </label>
                      <p
                        className="text-theme-primary font-mono text-xs truncate"
                        title={pool.id}
                      >
                        {pool.id}
                      </p>
                    </div>
                  </div>
                )}
              </div>
            );
          })}
        </ResponsiveListContainer.Mobile>
      </ResponsiveListContainer>

      <CreatePoolModal
        isOpen={showCreateModal}
        onClose={() => setShowCreateModal(false)}
        onCreated={handleAfterCreate}
      />

      <EditPoolModal
        pool={editPool}
        onClose={() => setEditPool(null)}
        onUpdated={handleAfterEdit}
      />

      <PoolDetailModal
        pool={detailPool}
        onClose={() => setDetailPool(null)}
      />

      <Modal
        isOpen={!!deletePool}
        onClose={() => (deleting ? null : setDeletePool(null))}
        title="Archive instance pool"
        subtitle="This action cannot be undone"
        size="md"
        footer={
          <div className="flex items-center justify-end gap-3">
            <Button
              variant="ghost"
              onClick={() => setDeletePool(null)}
              disabled={deleting}
            >
              Cancel
            </Button>
            <Button
              variant="danger"
              onClick={handleConfirmDelete}
              disabled={deleting}
            >
              {deleting ? 'Archiving...' : 'Archive Pool'}
            </Button>
          </div>
        }
      >
        <div className="space-y-3">
          <p className="text-theme-primary">
            Archive pool <strong>{deletePool?.name}</strong>? The reaper stops
            replenishing it. Members are <strong>not</strong> terminated —
            ready and claimed instances keep running until the operator
            terminates them. Drain the pool first if you want its ready
            members torn down.
          </p>
          {deletePool && deletePool.claimed_count > 0 && (
            <div className="p-3 bg-theme-warning-bg border border-theme-warning-border/30 rounded-lg">
              <p className="text-theme-warning-fg text-sm">
                <strong>Heads up:</strong> {deletePool.claimed_count}{' '}
                claimed instance(s) will continue running. You&apos;ll need to
                terminate them separately.
              </p>
            </div>
          )}
        </div>
      </Modal>
    </PageContainer>
  );
};

// =============================================================================
// Create Pool modal — colocated so the page is self-contained.
// =============================================================================

interface CreatePoolModalProps {
  isOpen: boolean;
  onClose: () => void;
  onCreated: (pool: InstancePoolSummary) => void;
}

interface CreateFormState {
  name: string;
  description: string;
  node_template_id: string;
  target_size: number;
  min_size: number;
  max_size: number;
  lifecycle_class: 'ephemeral' | 'spot';
}

interface CreateFormErrors {
  name?: string;
  node_template_id?: string;
  sizing?: string;
}

const INITIAL_FORM: CreateFormState = {
  name: '',
  description: '',
  node_template_id: '',
  target_size: 2,
  min_size: 1,
  max_size: 4,
  lifecycle_class: 'ephemeral',
};

const CreatePoolModal: React.FC<CreatePoolModalProps> = ({
  isOpen,
  onClose,
  onCreated,
}) => {
  const { addNotification } = useNotifications();
  const [form, setForm] = useState<CreateFormState>(INITIAL_FORM);
  const [errors, setErrors] = useState<CreateFormErrors>({});
  const [submitting, setSubmitting] = useState(false);
  const [templates, setTemplates] = useState<SystemNodeTemplate[]>([]);
  const [loadingTemplates, setLoadingTemplates] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setForm(INITIAL_FORM);
    setErrors({});
    setLoadingTemplates(true);
    systemApi
      .getTemplates({ per_page: 200 })
      .then((d) => setTemplates(d.templates.filter((t) => t.enabled)))
      .catch((err) => {
        logger.error('CreatePoolModal: failed to load templates', {
          error: err instanceof Error ? err.message : String(err),
        });
        addNotification({
          type: 'error',
          message: 'Failed to load node templates',
        });
      })
      .finally(() => setLoadingTemplates(false));
  }, [isOpen, addNotification]);

  const handleChange = useCallback(
    <K extends keyof CreateFormState>(
      field: K,
      value: CreateFormState[K],
    ) => {
      setForm((prev) => ({ ...prev, [field]: value }));
    },
    [],
  );

  const validate = useCallback((): boolean => {
    const e: CreateFormErrors = {};
    if (!form.name.trim()) e.name = 'Name is required';
    else if (!/^[a-zA-Z0-9][a-zA-Z0-9\-_.]*$/.test(form.name))
      e.name =
        'Name must start with alphanumeric and contain only letters, numbers, hyphens, underscores, and dots';
    if (!form.node_template_id)
      e.node_template_id = 'Template is required';
    if (
      form.min_size < 0 ||
      form.target_size < form.min_size ||
      form.max_size < form.target_size
    ) {
      e.sizing = 'Sizing must satisfy 0 ≤ min ≤ target ≤ max';
    }
    setErrors(e);
    return Object.keys(e).length === 0;
  }, [form]);

  const handleSubmit = useCallback(
    async (event: React.FormEvent) => {
      event.preventDefault();
      if (!validate()) return;
      setSubmitting(true);
      try {
        const created = await instancePoolsApi.create({
          name: form.name.trim(),
          description: form.description.trim() || undefined,
          node_template_id: form.node_template_id,
          target_size: form.target_size,
          min_size: form.min_size,
          max_size: form.max_size,
          lifecycle_class: form.lifecycle_class,
        });
        // No pool exists yet on the pending branch — never a success toast,
        // and never an upsert of a body that carries no pool.
        if (isPendingApproval(created)) {
          addNotification(
            pendingApprovalNotice(
              `creating pool "${form.name.trim()}"`,
              created,
            ),
          );
          onClose();
          return;
        }
        onCreated(created);
      } catch (err) {
        addNotification({
          type: 'error',
          message:
            err instanceof Error ? err.message : 'Failed to create pool',
        });
      } finally {
        setSubmitting(false);
      }
    },
    [form, validate, onCreated, onClose, addNotification],
  );

  return (
    <Modal
      isOpen={isOpen}
      onClose={() => (submitting ? null : onClose())}
      title="Create instance pool"
      subtitle="Pre-warmed NodeInstances ready for instant claim"
      icon={<Boxes className="w-6 h-6" />}
      size="lg"
      footer={
        <div className="flex items-center justify-end gap-3">
          <Button variant="ghost" onClick={onClose} disabled={submitting}>
            Cancel
          </Button>
          <Button
            variant="primary"
            onClick={handleSubmit}
            disabled={submitting || loadingTemplates}
          >
            {submitting ? 'Creating...' : 'Create Pool'}
          </Button>
        </div>
      }
    >
      <form onSubmit={handleSubmit} className="space-y-5">
        <FormField
          label="Name"
          id="pool-name"
          required
          value={form.name}
          onChange={(v) => handleChange('name', v)}
          placeholder="web-warm-pool"
          disabled={submitting}
          error={errors.name}
        />

        <FormField
          label="Description"
          id="pool-description"
          type="textarea"
          rows={2}
          value={form.description}
          onChange={(v) => handleChange('description', v)}
          placeholder="Optional — what's this pool for?"
          disabled={submitting}
        />

        <FormField
          label="Node template"
          id="pool-template"
          type="select"
          required
          value={form.node_template_id}
          onChange={(v) => handleChange('node_template_id', v)}
          disabled={submitting || loadingTemplates}
          error={errors.node_template_id}
          options={[
            {
              value: '',
              label: loadingTemplates ? 'Loading templates...' : 'Select a template',
            },
            ...templates.map((t) => ({
              value: t.id,
              label: t.node_platform_name
                ? `${t.name} (${t.node_platform_name})`
                : t.name,
            })),
          ]}
        />

        <div className="grid grid-cols-3 gap-3">
          <FormField
            label="Min size"
            id="pool-min"
            type="number"
            min={0}
            value={String(form.min_size)}
            onChange={(v) => handleChange('min_size', Number(v))}
            disabled={submitting}
          />
          <FormField
            label="Target size"
            id="pool-target"
            type="number"
            required
            min={0}
            value={String(form.target_size)}
            onChange={(v) => handleChange('target_size', Number(v))}
            disabled={submitting}
          />
          <FormField
            label="Max size"
            id="pool-max"
            type="number"
            min={0}
            value={String(form.max_size)}
            onChange={(v) => handleChange('max_size', Number(v))}
            disabled={submitting}
          />
        </div>
        {errors.sizing && (
          <p className="text-sm text-theme-danger-fg">{errors.sizing}</p>
        )}

        <FormField
          label="Lifecycle class"
          id="pool-lifecycle"
          type="select"
          value={form.lifecycle_class}
          onChange={(v) => handleChange('lifecycle_class', v as 'ephemeral' | 'spot')}
          disabled={submitting}
          options={[
            { value: 'ephemeral', label: 'ephemeral — short-lived, predictable cost' },
            { value: 'spot', label: 'spot — interruptible, cost-optimized' },
          ]}
        />
      </form>
    </Modal>
  );
};

// =============================================================================
// Edit Pool modal — mirrors CreatePoolModal as the edit form. Only the fields
// the controller's `update_params` permits are editable (description, sizing,
// status). Name, node template, and lifecycle_class are immutable post-create
// (not in the permit list), so they render as read-only context.
// =============================================================================

interface EditPoolModalProps {
  pool: InstancePoolSummary | null;
  onClose: () => void;
  onUpdated: (pool: InstancePoolSummary) => void;
}

interface EditFormState {
  description: string;
  target_size: number;
  min_size: number;
  max_size: number;
  status: InstancePoolSummary['status'];
}

interface EditFormErrors {
  sizing?: string;
}

const EditPoolModal: React.FC<EditPoolModalProps> = ({
  pool,
  onClose,
  onUpdated,
}) => {
  const { addNotification } = useNotifications();
  const [form, setForm] = useState<EditFormState | null>(null);
  const [errors, setErrors] = useState<EditFormErrors>({});
  const [submitting, setSubmitting] = useState(false);

  // Seed the form from the pool whenever a new pool is selected for editing.
  useEffect(() => {
    if (!pool) {
      setForm(null);
      return;
    }
    setErrors({});
    setForm({
      description: pool.description ?? '',
      target_size: pool.target_size,
      min_size: pool.min_size,
      max_size: pool.max_size,
      status: pool.status,
    });
  }, [pool]);

  const handleChange = useCallback(
    <K extends keyof EditFormState>(field: K, value: EditFormState[K]) => {
      setForm((prev) => (prev ? { ...prev, [field]: value } : prev));
    },
    [],
  );

  const validate = useCallback((): boolean => {
    if (!form) return false;
    const e: EditFormErrors = {};
    if (
      form.min_size < 0 ||
      form.target_size < form.min_size ||
      form.max_size < form.target_size
    ) {
      e.sizing = 'Sizing must satisfy 0 ≤ min ≤ target ≤ max';
    }
    setErrors(e);
    return Object.keys(e).length === 0;
  }, [form]);

  const handleSubmit = useCallback(
    async (event: React.FormEvent) => {
      event.preventDefault();
      if (!pool || !form) return;
      if (!validate()) return;
      setSubmitting(true);
      try {
        const updated = await instancePoolsApi.update(pool.id, {
          description: form.description.trim() || undefined,
          target_size: form.target_size,
          min_size: form.min_size,
          max_size: form.max_size,
          status: form.status,
        });
        // The form always sends target_size, max_size AND status, so both
        // gated transitions are reachable from this one submit. Nothing has
        // been written on the pending branch — never a success toast, and
        // never an upsert of a body that carries no pool.
        if (isPendingApproval(updated)) {
          addNotification(
            pendingApprovalNotice(`updating pool "${pool.name}"`, updated),
          );
          onClose();
          return;
        }
        onUpdated(updated);
      } catch (err) {
        addNotification({
          type: 'error',
          message:
            err instanceof Error ? err.message : 'Failed to update pool',
        });
      } finally {
        setSubmitting(false);
      }
    },
    [pool, form, validate, onUpdated, onClose, addNotification],
  );

  return (
    <Modal
      isOpen={!!pool}
      onClose={() => (submitting ? null : onClose())}
      title={pool ? `Edit ${pool.name}` : 'Edit instance pool'}
      subtitle="Adjust sizing, status, and description"
      icon={<Boxes className="w-6 h-6" />}
      size="lg"
      footer={
        <div className="flex items-center justify-end gap-3">
          <Button variant="ghost" onClick={onClose} disabled={submitting}>
            Cancel
          </Button>
          <Button
            variant="primary"
            onClick={handleSubmit}
            disabled={submitting || !form}
          >
            {submitting ? 'Saving...' : 'Save Changes'}
          </Button>
        </div>
      }
    >
      {pool && form && (
        <form onSubmit={handleSubmit} className="space-y-5">
          {/* Read-only context — name, template, and lifecycle_class are
              immutable post-create. */}
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">
                Name
              </label>
              <p className="px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-secondary text-sm">
                {pool.name}
              </p>
            </div>
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">
                Template
              </label>
              <p className="px-3 py-2 rounded-lg border border-theme bg-theme-background text-sm">
                {pool.node_template_id || pool.node_template_name ? (
                  <EntityLink
                    type="node_template"
                    id={pool.node_template_id}
                    label={pool.node_template_name ?? pool.node_template_id}
                  />
                ) : (
                  <span className="text-theme-secondary">—</span>
                )}
              </p>
            </div>
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">
                Lifecycle class
              </label>
              <p className="px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-secondary text-sm">
                {pool.lifecycle_class}
              </p>
            </div>
          </div>

          <FormField
            label="Description"
            id="edit-pool-description"
            type="textarea"
            rows={2}
            value={form.description}
            onChange={(v) => handleChange('description', v)}
            placeholder="Optional — what's this pool for?"
            disabled={submitting}
          />

          <div className="grid grid-cols-3 gap-3">
            <FormField
              label="Min size"
              id="edit-pool-min"
              type="number"
              min={0}
              value={String(form.min_size)}
              onChange={(v) => handleChange('min_size', Number(v))}
              disabled={submitting}
            />
            <FormField
              label="Target size"
              id="edit-pool-target"
              type="number"
              required
              min={0}
              value={String(form.target_size)}
              onChange={(v) => handleChange('target_size', Number(v))}
              disabled={submitting}
            />
            <FormField
              label="Max size"
              id="edit-pool-max"
              type="number"
              min={0}
              value={String(form.max_size)}
              onChange={(v) => handleChange('max_size', Number(v))}
              disabled={submitting}
            />
          </div>
          {errors.sizing && (
            <p className="text-sm text-theme-danger-fg">{errors.sizing}</p>
          )}

          <FormField
            label="Status"
            id="edit-pool-status"
            type="select"
            value={form.status}
            onChange={(v) => handleChange('status', v as InstancePoolSummary['status'])}
            disabled={submitting}
            options={[
              { value: 'active', label: 'active' },
              { value: 'paused', label: 'paused' },
              { value: 'draining', label: 'draining' },
              { value: 'archived', label: 'archived' },
            ]}
          />
        </form>
      )}
    </Modal>
  );
};

// =============================================================================
// Pool Detail modal
// =============================================================================

interface PoolDetailModalProps {
  pool: InstancePoolSummary | null;
  onClose: () => void;
}

const PoolDetailModal: React.FC<PoolDetailModalProps> = ({
  pool,
  onClose,
}) => {
  if (!pool) return null;
  const lastReplenished = pool.last_replenished_at
    ? new Date(pool.last_replenished_at).toLocaleString()
    : 'never';

  return (
    <Modal
      isOpen={!!pool}
      onClose={onClose}
      title={pool.name}
      subtitle={`${pool.lifecycle_class} pool — ${pool.status}`}
      icon={<Boxes className="w-6 h-6" />}
      size="lg"
      footer={
        <div className="flex items-center justify-end gap-3">
          <Button variant="ghost" onClick={onClose}>
            Close
          </Button>
        </div>
      }
    >
      <div className="space-y-5">
        <section>
          <h3 className="text-sm font-medium text-theme-primary mb-2">
            Status
          </h3>
          <div className="flex flex-wrap gap-2">
            <StatusBadge status={pool.status} size="xs" />
            <span
              className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${lifecyclePillClasses(
                pool.lifecycle_class,
              )}`}
            >
              {pool.lifecycle_class}
            </span>
          </div>
          {pool.description && (
            <p className="mt-2 text-sm text-theme-secondary">
              {pool.description}
            </p>
          )}
          {(pool.node_template_id || pool.node_template_name) && (
            <p className="mt-2 text-sm text-theme-secondary">
              Template:{' '}
              <EntityLink
                type="node_template"
                id={pool.node_template_id}
                label={pool.node_template_name ?? pool.node_template_id}
              />
            </p>
          )}
        </section>

        <section>
          <h3 className="text-sm font-medium text-theme-primary mb-2">
            Sizing
          </h3>
          <div className="grid grid-cols-3 gap-3 text-sm">
            <div className="p-3 bg-theme-background-secondary rounded-lg">
              <div className="text-xs text-theme-tertiary">min</div>
              <div className="font-mono text-theme-primary">
                {pool.min_size}
              </div>
            </div>
            <div className="p-3 bg-theme-background-secondary rounded-lg">
              <div className="text-xs text-theme-tertiary">target</div>
              <div className="font-mono text-theme-primary">
                {pool.target_size}
              </div>
            </div>
            <div className="p-3 bg-theme-background-secondary rounded-lg">
              <div className="text-xs text-theme-tertiary">max</div>
              <div className="font-mono text-theme-primary">
                {pool.max_size}
              </div>
            </div>
          </div>
          {pool.deficit > 0 && (
            <div className="mt-2 text-xs text-theme-warning-fg">
              Reaper will provision {pool.deficit} additional instance(s) on
              the next tick.
            </div>
          )}
        </section>

        <section>
          <h3 className="text-sm font-medium text-theme-primary mb-2">
            Members
          </h3>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm">
            <div className="p-3 bg-theme-success-bg rounded-lg">
              <div className="text-xs text-theme-success-fg">ready</div>
              <div className="font-mono text-theme-primary">
                {pool.ready_count}
              </div>
            </div>
            <div className="p-3 bg-theme-info-bg rounded-lg">
              <div className="text-xs text-theme-info-fg">warming</div>
              <div className="font-mono text-theme-primary">
                {pool.warming_count}
              </div>
            </div>
            <div className="p-3 bg-theme-interactive-primary/10 rounded-lg">
              <div className="text-xs text-theme-interactive-primary">
                claimed
              </div>
              <div className="font-mono text-theme-primary">
                {pool.claimed_count}
              </div>
            </div>
            <div className="p-3 bg-theme-danger-bg rounded-lg">
              <div className="text-xs text-theme-danger-fg">errored</div>
              <div className="font-mono text-theme-primary">
                {pool.errored_count}
              </div>
            </div>
          </div>
        </section>

        <section>
          <h3 className="text-sm font-medium text-theme-primary mb-2">
            History
          </h3>
          <div className="text-sm text-theme-secondary">
            Last replenished:{' '}
            <span className="text-theme-primary font-mono">
              {lastReplenished}
            </span>
          </div>
        </section>
      </div>
    </Modal>
  );
};

export default InstancePoolsPage;

// Internal exports — kept module-private for the colocated test only.
export const __test__ = { instancePoolsApi };
