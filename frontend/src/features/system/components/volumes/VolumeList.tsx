import React, { useState } from 'react';
import {
  HardDrive,
  Search,
  MoreVertical,
  Eye,
  Edit2,
  Trash2,
  Link,
  Unlink,
  Camera,
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { systemApi } from '@system/features/system/services/systemApi';
import { useInfiniteResourceList } from '@system/features/system/hooks/useResourceList';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import type { SystemProviderVolume } from '@system/features/system/types/system.types';

interface VolumeListProps {
  onView?: (volume: SystemProviderVolume) => void;
  onEdit?: (volume: SystemProviderVolume) => void;
  onDelete?: (volumeId: string) => void;
  onCreate?: () => void;
  onAttach?: (volume: SystemProviderVolume) => void;
  onDetach?: (volume: SystemProviderVolume) => void;
  onSnapshot?: (volume: SystemProviderVolume) => void;
}

interface VolumeListFilters {
  search: string;
  status: string;
  attached: 'all' | 'attached' | 'unattached';
}

const statusVariants: Record<string, 'success' | 'warning' | 'danger' | 'secondary' | 'info'> = {
  available: 'success',
  'in-use': 'info',
  creating: 'warning',
  deleting: 'warning',
  deleted: 'secondary',
  error: 'danger'
};

const volumeTypeLabels: Record<string, string> = {
  gp2: 'General Purpose SSD (gp2)',
  gp3: 'General Purpose SSD (gp3)',
  io1: 'Provisioned IOPS SSD (io1)',
  io2: 'Provisioned IOPS SSD (io2)',
  st1: 'Throughput Optimized HDD',
  sc1: 'Cold HDD',
  standard: 'Magnetic',
  ssd: 'SSD',
  hdd: 'HDD',
  custom: 'Custom'
};

const formatSize = (sizeGb: number): string => {
  if (sizeGb >= 1024) return `${(sizeGb / 1024).toFixed(1)} TB`;
  return `${sizeGb} GB`;
};

export const VolumeList: React.FC<VolumeListProps> = ({
  onView,
  onEdit,
  onDelete,
  onCreate,
  onAttach,
  onDetach,
  onSnapshot,
}) => {
  const { hasPermission } = usePermissions();

  const canCreate = hasPermission('system.volumes.create');
  const canUpdate = hasPermission('system.volumes.update');
  const canDelete = hasPermission('system.volumes.delete');
  const canSnapshot = hasPermission('system.volumes.snapshot');

  // All filters server-side: status, attached, search.
  // Search is committed via form submit; status & attached refetch on change.
  const {
    items: volumes,
    filteredItems: filteredVolumes,
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
  } = useInfiniteResourceList<SystemProviderVolume, VolumeListFilters>({
    fetcher: ({ page, per_page, filters }) => {
      const params: { page: number; per_page: number; status?: string; attached?: boolean; search?: string } = { page, per_page };
      if (filters.status !== 'all') params.status = filters.status;
      if (filters.attached === 'attached') params.attached = true;
      if (filters.attached === 'unattached') params.attached = false;
      if (filters.search) params.search = filters.search;
      return systemApi.getVolumes(params).then(d => ({ items: d.volumes, meta: d.meta }));
    },
    initialFilters: { search: '', status: 'all', attached: 'all' },
    perPage: 20,
    serverFilterKey: (f) => JSON.stringify({ search: f.search, status: f.status, attached: f.attached }),
    errorMessage: 'Failed to load volumes',
  });

  const [searchInput, setSearchInput] = useState<string>(filters.search);
  const handleSearch = (e: React.FormEvent) => {
    e.preventDefault();
    setFilters({ ...filters, search: searchInput });
  };

  return (
    <ResponsiveListContainer
      loading={loading}
      refreshing={refreshing}
      totalCount={volumes.length}
      filteredCount={filteredVolumes.length}
      onRefresh={handleRefresh}
      onLoadMore={loadMore}
      hasMore={hasMore}
      loadingMore={loadingMore}
      serverTotalCount={totalCount}
      emptyState={{
        icon: HardDrive,
        title: 'No volumes found',
        description: filters.search || filters.status !== 'all' || filters.attached !== 'all'
          ? 'Try adjusting your filters'
          : 'Create a volume to get started',
        action: canCreate && onCreate && !filters.search && filters.status === 'all' && filters.attached === 'all'
          ? { label: 'Create Volume', onClick: onCreate }
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
              placeholder="Search volumes (press Enter)..."
              className="w-full pl-10 pr-4 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
            />
          </div>
        </form>

        <select
          value={filters.status}
          onChange={(e) => setFilters({ ...filters, status: e.target.value })}
          className="px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary text-sm focus:outline-none focus:border-theme-focus"
        >
          <option value="all">All Status</option>
          <option value="available">Available</option>
          <option value="in-use">In Use</option>
          <option value="creating">Creating</option>
          <option value="error">Error</option>
        </select>

        <select
          value={filters.attached}
          onChange={(e) => setFilters({ ...filters, attached: e.target.value as VolumeListFilters['attached'] })}
          className="px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary text-sm focus:outline-none focus:border-theme-focus"
        >
          <option value="all">All Volumes</option>
          <option value="attached">Attached</option>
          <option value="unattached">Unattached</option>
        </select>

      </ResponsiveListContainer.Filters>

      <ResponsiveListContainer.Desktop>
        <table className="w-full">
          <thead>
            <tr className="border-b border-theme bg-theme-background">
              <th className="px-4 py-3 text-left text-sm font-medium text-theme-secondary">Volume</th>
              <th className="px-4 py-3 text-left text-sm font-medium text-theme-secondary">Size</th>
              <th className="px-4 py-3 text-left text-sm font-medium text-theme-secondary">Type</th>
              <th className="px-4 py-3 text-left text-sm font-medium text-theme-secondary">Status</th>
              <th className="px-4 py-3 text-left text-sm font-medium text-theme-secondary">Attached To</th>
              <th className="px-4 py-3 text-right text-sm font-medium text-theme-secondary">Actions</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-theme">
            {filteredVolumes.map((volume) => (
              <tr key={volume.id} className="hover:bg-theme-surface-hover transition-colors">
                <td className="px-4 py-3">
                  <div className="flex items-center gap-3">
                    <HardDrive className="w-5 h-5 text-theme-tertiary" />
                    <div>
                      <p className="font-medium text-theme-primary">{volume.name}</p>
                      {volume.description && (
                        <p className="text-sm text-theme-secondary truncate max-w-xs">
                          {volume.description}
                        </p>
                      )}
                    </div>
                  </div>
                </td>
                <td className="px-4 py-3">
                  <span className="text-theme-primary font-mono">{formatSize(volume.size_gb)}</span>
                  {volume.iops && (
                    <span className="ml-2 text-sm text-theme-secondary">{volume.iops} IOPS</span>
                  )}
                </td>
                <td className="px-4 py-3">
                  <Badge variant="outline" size="sm">
                    {volumeTypeLabels[volume.volume_type] || volume.volume_type}
                  </Badge>
                </td>
                <td className="px-4 py-3">
                  <Badge
                    variant={statusVariants[volume.status] || 'secondary'}
                    size="sm"
                    dot
                    pulse={volume.status === 'creating'}
                  >
                    {volume.status}
                  </Badge>
                </td>
                <td className="px-4 py-3">
                  {volume.node_instance_id ? (
                    <div className="flex items-center gap-2">
                      <Link className="w-4 h-4 text-theme-success" />
                      <span className="text-sm text-theme-primary">{volume.device_name || 'Attached'}</span>
                    </div>
                  ) : (
                    <span className="text-sm text-theme-tertiary">Not attached</span>
                  )}
                </td>
                <td className="px-4 py-3">
                  <div className="flex items-center justify-end gap-2">
                    {onView && (
                      <Button variant="ghost" size="sm" onClick={() => onView(volume)}>
                        <Eye className="w-4 h-4" />
                      </Button>
                    )}
                    <div className="relative">
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={(e) => {
                          e.stopPropagation();
                          setDropdownOpen(dropdownOpen === volume.id ? null : volume.id);
                        }}
                      >
                        <MoreVertical className="w-4 h-4" />
                      </Button>
                      {dropdownOpen === volume.id && (
                        <div className="absolute right-0 top-full mt-1 w-48 bg-theme-surface rounded-lg shadow-lg border border-theme z-10">
                          {canUpdate && onEdit && (
                            <button
                              onClick={() => { onEdit(volume); setDropdownOpen(null); }}
                              className="w-full flex items-center gap-2 px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover"
                            >
                              <Edit2 className="w-4 h-4" />
                              Edit
                            </button>
                          )}
                          {volume.status === 'available' && !volume.node_instance_id && onAttach && (
                            <button
                              onClick={() => { onAttach(volume); setDropdownOpen(null); }}
                              className="w-full flex items-center gap-2 px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover"
                            >
                              <Link className="w-4 h-4" />
                              Attach
                            </button>
                          )}
                          {volume.status === 'in-use' && volume.node_instance_id && onDetach && (
                            <button
                              onClick={() => { onDetach(volume); setDropdownOpen(null); }}
                              className="w-full flex items-center gap-2 px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover"
                            >
                              <Unlink className="w-4 h-4" />
                              Detach
                            </button>
                          )}
                          {canSnapshot && volume.status !== 'creating' && onSnapshot && (
                            <button
                              onClick={() => { onSnapshot(volume); setDropdownOpen(null); }}
                              className="w-full flex items-center gap-2 px-4 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover"
                            >
                              <Camera className="w-4 h-4" />
                              Create Snapshot
                            </button>
                          )}
                          {canDelete && onDelete && volume.status === 'available' && !volume.node_instance_id && (
                            <>
                              <div className="border-t border-theme my-1" />
                              <button
                                onClick={() => { onDelete(volume.id); setDropdownOpen(null); }}
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
        {filteredVolumes.map((volume) => (
          <div key={volume.id} className="p-4">
            <div className="flex items-start justify-between mb-3">
              <div className="flex items-center gap-3">
                <HardDrive className="w-5 h-5 text-theme-tertiary" />
                <div>
                  <p className="font-medium text-theme-primary">{volume.name}</p>
                  <p className="text-sm text-theme-secondary">{formatSize(volume.size_gb)}</p>
                </div>
              </div>
              <Badge variant={statusVariants[volume.status] || 'secondary'} size="sm" dot>
                {volume.status}
              </Badge>
            </div>
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Badge variant="outline" size="xs">
                  {volumeTypeLabels[volume.volume_type] || volume.volume_type}
                </Badge>
                {volume.encrypted && (<Badge variant="info" size="xs">Encrypted</Badge>)}
              </div>
              <div className="flex items-center gap-2">
                {onView && (
                  <Button variant="ghost" size="sm" onClick={() => onView(volume)}>
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

export default VolumeList;
