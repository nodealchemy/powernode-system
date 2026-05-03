import React, { useCallback } from 'react';
import {
  FileText,
  Search,
  Eye,
  Edit,
  Trash2,
  Globe,
  Lock,
  MoreVertical,
  Filter,
  Copy,
  Download
} from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import { useInfiniteResourceList } from '@system/features/system/hooks/useResourceList';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import type { SystemNodeTemplate } from '@system/features/system/types/system.types';

interface TemplateListFilters {
  search: string;
  visibility: 'all' | 'public' | 'private';
  enabled: 'all' | 'enabled' | 'disabled';
}

interface TemplateListProps {
  /** Callback when view template is clicked */
  onView?: (template: SystemNodeTemplate) => void;
  /** Callback when edit template is clicked */
  onEdit?: (template: SystemNodeTemplate) => void;
  /** Callback when delete template is clicked */
  onDelete?: (templateId: string) => void;
  /** Callback when create template is clicked */
  onCreate?: () => void;
  /** Callback when duplicate template is clicked */
  onDuplicate?: (template: SystemNodeTemplate) => void;
  /** Optional className */
  className?: string;
}

/**
 * TemplateList - Displays a list of node templates with search, filtering, and pagination
 *
 * Uses platform patterns:
 * - Permission-based access control via usePermissions
 * - Theme-aware styling with theme classes
 * - Responsive design (desktop table, mobile cards)
 */
export const TemplateList: React.FC<TemplateListProps> = ({
  onView,
  onEdit,
  onDelete,
  onCreate,
  onDuplicate,
  className = ''
}) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();

  const canCreate = hasPermission('system.templates.create');
  const canUpdate = hasPermission('system.templates.update');
  const canDelete = hasPermission('system.templates.delete');
  const canExport = hasPermission('system.templates.read');

  const handleExport = useCallback(async (template: SystemNodeTemplate) => {
    try {
      await systemApi.exportTemplate(template.id);
      addNotification({ type: 'success', message: `Exported ${template.name}` });
    } catch {
      addNotification({ type: 'error', message: `Failed to export ${template.name}` });
    }
  }, [addNotification]);

  const {
    items: templates,
    filteredItems: filteredTemplates,
    loading,
    loadingMore,
    refreshing,
    hasMore,
    totalCount,
    loadMore,
    filters,
    setFilters,
    refresh: handleRefresh,
    dropdownOpen,
    setDropdownOpen,
  } = useInfiniteResourceList<SystemNodeTemplate, TemplateListFilters>({
    fetcher: ({ page, per_page }) =>
      systemApi.getTemplates({ page, per_page }).then(d => ({ items: d.templates, meta: d.meta })),
    initialFilters: { search: '', visibility: 'all', enabled: 'all' },
    perPage: 20,
    // All filters are client-side; no server-bound subset.
    serverFilterKey: () => '',
    clientFilterFn: (template, f) => {
      if (f.search) {
        const q = f.search.toLowerCase();
        if (
          !template.name.toLowerCase().includes(q) &&
          !template.description?.toLowerCase().includes(q) &&
          !template.node_platform_name?.toLowerCase().includes(q)
        ) {
          return false;
        }
      }
      if (f.visibility !== 'all') {
        if (f.visibility === 'public' && !template.public) return false;
        if (f.visibility === 'private' && template.public) return false;
      }
      if (f.enabled !== 'all') {
        if (f.enabled === 'enabled' && !template.enabled) return false;
        if (f.enabled === 'disabled' && template.enabled) return false;
      }
      return true;
    },
    errorMessage: 'Failed to load templates',
  });

  return (
    <ResponsiveListContainer
      loading={loading}
      refreshing={refreshing}
      totalCount={templates.length}
      filteredCount={filteredTemplates.length}
      onRefresh={handleRefresh}
      onLoadMore={loadMore}
      hasMore={hasMore}
      loadingMore={loadingMore}
      serverTotalCount={totalCount}
      className={className}
      emptyState={{
        icon: FileText,
        title: 'No templates configured',
        description: 'Create your first node template to standardize your infrastructure configurations',
        action: canCreate && onCreate ? { label: 'Create Template', onClick: onCreate } : undefined,
      }}
    >
      <ResponsiveListContainer.Filters>
        <div className="flex-1">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <input
              type="text"
              placeholder="Search templates..."
              value={filters.search}
              onChange={(e) => setFilters({ ...filters, search: e.target.value })}
              className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
            />
          </div>
        </div>

        <div className="sm:w-36">
          <select
            value={filters.visibility}
            onChange={(e) => setFilters({ ...filters, visibility: e.target.value as TemplateListFilters['visibility'] })}
            className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus appearance-none"
          >
            <option value="all">All Visibility</option>
            <option value="public">Public</option>
            <option value="private">Private</option>
          </select>
        </div>

        <div className="sm:w-36">
          <div className="relative">
            <Filter className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <select
              value={filters.enabled}
              onChange={(e) => setFilters({ ...filters, enabled: e.target.value as TemplateListFilters['enabled'] })}
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
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Template</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Platform</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Modules</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Visibility</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Status</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Nodes</th>
                <th className="text-right py-3 px-4 font-medium text-theme-primary">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-theme">
              {filteredTemplates.map((template) => (
                <tr key={template.id} className="hover:bg-theme-surface-hover transition-colors duration-200">
                  <td className="py-3 px-4">
                    <div>
                      <div className="flex items-center gap-2">
                        <FileText className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                        <span
                          className="font-medium text-theme-primary hover:text-theme-link cursor-pointer"
                          onClick={() => onView?.(template)}
                        >
                          {template.name}
                        </span>
                      </div>
                      {template.description && (
                        <p className="text-sm text-theme-secondary mt-1 truncate max-w-xs">
                          {template.description}
                        </p>
                      )}
                    </div>
                  </td>

                  <td className="py-3 px-4">
                    <span className="text-theme-secondary">
                      {template.node_platform_name || '-'}
                    </span>
                  </td>

                  <td className="py-3 px-4">
                    {template.modules && template.modules.length > 0 ? (
                      <div className="flex flex-wrap gap-1 max-w-xs">
                        {template.modules.slice(0, 4).map((m) => (
                          <span key={m.id} title={`priority ${m.priority}`}>
                            <Badge variant="secondary" size="xs">{m.name}</Badge>
                          </span>
                        ))}
                        {template.modules.length > 4 && (
                          <Badge variant="secondary" size="xs">+{template.modules.length - 4}</Badge>
                        )}
                      </div>
                    ) : (
                      <span className="text-theme-tertiary text-sm">none</span>
                    )}
                  </td>

                  <td className="py-3 px-4">
                    <Badge
                      variant={template.public ? 'info' : 'secondary'}
                    >
                      {template.public ? (
                        <><Globe className="w-3 h-3 mr-1" />Public</>
                      ) : (
                        <><Lock className="w-3 h-3 mr-1" />Private</>
                      )}
                    </Badge>
                  </td>

                  <td className="py-3 px-4">
                    <Badge
                      variant={template.enabled ? 'success' : 'secondary'}
                      dot
                      pulse={template.enabled}
                    >
                      {template.enabled ? 'Enabled' : 'Disabled'}
                    </Badge>
                  </td>

                  <td className="py-3 px-4">
                    <span className="text-theme-primary font-medium">
                      {template.node_count || 0}
                    </span>
                  </td>

                  <td className="py-3 px-4">
                    <div className="flex items-center justify-end gap-2">
                      <Button
                        variant="outline"
                        size="sm"
                        onClick={() => onView?.(template)}
                        title="View Details"
                      >
                        <Eye className="w-4 h-4" />
                      </Button>

                      {canCreate && onDuplicate && (
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => onDuplicate(template)}
                          title="Duplicate Template"
                        >
                          <Copy className="w-4 h-4" />
                        </Button>
                      )}

                      {canExport && (
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => handleExport(template)}
                          title="Export Template (JSON bundle)"
                        >
                          <Download className="w-4 h-4" />
                        </Button>
                      )}

                      {canUpdate && onEdit && (
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => onEdit(template)}
                          title="Edit Template"
                        >
                          <Edit className="w-4 h-4" />
                        </Button>
                      )}

                      {canDelete && onDelete && (
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => onDelete(template.id)}
                          title="Delete Template"
                        >
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
        {filteredTemplates.map((template) => (
            <div key={template.id} className="p-4">
              {/* Header */}
              <div className="flex items-start justify-between mb-3">
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 mb-1">
                    <FileText className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                    <span
                      className="font-medium text-theme-primary hover:text-theme-link cursor-pointer truncate"
                      onClick={() => onView?.(template)}
                    >
                      {template.name}
                    </span>
                  </div>
                  {template.description && (
                    <p className="text-sm text-theme-secondary truncate">
                      {template.description}
                    </p>
                  )}
                </div>

                <div className="relative">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={(e) => {
                      e.stopPropagation();
                      setDropdownOpen(dropdownOpen === template.id ? null : template.id);
                    }}
                  >
                    <MoreVertical className="w-4 h-4" />
                  </Button>

                  {dropdownOpen === template.id && (
                    <div className="absolute right-0 mt-1 w-48 bg-theme-surface border border-theme rounded-lg shadow-lg z-10">
                      <div className="py-1">
                        <button
                          onClick={() => {
                            onView?.(template);
                            setDropdownOpen(null);
                          }}
                          className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                        >
                          <Eye className="w-4 h-4" />
                          View Details
                        </button>
                        {canCreate && onDuplicate && (
                          <button
                            onClick={() => {
                              onDuplicate(template);
                              setDropdownOpen(null);
                            }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Copy className="w-4 h-4" />
                            Duplicate
                          </button>
                        )}
                        {canExport && (
                          <button
                            onClick={() => {
                              handleExport(template);
                              setDropdownOpen(null);
                            }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Download className="w-4 h-4" />
                            Export Bundle
                          </button>
                        )}
                        {canUpdate && onEdit && (
                          <button
                            onClick={() => {
                              onEdit(template);
                              setDropdownOpen(null);
                            }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Edit className="w-4 h-4" />
                            Edit Template
                          </button>
                        )}
                        {canDelete && onDelete && (
                          <button
                            onClick={() => {
                              onDelete(template.id);
                              setDropdownOpen(null);
                            }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-error hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Trash2 className="w-4 h-4" />
                            Delete Template
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
                    variant={template.public ? 'info' : 'secondary'}
                    size="xs"
                  >
                    {template.public ? 'Public' : 'Private'}
                  </Badge>
                </div>

                <div className="text-center">
                  <Badge
                    variant={template.enabled ? 'success' : 'secondary'}
                    size="xs"
                    dot
                  >
                    {template.enabled ? 'Enabled' : 'Disabled'}
                  </Badge>
                </div>

                <div className="text-center">
                  <div className="text-sm font-medium text-theme-primary">
                    {template.node_count || 0}
                  </div>
                  <div className="text-xs text-theme-secondary">Nodes</div>
                </div>
              </div>

              {/* Platform */}
              {template.node_platform_name && (
                <div className="text-xs text-theme-secondary">
                  Platform: {template.node_platform_name}
                </div>
              )}

              {/* Modules */}
              {template.modules && template.modules.length > 0 && (
                <div className="mt-2 flex flex-wrap gap-1">
                  {template.modules.slice(0, 6).map((m) => (
                    <Badge key={m.id} variant="secondary" size="xs">{m.name}</Badge>
                  ))}
                  {template.modules.length > 6 && (
                    <Badge variant="secondary" size="xs">+{template.modules.length - 6}</Badge>
                  )}
                </div>
              )}
            </div>
          ))}
      </ResponsiveListContainer.Mobile>
    </ResponsiveListContainer>
  );
};

export default TemplateList;
