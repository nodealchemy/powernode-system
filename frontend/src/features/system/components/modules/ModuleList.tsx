import React, { useCallback, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  Package,
  Search,
  Plus,
  Eye,
  Edit,
  Trash2,
  Globe,
  Lock,
  MoreVertical,
  Filter,
  FolderTree,
  GitBranch,
  Power,
  ShieldCheck,
  ChevronRight,
  ChevronDown,
  X
} from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { EntityLink } from '@/shared/components/entity';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useQueryParamFilter } from '@/shared/hooks/useQueryParamFilter';
import { systemApi } from '@system/features/system/services/systemApi';
import { useResourceList } from '@system/features/system/hooks/useResourceList';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import type { SystemNodeModule, SystemNodeModuleCategory } from '@system/features/system/types/system.types';

interface ModuleListFilters {
  search: string;
  variety: 'all' | 'config' | 'instance' | 'subscription';
  enabled: 'all' | 'enabled' | 'disabled';
  categoryId: string | null;
  /** Deep-link filter — seeded from ?parent_module_id=<id> (dependents). */
  parentModuleId: string | null;
  /** Deep-link filter — seeded from ?platform=<node_platform_id>. */
  platformId: string | null;
}

interface ModuleListProps {
  onView?: (module: SystemNodeModule) => void;
  onEdit?: (module: SystemNodeModule) => void;
  onDelete?: (moduleId: string) => void;
  onCreate?: () => void;
  onCategoryCreate?: () => void;
  onCategoryEdit?: (category: SystemNodeModuleCategory) => void;
  onCategoryDelete?: (categoryId: string) => void;
  className?: string;
}

const varietyLabels: Record<string, string> = {
  config: 'Config',
  instance: 'Instance',
  subscription: 'Subscription'
};

const varietyColors: Record<string, 'info' | 'success' | 'warning' | 'primary'> = {
  config: 'info',
  instance: 'success',
  subscription: 'warning'
};

/**
 * ModuleList - Displays a list of node modules with category sidebar and filtering
 */
export const ModuleList: React.FC<ModuleListProps> = ({
  onView,
  onEdit,
  onDelete,
  onCreate,
  onCategoryCreate,
  onCategoryEdit,
  onCategoryDelete,
  className = ''
}) => {
  const { hasPermission } = usePermissions();
  const navigate = useNavigate();

  const canCreate = hasPermission('system.modules.create');
  const canUpdate = hasPermission('system.modules.update');
  const canDelete = hasPermission('system.modules.delete');

  // Deep-link: ?parent_module_id=<id> shows a module's dependents;
  // ?platform=<id> shows modules on one platform.
  const { seedFilters, hasActiveParamFilter, clearParamFilters } =
    useQueryParamFilter<ModuleListFilters>({
      parent_module_id: 'parentModuleId',
      platform: 'platformId',
    });

  // Categories load alongside modules but live as their own collection.
  // Tracked outside useResourceList because it manages a single resource.
  const [categories, setCategories] = useState<SystemNodeModuleCategory[]>([]);
  const [showCategorySidebar, setShowCategorySidebar] = useState(true);

  const {
    items: modules,
    filteredItems: filteredModules,
    loading,
    refreshing,
    filters,
    setFilters,
    refresh: handleRefresh,
    dropdownOpen,
    setDropdownOpen,
  } = useResourceList<SystemNodeModule, ModuleListFilters>({
    fetcher: async () => {
      const [modulesData, categoriesData] = await Promise.all([
        systemApi.getModules(),
        systemApi.getModuleCategories(),
      ]);
      setCategories(categoriesData);
      return modulesData.modules;
    },
    initialFilters: seedFilters({
      search: '', variety: 'all', enabled: 'all', categoryId: null,
      parentModuleId: null, platformId: null,
    }),
    filterFn: (mod, f) => {
      if (f.search) {
        const searchLower = f.search.toLowerCase();
        // Search now also matches the parent module name so operators
        // can find dependant overrides by typing their parent's name.
        if (
          !mod.name.toLowerCase().includes(searchLower) &&
          !mod.description?.toLowerCase().includes(searchLower) &&
          !mod.parent_module_name?.toLowerCase().includes(searchLower)
        ) {
          return false;
        }
      }
      if (f.variety !== 'all' && mod.variety !== f.variety) return false;
      if (f.enabled !== 'all') {
        if (f.enabled === 'enabled' && !mod.enabled) return false;
        if (f.enabled === 'disabled' && mod.enabled) return false;
      }
      if (f.categoryId && mod.category_id !== f.categoryId) return false;
      if (f.parentModuleId && mod.parent_module_id !== f.parentModuleId) return false;
      if (f.platformId && mod.node_platform_id !== f.platformId) return false;
      return true;
    },
    errorMessage: 'Failed to load modules',
  });

  // Clearing a deep-link chip resets BOTH the URL params and the seeded
  // filter state (useResourceList reads initialFilters only once). Both
  // deep-link dimensions clear together since they share one chip surface.
  const clearDeepLinkFilters = useCallback(() => {
    setFilters((prev) => ({ ...prev, parentModuleId: null, platformId: null }));
    clearParamFilters();
  }, [setFilters, clearParamFilters]);

  // Click-to-expand state — Set<id> so multiple rows can be open at once.
  // Mirrors the disclosure pattern in NodeList/TemplateList; the expansion
  // shows the module's OWN spec / lifecycle / version inline (no modal
  // round-trip) while cross-references render as EntityLinks.
  const [expandedModuleIds, setExpandedModuleIds] = useState<Set<string>>(new Set());
  const toggleExpanded = useCallback((id: string) => {
    setExpandedModuleIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) { next.delete(id); } else { next.add(id); }
      return next;
    });
  }, []);

  return (
    <div className={`flex gap-6 ${className}`}>
      {/* Category Sidebar */}
      {showCategorySidebar && (
        <div className="w-64 flex-shrink-0">
          <div className="bg-theme-surface rounded-lg border border-theme p-4">
            <div className="flex items-center justify-between mb-4">
              <div className="flex items-center gap-2">
                <FolderTree className="w-5 h-5 text-theme-info-fg" />
                <h3 className="font-medium text-theme-primary">Categories</h3>
              </div>
              {canCreate && onCategoryCreate && (
                <Button
                  variant="outline"
                  size="sm"
                  onClick={onCategoryCreate}
                  title="Add Category"
                >
                  <Plus className="w-3 h-3" />
                </Button>
              )}
            </div>
            <div className="space-y-1">
              <button
                onClick={() => setFilters(prev => ({ ...prev, categoryId: null }))}
                className={`w-full text-left px-3 py-2 rounded-lg text-sm transition-colors ${
                  filters.categoryId === null
                    ? 'bg-theme-info-fg text-white'
                    : 'text-theme-secondary hover:bg-theme-surface-hover'
                }`}
              >
                All Categories
                <span className="float-right text-xs opacity-75">
                  {modules.length}
                </span>
              </button>
              {categories.length === 0 ? (
                <div className="text-center py-4 text-theme-tertiary text-sm">
                  No categories defined
                </div>
              ) : (
                categories.map(category => {
                  const count = modules.filter(m => m.category_id === category.id).length;
                  return (
                    <div
                      key={category.id}
                      className="group flex items-center"
                    >
                      <button
                        onClick={() => setFilters(prev => ({ ...prev, categoryId: category.id }))}
                        className={`flex-1 text-left px-3 py-2 rounded-lg text-sm transition-colors ${
                          filters.categoryId === category.id
                            ? 'bg-theme-info-fg text-white'
                            : 'text-theme-secondary hover:bg-theme-surface-hover'
                        }`}
                        style={{ paddingLeft: `${(category.depth + 1) * 12}px` }}
                      >
                        {category.name}
                        <span className="float-right text-xs opacity-75">
                          {count}
                        </span>
                      </button>
                      {/* Category actions (show on hover) */}
                      {canUpdate && (
                        <div className="opacity-0 group-hover:opacity-100 transition-opacity flex items-center gap-1 px-1">
                          {onCategoryEdit && (
                            <button
                              onClick={(e) => {
                                e.stopPropagation();
                                onCategoryEdit(category);
                              }}
                              className="p-1 text-theme-secondary hover:text-theme-primary rounded"
                              title="Edit category"
                            >
                              <Edit className="w-3 h-3" />
                            </button>
                          )}
                          {onCategoryDelete && count === 0 && (
                            <button
                              onClick={(e) => {
                                e.stopPropagation();
                                onCategoryDelete(category.id);
                              }}
                              className="p-1 text-theme-secondary hover:text-theme-error-fg rounded"
                              title="Delete category"
                            >
                              <Trash2 className="w-3 h-3" />
                            </button>
                          )}
                        </div>
                      )}
                    </div>
                  );
                })
              )}
            </div>
          </div>
        </div>
      )}

      <div className="flex-1">
        <ResponsiveListContainer
          loading={loading}
          refreshing={refreshing}
          totalCount={modules.length}
          filteredCount={filteredModules.length}
          onRefresh={handleRefresh}
          emptyState={{
            icon: Package,
            title: 'No modules configured',
            description: 'Create modules to define node configuration packages',
            action: canCreate && onCreate ? { label: 'Create Module', onClick: onCreate } : undefined,
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

            <div className="sm:w-36">
              <select
                value={filters.variety}
                onChange={(e) => setFilters({ ...filters, variety: e.target.value as ModuleListFilters['variety'] })}
                className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus appearance-none"
              >
                <option value="all">All Types</option>
                <option value="config">Config</option>
                <option value="instance">Instance</option>
                <option value="subscription">Subscription</option>
              </select>
            </div>

            <div className="sm:w-32">
              <div className="relative">
                <Filter className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
                <select
                  value={filters.enabled}
                  onChange={(e) => setFilters({ ...filters, enabled: e.target.value as ModuleListFilters['enabled'] })}
                  className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus appearance-none"
                >
                  <option value="all">All Status</option>
                  <option value="enabled">Enabled</option>
                  <option value="disabled">Disabled</option>
                </select>
              </div>
            </div>

            <Button
              variant="outline"
              onClick={() => setShowCategorySidebar(!showCategorySidebar)}
              className="sm:w-auto"
              title={showCategorySidebar ? 'Hide categories' : 'Show categories'}
            >
              <FolderTree className="w-4 h-4" />
            </Button>

            {hasActiveParamFilter && (filters.parentModuleId || filters.platformId) && (
              <div className="flex items-center">
                <button
                  type="button"
                  onClick={clearDeepLinkFilters}
                  className="inline-flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm bg-theme-info-bg border border-theme-info-border text-theme-info-fg hover:bg-theme-info-bg transition-colors"
                  title="Clear deep-link filter"
                >
                  <span>{filters.parentModuleId ? 'Filtered to dependents' : 'Filtered by platform'}</span>
                  <X className="w-3.5 h-3.5" />
                </button>
              </div>
            )}
          </ResponsiveListContainer.Filters>

          <ResponsiveListContainer.Desktop>
            <table className="w-full">
              <thead>
                <tr className="bg-theme-background border-b border-theme">
                  <th className="w-8 py-3 px-2"></th>
                  <th className="text-left py-3 px-4 font-medium text-theme-primary">Module</th>
                  <th className="text-left py-3 px-4 font-medium text-theme-primary">Type</th>
                  <th className="text-left py-3 px-4 font-medium text-theme-primary">Category</th>
                  <th className="text-left py-3 px-4 font-medium text-theme-primary">Visibility</th>
                  <th className="text-left py-3 px-4 font-medium text-theme-primary">Status</th>
                  <th className="text-right py-3 px-4 font-medium text-theme-primary">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-theme">
                {filteredModules.map((module) => {
                  const expanded = expandedModuleIds.has(module.id);
                  return (
                  <React.Fragment key={module.id}>
                  <tr className="hover:bg-theme-surface-hover transition-colors duration-200">
                    <td className="py-3 px-2 align-middle">
                      <button
                        type="button"
                        onClick={() => toggleExpanded(module.id)}
                        className="p-1 text-theme-secondary hover:text-theme-primary rounded transition-colors"
                        title={expanded ? 'Collapse details' : 'Expand details'}
                      >
                        {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                      </button>
                    </td>
                    <td className="py-3 px-4">
                      <div>
                        <div className="flex items-center gap-2 flex-wrap">
                          <Package className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                          <span
                            className="font-medium text-theme-primary hover:text-theme-link cursor-pointer"
                            onClick={() => onView?.(module)}
                          >
                            {module.name}
                          </span>
                          {module.priority > 0 && (
                            <span className="text-xs text-theme-tertiary">
                              P{module.priority}
                            </span>
                          )}
                          {/* Operator-relevant flags surface as small icons
                              next to the name. Hover titles explain what
                              each one means; no extra columns needed. */}
                          {module.lock_spec && (
                            <Lock className="w-3.5 h-3.5 text-theme-warning-fg" aria-label="Spec locked" />
                          )}
                          {module.reboot_required && (
                            <Power className="w-3.5 h-3.5 text-theme-warning-fg" aria-label="Reboot required on attach/detach" />
                          )}
                          {module.protected_spec && module.protected_spec.length > 0 && (
                            <ShieldCheck className="w-3.5 h-3.5 text-theme-info-fg" aria-label="Declares protected_spec" />
                          )}
                        </div>
                        {module.dependant && (
                          <p className="text-xs text-theme-info-fg mt-0.5 flex items-center gap-1">
                            <GitBranch className="w-3 h-3" />
                            dependant of{' '}
                            {module.parent_module_id ? (
                              <EntityLink
                                type="node_module"
                                id={module.parent_module_id}
                                label={module.parent_module_name ?? 'parent'}
                                className="text-xs"
                              />
                            ) : (
                              <code className="text-theme-info-fg">{module.parent_module_name ?? 'parent'}</code>
                            )}
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
                      <Badge variant={varietyColors[module.variety] || 'secondary'}>
                        {varietyLabels[module.variety] || module.variety}
                      </Badge>
                    </td>

                    <td className="py-3 px-4">
                      {module.category_id ? (
                        <EntityLink
                          type="node_module_category"
                          id={module.category_id}
                          label={module.category_name || module.category_id}
                          className="text-sm"
                        />
                      ) : (
                        <span className="text-sm text-theme-secondary">
                          {module.category_name || '—'}
                        </span>
                      )}
                    </td>

                    <td className="py-3 px-4">
                      <Badge variant={module.public ? 'info' : 'secondary'}>
                        {module.public ? (
                          <><Globe className="w-3 h-3 mr-1" />Public</>
                        ) : (
                          <><Lock className="w-3 h-3 mr-1" />Private</>
                        )}
                      </Badge>
                    </td>

                    <td className="py-3 px-4">
                      <Badge variant={module.enabled ? 'success' : 'secondary'} dot pulse={module.enabled}>
                        {module.enabled ? 'Enabled' : 'Disabled'}
                      </Badge>
                    </td>

                    <td className="py-3 px-4">
                      <div className="flex items-center justify-end gap-2">
                        <Button variant="outline" size="sm" onClick={() => onView?.(module)} title="View Details">
                          <Eye className="w-4 h-4" />
                        </Button>

                        {canUpdate && onEdit && (
                          <Button variant="outline" size="sm" onClick={() => onEdit(module)} title="Edit Module">
                            <Edit className="w-4 h-4" />
                          </Button>
                        )}

                        {canDelete && onDelete && (
                          <Button variant="outline" size="sm" onClick={() => onDelete(module.id)} title="Delete Module">
                            <Trash2 className="w-4 h-4 text-theme-error-fg" />
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
                          {module.description && (
                            <div className="col-span-full">
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Description</label>
                              <p className="text-theme-primary">{module.description}</p>
                            </div>
                          )}
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Type</label>
                            <p className="text-theme-primary">{varietyLabels[module.variety] || module.variety}</p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Status</label>
                            <p className="text-theme-primary">{module.enabled ? 'Enabled' : 'Disabled'}</p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Visibility</label>
                            <p className="text-theme-primary">{module.public ? 'Public' : 'Private'}</p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Priority</label>
                            <p className="text-theme-primary">P{module.priority}</p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Category</label>
                            <p className="text-theme-primary">
                              {module.category_id ? (
                                <EntityLink type="node_module_category" id={module.category_id} label={module.category_name || module.category_id} />
                              ) : (
                                module.category_name || '—'
                              )}
                            </p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Platform</label>
                            <p className="text-theme-primary">
                              {module.node_platform_id ? (
                                <EntityLink type="node_platform" id={module.node_platform_id} label={module.node_platform_name || module.node_platform_id} />
                              ) : (
                                module.node_platform_name || '—'
                              )}
                            </p>
                          </div>
                          {module.dependant && (
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Dependant Of</label>
                              <p className="text-theme-primary">
                                {module.parent_module_id ? (
                                  <EntityLink type="node_module" id={module.parent_module_id} label={module.parent_module_name ?? 'parent'} />
                                ) : (
                                  module.parent_module_name ?? '—'
                                )}
                              </p>
                            </div>
                          )}
                          {/* Lifecycle hooks — mirror the NodeDetailModal Modules tab */}
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">init_start</label>
                            <code className="text-theme-primary text-xs">{module.init_start || <span className="italic text-theme-tertiary">unset</span>}</code>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">init_stop</label>
                            <code className="text-theme-primary text-xs">{module.init_stop || <span className="italic text-theme-tertiary">unset</span>}</code>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">init_restart</label>
                            <code className="text-theme-primary text-xs">{module.init_restart || <span className="italic text-theme-tertiary">unset</span>}</code>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Lifecycle Flags</label>
                            <p className="text-theme-primary text-xs">
                              {module.reboot_required ? 'reboot required on attach/detach' : 'hot-swap allowed'}
                              {module.lock_spec ? ' · spec locked' : ''}
                            </p>
                          </div>
                          {/* Spec footprint — counts of each glob spec the module owns */}
                          <div className="col-span-full">
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Spec Footprint</label>
                            <div className="flex flex-wrap gap-2">
                              <Badge variant="default" size="xs">file_spec: {module.file_spec?.length ?? 0}</Badge>
                              <Badge variant="default" size="xs">package_spec: {module.package_spec?.length ?? 0}</Badge>
                              <Badge variant="default" size="xs">mask: {module.mask?.length ?? 0}</Badge>
                              {module.protected_spec && module.protected_spec.length > 0 && (
                                <Badge variant="warning" size="xs">protected_spec: {module.protected_spec.length}</Badge>
                              )}
                              {module.dependency_spec && module.dependency_spec.length > 0 && (
                                <Badge variant="info" size="xs">dependency_spec: {module.dependency_spec.length}</Badge>
                              )}
                            </div>
                          </div>
                          {/* Latest version snapshot — populated once published */}
                          {module.latest_version && (
                            <div className="col-span-full">
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Latest Version</label>
                              <div className="flex flex-wrap items-center gap-2 text-xs">
                                <span className="text-theme-primary font-medium">{module.latest_version.version_number || '—'}</span>
                                {module.latest_version.promotion_state && (
                                  <Badge variant="default" size="xs">{module.latest_version.promotion_state}</Badge>
                                )}
                                {module.latest_version.oci_digest && (
                                  <code className="text-theme-tertiary truncate max-w-xs" title={module.latest_version.oci_digest}>{module.latest_version.oci_digest}</code>
                                )}
                              </div>
                            </div>
                          )}
                          {(module.dependents_count ?? 0) > 0 && (
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Dependents</label>
                              <button
                                type="button"
                                onClick={() => navigate(`/app/system/catalog/modules?parent_module_id=${module.id}`)}
                                className="text-theme-link hover:underline cursor-pointer text-xs"
                                title="View modules that depend on this one"
                              >
                                {module.dependents_count} module{module.dependents_count !== 1 ? 's' : ''} depend on this
                              </button>
                            </div>
                          )}
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Module ID</label>
                            <p className="text-theme-primary font-mono text-xs truncate" title={module.id}>{module.id}</p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                            <p className="text-theme-primary text-xs">{module.created_at ? new Date(module.created_at).toLocaleString() : '—'}</p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Updated</label>
                            <p className="text-theme-primary text-xs">{module.updated_at ? new Date(module.updated_at).toLocaleString() : '—'}</p>
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
            {filteredModules.map((module) => {
              const expanded = expandedModuleIds.has(module.id);
              return (
              <div key={module.id} className="p-4">
                <div className="flex items-start justify-between mb-3">
                  <div className="flex items-start gap-2 flex-1 min-w-0">
                    <button
                      type="button"
                      onClick={() => toggleExpanded(module.id)}
                      className="p-1 -ml-1 mt-0.5 text-theme-secondary hover:text-theme-primary rounded transition-colors flex-shrink-0"
                      title={expanded ? 'Collapse details' : 'Expand details'}
                    >
                      {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                    </button>
                    <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 mb-1 flex-wrap">
                      <Package className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                      <span
                        className="font-medium text-theme-primary hover:text-theme-link cursor-pointer truncate"
                        onClick={() => onView?.(module)}
                      >
                        {module.name}
                      </span>
                      {module.lock_spec && (
                        <Lock className="w-3.5 h-3.5 text-theme-warning-fg" aria-label="Spec locked" />
                      )}
                      {module.reboot_required && (
                        <Power className="w-3.5 h-3.5 text-theme-warning-fg" aria-label="Reboot required" />
                      )}
                      {module.protected_spec && module.protected_spec.length > 0 && (
                        <ShieldCheck className="w-3.5 h-3.5 text-theme-info-fg" aria-label="Declares protected_spec" />
                      )}
                    </div>
                    {module.dependant && (
                      <p className="text-xs text-theme-info-fg flex items-center gap-1">
                        <GitBranch className="w-3 h-3" />
                        dependant of{' '}
                        {module.parent_module_id ? (
                          <EntityLink type="node_module" id={module.parent_module_id} label={module.parent_module_name ?? 'parent'} className="text-xs" />
                        ) : (
                          <code>{module.parent_module_name ?? 'parent'}</code>
                        )}
                      </p>
                    )}
                    {module.description && (
                      <p className="text-sm text-theme-secondary truncate">{module.description}</p>
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
                              className="w-full text-left px-4 py-2 text-sm text-theme-error-fg hover:bg-theme-surface-hover flex items-center gap-2"
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

                <div className="grid grid-cols-3 gap-4">
                  <div className="text-center">
                    <Badge variant={varietyColors[module.variety] || 'secondary'} size="xs">
                      {varietyLabels[module.variety] || module.variety}
                    </Badge>
                  </div>
                  <div className="text-center">
                    <Badge variant={module.public ? 'info' : 'secondary'} size="xs">
                      {module.public ? 'Public' : 'Private'}
                    </Badge>
                  </div>
                  <div className="text-center">
                    <Badge variant={module.enabled ? 'success' : 'secondary'} size="xs" dot>
                      {module.enabled ? 'Enabled' : 'Disabled'}
                    </Badge>
                  </div>
                </div>

                {/* Expanded body — module's OWN spec / lifecycle / version inline */}
                {expanded && (
                  <div className="mt-3 pt-3 border-t border-theme grid grid-cols-2 gap-3 text-sm">
                    {module.description && (
                      <div className="col-span-2">
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Description</label>
                        <p className="text-theme-primary">{module.description}</p>
                      </div>
                    )}
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Priority</label>
                      <p className="text-theme-primary">P{module.priority}</p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Category</label>
                      <p className="text-theme-primary">
                        {module.category_id ? (
                          <EntityLink type="node_module_category" id={module.category_id} label={module.category_name || module.category_id} />
                        ) : (
                          module.category_name || '—'
                        )}
                      </p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Platform</label>
                      <p className="text-theme-primary">
                        {module.node_platform_id ? (
                          <EntityLink type="node_platform" id={module.node_platform_id} label={module.node_platform_name || module.node_platform_id} />
                        ) : (
                          module.node_platform_name || '—'
                        )}
                      </p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">init_start</label>
                      <code className="text-theme-primary text-xs">{module.init_start || <span className="italic text-theme-tertiary">unset</span>}</code>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">init_stop</label>
                      <code className="text-theme-primary text-xs">{module.init_stop || <span className="italic text-theme-tertiary">unset</span>}</code>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">init_restart</label>
                      <code className="text-theme-primary text-xs">{module.init_restart || <span className="italic text-theme-tertiary">unset</span>}</code>
                    </div>
                    <div className="col-span-2">
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Spec Footprint</label>
                      <div className="flex flex-wrap gap-2">
                        <Badge variant="default" size="xs">file_spec: {module.file_spec?.length ?? 0}</Badge>
                        <Badge variant="default" size="xs">package_spec: {module.package_spec?.length ?? 0}</Badge>
                        <Badge variant="default" size="xs">mask: {module.mask?.length ?? 0}</Badge>
                        {module.protected_spec && module.protected_spec.length > 0 && (
                          <Badge variant="warning" size="xs">protected_spec: {module.protected_spec.length}</Badge>
                        )}
                      </div>
                    </div>
                    {module.latest_version && (
                      <div className="col-span-2">
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Latest Version</label>
                        <div className="flex flex-wrap items-center gap-2 text-xs">
                          <span className="text-theme-primary font-medium">{module.latest_version.version_number || '—'}</span>
                          {module.latest_version.promotion_state && (
                            <Badge variant="default" size="xs">{module.latest_version.promotion_state}</Badge>
                          )}
                        </div>
                      </div>
                    )}
                    <div className="col-span-2">
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Module ID</label>
                      <p className="text-theme-primary font-mono text-xs truncate" title={module.id}>{module.id}</p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                      <p className="text-theme-primary text-xs">{module.created_at ? new Date(module.created_at).toLocaleString() : '—'}</p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Updated</label>
                      <p className="text-theme-primary text-xs">{module.updated_at ? new Date(module.updated_at).toLocaleString() : '—'}</p>
                    </div>
                  </div>
                )}
              </div>
              );
            })}
          </ResponsiveListContainer.Mobile>
        </ResponsiveListContainer>
      </div>
    </div>
  );
};

export default ModuleList;
