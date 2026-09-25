import React, { useCallback, useMemo, useState } from 'react';
import { Boxes, Plus, Search, Filter } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { logger } from '@/shared/utils/logger';
import { useInfiniteResourceList } from '@system/features/system/hooks/useResourceList';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import { isPendingApproval } from '@system/features/system/services/api/helpers';
import { pendingApprovalNotice } from '@system/features/system/utils/pendingApproval';
import {
  instancePoolsApi,
  summariseRecycle,
  type InstancePoolListFilters,
  type InstancePoolSummary,
} from '@system/features/system/components/instance-pools/instancePoolsApi';
import { InstancePoolRow } from '@system/features/system/components/instance-pools/InstancePoolRow';
import { InstancePoolCard } from '@system/features/system/components/instance-pools/InstancePoolCard';
import { CreatePoolModal } from '@system/features/system/components/instance-pools/CreatePoolModal';
import { EditPoolModal } from '@system/features/system/components/instance-pools/EditPoolModal';
import { PoolDetailModal } from '@system/features/system/components/instance-pools/PoolDetailModal';

// =============================================================================
// Page
//
// C12 (fe-dupes.md / component-status-plane campaign): the list, the three
// modals (Create/Edit/Detail), the desktop row and the mobile card used to
// all live in this one 1873-line file. Split onto section components under
// features/system/components/instance-pools/ — types, the inline API client,
// and the lifecycle-pill helper live in instancePoolsApi.ts; the two row
// renderers and three modals are their own files. This page is now purely
// the orchestrator: list state, mutation handlers, and composing the pieces.
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
              {filteredPools.map((pool) => (
                <InstancePoolRow
                  key={pool.id}
                  pool={pool}
                  expanded={expandedPoolIds.has(pool.id)}
                  isActioning={actioningPoolId === pool.id}
                  canControl={canControl}
                  onToggleExpand={toggleExpanded}
                  onView={handleViewPool}
                  onEdit={setEditPool}
                  onReplenish={handleReplenish}
                  onDrain={handleDrain}
                  onRecycleStale={handleRecycleStale}
                  onDelete={setDeletePool}
                />
              ))}
            </tbody>
          </table>
        </ResponsiveListContainer.Desktop>

        <ResponsiveListContainer.Mobile>
          {filteredPools.map((pool) => (
            <InstancePoolCard
              key={pool.id}
              pool={pool}
              expanded={expandedPoolIds.has(pool.id)}
              isActioning={actioningPoolId === pool.id}
              canControl={canControl}
              onToggleExpand={toggleExpanded}
              onView={handleViewPool}
              onEdit={setEditPool}
              onReplenish={handleReplenish}
              onDrain={handleDrain}
              onRecycleStale={handleRecycleStale}
              onDelete={setDeletePool}
            />
          ))}
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

export default InstancePoolsPage;

