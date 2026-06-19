import React, { useCallback, useState } from 'react';
import {
  Activity,
  Search,
  Filter,
  Eye,
  Clock,
  CheckCircle,
  XCircle,
  AlertCircle,
  Pause,
  Play,
  MoreVertical,
  ChevronRight,
  ChevronDown
} from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { EntityLink } from '@/shared/components/entity';
import { systemApi } from '@system/features/system/services/systemApi';
import { resolveOperableType } from '@system/features/system/entityRegistry';
import { useResourceList } from '@system/features/system/hooks/useResourceList';
import { useSystemWebSocket } from '@system/features/system/hooks/useSystemWebSocket';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import type { SystemTask } from '@system/features/system/types/system.types';

interface OperationListFilters {
  search: string;
  status: 'all' | 'pending' | 'scheduled' | 'running' | 'complete' | 'failed' | 'aborted';
}

interface OperationListProps {
  onView?: (operation: SystemTask) => void;
  className?: string;
}

const statusLabels: Record<string, string> = {
  pending: 'Pending',
  scheduled: 'Scheduled',
  running: 'Running',
  complete: 'Complete',
  failed: 'Failed',
  aborted: 'Aborted',
  cancelled: 'Cancelled'
};

const statusColors: Record<string, 'info' | 'success' | 'warning' | 'danger' | 'secondary' | 'primary'> = {
  pending: 'warning',
  scheduled: 'info',
  running: 'primary',
  complete: 'success',
  failed: 'danger',
  aborted: 'secondary',
  cancelled: 'secondary'
};

const StatusIcon: React.FC<{ status: string }> = ({ status }) => {
  switch (status) {
    case 'pending':
    case 'scheduled':
      return <Clock className="w-4 h-4" />;
    case 'running':
      return <Play className="w-4 h-4" />;
    case 'complete':
      return <CheckCircle className="w-4 h-4" />;
    case 'failed':
      return <XCircle className="w-4 h-4" />;
    case 'aborted':
    case 'cancelled':
      return <Pause className="w-4 h-4" />;
    default:
      return <AlertCircle className="w-4 h-4" />;
  }
};

/**
 * Render a task's polymorphic `operable` as a link to the referenced object.
 * Resolves the backend `operable_type` (e.g. "System::Node" / "node") to a
 * registered entity type; when both the type and id resolve, an `<EntityLink>`
 * opens that object's detail surface — otherwise it degrades to the raw type
 * label as plain text (or "—" when absent).
 */
const OperableReference: React.FC<{ operation: SystemTask }> = ({ operation }) => {
  if (!operation.operable_type) {
    return <span className="text-sm text-theme-tertiary">—</span>;
  }
  const t = resolveOperableType(operation.operable_type);
  if (t && operation.operable_id) {
    return (
      <EntityLink
        type={t}
        id={operation.operable_id}
        label={operation.operable_type}
        className="text-sm"
      />
    );
  }
  return <span className="text-sm text-theme-secondary">{operation.operable_type}</span>;
};

/**
 * OperationList - Displays a list of system operations with filtering
 */
export const OperationList: React.FC<OperationListProps> = ({
  onView,
  className = ''
}) => {
  const {
    items: operations,
    filteredItems: filteredOperations,
    loading,
    refreshing,
    filters,
    setFilters,
    refresh: handleRefresh,
    upsertItem,
    patchItem,
    dropdownOpen,
    setDropdownOpen,
  } = useResourceList<SystemTask, OperationListFilters>({
    fetcher: () => systemApi.getTasks().then(d => d.tasks),
    initialFilters: { search: '', status: 'all' },
    filterFn: (operation, f) => {
      if (f.search) {
        const searchLower = f.search.toLowerCase();
        if (
          !operation.command.toLowerCase().includes(searchLower) &&
          !operation.description?.toLowerCase().includes(searchLower) &&
          !operation.operable_type?.toLowerCase().includes(searchLower)
        ) {
          return false;
        }
      }
      if (f.status !== 'all' && operation.status !== f.status) {
        return false;
      }
      return true;
    },
    errorMessage: 'Failed to load operations',
  });

  // Live updates from SystemChannel — task creates/updates upsert into the
  // list, progress ticks patch the existing row in place.
  useSystemWebSocket({
    onOperationUpdate: (op) => upsertItem(op as unknown as SystemTask),
    onOperationProgress: (p) => patchItem(p.operation_id, {
      status: p.status,
      progress: p.progress,
      description: p.description,
    } as Partial<SystemTask>),
  });

  const formatDateTime = (dateString?: string) => {
    if (!dateString) return '—';
    return new Date(dateString).toLocaleString();
  };

  const formatDuration = (operation: SystemTask) => {
    if (!operation.started_at) return '—';
    const start = new Date(operation.started_at).getTime();
    const end = operation.completed_at
      ? new Date(operation.completed_at).getTime()
      : Date.now();
    const duration = Math.floor((end - start) / 1000);

    if (duration < 60) return `${duration}s`;
    if (duration < 3600) return `${Math.floor(duration / 60)}m ${duration % 60}s`;
    return `${Math.floor(duration / 3600)}h ${Math.floor((duration % 3600) / 60)}m`;
  };

  // Click-to-expand state — Set<id> so multiple rows can be open at once.
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  const toggleExpanded = useCallback((id: string) => {
    setExpandedIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) { next.delete(id); } else { next.add(id); }
      return next;
    });
  }, []);

  return (
    <ResponsiveListContainer
      loading={loading}
      refreshing={refreshing}
      totalCount={operations.length}
      filteredCount={filteredOperations.length}
      onRefresh={handleRefresh}
      className={className}
      emptyState={{
        icon: Activity,
        title: 'No operations',
        description: 'Operations will appear here when system tasks are executed',
      }}
    >
      <ResponsiveListContainer.Filters>
        <div className="flex-1">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <input
              type="text"
              placeholder="Search operations..."
              value={filters.search}
              onChange={(e) => setFilters({ ...filters, search: e.target.value })}
              className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
            />
          </div>
        </div>

        <div className="sm:w-40">
          <div className="relative">
            <Filter className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <select
              value={filters.status}
              onChange={(e) => setFilters({ ...filters, status: e.target.value as OperationListFilters['status'] })}
              className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus appearance-none"
            >
              <option value="all">All Status</option>
              <option value="pending">Pending</option>
              <option value="scheduled">Scheduled</option>
              <option value="running">Running</option>
              <option value="complete">Complete</option>
              <option value="failed">Failed</option>
              <option value="aborted">Aborted</option>
            </select>
          </div>
        </div>
      </ResponsiveListContainer.Filters>

      <ResponsiveListContainer.Desktop>
        <table className="w-full">
          <thead>
            <tr className="bg-theme-background border-b border-theme">
              <th className="w-8 py-3 px-2"></th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Operation</th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Resource</th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Status</th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Progress</th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Duration</th>
              <th className="text-right py-3 px-4 font-medium text-theme-primary">Actions</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-theme">
            {filteredOperations.map((operation) => {
              const expanded = expandedIds.has(operation.id);
              return (
              <React.Fragment key={operation.id}>
              <tr className="hover:bg-theme-surface-hover transition-colors duration-200">
                <td className="py-3 px-2 align-middle">
                  <button
                    type="button"
                    onClick={() => toggleExpanded(operation.id)}
                    className="p-1 text-theme-secondary hover:text-theme-primary rounded transition-colors"
                    title={expanded ? 'Collapse details' : 'Expand details'}
                  >
                    {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                  </button>
                </td>
                <td className="py-3 px-4">
                  <div>
                    <div className="flex items-center gap-2">
                      <Activity className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                      <span
                        className="font-medium text-theme-primary hover:text-theme-link cursor-pointer"
                        onClick={() => onView?.(operation)}
                      >
                        {operation.command}
                      </span>
                    </div>
                    {operation.description && (
                      <p className="text-sm text-theme-secondary mt-1 truncate max-w-xs">
                        {operation.description}
                      </p>
                    )}
                  </div>
                </td>

                <td className="py-3 px-4">
                  <OperableReference operation={operation} />
                </td>

                <td className="py-3 px-4">
                  <Badge variant={statusColors[operation.status] || 'secondary'}>
                    <StatusIcon status={operation.status} />
                    <span className="ml-1">{statusLabels[operation.status] || operation.status}</span>
                  </Badge>
                </td>

                <td className="py-3 px-4">
                  {operation.status === 'running' ? (
                    <div className="flex items-center gap-2">
                      <div className="w-24 bg-theme-background rounded-full h-2">
                        <div
                          className="bg-theme-info-bg h-2 rounded-full transition-all duration-300"
                          style={{ width: `${operation.progress || 0}%` }}
                        />
                      </div>
                      <span className="text-sm text-theme-secondary">
                        {operation.progress || 0}%
                      </span>
                    </div>
                  ) : (
                    <span className="text-sm text-theme-tertiary">—</span>
                  )}
                </td>

                <td className="py-3 px-4">
                  <span className="text-sm text-theme-secondary">
                    {formatDuration(operation)}
                  </span>
                </td>

                <td className="py-3 px-4">
                  <div className="flex items-center justify-end gap-2">
                    <Button variant="outline" size="sm" onClick={() => onView?.(operation)} title="View Details">
                      <Eye className="w-4 h-4" />
                    </Button>
                  </div>
                </td>
              </tr>
              {expanded && (
                <tr className="bg-theme-background border-b border-theme">
                  <td></td>
                  <td colSpan={6} className="py-3 px-4">
                    <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
                      {operation.description && (
                        <div className="col-span-full">
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Description</label>
                          <p className="text-theme-primary">{operation.description}</p>
                        </div>
                      )}
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Status</label>
                        <p className="text-theme-primary">{statusLabels[operation.status] || operation.status}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Progress</label>
                        <p className="text-theme-primary">{operation.progress || 0}%</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Duration</label>
                        <p className="text-theme-primary">{formatDuration(operation)}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Resource</label>
                        <OperableReference operation={operation} />
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Exclusive</label>
                        <p className="text-theme-primary">{operation.exclusive ? 'Yes' : 'No'}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Initiated By</label>
                        <p className="text-theme-primary">{operation.initiated_by_name || 'System'}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Scheduled</label>
                        <p className="text-theme-primary text-xs">{formatDateTime(operation.scheduled_at)}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Started</label>
                        <p className="text-theme-primary text-xs">{formatDateTime(operation.started_at)}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Completed</label>
                        <p className="text-theme-primary text-xs">{formatDateTime(operation.completed_at)}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Operation ID</label>
                        <p className="text-theme-primary font-mono text-xs truncate" title={operation.id}>{operation.id}</p>
                      </div>
                      {operation.error_message && (
                        <div className="col-span-full">
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Error</label>
                          <pre className="text-xs text-theme-error-fg whitespace-pre-wrap font-mono">{operation.error_message}</pre>
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
        {filteredOperations.map((operation) => {
          const expanded = expandedIds.has(operation.id);
          return (
          <div key={operation.id} className="p-4">
            <div className="flex items-start justify-between mb-3">
              <div className="flex items-start gap-2 flex-1 min-w-0">
                <button
                  type="button"
                  onClick={() => toggleExpanded(operation.id)}
                  className="p-1 -ml-1 mt-0.5 text-theme-secondary hover:text-theme-primary rounded transition-colors flex-shrink-0"
                  title={expanded ? 'Collapse details' : 'Expand details'}
                >
                  {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                </button>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 mb-1">
                    <Activity className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                    <span
                      className="font-medium text-theme-primary hover:text-theme-link cursor-pointer truncate"
                      onClick={() => onView?.(operation)}
                    >
                      {operation.command}
                    </span>
                  </div>
                  {operation.description && (
                    <p className="text-sm text-theme-secondary truncate">{operation.description}</p>
                  )}
                </div>
              </div>

              <div className="relative">
                <Button
                  variant="outline"
                  size="sm"
                  onClick={(e) => {
                    e.stopPropagation();
                    setDropdownOpen(dropdownOpen === operation.id ? null : operation.id);
                  }}
                >
                  <MoreVertical className="w-4 h-4" />
                </Button>

                {dropdownOpen === operation.id && (
                  <div className="absolute right-0 mt-1 w-48 bg-theme-surface border border-theme rounded-lg shadow-lg z-10">
                    <div className="py-1">
                      <button
                        onClick={() => { onView?.(operation); setDropdownOpen(null); }}
                        className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                      >
                        <Eye className="w-4 h-4" />
                        View Details
                      </button>
                    </div>
                  </div>
                )}
              </div>
            </div>

            <div className="flex items-center justify-between">
              <Badge variant={statusColors[operation.status] || 'secondary'} size="xs">
                <StatusIcon status={operation.status} />
                <span className="ml-1">{statusLabels[operation.status] || operation.status}</span>
              </Badge>
              <span className="text-xs text-theme-tertiary">
                {formatDateTime(operation.started_at || operation.created_at)}
              </span>
            </div>

            {operation.status === 'running' && (
              <div className="mt-3">
                <div className="w-full bg-theme-background rounded-full h-2">
                  <div
                    className="bg-theme-info-bg h-2 rounded-full transition-all duration-300"
                    style={{ width: `${operation.progress || 0}%` }}
                  />
                </div>
                <p className="text-xs text-theme-secondary mt-1 text-right">
                  {operation.progress || 0}% complete
                </p>
              </div>
            )}

            {expanded && (
              <div className="mt-3 pt-3 border-t border-theme grid grid-cols-2 gap-3 text-sm">
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Resource</label>
                  <OperableReference operation={operation} />
                </div>
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Duration</label>
                  <p className="text-theme-primary">{formatDuration(operation)}</p>
                </div>
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Initiated By</label>
                  <p className="text-theme-primary">{operation.initiated_by_name || 'System'}</p>
                </div>
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Exclusive</label>
                  <p className="text-theme-primary">{operation.exclusive ? 'Yes' : 'No'}</p>
                </div>
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Started</label>
                  <p className="text-theme-primary text-xs">{formatDateTime(operation.started_at)}</p>
                </div>
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Completed</label>
                  <p className="text-theme-primary text-xs">{formatDateTime(operation.completed_at)}</p>
                </div>
                <div className="col-span-2">
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Operation ID</label>
                  <p className="text-theme-primary font-mono text-xs truncate" title={operation.id}>{operation.id}</p>
                </div>
                {operation.error_message && (
                  <div className="col-span-2">
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Error</label>
                    <pre className="text-xs text-theme-error-fg whitespace-pre-wrap font-mono">{operation.error_message}</pre>
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

export default OperationList;
