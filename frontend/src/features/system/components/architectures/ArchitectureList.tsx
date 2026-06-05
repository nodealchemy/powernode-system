import React, { useCallback, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  Cpu,
  Search,
  Eye,
  Edit,
  Trash2,
  MoreVertical,
  Filter,
  Lock,
  ChevronRight,
  ChevronDown
} from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { systemApi } from '@system/features/system/services/systemApi';
import { useResourceList } from '@system/features/system/hooks/useResourceList';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import type { ArchitectureFamily, SystemNodeArchitecture } from '@system/features/system/types/system.types';

interface ArchitectureListFilters {
  search: string;
  enabled: 'all' | 'enabled' | 'disabled';
  family: 'all' | ArchitectureFamily;
  canonical: 'all' | 'canonical' | 'custom';
}

interface ArchitectureListProps {
  onView?: (architecture: SystemNodeArchitecture) => void;
  onEdit?: (architecture: SystemNodeArchitecture) => void;
  onDelete?: (architectureId: string) => void;
  onCreate?: () => void;
  className?: string;
}

const FAMILY_OPTIONS: { value: 'all' | ArchitectureFamily; label: string }[] = [
  { value: 'all', label: 'All Families' },
  { value: 'x86', label: 'x86' },
  { value: 'arm', label: 'ARM' },
  { value: 'power', label: 'Power' },
  { value: 'z', label: 'IBM Z' },
  { value: 'risc-v', label: 'RISC-V' },
  { value: 'mips', label: 'MIPS' },
  { value: 'other', label: 'Other' },
];

const platformsCountOf = (a: SystemNodeArchitecture): number =>
  a.usage?.node_platforms ?? a.platform_count ?? 0;

/**
 * ArchitectureList — Catalog → Architectures tab table.
 *
 * Renders the platform-wide architecture catalog with Description, Family,
 * Usage (platforms/repos/packages), and Status columns. Canonical rows
 * show a "canonical" badge and have their delete affordance hidden — they
 * can only evolve via migration.
 */
export const ArchitectureList: React.FC<ArchitectureListProps> = ({
  onView,
  onEdit,
  onDelete,
  onCreate,
  className = ''
}) => {
  const { hasPermission } = usePermissions();
  const navigate = useNavigate();

  const canManage = hasPermission('system.architectures.manage');

  // Click-to-expand state — Set<id> so multiple rows can be open at once.
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  const toggleExpanded = useCallback((id: string) => {
    setExpandedIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) { next.delete(id); } else { next.add(id); }
      return next;
    });
  }, []);

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
    initialFilters: { search: '', enabled: 'all', family: 'all', canonical: 'all' },
    filterFn: (arch, f) => {
      if (f.search) {
        const searchLower = f.search.toLowerCase();
        const haystack = [arch.name, arch.display_name, arch.description, arch.apt_name, arch.rpm_name]
          .filter(Boolean)
          .join(' ')
          .toLowerCase();
        if (!haystack.includes(searchLower)) return false;
      }
      if (f.enabled !== 'all') {
        if (f.enabled === 'enabled' && !arch.enabled) return false;
        if (f.enabled === 'disabled' && arch.enabled) return false;
      }
      if (f.family !== 'all' && arch.family !== f.family) return false;
      if (f.canonical === 'canonical' && !arch.is_canonical) return false;
      if (f.canonical === 'custom' && arch.is_canonical) return false;
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
        title: 'No architectures match these filters',
        description: 'Adjust the family / canonical / status filters above, or create a custom architecture.',
        action: canManage && onCreate ? { label: 'Create Architecture', onClick: onCreate } : undefined,
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

        <div className="sm:w-40">
          <div className="relative">
            <Filter className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <select
              value={filters.family}
              onChange={(e) =>
                setFilters({ ...filters, family: e.target.value as ArchitectureListFilters['family'] })
              }
              className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus appearance-none"
            >
              {FAMILY_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>{o.label}</option>
              ))}
            </select>
          </div>
        </div>

        <div className="sm:w-36">
          <select
            value={filters.canonical}
            onChange={(e) =>
              setFilters({ ...filters, canonical: e.target.value as ArchitectureListFilters['canonical'] })
            }
            className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus appearance-none"
          >
            <option value="all">All Origins</option>
            <option value="canonical">Canonical only</option>
            <option value="custom">Custom only</option>
          </select>
        </div>

        <div className="sm:w-36">
          <select
            value={filters.enabled}
            onChange={(e) =>
              setFilters({ ...filters, enabled: e.target.value as ArchitectureListFilters['enabled'] })
            }
            className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus appearance-none"
          >
            <option value="all">All Status</option>
            <option value="enabled">Enabled</option>
            <option value="disabled">Disabled</option>
          </select>
        </div>
      </ResponsiveListContainer.Filters>

      <ResponsiveListContainer.Desktop>
        <table className="w-full">
          <thead>
            <tr className="bg-theme-background border-b border-theme">
              <th className="w-8 py-3 px-2"></th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Architecture</th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Family</th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Description</th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Usage</th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Status</th>
              <th className="text-right py-3 px-4 font-medium text-theme-primary">Actions</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-theme">
            {filteredArchitectures.map((architecture) => {
              const expanded = expandedIds.has(architecture.id);
              return (
              <React.Fragment key={architecture.id}>
              <tr className="hover:bg-theme-surface-hover transition-colors duration-200">
                <td className="py-3 px-2 align-top">
                  <button
                    type="button"
                    onClick={() => toggleExpanded(architecture.id)}
                    className="p-1 text-theme-secondary hover:text-theme-primary rounded transition-colors"
                    title={expanded ? 'Collapse details' : 'Expand details'}
                  >
                    {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                  </button>
                </td>
                <td className="py-3 px-4">
                  <div className="flex items-start gap-2">
                    <Cpu className="w-4 h-4 text-theme-tertiary flex-shrink-0 mt-1" />
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <span
                          className="font-medium text-theme-primary hover:text-theme-link cursor-pointer"
                          onClick={() => onView?.(architecture)}
                        >
                          {architecture.name}
                        </span>
                        <Badge variant={architecture.is_canonical ? 'info' : 'secondary'} size="xs">
                          {architecture.is_canonical ? (
                            <><Lock className="w-3 h-3 mr-1" />canonical</>
                          ) : (
                            'operator'
                          )}
                        </Badge>
                      </div>
                      {architecture.display_name && (
                        <p className="text-sm text-theme-secondary truncate max-w-xs">
                          {architecture.display_name}
                        </p>
                      )}
                      {(architecture.apt_name || architecture.rpm_name) && (
                        <p className="text-xs text-theme-tertiary font-mono">
                          {architecture.apt_name && <>apt: {architecture.apt_name}</>}
                          {architecture.apt_name && architecture.rpm_name && ' · '}
                          {architecture.rpm_name && <>rpm: {architecture.rpm_name}</>}
                        </p>
                      )}
                    </div>
                  </div>
                </td>

                <td className="py-3 px-4">
                  <Badge variant="secondary" size="xs">{architecture.family}</Badge>
                </td>

                <td className="py-3 px-4 max-w-md">
                  <p className="text-sm text-theme-secondary line-clamp-2">
                    {architecture.description || <span className="text-theme-tertiary">—</span>}
                  </p>
                </td>

                <td className="py-3 px-4">
                  <div className="text-xs text-theme-secondary leading-tight">
                    <div>
                      {platformsCountOf(architecture) > 0 ? (
                        <button
                          type="button"
                          onClick={() => navigate(`/app/system/catalog/platforms?architecture=${architecture.id}`)}
                          className="font-medium text-theme-link hover:underline cursor-pointer"
                          title="View platforms on this architecture"
                        >
                          {platformsCountOf(architecture)}
                        </button>
                      ) : (
                        <span className="font-medium text-theme-primary">0</span>
                      )}{' '}platforms
                    </div>
                    <div><span className="font-medium text-theme-primary">{architecture.usage?.package_repositories ?? 0}</span> repos</div>
                    <div><span className="font-medium text-theme-primary">{architecture.usage?.packages ?? 0}</span> packages</div>
                  </div>
                </td>

                <td className="py-3 px-4">
                  <Badge variant={architecture.enabled ? 'success' : 'secondary'} dot pulse={architecture.enabled}>
                    {architecture.enabled ? 'Enabled' : 'Disabled'}
                  </Badge>
                </td>

                <td className="py-3 px-4">
                  <div className="flex items-center justify-end gap-2">
                    <Button variant="outline" size="sm" onClick={() => onView?.(architecture)} title="View Details">
                      <Eye className="w-4 h-4" />
                    </Button>

                    {canManage && onEdit && !architecture.is_canonical && (
                      <Button variant="outline" size="sm" onClick={() => onEdit(architecture)} title="Edit Architecture">
                        <Edit className="w-4 h-4" />
                      </Button>
                    )}

                    {canManage && onDelete && !architecture.is_canonical && (
                      <Button variant="outline" size="sm" onClick={() => onDelete(architecture.id)} title="Delete Architecture">
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
                      {architecture.description && (
                        <div className="col-span-full">
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Description</label>
                          <p className="text-theme-primary">{architecture.description}</p>
                        </div>
                      )}
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Family</label>
                        <p className="text-theme-primary">{architecture.family}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Origin</label>
                        <p className="text-theme-primary">{architecture.is_canonical ? 'canonical' : 'operator'}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Status</label>
                        <p className="text-theme-primary">{architecture.enabled ? 'Enabled' : 'Disabled'}</p>
                      </div>
                      {architecture.display_name && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Display name</label>
                          <p className="text-theme-primary">{architecture.display_name}</p>
                        </div>
                      )}
                      {(architecture.apt_name || architecture.rpm_name) && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Package names</label>
                          <p className="text-theme-primary font-mono text-xs">
                            {architecture.apt_name && <>apt: {architecture.apt_name}</>}
                            {architecture.apt_name && architecture.rpm_name && ' · '}
                            {architecture.rpm_name && <>rpm: {architecture.rpm_name}</>}
                          </p>
                        </div>
                      )}
                      {architecture.kernel_options && (
                        <div className="col-span-full">
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Kernel options</label>
                          <p className="text-theme-primary font-mono text-xs break-all">{architecture.kernel_options}</p>
                        </div>
                      )}
                      {architecture.aliases && architecture.aliases.length > 0 && (
                        <div className="col-span-full">
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Aliases</label>
                          <div className="flex flex-wrap gap-1">
                            {architecture.aliases.map((alias) => (
                              <Badge key={alias} variant="secondary" size="xs">{alias}</Badge>
                            ))}
                          </div>
                        </div>
                      )}
                      <div className="col-span-full">
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Usage</label>
                        <div className="flex flex-wrap gap-4 text-xs text-theme-secondary">
                          <span>
                            {platformsCountOf(architecture) > 0 ? (
                              <button
                                type="button"
                                onClick={() => navigate(`/app/system/catalog/platforms?architecture=${architecture.id}`)}
                                className="font-medium text-theme-link hover:underline cursor-pointer"
                                title="View platforms on this architecture"
                              >
                                {platformsCountOf(architecture)}
                              </button>
                            ) : (
                              <span className="font-medium text-theme-primary">0</span>
                            )}{' '}platforms
                          </span>
                          <span><span className="font-medium text-theme-primary">{architecture.usage?.package_repositories ?? 0}</span> repos</span>
                          <span><span className="font-medium text-theme-primary">{architecture.usage?.packages ?? 0}</span> packages</span>
                        </div>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Visibility</label>
                        <p className="text-theme-primary">{architecture.public ? 'Public' : 'Private'}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Architecture ID</label>
                        <p className="text-theme-primary font-mono text-xs truncate" title={architecture.id}>{architecture.id}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                        <p className="text-theme-primary text-xs">{new Date(architecture.created_at).toLocaleString()}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Updated</label>
                        <p className="text-theme-primary text-xs">{new Date(architecture.updated_at).toLocaleString()}</p>
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
        {filteredArchitectures.map((architecture) => {
          const expanded = expandedIds.has(architecture.id);
          return (
          <div key={architecture.id} className="p-4">
            <div className="flex items-start justify-between mb-3">
              <div className="flex items-start gap-2 flex-1 min-w-0">
                <button
                  type="button"
                  onClick={() => toggleExpanded(architecture.id)}
                  className="p-1 -ml-1 mt-0.5 text-theme-secondary hover:text-theme-primary rounded transition-colors flex-shrink-0"
                  title={expanded ? 'Collapse details' : 'Expand details'}
                >
                  {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                </button>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 mb-1">
                    <Cpu className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
                    <span
                      className="font-medium text-theme-primary hover:text-theme-link cursor-pointer truncate"
                      onClick={() => onView?.(architecture)}
                    >
                      {architecture.name}
                    </span>
                    <Badge variant={architecture.is_canonical ? 'info' : 'secondary'} size="xs">
                      {architecture.is_canonical ? 'canonical' : 'operator'}
                    </Badge>
                  </div>
                  {architecture.display_name && (
                    <p className="text-sm text-theme-secondary truncate">{architecture.display_name}</p>
                  )}
                  {architecture.description && (
                    <p className="text-xs text-theme-tertiary line-clamp-2 mt-1">{architecture.description}</p>
                  )}
                </div>
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
                      {canManage && onEdit && !architecture.is_canonical && (
                        <button
                          onClick={() => { onEdit(architecture); setDropdownOpen(null); }}
                          className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                        >
                          <Edit className="w-4 h-4" />
                          Edit Architecture
                        </button>
                      )}
                      {canManage && onDelete && !architecture.is_canonical && (
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

            <div className="grid grid-cols-4 gap-2 text-center text-xs">
              <div>
                <div className="text-sm font-medium text-theme-primary">{architecture.family}</div>
                <div className="text-theme-tertiary">family</div>
              </div>
              <div>
                {platformsCountOf(architecture) > 0 ? (
                  <button
                    type="button"
                    onClick={() => navigate(`/app/system/catalog/platforms?architecture=${architecture.id}`)}
                    className="text-sm font-medium text-theme-link hover:underline cursor-pointer"
                    title="View platforms on this architecture"
                  >
                    {platformsCountOf(architecture)}
                  </button>
                ) : (
                  <div className="text-sm font-medium text-theme-primary">0</div>
                )}
                <div className="text-theme-tertiary">platforms</div>
              </div>
              <div>
                <div className="text-sm font-medium text-theme-primary">{architecture.usage?.package_repositories ?? 0}</div>
                <div className="text-theme-tertiary">repos</div>
              </div>
              <div>
                <Badge variant={architecture.enabled ? 'success' : 'secondary'} size="xs" dot>
                  {architecture.enabled ? 'On' : 'Off'}
                </Badge>
              </div>
            </div>

            {expanded && (
              <div className="mt-3 pt-3 border-t border-theme grid grid-cols-2 gap-3 text-sm">
                {architecture.description && (
                  <div className="col-span-2">
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Description</label>
                    <p className="text-theme-primary">{architecture.description}</p>
                  </div>
                )}
                {(architecture.apt_name || architecture.rpm_name) && (
                  <div className="col-span-2">
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Package names</label>
                    <p className="text-theme-primary font-mono text-xs">
                      {architecture.apt_name && <>apt: {architecture.apt_name}</>}
                      {architecture.apt_name && architecture.rpm_name && ' · '}
                      {architecture.rpm_name && <>rpm: {architecture.rpm_name}</>}
                    </p>
                  </div>
                )}
                {architecture.kernel_options && (
                  <div className="col-span-2">
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Kernel options</label>
                    <p className="text-theme-primary font-mono text-xs break-all">{architecture.kernel_options}</p>
                  </div>
                )}
                {architecture.aliases && architecture.aliases.length > 0 && (
                  <div className="col-span-2">
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Aliases</label>
                    <div className="flex flex-wrap gap-1">
                      {architecture.aliases.map((alias) => (
                        <Badge key={alias} variant="secondary" size="xs">{alias}</Badge>
                      ))}
                    </div>
                  </div>
                )}
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Packages</label>
                  <p className="text-theme-primary">{architecture.usage?.packages ?? 0}</p>
                </div>
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Visibility</label>
                  <p className="text-theme-primary">{architecture.public ? 'Public' : 'Private'}</p>
                </div>
                <div className="col-span-2">
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Architecture ID</label>
                  <p className="text-theme-primary font-mono text-xs truncate" title={architecture.id}>{architecture.id}</p>
                </div>
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                  <p className="text-theme-primary text-xs">{new Date(architecture.created_at).toLocaleString()}</p>
                </div>
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Updated</label>
                  <p className="text-theme-primary text-xs">{new Date(architecture.updated_at).toLocaleString()}</p>
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

export default ArchitectureList;
