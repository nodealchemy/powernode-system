import React from 'react';
import {
  Package,
  Search,
  Eye,
  Edit,
  Trash2,
  Globe,
  Lock,
  MoreVertical,
  Filter,
  FileCode,
  Link
} from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { systemApi } from '@system/features/system/services/systemApi';
import { useResourceList } from '@system/features/system/hooks/useResourceList';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import type { SystemPuppetModule } from '@system/features/system/types/system.types';

interface PuppetModuleListFilters {
  search: string;
  enabled: 'all' | 'enabled' | 'disabled';
}

interface PuppetModuleListProps {
  onView?: (module: SystemPuppetModule) => void;
  onEdit?: (module: SystemPuppetModule) => void;
  onDelete?: (moduleId: string) => void;
  onCreate?: () => void;
  className?: string;
}

/**
 * PuppetModuleList - Displays a list of Puppet modules
 */
export const PuppetModuleList: React.FC<PuppetModuleListProps> = ({
  onView,
  onEdit,
  onDelete,
  onCreate,
  className = ''
}) => {
  const { hasPermission } = usePermissions();

  const canCreate = hasPermission('system.puppet.create');
  const canUpdate = hasPermission('system.puppet.update');
  const canDelete = hasPermission('system.puppet.delete');

  const {
    items: puppetModules,
    filteredItems: filteredModules,
    loading,
    refreshing,
    filters,
    setFilters,
    refresh: handleRefresh,
    dropdownOpen,
    setDropdownOpen,
  } = useResourceList<SystemPuppetModule, PuppetModuleListFilters>({
    fetcher: () => systemApi.getPuppetModules().then(d => d.puppetModules),
    initialFilters: { search: '', enabled: 'all' },
    filterFn: (mod, f) => {
      if (f.search) {
        const searchLower = f.search.toLowerCase();
        if (
          !mod.name.toLowerCase().includes(searchLower) &&
          !mod.description?.toLowerCase().includes(searchLower) &&
          !mod.author?.toLowerCase().includes(searchLower) &&
          !mod.forge_name?.toLowerCase().includes(searchLower)
        ) {
          return false;
        }
      }
      if (f.enabled !== 'all') {
        if (f.enabled === 'enabled' && !mod.enabled) return false;
        if (f.enabled === 'disabled' && mod.enabled) return false;
      }
      return true;
    },
    errorMessage: 'Failed to load Puppet modules',
  });

  return (
    <ResponsiveListContainer
      loading={loading}
      refreshing={refreshing}
      totalCount={puppetModules.length}
      filteredCount={filteredModules.length}
      onRefresh={handleRefresh}
      className={className}
      emptyState={{
        icon: Package,
        title: 'No Puppet modules',
        description: 'Add Puppet modules for configuration management',
        action: canCreate && onCreate ? { label: 'Add Puppet Module', onClick: onCreate } : undefined,
      }}
    >
      <ResponsiveListContainer.Filters>
        <div className="flex-1">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <input
              type="text"
              placeholder="Search modules..."
              value={filters.search}
              onChange={(e) => setFilters({ ...filters, search: e.target.value })}
              className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
            />
          </div>
        </div>

        <div className="sm:w-32">
          <div className="relative">
            <Filter className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <select
              value={filters.enabled}
              onChange={(e) => setFilters({ ...filters, enabled: e.target.value as PuppetModuleListFilters['enabled'] })}
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
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Module</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Version</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Author</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Resources</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Status</th>
                <th className="text-right py-3 px-4 font-medium text-theme-primary">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-theme">
              {filteredModules.map((module) => (
                <tr key={module.id} className="hover:bg-theme-surface-hover transition-colors duration-200">
                  <td className="py-3 px-4">
                    <div>
                      <div className="flex items-center gap-2">
                        <Package className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                        <span
                          className="font-medium text-theme-primary hover:text-theme-link cursor-pointer"
                          onClick={() => onView?.(module)}
                        >
                          {module.name}
                        </span>
                      </div>
                      {module.forge_name && (
                        <p className="text-xs text-theme-tertiary mt-1 font-mono">
                          {module.forge_name}
                        </p>
                      )}
                      {module.description && (
                        <p className="text-sm text-theme-secondary mt-1 truncate max-w-xs">
                          {module.description}
                        </p>
                      )}
                    </div>
                  </td>

                  <td className="py-3 px-4">
                    <span className="text-sm text-theme-primary">
                      {module.version || '—'}
                    </span>
                  </td>

                  <td className="py-3 px-4">
                    <span className="text-sm text-theme-secondary">
                      {module.author || '—'}
                    </span>
                  </td>

                  <td className="py-3 px-4">
                    <div className="flex items-center gap-4 text-sm text-theme-secondary">
                      <div className="flex items-center gap-1" title="Resources">
                        <FileCode className="w-4 h-4" />
                        <span>{module.resource_count || 0}</span>
                      </div>
                      <div className="flex items-center gap-1" title="Assigned Modules">
                        <Link className="w-4 h-4" />
                        <span>{module.assigned_modules_count || 0}</span>
                      </div>
                    </div>
                  </td>

                  <td className="py-3 px-4">
                    <div className="flex items-center gap-2">
                      <Badge variant={module.enabled ? 'success' : 'secondary'} dot pulse={module.enabled}>
                        {module.enabled ? 'Enabled' : 'Disabled'}
                      </Badge>
                      {module.public ? (
                        <Badge variant="info" size="xs">
                          <Globe className="w-3 h-3 mr-1" />
                          Public
                        </Badge>
                      ) : (
                        <Badge variant="secondary" size="xs">
                          <Lock className="w-3 h-3 mr-1" />
                          Private
                        </Badge>
                      )}
                    </div>
                  </td>

                  <td className="py-3 px-4">
                    <div className="flex items-center justify-end gap-2">
                      <div className="relative">
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={(e) => {
                            e.stopPropagation();
                            setDropdownOpen(dropdownOpen === module.id ? null : module.id);
                          }}
                        >
                          <MoreVertical className="w-4 h-4" />
                        </Button>

                        {dropdownOpen === module.id && (
                          <div className="absolute right-0 mt-1 w-48 bg-theme-surface border border-theme rounded-lg shadow-lg z-10">
                            <div className="py-1">
                              <button
                                onClick={() => { onView?.(module); setDropdownOpen(null); }}
                                className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                              >
                                <Eye className="w-4 h-4" />
                                View Details
                              </button>
                              {canUpdate && onEdit && (
                                <button
                                  onClick={() => { onEdit(module); setDropdownOpen(null); }}
                                  className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                                >
                                  <Edit className="w-4 h-4" />
                                  Edit Module
                                </button>
                              )}
                              {canDelete && onDelete && (
                                <button
                                  onClick={() => { onDelete(module.id); setDropdownOpen(null); }}
                                  className="w-full text-left px-4 py-2 text-sm text-theme-error hover:bg-theme-surface-hover flex items-center gap-2"
                                >
                                  <Trash2 className="w-4 h-4" />
                                  Delete Module
                                </button>
                              )}
                            </div>
                          </div>
                        )}
                      </div>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
      </ResponsiveListContainer.Desktop>

      <ResponsiveListContainer.Mobile>
        {filteredModules.map((module) => (
            <div key={module.id} className="p-4">
              <div className="flex items-start justify-between mb-3">
                <div className="flex items-center gap-2">
                  <Package className="w-5 h-5 text-theme-tertiary flex-shrink-0" />
                  <div>
                    <h3
                      className="font-medium text-theme-primary hover:text-theme-link cursor-pointer"
                      onClick={() => onView?.(module)}
                    >
                      {module.name}
                    </h3>
                    {module.forge_name && (
                      <p className="text-xs text-theme-tertiary font-mono">
                        {module.forge_name}
                      </p>
                    )}
                    {module.version && (
                      <p className="text-sm text-theme-secondary">v{module.version}</p>
                    )}
                  </div>
                </div>

                <div className="relative">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={(e) => {
                      e.stopPropagation();
                      setDropdownOpen(dropdownOpen === module.id ? null : module.id);
                    }}
                  >
                    <MoreVertical className="w-4 h-4" />
                  </Button>

                  {dropdownOpen === module.id && (
                    <div className="absolute right-0 mt-1 w-48 bg-theme-surface border border-theme rounded-lg shadow-lg z-10">
                      <div className="py-1">
                        <button
                          onClick={() => { onView?.(module); setDropdownOpen(null); }}
                          className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                        >
                          <Eye className="w-4 h-4" />
                          View Details
                        </button>
                        {canUpdate && onEdit && (
                          <button
                            onClick={() => { onEdit(module); setDropdownOpen(null); }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Edit className="w-4 h-4" />
                            Edit Module
                          </button>
                        )}
                        {canDelete && onDelete && (
                          <button
                            onClick={() => { onDelete(module.id); setDropdownOpen(null); }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-error hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Trash2 className="w-4 h-4" />
                            Delete Module
                          </button>
                        )}
                      </div>
                    </div>
                  )}
                </div>
              </div>

              {module.description && (
                <p className="text-sm text-theme-secondary mb-3 line-clamp-2">
                  {module.description}
                </p>
              )}

              <div className="flex items-center gap-4 text-sm text-theme-secondary mb-3">
                <div className="flex items-center gap-1">
                  <FileCode className="w-4 h-4" />
                  <span>{module.resource_count || 0} resources</span>
                </div>
                <div className="flex items-center gap-1">
                  <Link className="w-4 h-4" />
                  <span>{module.assigned_modules_count || 0} assigned</span>
                </div>
              </div>

              <div className="flex items-center gap-2">
                <Badge variant={module.enabled ? 'success' : 'secondary'} dot pulse={module.enabled}>
                  {module.enabled ? 'Enabled' : 'Disabled'}
                </Badge>
                <Badge variant={module.public ? 'info' : 'secondary'}>
                  {module.public ? (
                    <><Globe className="w-3 h-3 mr-1" />Public</>
                  ) : (
                    <><Lock className="w-3 h-3 mr-1" />Private</>
                  )}
                </Badge>
              </div>
            </div>
          ))}
      </ResponsiveListContainer.Mobile>
    </ResponsiveListContainer>
  );
};

export default PuppetModuleList;
