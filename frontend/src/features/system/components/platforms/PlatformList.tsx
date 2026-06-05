import React, { useCallback, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  Layers,
  Search,
  Eye,
  Edit,
  Trash2,
  Globe,
  Lock,
  MoreVertical,
  Filter,
  Download,
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
import { platformsApi } from '@system/features/system/services/api/platformsApi';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useResourceList } from '@system/features/system/hooks/useResourceList';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import type { SystemNodePlatform } from '@system/features/system/types/system.types';

interface PlatformListFilters {
  search: string;
  enabled: 'all' | 'enabled' | 'disabled';
  /** Deep-link filter — seeded from ?architecture=<node_architecture_id>. */
  architectureId: string | null;
}

interface PlatformListProps {
  onView?: (platform: SystemNodePlatform) => void;
  onEdit?: (platform: SystemNodePlatform) => void;
  onDelete?: (platformId: string) => void;
  onCreate?: () => void;
  className?: string;
}

/**
 * PlatformList - Displays a list of node platforms with search, filtering, and pagination
 */
export const PlatformList: React.FC<PlatformListProps> = ({
  onView,
  onEdit,
  onDelete,
  onCreate,
  className = ''
}) => {
  const { hasPermission } = usePermissions();
  const navigate = useNavigate();

  const canCreate = hasPermission('system.platforms.create');
  const canUpdate = hasPermission('system.platforms.update');
  const canDelete = hasPermission('system.platforms.delete');

  // Deep-link: ?architecture=<id> pre-filters to one architecture's platforms.
  const { seedFilters, hasActiveParamFilter, clearParamFilters } =
    useQueryParamFilter<PlatformListFilters>({ architecture: 'architectureId' });

  // Click-to-expand state — Set<id> so multiple rows can be open at once.
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  const toggleExpanded = useCallback((id: string) => {
    setExpandedIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) { next.delete(id); } else { next.add(id); }
      return next;
    });
  }, []);

  const { addNotification } = useNotifications();
  const [downloadingId, setDownloadingId] = useState<string | null>(null);
  // Download a platform's published generic disk image (.img) for fleet
  // imaging (claim-by-ID). Offered only when an image is published; the
  // endpoint streams the bytes with a Content-Disposition filename.
  const handleDownloadImage = async (platform: SystemNodePlatform) => {
    setDownloadingId(platform.id);
    try {
      await platformsApi.downloadDiskImage(platform.id);
      addNotification({ type: 'success', message: `Downloading generic image for ${platform.name}…` });
    } catch (error) {
      const msg = error instanceof Error ? error.message : 'Failed to download image';
      addNotification({ type: 'error', message: msg });
    } finally {
      setDownloadingId(null);
    }
  };

  const {
    items: platforms,
    filteredItems: filteredPlatforms,
    loading,
    refreshing,
    filters,
    setFilters,
    refresh: handleRefresh,
    dropdownOpen,
    setDropdownOpen,
  } = useResourceList<SystemNodePlatform, PlatformListFilters>({
    fetcher: () => systemApi.getPlatforms(),
    initialFilters: seedFilters({ search: '', enabled: 'all', architectureId: null }),
    filterFn: (platform, f) => {
      if (f.search) {
        const searchLower = f.search.toLowerCase();
        if (
          !platform.name.toLowerCase().includes(searchLower) &&
          !platform.description?.toLowerCase().includes(searchLower) &&
          !platform.architecture_name?.toLowerCase().includes(searchLower)
        ) {
          return false;
        }
      }
      if (f.enabled !== 'all') {
        if (f.enabled === 'enabled' && !platform.enabled) return false;
        if (f.enabled === 'disabled' && platform.enabled) return false;
      }
      if (f.architectureId && platform.node_architecture_id !== f.architectureId) return false;
      return true;
    },
    errorMessage: 'Failed to load platforms',
  });

  // Clearing the deep-link chip resets BOTH the URL param and the seeded
  // filter state (useResourceList reads initialFilters only once).
  const clearArchitectureFilter = useCallback(() => {
    setFilters((prev) => ({ ...prev, architectureId: null }));
    clearParamFilters();
  }, [setFilters, clearParamFilters]);

  return (
    <ResponsiveListContainer
      loading={loading}
      refreshing={refreshing}
      totalCount={platforms.length}
      filteredCount={filteredPlatforms.length}
      onRefresh={handleRefresh}
      className={className}
      emptyState={{
        icon: Layers,
        title: 'No platforms configured',
        description: 'Create your first node platform to define operating system configurations',
        action: canCreate && onCreate ? { label: 'Create Platform', onClick: onCreate } : undefined,
      }}
    >
      <ResponsiveListContainer.Filters>
        <div className="flex-1">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <input
              type="text"
              placeholder="Search platforms..."
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
              onChange={(e) => setFilters({ ...filters, enabled: e.target.value as PlatformListFilters['enabled'] })}
              className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus appearance-none"
            >
              <option value="all">All Status</option>
              <option value="enabled">Enabled</option>
              <option value="disabled">Disabled</option>
            </select>
          </div>
        </div>

        {hasActiveParamFilter && filters.architectureId && (
          <div className="flex items-center">
            <button
              type="button"
              onClick={clearArchitectureFilter}
              className="inline-flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm bg-theme-info/10 border border-theme-info text-theme-info hover:bg-theme-info/20 transition-colors"
              title="Clear architecture filter"
            >
              <span>Filtered by architecture</span>
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
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Platform</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Architecture</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Visibility</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Status</th>
                <th className="text-left py-3 px-4 font-medium text-theme-primary">Templates</th>
                <th className="text-right py-3 px-4 font-medium text-theme-primary">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-theme">
              {filteredPlatforms.map((platform) => {
                const expanded = expandedIds.has(platform.id);
                return (
                <React.Fragment key={platform.id}>
                <tr className="hover:bg-theme-surface-hover transition-colors duration-200">
                  <td className="py-3 px-2 align-middle">
                    <button
                      type="button"
                      onClick={() => toggleExpanded(platform.id)}
                      className="p-1 text-theme-secondary hover:text-theme-primary rounded transition-colors"
                      title={expanded ? 'Collapse details' : 'Expand details'}
                    >
                      {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                    </button>
                  </td>
                  <td className="py-3 px-4">
                    <div>
                      <div className="flex items-center gap-2">
                        <Layers className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                        <span
                          className="font-medium text-theme-primary hover:text-theme-link cursor-pointer"
                          onClick={() => onView?.(platform)}
                        >
                          {platform.name}
                        </span>
                      </div>
                      {platform.description && (
                        <p className="text-sm text-theme-secondary mt-1 truncate max-w-xs">
                          {platform.description}
                        </p>
                      )}
                    </div>
                  </td>

                  <td className="py-3 px-4">
                    {platform.node_architecture_id ? (
                      <EntityLink
                        type="node_architecture"
                        id={platform.node_architecture_id}
                        label={platform.architecture_name || platform.node_architecture_id}
                      />
                    ) : (
                      <span className="text-theme-secondary">
                        {platform.architecture_name || '-'}
                      </span>
                    )}
                  </td>

                  <td className="py-3 px-4">
                    <Badge variant={platform.public ? 'info' : 'secondary'}>
                      {platform.public ? (
                        <><Globe className="w-3 h-3 mr-1" />Public</>
                      ) : (
                        <><Lock className="w-3 h-3 mr-1" />Private</>
                      )}
                    </Badge>
                  </td>

                  <td className="py-3 px-4">
                    <Badge variant={platform.enabled ? 'success' : 'secondary'} dot pulse={platform.enabled}>
                      {platform.enabled ? 'Enabled' : 'Disabled'}
                    </Badge>
                  </td>

                  <td className="py-3 px-4">
                    {(platform.template_count || 0) > 0 ? (
                      <button
                        type="button"
                        onClick={() => navigate(`/app/system/catalog/templates?platform=${platform.id}`)}
                        className="text-theme-link hover:underline cursor-pointer font-medium"
                        title="View templates on this platform"
                      >
                        {platform.template_count}
                      </button>
                    ) : (
                      <span className="text-theme-primary font-medium">0</span>
                    )}
                  </td>

                  <td className="py-3 px-4">
                    <div className="flex items-center justify-end gap-2">
                      <Button variant="outline" size="sm" onClick={() => onView?.(platform)} title="View Details">
                        <Eye className="w-4 h-4" />
                      </Button>

                      {platform.disk_image_publication_status === 'published' && (
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => handleDownloadImage(platform)}
                          disabled={downloadingId === platform.id}
                          title="Download the generic disk image (.img) for fleet imaging"
                        >
                          <Download className="w-4 h-4" />
                        </Button>
                      )}

                      {canUpdate && onEdit && (
                        <Button variant="outline" size="sm" onClick={() => onEdit(platform)} title="Edit Platform">
                          <Edit className="w-4 h-4" />
                        </Button>
                      )}

                      {canDelete && onDelete && (
                        <Button variant="outline" size="sm" onClick={() => onDelete(platform.id)} title="Delete Platform">
                          <Trash2 className="w-4 h-4 text-theme-error" />
                        </Button>
                      )}
                    </div>
                  </td>
                </tr>
                {expanded && (
                  <tr className="bg-theme-background border-b border-theme">
                    <td></td>
                    <td colSpan={5} className="py-3 px-4">
                      <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
                        {platform.description && (
                          <div className="col-span-full">
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Description</label>
                            <p className="text-theme-primary">{platform.description}</p>
                          </div>
                        )}
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Architecture</label>
                          <p className="text-theme-primary">
                            {platform.node_architecture_id ? (
                              <EntityLink
                                type="node_architecture"
                                id={platform.node_architecture_id}
                                label={platform.architecture_name || platform.node_architecture_id}
                              />
                            ) : (platform.architecture_name || '—')}
                          </p>
                        </div>
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Status</label>
                          <p className="text-theme-primary">{platform.enabled ? 'Enabled' : 'Disabled'}</p>
                        </div>
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Visibility</label>
                          <p className="text-theme-primary">{platform.public ? 'Public' : 'Private'}</p>
                        </div>
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Templates</label>
                          {(platform.template_count ?? 0) > 0 ? (
                            <button
                              type="button"
                              onClick={() => navigate(`/app/system/catalog/templates?platform=${platform.id}`)}
                              className="text-theme-link hover:underline cursor-pointer"
                              title="View templates on this platform"
                            >
                              {platform.template_count}
                            </button>
                          ) : (
                            <p className="text-theme-primary">0</p>
                          )}
                        </div>
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Modules</label>
                          {(platform.module_count ?? 0) > 0 ? (
                            <button
                              type="button"
                              onClick={() => navigate(`/app/system/catalog/modules?platform=${platform.id}`)}
                              className="text-theme-link hover:underline cursor-pointer"
                              title="View modules on this platform"
                            >
                              {platform.module_count}
                            </button>
                          ) : (
                            <p className="text-theme-primary">0</p>
                          )}
                        </div>
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Disk Image</label>
                          <p className="text-theme-primary">{platform.disk_image_publication_status || 'none'}</p>
                        </div>
                        {platform.disk_image_git_sha && (
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Image git_sha</label>
                            <p className="text-theme-primary font-mono text-xs truncate" title={platform.disk_image_git_sha}>{platform.disk_image_git_sha}</p>
                          </div>
                        )}
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Platform ID</label>
                          <p className="text-theme-primary font-mono text-xs truncate" title={platform.id}>{platform.id}</p>
                        </div>
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                          <p className="text-theme-primary text-xs">{new Date(platform.created_at).toLocaleString()}</p>
                        </div>
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Updated</label>
                          <p className="text-theme-primary text-xs">{new Date(platform.updated_at).toLocaleString()}</p>
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
        {filteredPlatforms.map((platform) => {
          const expanded = expandedIds.has(platform.id);
          return (
            <div key={platform.id} className="p-4">
              <div className="flex items-start justify-between mb-3">
                <div className="flex items-start gap-2 flex-1 min-w-0">
                  <button
                    type="button"
                    onClick={() => toggleExpanded(platform.id)}
                    className="p-1 -ml-1 mt-0.5 text-theme-secondary hover:text-theme-primary rounded transition-colors flex-shrink-0"
                    title={expanded ? 'Collapse details' : 'Expand details'}
                  >
                    {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                  </button>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 mb-1">
                      <Layers className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                      <span
                        className="font-medium text-theme-primary hover:text-theme-link cursor-pointer truncate"
                        onClick={() => onView?.(platform)}
                      >
                        {platform.name}
                      </span>
                    </div>
                    {platform.description && (
                      <p className="text-sm text-theme-secondary truncate">{platform.description}</p>
                    )}
                  </div>
                </div>

                <div className="relative">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={(e) => {
                      e.stopPropagation();
                      setDropdownOpen(dropdownOpen === platform.id ? null : platform.id);
                    }}
                  >
                    <MoreVertical className="w-4 h-4" />
                  </Button>

                  {dropdownOpen === platform.id && (
                    <div className="absolute right-0 mt-1 w-48 bg-theme-surface border border-theme rounded-lg shadow-lg z-10">
                      <div className="py-1">
                        <button
                          onClick={() => { onView?.(platform); setDropdownOpen(null); }}
                          className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                        >
                          <Eye className="w-4 h-4" />
                          View Details
                        </button>
                        {platform.disk_image_publication_status === 'published' && (
                          <button
                            onClick={() => { handleDownloadImage(platform); setDropdownOpen(null); }}
                            disabled={downloadingId === platform.id}
                            className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2 disabled:opacity-50"
                          >
                            <Download className="w-4 h-4" />
                            Download image
                          </button>
                        )}
                        {canUpdate && onEdit && (
                          <button
                            onClick={() => { onEdit(platform); setDropdownOpen(null); }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Edit className="w-4 h-4" />
                            Edit Platform
                          </button>
                        )}
                        {canDelete && onDelete && (
                          <button
                            onClick={() => { onDelete(platform.id); setDropdownOpen(null); }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-error hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Trash2 className="w-4 h-4" />
                            Delete Platform
                          </button>
                        )}
                      </div>
                    </div>
                  )}
                </div>
              </div>

              <div className="grid grid-cols-3 gap-4">
                <div className="text-center">
                  <Badge variant={platform.public ? 'info' : 'secondary'} size="xs">
                    {platform.public ? 'Public' : 'Private'}
                  </Badge>
                </div>
                <div className="text-center">
                  <Badge variant={platform.enabled ? 'success' : 'secondary'} size="xs" dot>
                    {platform.enabled ? 'Enabled' : 'Disabled'}
                  </Badge>
                </div>
                <div className="text-center">
                  {(platform.template_count || 0) > 0 ? (
                    <button
                      type="button"
                      onClick={() => navigate(`/app/system/catalog/templates?platform=${platform.id}`)}
                      className="text-sm font-medium text-theme-link hover:underline cursor-pointer"
                      title="View templates on this platform"
                    >
                      {platform.template_count}
                    </button>
                  ) : (
                    <div className="text-sm font-medium text-theme-primary">0</div>
                  )}
                  <div className="text-xs text-theme-secondary">Templates</div>
                </div>
              </div>

              {expanded && (
                <div className="mt-3 pt-3 border-t border-theme grid grid-cols-2 gap-3 text-sm">
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Architecture</label>
                    <p className="text-theme-primary">
                      {platform.node_architecture_id ? (
                        <EntityLink
                          type="node_architecture"
                          id={platform.node_architecture_id}
                          label={platform.architecture_name || platform.node_architecture_id}
                        />
                      ) : (platform.architecture_name || '—')}
                    </p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Modules</label>
                    {(platform.module_count ?? 0) > 0 ? (
                      <button
                        type="button"
                        onClick={() => navigate(`/app/system/catalog/modules?platform=${platform.id}`)}
                        className="text-theme-link hover:underline cursor-pointer"
                        title="View modules on this platform"
                      >
                        {platform.module_count}
                      </button>
                    ) : (
                      <p className="text-theme-primary">0</p>
                    )}
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Disk Image</label>
                    <p className="text-theme-primary">{platform.disk_image_publication_status || 'none'}</p>
                  </div>
                  {platform.disk_image_git_sha && (
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Image git_sha</label>
                      <p className="text-theme-primary font-mono text-xs truncate" title={platform.disk_image_git_sha}>{platform.disk_image_git_sha}</p>
                    </div>
                  )}
                  <div className="col-span-2">
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Platform ID</label>
                    <p className="text-theme-primary font-mono text-xs truncate" title={platform.id}>{platform.id}</p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                    <p className="text-theme-primary text-xs">{new Date(platform.created_at).toLocaleString()}</p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Updated</label>
                    <p className="text-theme-primary text-xs">{new Date(platform.updated_at).toLocaleString()}</p>
                  </div>
                </div>
              )}
            </div>
          );
          })}
      </ResponsiveListContainer.Mobile>
    </ResponsiveListContainer>
  );
};

export default PlatformList;
