import React, { useState } from 'react';
import {
  Network,
  Search,
  MoreVertical,
  Eye,
  Edit2,
  Trash2,
  Globe
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { systemApi } from '@system/features/system/services/systemApi';
import { useInfiniteResourceList } from '@system/features/system/hooks/useResourceList';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import type { SystemProviderNetwork } from '@system/features/system/types/system.types';

interface NetworkListProps {
  onView?: (network: SystemProviderNetwork) => void;
  onEdit?: (network: SystemProviderNetwork) => void;
  onDelete?: (networkId: string) => void;
  onCreate?: () => void;
}

interface NetworkListFilters {
  search: string;
  statusFilter: 'all' | 'available' | 'pending' | 'error';
}

const statusVariants: Record<string, 'success' | 'warning' | 'danger' | 'secondary'> = {
  available: 'success',
  pending: 'warning',
  deleting: 'warning',
  deleted: 'secondary',
  error: 'danger'
};

export const NetworkList: React.FC<NetworkListProps> = ({
  onView,
  onEdit,
  onDelete,
  onCreate
}) => {
  const { hasPermission } = usePermissions();

  const canCreate = hasPermission('system.networks.create');
  const canUpdate = hasPermission('system.networks.update');
  const canDelete = hasPermission('system.networks.delete');

  // Server-side search (committed on form submit) + client-side status filter.
  const {
    items: networks,
    filteredItems: filteredNetworks,
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
  } = useInfiniteResourceList<SystemProviderNetwork, NetworkListFilters>({
    fetcher: ({ page, per_page, filters }) => {
      const params: { page: number; per_page: number; search?: string } = { page, per_page };
      if (filters.search) params.search = filters.search;
      return systemApi.getNetworks(params).then(d => ({ items: d.networks, meta: d.meta }));
    },
    initialFilters: { search: '', statusFilter: 'all' },
    perPage: 20,
    serverFilterKey: (f) => JSON.stringify({ search: f.search }),
    clientFilterFn: (n, f) => f.statusFilter === 'all' || n.status === f.statusFilter,
    errorMessage: 'Failed to load networks',
  });

  // Search input is uncommitted local state; commits on form submit.
  const [searchInput, setSearchInput] = useState<string>(filters.search);
  const handleSearch = (e: React.FormEvent) => {
    e.preventDefault();
    setFilters({ ...filters, search: searchInput });
  };

  return (
    <ResponsiveListContainer
      loading={loading}
      refreshing={refreshing}
      totalCount={networks.length}
      filteredCount={filteredNetworks.length}
      onRefresh={handleRefresh}
      onLoadMore={loadMore}
      hasMore={hasMore}
      loadingMore={loadingMore}
      serverTotalCount={totalCount}
      emptyState={{
        icon: Network,
        title: 'No networks found',
        description: filters.search || filters.statusFilter !== 'all'
          ? 'Try adjusting your filters'
          : 'Create a network to get started',
        action: canCreate && onCreate && !filters.search && filters.statusFilter === 'all'
          ? { label: 'Create Network', onClick: onCreate }
          : undefined,
      }}
    >
      <ResponsiveListContainer.Filters>
        <form onSubmit={handleSearch} className="flex-1 max-w-md">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-theme-tertiary" />
            <input
              type="text"
              value={searchInput}
              onChange={(e) => setSearchInput(e.target.value)}
              placeholder="Search networks (press Enter)..."
              className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
            />
          </div>
        </form>

        <select
          value={filters.statusFilter}
          onChange={(e) => setFilters({ ...filters, statusFilter: e.target.value as NetworkListFilters['statusFilter'] })}
          className="px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary text-sm focus:outline-none focus:border-theme-focus"
        >
          <option value="all">All Status</option>
          <option value="available">Available</option>
          <option value="pending">Pending</option>
          <option value="error">Error</option>
        </select>

      </ResponsiveListContainer.Filters>

      <ResponsiveListContainer.Desktop>
        <table className="w-full">
          <thead>
            <tr className="border-b border-theme bg-theme-background">
              <th className="px-4 py-3 text-left text-sm font-medium text-theme-secondary">Network</th>
              <th className="px-4 py-3 text-left text-sm font-medium text-theme-secondary">CIDR Block</th>
              <th className="px-4 py-3 text-left text-sm font-medium text-theme-secondary">Status</th>
              <th className="px-4 py-3 text-left text-sm font-medium text-theme-secondary">Region</th>
              <th className="px-4 py-3 text-left text-sm font-medium text-theme-secondary">Features</th>
              <th className="px-4 py-3 text-right text-sm font-medium text-theme-secondary">Actions</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-theme">
            {filteredNetworks.map((network) => (
              <tr key={network.id} className="hover:bg-theme-surface-hover transition-colors">
                <td className="px-4 py-3">
                  <div className="flex items-center gap-3">
                    <Network className="w-5 h-5 text-theme-tertiary" />
                    <div>
                      <p className="font-medium text-theme-primary">{network.name}</p>
                      {network.description && (
                        <p className="text-sm text-theme-secondary truncate max-w-xs">
                          {network.description}
                        </p>
                      )}
                    </div>
                  </div>
                </td>
                <td className="px-4 py-3">
                  <span className="font-mono text-theme-primary">{network.cidr_block}</span>
                </td>
                <td className="px-4 py-3">
                  <Badge
                    variant={statusVariants[network.status] || 'secondary'}
                    size="sm"
                    dot
                    pulse={network.status === 'pending'}
                  >
                    {network.status}
                  </Badge>
                </td>
                <td className="px-4 py-3">
                  <span className="text-sm text-theme-secondary">
                    {network.region_name || network.provider_region_id || '—'}
                  </span>
                </td>
                <td className="px-4 py-3">
                  <div className="flex items-center gap-2">
                    {network.is_default && (<Badge variant="info" size="xs">Default</Badge>)}
                    {network.dns_support && (
                      <Badge variant="outline" size="xs">
                        <Globe className="w-3 h-3 mr-1" />
                        DNS
                      </Badge>
                    )}
                  </div>
                </td>
                <td className="px-4 py-3">
                  <div className="flex items-center justify-end gap-2">
                    {onView && (
                      <Button variant="ghost" size="sm" onClick={() => onView(network)}>
                        <Eye className="w-4 h-4" />
                      </Button>
                    )}
                    <div className="relative">
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={(e) => {
                          e.stopPropagation();
                          setDropdownOpen(dropdownOpen === network.id ? null : network.id);
                        }}
                      >
                        <MoreVertical className="w-4 h-4" />
                      </Button>
                      {dropdownOpen === network.id && (
                        <div className="absolute right-0 top-full mt-1 w-40 bg-theme-surface rounded-lg shadow-lg border border-theme z-10">
                          {canUpdate && onEdit && (
                            <button
                              onClick={() => { onEdit(network); setDropdownOpen(null); }}
                              className="w-full flex items-center gap-2 px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover"
                            >
                              <Edit2 className="w-4 h-4" />
                              Edit
                            </button>
                          )}
                          {canDelete && onDelete && network.status === 'available' && !network.is_default && (
                            <>
                              <div className="border-t border-theme my-1" />
                              <button
                                onClick={() => { onDelete(network.id); setDropdownOpen(null); }}
                                className="w-full flex items-center gap-2 px-4 py-2 text-sm text-theme-error hover:bg-theme-surface-hover"
                              >
                                <Trash2 className="w-4 h-4" />
                                Delete
                              </button>
                            </>
                          )}
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
        {filteredNetworks.map((network) => (
          <div key={network.id} className="p-4">
            <div className="flex items-start justify-between mb-3">
              <div className="flex items-center gap-3">
                <Network className="w-5 h-5 text-theme-tertiary" />
                <div>
                  <p className="font-medium text-theme-primary">{network.name}</p>
                  <p className="text-sm font-mono text-theme-secondary">{network.cidr_block}</p>
                </div>
              </div>
              <Badge variant={statusVariants[network.status] || 'secondary'} size="sm" dot>
                {network.status}
              </Badge>
            </div>
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                {network.is_default && (<Badge variant="info" size="xs">Default</Badge>)}
                {network.dns_support && (<Badge variant="outline" size="xs">DNS</Badge>)}
              </div>
              <div className="flex items-center gap-2">
                {onView && (
                  <Button variant="ghost" size="sm" onClick={() => onView(network)}>
                    <Eye className="w-4 h-4" />
                  </Button>
                )}
              </div>
            </div>
          </div>
        ))}
      </ResponsiveListContainer.Mobile>
    </ResponsiveListContainer>
  );
};

export default NetworkList;
