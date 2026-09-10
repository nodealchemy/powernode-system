import React from 'react';
import { MapPin, Plus, Edit2, Trash2, Layers, ChevronDown, ChevronRight } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { EntityLink } from '@/shared/components/entity';
import type {
  SystemProviderRegion,
  SystemProviderAvailabilityZone
} from '@system/features/system/types/system.types';

export interface ProviderRegionsTabProps {
  regions: SystemProviderRegion[];
  canManageRegions: boolean;
  canUpdateRegions: boolean;
  canDeleteRegions: boolean;
  hasCloudConnection: boolean;
  expandedRegionId: string | null;
  zones: SystemProviderAvailabilityZone[];
  zonesLoading: boolean;
  zonesTotal: number;
  onAddRegion: () => void;
  onEditRegion: (region: SystemProviderRegion) => void;
  onDeleteRegionRequest: (region: SystemProviderRegion) => void;
  onToggleRegionZones: (region: SystemProviderRegion) => void;
  onAddZone: (regionId: string) => void;
  onEditZone: (regionId: string, zone: SystemProviderAvailabilityZone) => void;
  onDeleteZone: (regionId: string, zone: SystemProviderAvailabilityZone) => void;
}

export const ProviderRegionsTab: React.FC<ProviderRegionsTabProps> = ({
  regions,
  canManageRegions,
  canUpdateRegions,
  canDeleteRegions,
  hasCloudConnection,
  expandedRegionId,
  zones,
  zonesLoading,
  zonesTotal,
  onAddRegion,
  onEditRegion,
  onDeleteRegionRequest,
  onToggleRegionZones,
  onAddZone,
  onEditZone,
  onDeleteZone,
}) => (
  <div className="space-y-4">
    {/* Header with Add button */}
    {canManageRegions && (
      <div className="flex justify-end">
        <Button variant="primary" size="sm" onClick={onAddRegion}>
          <Plus className="w-4 h-4 mr-2" />
          Add Region
        </Button>
      </div>
    )}

    {regions.length === 0 ? (
      <div className="text-center py-12">
        <MapPin className="w-12 h-12 text-theme-tertiary mx-auto mb-4" />
        <p className="text-theme-secondary">No regions configured</p>
        <p className="text-sm text-theme-tertiary mt-1">
          Add regions to define deployment locations
        </p>
      </div>
    ) : (
      regions.map(region => (
        <div
          key={region.id}
          className="bg-theme-background rounded-lg p-4 border border-theme"
        >
          <div className="flex items-start justify-between mb-2">
            <div>
              <h4 className="font-medium text-theme-primary">{region.name}</h4>
              {region.region_code && (
                <p className="text-sm text-theme-secondary">{region.region_code}</p>
              )}
              {region.provider_id && (
                <p className="text-xs text-theme-secondary mt-1">
                  Provider:{' '}
                  <EntityLink
                    type="provider"
                    id={region.provider_id}
                    label={region.provider_name || region.provider_id}
                    className="text-xs"
                  />
                </p>
              )}
            </div>
            <div className="flex items-center gap-2">
              <button
                type="button"
                onClick={() => onToggleRegionZones(region)}
                className="flex items-center gap-1 text-sm text-theme-secondary hover:text-theme-primary"
                aria-expanded={expandedRegionId === region.id}
                title="Show availability zones"
                data-testid={`region-zones-toggle-${region.id}`}
              >
                {expandedRegionId === region.id ? (
                  <ChevronDown className="w-4 h-4" />
                ) : (
                  <ChevronRight className="w-4 h-4" />
                )}
                {region.zone_count || 0} zones • {region.instance_type_count || 0} instance types
              </button>
              {canManageRegions && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => onEditRegion(region)}
                  title="Edit region"
                >
                  <Edit2 className="w-4 h-4" />
                </Button>
              )}
              {canDeleteRegions && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => onDeleteRegionRequest(region)}
                  title="Delete region"
                  className="text-theme-error-fg hover:text-theme-error-fg"
                >
                  <Trash2 className="w-4 h-4" />
                </Button>
              )}
            </div>
          </div>
          {region.description && (
            <p className="text-sm text-theme-secondary mt-2">{region.description}</p>
          )}
          {region.endpoint_url && (
            <p className="text-xs text-theme-tertiary mt-2 font-mono">
              {region.endpoint_url}
            </p>
          )}

          {expandedRegionId === region.id && (
            <div
              className="mt-3 pt-3 border-t border-theme"
              data-testid={`region-zones-${region.id}`}
            >
              <div className="flex items-center justify-between mb-2">
                <h5 className="text-sm font-medium text-theme-primary flex items-center gap-2">
                  <Layers className="w-4 h-4" />
                  Availability zones
                </h5>
                {canManageRegions && (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => onAddZone(region.id)}
                    title={
                      hasCloudConnection
                        ? 'Add availability zone (manual override)'
                        : 'Add availability zone'
                    }
                  >
                    <Plus className="w-4 h-4 mr-1" />
                    Add Zone
                  </Button>
                )}
              </div>

              {zonesLoading ? (
                <LoadingSpinner size="sm" />
              ) : zones.length === 0 ? (
                <p className="text-sm text-theme-tertiary">
                  No availability zones in this region
                </p>
              ) : (
                <ul className="space-y-1">
                  {zonesTotal > zones.length && (
                    <li className="text-xs text-theme-warning-fg">
                      Showing {zones.length} of {zonesTotal} zones — narrow the
                      catalog or use the API for the rest.
                    </li>
                  )}
                  {zones.map(zone => (
                    <li
                      key={zone.id}
                      className="flex items-center justify-between gap-2 text-sm"
                      data-testid={`availability-zone-${zone.id}`}
                    >
                      <span className="text-theme-primary">
                        {zone.name}{' '}
                        <span className="font-mono text-theme-secondary">
                          {zone.zone_code}
                        </span>
                      </span>
                      <span className="flex items-center gap-2">
                        <Badge
                          variant={zone.status === 'available' ? 'success' : 'warning'}
                          size="xs"
                        >
                          {zone.status}
                        </Badge>
                        {canUpdateRegions && (
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => onEditZone(region.id, zone)}
                            title="Edit availability zone"
                          >
                            <Edit2 className="w-4 h-4" />
                          </Button>
                        )}
                        {canDeleteRegions && (
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => onDeleteZone(region.id, zone)}
                            title="Delete availability zone"
                            className="text-theme-error-fg hover:text-theme-error-fg"
                          >
                            <Trash2 className="w-4 h-4" />
                          </Button>
                        )}
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          )}
        </div>
      ))
    )}
  </div>
);

export default ProviderRegionsTab;
