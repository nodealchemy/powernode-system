import React, { useCallback, useRef, useState } from 'react';
import {
  Server,
  Search,
  Eye,
  Edit,
  Trash2,
  Power,
  PowerOff,
  MoreVertical,
  Filter,
  ChevronRight,
  ChevronDown
} from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { systemApi } from '@system/features/system/services/systemApi';
import { useInfiniteResourceList } from '@system/features/system/hooks/useResourceList';
import { useSystemWebSocket } from '@system/features/system/hooks/useSystemWebSocket';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import type { SystemNode } from '@system/features/system/types/system.types';

interface NodeListFilters {
  search: string;
  enabled: 'all' | 'enabled' | 'disabled';
}

interface NodeListProps {
  /** Callback when view node is clicked */
  onView?: (node: SystemNode) => void;
  /** Callback when edit node is clicked */
  onEdit?: (node: SystemNode) => void;
  /** Callback when delete node is clicked */
  onDelete?: (nodeId: string) => void;
  /** Callback when create node is clicked */
  onCreate?: () => void;
  /** Callback when toggle enabled is clicked */
  onToggleEnabled?: (node: SystemNode) => void;
  /** Key to trigger refresh - change this value to refetch nodes */
  refreshKey?: number;
  /** Optional className */
  className?: string;
}

/**
 * NodeList - Displays a list of system nodes with search, filtering, and pagination
 *
 * Uses platform patterns:
 * - Permission-based access control via usePermissions
 * - Theme-aware styling with theme classes
 * - Responsive design (desktop table, mobile cards)
 */
export const NodeList: React.FC<NodeListProps> = ({
  onView,
  onEdit,
  onDelete,
  onCreate,
  onToggleEnabled,
  refreshKey,
  className = ''
}) => {
  const { hasPermission } = usePermissions();

  const canCreate = hasPermission('system.nodes.create');
  const canUpdate = hasPermission('system.nodes.update');
  const canDelete = hasPermission('system.nodes.delete');

  const {
    items: nodes,
    filteredItems: filteredNodes,
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
    dropdownOpen,
    setDropdownOpen,
  } = useInfiniteResourceList<SystemNode, NodeListFilters>({
    fetcher: ({ page, per_page, filters }) => {
      const params: { page: number; per_page: number; enabled?: boolean } = { page, per_page };
      if (filters.enabled !== 'all') {
        params.enabled = filters.enabled === 'enabled';
      }
      return systemApi.getNodes(params).then(d => ({ items: d.nodes, meta: d.meta }));
    },
    initialFilters: { search: '', enabled: 'all' },
    perPage: 20,
    // `enabled` is server-side (refetch on change); `search` is client-side
    // (no per-keystroke API churn).
    serverFilterKey: (f) => JSON.stringify({ enabled: f.enabled }),
    clientFilterFn: (node, f) => {
      if (!f.search) return true;
      const q = f.search.toLowerCase();
      return (
        node.name.toLowerCase().includes(q) ||
        !!node.description?.toLowerCase().includes(q) ||
        !!node.public_address?.toLowerCase().includes(q)
      );
    },
    errorMessage: 'Failed to load nodes',
  });

  // Live updates: when the SystemChannel pushes a node update, merge it
  // into the in-memory accumulator.
  useSystemWebSocket({
    onNodeUpdate: (n) => upsertItem(n as unknown as SystemNode),
  });

  // Refetch on parent's refreshKey toggle (kept for parent-driven refresh,
  // e.g. after a create/edit modal closes).
  React.useEffect(() => {
    if (refreshKey !== undefined && refreshKey > 0) {
      handleRefresh();
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refreshKey]);

  // Click-to-expand state — Set<id> so multiple rows can be open at once.
  const [expandedNodeIds, setExpandedNodeIds] = useState<Set<string>>(new Set());
  const toggleExpanded = useCallback((id: string) => {
    setExpandedNodeIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) { next.delete(id); } else { next.add(id); }
      return next;
    });
  }, []);

  // Arm-and-confirm pattern for destructive actions (delete). First click
  // sets a 5s armed window with a visual cue; second click within window
  // fires. Keyed by `${action}:${nodeId}` so distinct nodes arm separately.
  const [armedAction, setArmedAction] = useState<string | null>(null);
  const armActionTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const armOrFire = useCallback((key: string, fire: () => void) => {
    if (armedAction === key) {
      if (armActionTimeoutRef.current) clearTimeout(armActionTimeoutRef.current);
      setArmedAction(null);
      fire();
      return;
    }
    setArmedAction(key);
    if (armActionTimeoutRef.current) clearTimeout(armActionTimeoutRef.current);
    armActionTimeoutRef.current = setTimeout(() => setArmedAction(null), 5000);
  }, [armedAction]);

  return (
    <ResponsiveListContainer
      loading={loading}
      refreshing={refreshing}
      totalCount={nodes.length}
      filteredCount={filteredNodes.length}
      onRefresh={handleRefresh}
      onLoadMore={loadMore}
      hasMore={hasMore}
      loadingMore={loadingMore}
      serverTotalCount={totalCount}
      className={className}
      emptyState={{
        icon: Server,
        title: 'No nodes configured',
        description: 'Create your first infrastructure node to start managing your systems',
        action: canCreate && onCreate ? { label: 'Create Node', onClick: onCreate } : undefined,
      }}
    >
      <ResponsiveListContainer.Filters>
        <div className="flex-1">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <input
              type="text"
              placeholder="Search nodes..."
              value={filters.search}
              onChange={(e) => setFilters({ ...filters, search: e.target.value })}
              className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
            />
          </div>
        </div>

        <div className="sm:w-48">
          <div className="relative">
            <Filter className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <select
              value={filters.enabled}
              onChange={(e) => setFilters({ ...filters, enabled: e.target.value as NodeListFilters['enabled'] })}
              className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus appearance-none"
            >
              <option value="all">All Status</option>
              <option value="enabled">Enabled</option>
              <option value="disabled">Disabled</option>
            </select>
          </div>
        </div>

      </ResponsiveListContainer.Filters>

      <ResponsiveListContainer.Desktop>
        <table className="w-full">
            <thead>
              <tr className="bg-theme-background border-b border-theme">
                <th className="w-8 py-3 px-2"></th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Node</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Template</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Status</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Instances</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Address</th>
                <th className="text-right py-3 px-4 font-medium text-theme-primary">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-theme">
              {filteredNodes.map((node) => {
                const expanded = expandedNodeIds.has(node.id);
                const deleteArmed = armedAction === `delete:${node.id}`;
                return (
                <React.Fragment key={node.id}>
                <tr className="hover:bg-theme-surface-hover transition-colors duration-200">
                  <td className="py-3 px-2 align-middle">
                    <button
                      type="button"
                      onClick={() => toggleExpanded(node.id)}
                      className="p-1 text-theme-secondary hover:text-theme-primary rounded transition-colors"
                      title={expanded ? 'Collapse details' : 'Expand details'}
                    >
                      {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                    </button>
                  </td>
                  <td className="py-3 px-4">
                    <div>
                      <div className="flex items-center gap-2">
                        <Server className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                        <span
                          className="font-medium text-theme-primary hover:text-theme-link cursor-pointer"
                          onClick={() => onView?.(node)}
                        >
                          {node.name}
                        </span>
                      </div>
                      {node.description && (
                        <p className="text-sm text-theme-secondary mt-1 truncate max-w-xs">
                          {node.description}
                        </p>
                      )}
                    </div>
                  </td>

                  <td className="py-3 px-4">
                    <span className="text-theme-secondary">
                      {node.node_template_name || '-'}
                    </span>
                  </td>

                  <td className="py-3 px-4">
                    <Badge
                      variant={node.enabled ? 'success' : 'secondary'}
                      dot
                      pulse={node.enabled}
                    >
                      {node.enabled ? 'Enabled' : 'Disabled'}
                    </Badge>
                  </td>

                  <td className="py-3 px-4">
                    <span className="text-theme-primary font-medium">
                      {node.instance_count || 0}
                    </span>
                  </td>

                  <td className="py-3 px-4">
                    <span className="text-theme-secondary font-mono text-sm">
                      {node.public_address || '-'}
                    </span>
                  </td>

                  <td className="py-3 px-4">
                    <div className="flex items-center justify-end gap-2">
                      <Button
                        variant="outline"
                        size="sm"
                        onClick={() => onView?.(node)}
                        title="View Details"
                      >
                        <Eye className="w-4 h-4" />
                      </Button>

                      {canUpdate && onEdit && (
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => onEdit(node)}
                          title="Edit Node"
                        >
                          <Edit className="w-4 h-4" />
                        </Button>
                      )}

                      {canUpdate && onToggleEnabled && (
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => onToggleEnabled(node)}
                          title={node.enabled ? 'Disable Node' : 'Enable Node'}
                        >
                          {node.enabled ? (
                            <PowerOff className="w-4 h-4 text-theme-warning" />
                          ) : (
                            <Power className="w-4 h-4 text-theme-success" />
                          )}
                        </Button>
                      )}

                      {canDelete && onDelete && (
                        <Button
                          variant={deleteArmed ? 'danger' : 'outline'}
                          size="sm"
                          onClick={() => armOrFire(`delete:${node.id}`, () => onDelete(node.id))}
                          title={deleteArmed ? 'Click again to confirm delete' : 'Delete Node'}
                        >
                          {deleteArmed ? <span className="text-xs px-1">Confirm?</span> : <Trash2 className="w-4 h-4 text-theme-error" />}
                        </Button>
                      )}
                    </div>
                  </td>
                </tr>
                {expanded && (
                  <tr className="bg-theme-background border-b border-theme">
                    <td></td>
                    <td colSpan={6} className="py-3 px-4">
                      <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
                        {node.description && (
                          <div className="col-span-full">
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Description</label>
                            <p className="text-theme-primary">{node.description}</p>
                          </div>
                        )}
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Status</label>
                          <p className="text-theme-primary">{node.status || (node.enabled ? 'enabled' : 'disabled')}</p>
                        </div>
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Instances</label>
                          <p className="text-theme-primary">{node.running_instances_count ?? 0} running of {node.instance_count ?? 0} total</p>
                        </div>
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Public IP Allocation</label>
                          <p className="text-theme-primary">{node.allocate_public_ip ? 'Enabled' : 'Disabled'}</p>
                        </div>
                        {node.public_address && (
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Public Address</label>
                            <p className="text-theme-primary font-mono text-xs">{node.public_address}</p>
                          </div>
                        )}
                        {node.node_template_name && (
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Template</label>
                            <p className="text-theme-primary">{node.node_template_name}</p>
                          </div>
                        )}
                        {node.worker_id && (
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Worker</label>
                            <p className="text-theme-primary font-mono text-xs truncate" title={node.worker_id}>{node.worker_id}</p>
                          </div>
                        )}
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Node ID</label>
                          <p className="text-theme-primary font-mono text-xs truncate" title={node.id}>{node.id}</p>
                        </div>
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                          <p className="text-theme-primary text-xs">{new Date(node.created_at).toLocaleString()}</p>
                        </div>
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Updated</label>
                          <p className="text-theme-primary text-xs">{new Date(node.updated_at).toLocaleString()}</p>
                        </div>
                        {node.config && Object.keys(node.config).length > 0 && (
                          <div className="col-span-full">
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Config</label>
                            <pre className="text-xs text-theme-primary bg-theme-surface-hover p-2 rounded border border-theme font-mono whitespace-pre-wrap break-all max-h-48 overflow-auto">{JSON.stringify(node.config, null, 2)}</pre>
                          </div>
                        )}
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
        {filteredNodes.map((node) => {
          const expanded = expandedNodeIds.has(node.id);
          const deleteArmed = armedAction === `delete:${node.id}`;
          return (
            <div key={node.id} className="p-4">
              {/* Header */}
              <div className="flex items-start justify-between mb-3">
                <div className="flex items-start gap-2 flex-1 min-w-0">
                  <button
                    type="button"
                    onClick={() => toggleExpanded(node.id)}
                    className="p-1 -ml-1 mt-0.5 text-theme-secondary hover:text-theme-primary rounded transition-colors flex-shrink-0"
                    title={expanded ? 'Collapse details' : 'Expand details'}
                  >
                    {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                  </button>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 mb-1">
                      <Server className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                      <span
                        className="font-medium text-theme-primary hover:text-theme-link cursor-pointer truncate"
                        onClick={() => onView?.(node)}
                      >
                        {node.name}
                      </span>
                    </div>
                    {node.description && (
                      <p className="text-sm text-theme-secondary truncate">
                        {node.description}
                      </p>
                    )}
                  </div>
                </div>

                <div className="relative">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={(e) => {
                      e.stopPropagation();
                      setDropdownOpen(dropdownOpen === node.id ? null : node.id);
                    }}
                  >
                    <MoreVertical className="w-4 h-4" />
                  </Button>

                  {dropdownOpen === node.id && (
                    <div className="absolute right-0 mt-1 w-48 bg-theme-surface border border-theme rounded-lg shadow-lg z-10">
                      <div className="py-1">
                        <button
                          onClick={() => {
                            onView?.(node);
                            setDropdownOpen(null);
                          }}
                          className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                        >
                          <Eye className="w-4 h-4" />
                          View Details
                        </button>
                        {canUpdate && onEdit && (
                          <button
                            onClick={() => {
                              onEdit(node);
                              setDropdownOpen(null);
                            }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Edit className="w-4 h-4" />
                            Edit Node
                          </button>
                        )}
                        {canUpdate && onToggleEnabled && (
                          <button
                            onClick={() => {
                              onToggleEnabled(node);
                              setDropdownOpen(null);
                            }}
                            className={`w-full text-left px-4 py-2 text-sm hover:bg-theme-surface-hover flex items-center gap-2 ${
                              node.enabled ? 'text-theme-warning' : 'text-theme-success'
                            }`}
                          >
                            {node.enabled ? (
                              <>
                                <PowerOff className="w-4 h-4" />
                                Disable Node
                              </>
                            ) : (
                              <>
                                <Power className="w-4 h-4" />
                                Enable Node
                              </>
                            )}
                          </button>
                        )}
                        {canDelete && onDelete && (
                          <button
                            onClick={() => {
                              armOrFire(`delete:${node.id}`, () => {
                                onDelete(node.id);
                                setDropdownOpen(null);
                              });
                            }}
                            className={`w-full text-left px-4 py-2 text-sm hover:bg-theme-surface-hover flex items-center gap-2 ${
                              deleteArmed ? 'text-theme-error font-medium' : 'text-theme-error'
                            }`}
                          >
                            <Trash2 className="w-4 h-4" />
                            {deleteArmed ? 'Click again to confirm' : 'Delete Node'}
                          </button>
                        )}
                      </div>
                    </div>
                  )}
                </div>
              </div>

              {/* Stats */}
              <div className="grid grid-cols-3 gap-4 mb-3">
                <div className="text-center">
                  <Badge
                    variant={node.enabled ? 'success' : 'secondary'}
                    size="xs"
                    dot
                  >
                    {node.enabled ? 'Enabled' : 'Disabled'}
                  </Badge>
                </div>

                <div className="text-center">
                  <div className="text-sm font-medium text-theme-primary">
                    {node.instance_count || 0}
                  </div>
                  <div className="text-xs text-theme-secondary">Instances</div>
                </div>

                <div className="text-center">
                  <div className="text-sm text-theme-secondary truncate">
                    {node.node_template_name || '-'}
                  </div>
                  <div className="text-xs text-theme-tertiary">Template</div>
                </div>
              </div>

              {/* Address */}
              {node.public_address && (
                <div className="text-xs text-theme-secondary font-mono">
                  Address: {node.public_address}
                </div>
              )}

              {/* Expanded body */}
              {expanded && (
                <div className="mt-3 pt-3 border-t border-theme grid grid-cols-2 gap-3 text-sm">
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Status</label>
                    <p className="text-theme-primary">{node.status || (node.enabled ? 'enabled' : 'disabled')}</p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Running</label>
                    <p className="text-theme-primary">{node.running_instances_count ?? 0} / {node.instance_count ?? 0}</p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Public IP</label>
                    <p className="text-theme-primary">{node.allocate_public_ip ? 'Allocated' : 'Disabled'}</p>
                  </div>
                  {node.worker_id && (
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Worker</label>
                      <p className="text-theme-primary font-mono text-xs truncate" title={node.worker_id}>{node.worker_id}</p>
                    </div>
                  )}
                  <div className="col-span-2">
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Node ID</label>
                    <p className="text-theme-primary font-mono text-xs truncate" title={node.id}>{node.id}</p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                    <p className="text-theme-primary text-xs">{new Date(node.created_at).toLocaleString()}</p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Updated</label>
                    <p className="text-theme-primary text-xs">{new Date(node.updated_at).toLocaleString()}</p>
                  </div>
                  {node.config && Object.keys(node.config).length > 0 && (
                    <div className="col-span-2">
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Config</label>
                      <pre className="text-xs text-theme-primary bg-theme-surface-hover p-2 rounded border border-theme font-mono whitespace-pre-wrap break-all max-h-48 overflow-auto">{JSON.stringify(node.config, null, 2)}</pre>
                    </div>
                  )}
                </div>
              )}
            </div>
          );
          })}
      </ResponsiveListContainer.Mobile>
    </ResponsiveListContainer>
  );
};
