import React from 'react';
import {
  Cpu,
  Search,
  Eye,
  Edit,
  Trash2,
  Globe,
  Lock,
  MoreVertical,
  Filter
} from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { systemApi } from '@system/features/system/services/systemApi';
import { useResourceList } from '@system/features/system/hooks/useResourceList';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import type { SystemNodeArchitecture } from '@system/features/system/types/system.types';

interface ArchitectureListFilters {
  search: string;
  enabled: 'all' | 'enabled' | 'disabled';
}

interface ArchitectureListProps {
  onView?: (architecture: SystemNodeArchitecture) => void;
  onEdit?: (architecture: SystemNodeArchitecture) => void;
  onDelete?: (architectureId: string) => void;
  onCreate?: () => void;
  className?: string;
}

/**
 * ArchitectureList - Displays a list of node architectures with search, filtering, and pagination
 */
export const ArchitectureList: React.FC<ArchitectureListProps> = ({
  onView,
  onEdit,
  onDelete,
  onCreate,
  className = ''
}) => {
  const { hasPermission } = usePermissions();

  const canCreate = hasPermission('system.architectures.create');
  const canUpdate = hasPermission('system.architectures.update');
  const canDelete = hasPermission('system.architectures.delete');

  const {
    items: architectures,
    filteredItems: filteredArchitectures,
    loading,
    refreshing,
    filters,
    setFilters,
    refresh: handleRefresh,
    dropdownOpen,
    setDropdownOpen,
  } = useResourceList<SystemNodeArchitecture, ArchitectureListFilters>({
    fetcher: () => systemApi.getArchitectures(),
    initialFilters: { search: '', enabled: 'all' },
    filterFn: (arch, f) => {
      if (f.search) {
        const searchLower = f.search.toLowerCase();
        if (
          !arch.name.toLowerCase().includes(searchLower) &&
          !arch.description?.toLowerCase().includes(searchLower)
        ) {
          return false;
        }
      }
      if (f.enabled !== 'all') {
        if (f.enabled === 'enabled' && !arch.enabled) return false;
        if (f.enabled === 'disabled' && arch.enabled) return false;
      }
      return true;
    },
    errorMessage: 'Failed to load architectures',
  });

  return (
    <ResponsiveListContainer
      loading={loading}
      refreshing={refreshing}
      totalCount={architectures.length}
      filteredCount={filteredArchitectures.length}
      onRefresh={handleRefresh}
      className={className}
      emptyState={{
        icon: Cpu,
        title: 'No architectures configured',
        description: 'Create your first node architecture to define hardware configurations',
        action: canCreate && onCreate ? { label: 'Create Architecture', onClick: onCreate } : undefined,
      }}
    >
      <ResponsiveListContainer.Filters>
        <div className="flex-1">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <input
              type="text"
              placeholder="Search architectures..."
              value={filters.search}
              onChange={(e) => setFilters({ ...filters, search: e.target.value })}
              className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
            />
          </div>
        </div>

        <div className="sm:w-36">
          <div className="relative">
            <Filter className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <select
              value={filters.enabled}
              onChange={(e) => setFilters({ ...filters, enabled: e.target.value as ArchitectureListFilters['enabled'] })}
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
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Architecture</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Kernel Options</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Visibility</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Status</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Platforms</th>
                <th className="text-right py-3 px-4 font-medium text-theme-primary">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-theme">
              {filteredArchitectures.map((architecture) => (
                <tr key={architecture.id} className="hover:bg-theme-surface-hover transition-colors duration-200">
                  <td className="py-3 px-4">
                    <div>
                      <div className="flex items-center gap-2">
                        <Cpu className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                        <span
                          className="font-medium text-theme-primary hover:text-theme-link cursor-pointer"
                          onClick={() => onView?.(architecture)}
                        >
                          {architecture.name}
                        </span>
                      </div>
                      {architecture.description && (
                        <p className="text-sm text-theme-secondary mt-1 truncate max-w-xs">
                          {architecture.description}
                        </p>
                      )}
                    </div>
                  </td>

                  <td className="py-3 px-4">
                    <span className="text-theme-secondary text-sm font-mono">
                      {architecture.kernel_options || '-'}
                    </span>
                  </td>

                  <td className="py-3 px-4">
                    <Badge variant={architecture.public ? 'info' : 'secondary'}>
                      {architecture.public ? (
                        <><Globe className="w-3 h-3 mr-1" />Public</>
                      ) : (
                        <><Lock className="w-3 h-3 mr-1" />Private</>
                      )}
                    </Badge>
                  </td>

                  <td className="py-3 px-4">
                    <Badge variant={architecture.enabled ? 'success' : 'secondary'} dot pulse={architecture.enabled}>
                      {architecture.enabled ? 'Enabled' : 'Disabled'}
                    </Badge>
                  </td>

                  <td className="py-3 px-4">
                    <span className="text-theme-primary font-medium">
                      {architecture.platform_count || 0}
                    </span>
                  </td>

                  <td className="py-3 px-4">
                    <div className="flex items-center justify-end gap-2">
                      <Button variant="outline" size="sm" onClick={() => onView?.(architecture)} title="View Details">
                        <Eye className="w-4 h-4" />
                      </Button>

                      {canUpdate && onEdit && (
                        <Button variant="outline" size="sm" onClick={() => onEdit(architecture)} title="Edit Architecture">
                          <Edit className="w-4 h-4" />
                        </Button>
                      )}

                      {canDelete && onDelete && (
                        <Button variant="outline" size="sm" onClick={() => onDelete(architecture.id)} title="Delete Architecture">
                          <Trash2 className="w-4 h-4 text-theme-error" />
                        </Button>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
      </ResponsiveListContainer.Desktop>

      <ResponsiveListContainer.Mobile>
        {filteredArchitectures.map((architecture) => (
            <div key={architecture.id} className="p-4">
              <div className="flex items-start justify-between mb-3">
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 mb-1">
                    <Cpu className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                    <span
                      className="font-medium text-theme-primary hover:text-theme-link cursor-pointer truncate"
                      onClick={() => onView?.(architecture)}
                    >
                      {architecture.name}
                    </span>
                  </div>
                  {architecture.description && (
                    <p className="text-sm text-theme-secondary truncate">{architecture.description}</p>
                  )}
                </div>

                <div className="relative">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={(e) => {
                      e.stopPropagation();
                      setDropdownOpen(dropdownOpen === architecture.id ? null : architecture.id);
                    }}
                  >
                    <MoreVertical className="w-4 h-4" />
                  </Button>

                  {dropdownOpen === architecture.id && (
                    <div className="absolute right-0 mt-1 w-48 bg-theme-surface border border-theme rounded-lg shadow-lg z-10">
                      <div className="py-1">
                        <button
                          onClick={() => { onView?.(architecture); setDropdownOpen(null); }}
                          className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                        >
                          <Eye className="w-4 h-4" />
                          View Details
                        </button>
                        {canUpdate && onEdit && (
                          <button
                            onClick={() => { onEdit(architecture); setDropdownOpen(null); }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Edit className="w-4 h-4" />
                            Edit Architecture
                          </button>
                        )}
                        {canDelete && onDelete && (
                          <button
                            onClick={() => { onDelete(architecture.id); setDropdownOpen(null); }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-error hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Trash2 className="w-4 h-4" />
                            Delete Architecture
                          </button>
                        )}
                      </div>
                    </div>
                  )}
                </div>
              </div>

              <div className="grid grid-cols-3 gap-4">
                <div className="text-center">
                  <Badge variant={architecture.public ? 'info' : 'secondary'} size="xs">
                    {architecture.public ? 'Public' : 'Private'}
                  </Badge>
                </div>
                <div className="text-center">
                  <Badge variant={architecture.enabled ? 'success' : 'secondary'} size="xs" dot>
                    {architecture.enabled ? 'Enabled' : 'Disabled'}
                  </Badge>
                </div>
                <div className="text-center">
                  <div className="text-sm font-medium text-theme-primary">{architecture.platform_count || 0}</div>
                  <div className="text-xs text-theme-secondary">Platforms</div>
                </div>
              </div>
            </div>
          ))}
      </ResponsiveListContainer.Mobile>
    </ResponsiveListContainer>
  );
};

export default ArchitectureList;
