import React, { useCallback, useState } from 'react';
import {
  Cloud,
  Search,
  Eye,
  Edit,
  Trash2,
  Globe,
  Lock,
  MoreVertical,
  Filter,
  Server,
  MapPin,
  ChevronRight,
  ChevronDown
} from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { systemApi } from '@system/features/system/services/systemApi';
import { useResourceList } from '@system/features/system/hooks/useResourceList';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import type { SystemProvider } from '@system/features/system/types/system.types';

interface ProviderListFilters {
  search: string;
  providerType: string;
  enabled: 'all' | 'enabled' | 'disabled';
}

interface ProviderListProps {
  onView?: (provider: SystemProvider) => void;
  onEdit?: (provider: SystemProvider) => void;
  onDelete?: (providerId: string) => void;
  onCreate?: () => void;
  className?: string;
}

const providerTypeIcons: Record<string, string> = {
  aws: '☁️',
  openstack: '🔶',
  gcp: '🌐',
  azure: '🔷',
  digitalocean: '💧',
  custom: '⚙️'
};

const providerTypeLabels: Record<string, string> = {
  aws: 'Amazon Web Services',
  openstack: 'OpenStack',
  gcp: 'Google Cloud Platform',
  azure: 'Microsoft Azure',
  digitalocean: 'DigitalOcean',
  custom: 'Custom Provider'
};

/**
 * ProviderList - Displays a list of infrastructure providers
 *
 * Uses platform patterns:
 * - Permission-based access control via usePermissions
 * - Theme-aware styling with theme classes
 * - Responsive design (desktop expandable table, mobile cards)
 *
 * Each row's own scalar/config detail expands inline (no modal round-trip);
 * region / connection counts surface the management tabs via the existing
 * detail modal (Eye / row "View Details" action).
 */
export const ProviderList: React.FC<ProviderListProps> = ({
  onView,
  onEdit,
  onDelete,
  onCreate,
  className = ''
}) => {
  const { hasPermission } = usePermissions();

  const canCreate = hasPermission('system.providers.create');
  const canUpdate = hasPermission('system.providers.update');
  const canDelete = hasPermission('system.providers.delete');

  const {
    items: providers,
    filteredItems: filteredProviders,
    loading,
    refreshing,
    filters,
    setFilters,
    refresh: handleRefresh,
    dropdownOpen,
    setDropdownOpen,
  } = useResourceList<SystemProvider, ProviderListFilters>({
    fetcher: () => systemApi.getProviders(),
    initialFilters: { search: '', providerType: 'all', enabled: 'all' },
    filterFn: (provider, f) => {
      if (f.search) {
        const searchLower = f.search.toLowerCase();
        if (
          !provider.name.toLowerCase().includes(searchLower) &&
          !provider.description?.toLowerCase().includes(searchLower) &&
          !provider.provider_type.toLowerCase().includes(searchLower)
        ) {
          return false;
        }
      }
      if (f.providerType !== 'all' && provider.provider_type !== f.providerType) {
        return false;
      }
      if (f.enabled !== 'all') {
        if (f.enabled === 'enabled' && !provider.enabled) return false;
        if (f.enabled === 'disabled' && provider.enabled) return false;
      }
      return true;
    },
    errorMessage: 'Failed to load providers',
  });

  // Distinct provider types — for the type filter dropdown.
  const providerTypes = [...new Set(providers.map(p => p.provider_type))];

  // Click-to-expand state — Set<id> so multiple rows can be open at once.
  const [expandedProviderIds, setExpandedProviderIds] = useState<Set<string>>(new Set());
  const toggleExpanded = useCallback((id: string) => {
    setExpandedProviderIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) { next.delete(id); } else { next.add(id); }
      return next;
    });
  }, []);

  /** Inline own-detail for a single provider — shared by desktop + mobile. */
  const renderProviderDetail = (provider: SystemProvider) => {
    const hasConfig = provider.config && Object.keys(provider.config).length > 0;
    const hasCapabilities = provider.capabilities && Object.keys(provider.capabilities).length > 0;
    return (
      <>
        {provider.description && (
          <div className="col-span-full">
            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Description</label>
            <p className="text-theme-primary">{provider.description}</p>
          </div>
        )}
        <div>
          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Type</label>
          <p className="text-theme-primary">{providerTypeLabels[provider.provider_type] || provider.provider_type}</p>
        </div>
        <div>
          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Status</label>
          <p className="text-theme-primary">{provider.enabled ? 'Enabled' : 'Disabled'}</p>
        </div>
        <div>
          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Visibility</label>
          <p className="text-theme-primary">{provider.public ? 'Public' : 'Private'}</p>
        </div>
        <div>
          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Regions</label>
          <p className="text-theme-primary">{provider.region_count || 0}</p>
        </div>
        <div>
          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Connections</label>
          <p className="text-theme-primary">{provider.connection_count || 0}</p>
        </div>
        <div>
          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Provider ID</label>
          <p className="text-theme-primary font-mono text-xs truncate" title={provider.id}>{provider.id}</p>
        </div>
        <div>
          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
          <p className="text-theme-primary text-xs">{new Date(provider.created_at).toLocaleString()}</p>
        </div>
        <div>
          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Updated</label>
          <p className="text-theme-primary text-xs">{new Date(provider.updated_at).toLocaleString()}</p>
        </div>
        {hasConfig && (
          <div className="col-span-full">
            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Configuration</label>
            <pre className="bg-theme-surface rounded p-3 text-xs text-theme-primary overflow-x-auto border border-theme font-mono">
              {JSON.stringify(provider.config, null, 2)}
            </pre>
          </div>
        )}
        {hasCapabilities && (
          <div className="col-span-full">
            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Capabilities</label>
            <pre className="bg-theme-surface rounded p-3 text-xs text-theme-primary overflow-x-auto border border-theme font-mono">
              {JSON.stringify(provider.capabilities, null, 2)}
            </pre>
          </div>
        )}
      </>
    );
  };

  return (
    <ResponsiveListContainer
      loading={loading}
      refreshing={refreshing}
      totalCount={providers.length}
      filteredCount={filteredProviders.length}
      onRefresh={handleRefresh}
      className={className}
      emptyState={{
        icon: Cloud,
        title: 'No providers configured',
        description: 'Add cloud providers to manage infrastructure across multiple platforms',
        action: canCreate && onCreate ? { label: 'Add Provider', onClick: onCreate } : undefined,
      }}
    >
      <ResponsiveListContainer.Filters>
        <div className="flex-1">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <input
              type="text"
              placeholder="Search providers..."
              value={filters.search}
              onChange={(e) => setFilters({ ...filters, search: e.target.value })}
              className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
            />
          </div>
        </div>

        <div className="sm:w-40">
          <select
            value={filters.providerType}
            onChange={(e) => setFilters({ ...filters, providerType: e.target.value })}
            className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus appearance-none"
          >
            <option value="all">All Types</option>
            {providerTypes.map(type => (
              <option key={type} value={type}>
                {providerTypeLabels[type] || type}
              </option>
            ))}
          </select>
        </div>

        <div className="sm:w-32">
          <div className="relative">
            <Filter className="absolute left-3 top-1/2 transform -translate-y-1/2 text-theme-tertiary w-4 h-4" />
            <select
              value={filters.enabled}
              onChange={(e) => setFilters({ ...filters, enabled: e.target.value as ProviderListFilters['enabled'] })}
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
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Provider</th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Type</th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Regions</th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Connections</th>
              <th className="text-left py-3 px-4 font-medium text-theme-primary">Status</th>
              <th className="text-right py-3 px-4 font-medium text-theme-primary">Actions</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-theme">
            {filteredProviders.map((provider) => {
              const expanded = expandedProviderIds.has(provider.id);
              return (
                <React.Fragment key={provider.id}>
                  <tr className="hover:bg-theme-surface-hover transition-colors duration-200">
                    <td className="py-3 px-2 align-middle">
                      <button
                        type="button"
                        onClick={() => toggleExpanded(provider.id)}
                        className="p-1 text-theme-secondary hover:text-theme-primary rounded transition-colors"
                        title={expanded ? 'Collapse details' : 'Expand details'}
                      >
                        {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                      </button>
                    </td>

                    <td className="py-3 px-4">
                      <div>
                        <div className="flex items-center gap-2">
                          <span className="text-lg flex-shrink-0">
                            {providerTypeIcons[provider.provider_type] || '☁️'}
                          </span>
                          <span
                            className="font-medium text-theme-primary hover:text-theme-link cursor-pointer"
                            onClick={() => onView?.(provider)}
                          >
                            {provider.name}
                          </span>
                        </div>
                        {provider.description && (
                          <p className="text-sm text-theme-secondary mt-1 truncate max-w-xs">
                            {provider.description}
                          </p>
                        )}
                      </div>
                    </td>

                    <td className="py-3 px-4">
                      <span className="text-theme-secondary">
                        {providerTypeLabels[provider.provider_type] || provider.provider_type}
                      </span>
                    </td>

                    <td className="py-3 px-4">
                      <div className="flex items-center gap-1 text-theme-primary font-medium">
                        <MapPin className="w-4 h-4 text-theme-tertiary" />
                        <span>{provider.region_count || 0}</span>
                      </div>
                    </td>

                    <td className="py-3 px-4">
                      <div className="flex items-center gap-1 text-theme-primary font-medium">
                        <Server className="w-4 h-4 text-theme-tertiary" />
                        <span>{provider.connection_count || 0}</span>
                      </div>
                    </td>

                    <td className="py-3 px-4">
                      <div className="flex items-center gap-2">
                        <Badge variant={provider.enabled ? 'success' : 'secondary'} dot pulse={provider.enabled}>
                          {provider.enabled ? 'Enabled' : 'Disabled'}
                        </Badge>
                        <Badge variant={provider.public ? 'info' : 'secondary'}>
                          {provider.public ? (
                            <><Globe className="w-3 h-3 mr-1" />Public</>
                          ) : (
                            <><Lock className="w-3 h-3 mr-1" />Private</>
                          )}
                        </Badge>
                      </div>
                    </td>

                    <td className="py-3 px-4">
                      <div className="flex items-center justify-end gap-2">
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => onView?.(provider)}
                          title="View Details"
                        >
                          <Eye className="w-4 h-4" />
                        </Button>

                        {canUpdate && onEdit && (
                          <Button
                            variant="outline"
                            size="sm"
                            onClick={() => onEdit(provider)}
                            title="Edit Provider"
                          >
                            <Edit className="w-4 h-4" />
                          </Button>
                        )}

                        {canDelete && onDelete && (
                          <Button
                            variant="outline"
                            size="sm"
                            onClick={() => onDelete(provider.id)}
                            title="Delete Provider"
                          >
                            <Trash2 className="w-4 h-4" />
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
                          {renderProviderDetail(provider)}
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
        {filteredProviders.map((provider) => {
          const expanded = expandedProviderIds.has(provider.id);
          return (
            <div key={provider.id} className="p-4">
              {/* Header */}
              <div className="flex items-start justify-between mb-3">
                <div className="flex items-start gap-2 flex-1 min-w-0">
                  <button
                    type="button"
                    onClick={() => toggleExpanded(provider.id)}
                    className="p-1 -ml-1 mt-0.5 text-theme-secondary hover:text-theme-primary rounded transition-colors flex-shrink-0"
                    title={expanded ? 'Collapse details' : 'Expand details'}
                  >
                    {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                  </button>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 mb-1">
                      <span className="text-lg flex-shrink-0">
                        {providerTypeIcons[provider.provider_type] || '☁️'}
                      </span>
                      <span
                        className="font-medium text-theme-primary hover:text-theme-link cursor-pointer truncate"
                        onClick={() => onView?.(provider)}
                      >
                        {provider.name}
                      </span>
                    </div>
                    <p className="text-sm text-theme-secondary truncate">
                      {providerTypeLabels[provider.provider_type] || provider.provider_type}
                    </p>
                  </div>
                </div>

                <div className="relative">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={(e) => {
                      e.stopPropagation();
                      setDropdownOpen(dropdownOpen === provider.id ? null : provider.id);
                    }}
                  >
                    <MoreVertical className="w-4 h-4" />
                  </Button>

                  {dropdownOpen === provider.id && (
                    <div className="absolute right-0 mt-1 w-48 bg-theme-surface border border-theme rounded-lg shadow-lg z-10">
                      <div className="py-1">
                        <button
                          onClick={() => { onView?.(provider); setDropdownOpen(null); }}
                          className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                        >
                          <Eye className="w-4 h-4" />
                          View Details
                        </button>
                        {canUpdate && onEdit && (
                          <button
                            onClick={() => { onEdit(provider); setDropdownOpen(null); }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Edit className="w-4 h-4" />
                            Edit Provider
                          </button>
                        )}
                        {canDelete && onDelete && (
                          <button
                            onClick={() => { onDelete(provider.id); setDropdownOpen(null); }}
                            className="w-full text-left px-4 py-2 text-sm text-theme-error-fg hover:bg-theme-surface-hover flex items-center gap-2"
                          >
                            <Trash2 className="w-4 h-4" />
                            Delete Provider
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
                  <Badge variant={provider.enabled ? 'success' : 'secondary'} size="xs" dot>
                    {provider.enabled ? 'Enabled' : 'Disabled'}
                  </Badge>
                </div>
                <div className="text-center">
                  <div className="text-sm font-medium text-theme-primary">
                    {provider.region_count || 0}
                  </div>
                  <div className="text-xs text-theme-secondary">Regions</div>
                </div>
                <div className="text-center">
                  <div className="text-sm font-medium text-theme-primary">
                    {provider.connection_count || 0}
                  </div>
                  <div className="text-xs text-theme-secondary">Connections</div>
                </div>
              </div>

              {/* Visibility */}
              <div className="flex items-center gap-2">
                <Badge variant={provider.public ? 'info' : 'secondary'} size="xs">
                  {provider.public ? 'Public' : 'Private'}
                </Badge>
              </div>

              {/* Expanded body */}
              {expanded && (
                <div className="mt-3 pt-3 border-t border-theme grid grid-cols-2 gap-3 text-sm">
                  {renderProviderDetail(provider)}
                </div>
              )}
            </div>
          );
        })}
      </ResponsiveListContainer.Mobile>
    </ResponsiveListContainer>
  );
};

export default ProviderList;
