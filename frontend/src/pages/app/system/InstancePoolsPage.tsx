import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Boxes,
  Plus,
  RefreshCw,
  Droplet,
  Trash2,
  Search,
  Filter,
} from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { apiClient } from '@/shared/services/apiClient';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { logger } from '@/shared/utils/logger';
import { useInfiniteResourceList } from '@system/features/system/hooks/useResourceList';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import {
  extractData,
  defaultMeta,
} from '@system/features/system/services/api/helpers';
import type {
  ApiEnvelope,
  PaginationMeta,
} from '@system/features/system/services/api/types';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeTemplate } from '@system/features/system/types/system.types';

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

  create: async (data: CreatePoolPayload): Promise<InstancePoolSummary> => {
    const response = await apiClient.post<
      ApiEnvelope<{ pool: InstancePoolSummary }>
    >('/system/instance_pools', { pool: data });
    return extractData(response).pool;
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

  destroy: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/instance_pools/${id}`);
  },
};

// =============================================================================
// Status pill helpers — validated theme tokens only.
// =============================================================================

function statusPillClasses(status: InstancePoolSummary['status']): string {
  switch (status) {
    case 'active':
      return 'bg-theme-success/10 text-theme-success';
    case 'draining':
      return 'bg-theme-warning/10 text-theme-warning';
    case 'archived':
      return 'bg-theme-text-secondary/10 text-theme-secondary';
    case 'paused':
      return 'bg-theme-info/10 text-theme-info';
    default:
      return 'bg-theme-text-secondary/10 text-theme-secondary';
  }
}

function lifecyclePillClasses(
  lifecycleClass: InstancePoolSummary['lifecycle_class'],
): string {
  return lifecycleClass === 'spot'
    ? 'bg-theme-warning/10 text-theme-warning'
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
  const [detailPool, setDetailPool] = useState<InstancePoolSummary | null>(
    null,
  );
  const [actioningPoolId, setActioningPoolId] = useState<string | null>(null);
  const [deletePool, setDeletePool] = useState<InstancePoolSummary | null>(
    null,
  );
  const [deleting, setDeleting] = useState(false);

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

  const handleConfirmDelete = useCallback(async () => {
    if (!deletePool) return;
    setDeleting(true);
    try {
      await instancePoolsApi.destroy(deletePool.id);
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
                return (
                  <tr
                    key={pool.id}
                    className="hover:bg-theme-surface-hover transition-colors duration-200"
                    data-testid={`pool-row-${pool.id}`}
                  >
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
                      <span
                        className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${statusPillClasses(
                          pool.status,
                        )}`}
                      >
                        {pool.status}
                      </span>
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
                        <div className="text-xs text-theme-warning mt-0.5">
                          deficit: {pool.deficit}
                        </div>
                      )}
                    </td>
                    <td className="py-3 px-4 text-sm text-theme-secondary">
                      <div className="font-mono">
                        <span className="text-theme-success">
                          {pool.ready_count} ready
                        </span>
                        <span className="text-theme-tertiary"> · </span>
                        <span>{pool.warming_count} warming</span>
                        <span className="text-theme-tertiary"> · </span>
                        <span>{pool.claimed_count} claimed</span>
                      </div>
                      {pool.errored_count > 0 && (
                        <div className="text-xs text-theme-danger mt-0.5">
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
                            onClick={() => handleReplenish(pool)}
                            disabled={
                              isActioning || pool.status === 'archived'
                            }
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
                            <Droplet className="w-4 h-4 text-theme-warning" />
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
                            <Trash2 className="w-4 h-4 text-theme-danger" />
                          </Button>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </ResponsiveListContainer.Desktop>

        <ResponsiveListContainer.Mobile>
          {filteredPools.map((pool) => {
            const isActioning = actioningPoolId === pool.id;
            return (
              <div
                key={pool.id}
                className="p-4"
                data-testid={`pool-card-${pool.id}`}
              >
                <div className="flex items-start justify-between mb-3">
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
                      <span
                        className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${statusPillClasses(
                          pool.status,
                        )}`}
                      >
                        {pool.status}
                      </span>
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
                    <span className="text-theme-success">
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
                      <span className="text-theme-danger">
                        {pool.errored_count}
                      </span>
                    </div>
                  )}
                </div>

                {canControl && (
                  <div className="flex items-center gap-2">
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => handleReplenish(pool)}
                      disabled={isActioning || pool.status === 'archived'}
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
                      <Droplet className="w-4 h-4 mr-1 text-theme-warning" />
                      Drain
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => setDeletePool(pool)}
                      disabled={isActioning || pool.status === 'archived'}
                      aria-label={`Delete ${pool.name}`}
                    >
                      <Trash2 className="w-4 h-4 mr-1 text-theme-danger" />
                      Delete
                    </Button>
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
            Archive pool <strong>{deletePool?.name}</strong>? The reaper will
            stop replenishing and ready members will be terminated. Already-
            claimed instances keep running until the operator terminates them.
          </p>
          {deletePool && deletePool.claimed_count > 0 && (
            <div className="p-3 bg-theme-warning/10 border border-theme-warning/30 rounded-lg">
              <p className="text-theme-warning text-sm">
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
    [form, validate, onCreated, addNotification],
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
        <div>
          <label
            htmlFor="pool-name"
            className="block text-sm font-medium text-theme-primary mb-1"
          >
            Name <span className="text-theme-danger">*</span>
          </label>
          <input
            id="pool-name"
            type="text"
            value={form.name}
            onChange={(e) => handleChange('name', e.target.value)}
            placeholder="web-warm-pool"
            disabled={submitting}
            className={`w-full px-3 py-2 rounded-lg border bg-theme-surface text-theme-primary placeholder-theme-secondary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary ${
              errors.name ? 'border-theme-danger' : 'border-theme'
            }`}
          />
          {errors.name && (
            <p className="mt-1 text-sm text-theme-danger">{errors.name}</p>
          )}
        </div>

        <div>
          <label
            htmlFor="pool-description"
            className="block text-sm font-medium text-theme-primary mb-1"
          >
            Description
          </label>
          <textarea
            id="pool-description"
            value={form.description}
            onChange={(e) => handleChange('description', e.target.value)}
            placeholder="Optional — what's this pool for?"
            rows={2}
            disabled={submitting}
            className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary placeholder-theme-secondary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary resize-none"
          />
        </div>

        <div>
          <label
            htmlFor="pool-template"
            className="block text-sm font-medium text-theme-primary mb-1"
          >
            Node template <span className="text-theme-danger">*</span>
          </label>
          <select
            id="pool-template"
            value={form.node_template_id}
            onChange={(e) =>
              handleChange('node_template_id', e.target.value)
            }
            disabled={submitting || loadingTemplates}
            className={`w-full px-3 py-2 rounded-lg border bg-theme-surface text-theme-primary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary ${
              errors.node_template_id ? 'border-theme-danger' : 'border-theme'
            }`}
          >
            <option value="">
              {loadingTemplates ? 'Loading templates...' : 'Select a template'}
            </option>
            {templates.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
                {t.node_platform_name ? ` (${t.node_platform_name})` : ''}
              </option>
            ))}
          </select>
          {errors.node_template_id && (
            <p className="mt-1 text-sm text-theme-danger">
              {errors.node_template_id}
            </p>
          )}
        </div>

        <div className="grid grid-cols-3 gap-3">
          <div>
            <label
              htmlFor="pool-min"
              className="block text-sm font-medium text-theme-primary mb-1"
            >
              Min size
            </label>
            <input
              id="pool-min"
              type="number"
              min={0}
              value={form.min_size}
              onChange={(e) =>
                handleChange('min_size', Number(e.target.value))
              }
              disabled={submitting}
              className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary"
            />
          </div>
          <div>
            <label
              htmlFor="pool-target"
              className="block text-sm font-medium text-theme-primary mb-1"
            >
              Target size <span className="text-theme-danger">*</span>
            </label>
            <input
              id="pool-target"
              type="number"
              min={0}
              value={form.target_size}
              onChange={(e) =>
                handleChange('target_size', Number(e.target.value))
              }
              disabled={submitting}
              className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary"
            />
          </div>
          <div>
            <label
              htmlFor="pool-max"
              className="block text-sm font-medium text-theme-primary mb-1"
            >
              Max size
            </label>
            <input
              id="pool-max"
              type="number"
              min={0}
              value={form.max_size}
              onChange={(e) =>
                handleChange('max_size', Number(e.target.value))
              }
              disabled={submitting}
              className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary"
            />
          </div>
        </div>
        {errors.sizing && (
          <p className="text-sm text-theme-danger">{errors.sizing}</p>
        )}

        <div>
          <label
            htmlFor="pool-lifecycle"
            className="block text-sm font-medium text-theme-primary mb-1"
          >
            Lifecycle class
          </label>
          <select
            id="pool-lifecycle"
            value={form.lifecycle_class}
            onChange={(e) =>
              handleChange(
                'lifecycle_class',
                e.target.value as 'ephemeral' | 'spot',
              )
            }
            disabled={submitting}
            className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary"
          >
            <option value="ephemeral">
              ephemeral — short-lived, predictable cost
            </option>
            <option value="spot">spot — interruptible, cost-optimized</option>
          </select>
        </div>
      </form>
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
            <span
              className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${statusPillClasses(
                pool.status,
              )}`}
            >
              {pool.status}
            </span>
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
            <div className="mt-2 text-xs text-theme-warning">
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
            <div className="p-3 bg-theme-success/10 rounded-lg">
              <div className="text-xs text-theme-success">ready</div>
              <div className="font-mono text-theme-primary">
                {pool.ready_count}
              </div>
            </div>
            <div className="p-3 bg-theme-info/10 rounded-lg">
              <div className="text-xs text-theme-info">warming</div>
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
            <div className="p-3 bg-theme-danger/10 rounded-lg">
              <div className="text-xs text-theme-danger">errored</div>
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
