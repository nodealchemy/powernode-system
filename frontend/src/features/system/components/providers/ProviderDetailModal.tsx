import React, { useState, useEffect, useCallback, useRef } from 'react';
import {
  Cloud,
  MapPin,
  Server,
  Settings,
  Globe,
  Lock,
  CheckCircle,
  XCircle,
  Plus,
  Edit2,
  Trash2,
  RefreshCw,
  DownloadCloud,
  Cpu,
  Layers,
  ChevronDown,
  ChevronRight
} from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { TabContainer, type Tab } from '@/shared/components/ui/TabContainer';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { EntityLink } from '@/shared/components/entity';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { systemApi } from '@system/features/system/services/systemApi';
import { RegionFormModal } from './RegionFormModal';
import { ConnectionFormModal } from './ConnectionFormModal';
import { InstanceTypeFormModal } from './InstanceTypeFormModal';
import { AvailabilityZoneFormModal } from './AvailabilityZoneFormModal';
import { logger } from '@/shared/utils/logger';
import type {
  SystemProvider,
  SystemProviderRegion,
  SystemProviderConnection,
  SystemProviderInstanceType,
  SystemProviderAvailabilityZone
} from '@system/features/system/types/system.types';
import type { ProviderCatalogSummary } from '@system/features/system/services/api/providersApi';

interface ProviderDetailModalProps {
  providerId: string | null;
  isOpen: boolean;
  onClose: () => void;
  onEdit?: (provider: SystemProvider) => void;
}

type TabId = 'info' | 'regions' | 'instance_types' | 'connections' | 'config';

const providerTypeLabels: Record<string, string> = {
  aws: 'Amazon Web Services',
  openstack: 'OpenStack',
  gcp: 'Google Cloud Platform',
  azure: 'Microsoft Azure',
  digitalocean: 'DigitalOcean',
  custom: 'Custom Provider'
};

const CATALOG_RESOURCE_LABELS: Array<[keyof ProviderCatalogSummary, string]> = [
  ['regions', 'regions'],
  ['availability_zones', 'availability zones'],
  ['instance_types', 'instance types'],
  ['volume_types', 'volume types']
];

/**
 * One-line summary of a catalog sync. Reports the total per resource and, when
 * anything was created, how many of those are new — an operator running this to
 * pick up a newly released instance type wants that number, and "0 new" on a
 * repeat sync is the signal that nothing changed upstream.
 *
 * `total` is absent on the availability-zone phase (synced per region, so the
 * service reports only created/updated); derive it rather than printing NaN.
 */
function summariseCatalog(catalog: ProviderCatalogSummary): string {
  return CATALOG_RESOURCE_LABELS.map(([key, label]) => {
    const counts = catalog?.[key];
    if (!counts) return `${label} 0`;
    const total = counts.total ?? counts.created + counts.updated;
    return counts.created > 0
      ? `${label} ${total} (${counts.created} new)`
      : `${label} ${total}`;
  }).join(', ');
}

/**
 * ProviderDetailModal - Modal for viewing provider details with tabs
 */
export const ProviderDetailModal: React.FC<ProviderDetailModalProps> = ({
  providerId,
  isOpen,
  onClose,
  onEdit
}) => {
  const { addNotification } = useNotifications();
  const { hasPermission } = usePermissions();

  // Permission checks
  const canManageRegions = hasPermission('system.regions.create');
  const canDeleteRegions = hasPermission('system.regions.delete');
  const canManageConnections = hasPermission('system.connections.create');
  const canDeleteConnections = hasPermission('system.connections.delete');
  const canTestConnections = hasPermission('system.connections.test');
  // ProviderConnectionsController#sync_catalog gates on connections.update, the
  // same permission as edit — not .test, which only probes credentials.
  const canSyncCatalog = hasPermission('system.connections.update');
  // Sub-catalog writes follow their own controllers' gates: instance types are
  // ProviderInstanceTypesController (system.providers.*), zones are
  // ProviderAvailabilityZonesController (system.regions.*).
  const canManageInstanceTypes = hasPermission('system.providers.create');
  const canUpdateInstanceTypes = hasPermission('system.providers.update');
  const canDeleteInstanceTypes = hasPermission('system.providers.delete');
  const canUpdateRegions = hasPermission('system.regions.update');

  const [provider, setProvider] = useState<SystemProvider | null>(null);
  const [regions, setRegions] = useState<SystemProviderRegion[]>([]);
  const [connections, setConnections] = useState<SystemProviderConnection[]>([]);
  const [loading, setLoading] = useState(false);
  const [activeTab, setActiveTab] = useState<TabId>('info');

  // Region modal state
  const [showRegionModal, setShowRegionModal] = useState(false);
  const [editRegion, setEditRegion] = useState<SystemProviderRegion | null>(null);
  const [regionToDelete, setRegionToDelete] = useState<SystemProviderRegion | null>(null);
  const [deletingRegion, setDeletingRegion] = useState(false);

  // Connection modal state
  const [showConnectionModal, setShowConnectionModal] = useState(false);
  const [editConnection, setEditConnection] = useState<SystemProviderConnection | null>(null);
  const [connectionToDelete, setConnectionToDelete] = useState<SystemProviderConnection | null>(null);
  const [deletingConnection, setDeletingConnection] = useState(false);
  const [testingConnection, setTestingConnection] = useState<string | null>(null);
  const [syncingCatalog, setSyncingCatalog] = useState<string | null>(null);

  // Sub-catalog: instance types (provider-scoped) and zones (region-scoped).
  const [instanceTypes, setInstanceTypes] = useState<SystemProviderInstanceType[]>([]);
  const [instanceTypesLoading, setInstanceTypesLoading] = useState(false);
  const [showInstanceTypeModal, setShowInstanceTypeModal] = useState(false);
  const [editInstanceType, setEditInstanceType] = useState<SystemProviderInstanceType | null>(null);
  const [expandedRegionId, setExpandedRegionId] = useState<string | null>(null);
  const [zones, setZones] = useState<SystemProviderAvailabilityZone[]>([]);
  const [zonesLoading, setZonesLoading] = useState(false);
  const [zonesTotal, setZonesTotal] = useState(0);
  const [instanceTypesTotal, setInstanceTypesTotal] = useState(0);
  /**
   * Guards the shared `zones` array against a late response. Expanding region B
   * while A's fetch is still open would otherwise render A's zones under B, and
   * the row's Delete would then aim a B-scoped request at an A zone.
   */
  const zoneRequestRef = useRef(0);
  const [zoneModalRegionId, setZoneModalRegionId] = useState<string | null>(null);
  const [editZone, setEditZone] = useState<SystemProviderAvailabilityZone | null>(null);

  /**
   * A provider with at least one connection gets its catalog from
   * sync_catalog, so a hand-written entry is an override rather than the
   * primary source. Drives the "manual override" labelling.
   */
  const hasCloudConnection = connections.length > 0;

  useEffect(() => {
    if (isOpen && providerId) {
      setLoading(true);
      setActiveTab('info');

      Promise.all([
        systemApi.getProvider(providerId),
        systemApi.getProviderRegions(providerId),
        systemApi.getProviderConnections()
      ])
        .then(([providerData, regionsData, connectionsData]) => {
          setProvider(providerData);
          setRegions(regionsData);
          // Filter connections for this provider
          setConnections(connectionsData.filter(c => c.provider_id === providerId));
        })
        .catch(() => {
          setProvider(null);
          setRegions([]);
          setConnections([]);
        })
        .finally(() => {
          setLoading(false);
        });
    }
  }, [isOpen, providerId]);

  // Refresh data
  const refreshData = useCallback(async () => {
    if (!providerId) return;

    try {
      const [regionsData, connectionsData] = await Promise.all([
        systemApi.getProviderRegions(providerId),
        systemApi.getProviderConnections()
      ]);
      setRegions(regionsData);
      setConnections(connectionsData.filter(c => c.provider_id === providerId));
    } catch (error) {
      addNotification({
        type: 'error',
        message: 'Failed to refresh data'
      });
    }
  }, [providerId, addNotification]);

  // Region handlers
  const handleAddRegion = useCallback(() => {
    setEditRegion(null);
    setShowRegionModal(true);
  }, []);

  const handleEditRegion = useCallback((region: SystemProviderRegion) => {
    setEditRegion(region);
    setShowRegionModal(true);
  }, []);

  const handleDeleteRegion = useCallback(async () => {
    if (!providerId || !regionToDelete) return;

    setDeletingRegion(true);
    try {
      await systemApi.deleteProviderRegion(providerId, regionToDelete.id);
      addNotification({
        type: 'success',
        message: `Region "${regionToDelete.name}" deleted successfully`
      });
      setRegionToDelete(null);
      await refreshData();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: `Failed to delete region: ${errorMessage}`
      });
    } finally {
      setDeletingRegion(false);
    }
  }, [providerId, regionToDelete, addNotification, refreshData]);

  // --- Sub-catalog: instance types (provider-scoped) ---------------------

  const refreshInstanceTypes = useCallback(async () => {
    if (!providerId) return;
    setInstanceTypesLoading(true);
    try {
      const { instanceTypes: rows, total } =
        await systemApi.getProviderInstanceTypesPage(providerId);
      setInstanceTypes(rows);
      setInstanceTypesTotal(total);
    } catch (error) {
      logger.error('[ProviderDetailModal] instance type load failed', error);
      addNotification({ type: 'error', message: 'Failed to load instance types' });
    } finally {
      setInstanceTypesLoading(false);
    }
  }, [providerId, addNotification]);

  // Fetched lazily: the tab is one of five and the list is the only consumer.
  useEffect(() => {
    if (isOpen && activeTab === 'instance_types' && providerId) {
      void refreshInstanceTypes();
    }
  }, [isOpen, activeTab, providerId, refreshInstanceTypes]);

  // Every piece of sub-catalog state is scoped to ONE provider. Dropping it
  // when providerId changes stops the previous provider's instance types and
  // zones rendering under the new provider's name.
  useEffect(() => {
    setInstanceTypes([]);
    setInstanceTypesTotal(0);
    setZonesTotal(0);
    setEditInstanceType(null);
    setShowInstanceTypeModal(false);
    setExpandedRegionId(null);
    setZones([]);
    setZoneModalRegionId(null);
    setEditZone(null);
  }, [providerId]);

  const handleDeleteInstanceType = useCallback(
    async (instanceType: SystemProviderInstanceType) => {
      if (!providerId) return;
      try {
        await systemApi.deleteProviderInstanceType(providerId, instanceType.id);
        addNotification({
          type: 'success',
          message: `Instance type "${instanceType.name}" deleted successfully`
        });
        await refreshInstanceTypes();
      } catch (error) {
        const errorMessage = error instanceof Error ? error.message : 'An error occurred';
        addNotification({
          type: 'error',
          message: `Failed to delete instance type: ${errorMessage}`
        });
      }
    },
    [providerId, addNotification, refreshInstanceTypes]
  );

  // --- Sub-catalog: availability zones (region-scoped) --------------------

  const loadZones = useCallback(
    async (regionId: string) => {
      if (!providerId) return;
      const token = ++zoneRequestRef.current;
      setZonesLoading(true);
      try {
        const { zones: rows, total } = await systemApi.getProviderAvailabilityZonesPage(
          providerId,
          regionId
        );
        if (token !== zoneRequestRef.current) return;
        setZones(rows);
        setZonesTotal(total);
      } catch (error) {
        if (token !== zoneRequestRef.current) return;
        logger.error('[ProviderDetailModal] availability zone load failed', error);
        addNotification({ type: 'error', message: 'Failed to load availability zones' });
      } finally {
        if (token === zoneRequestRef.current) setZonesLoading(false);
      }
    },
    [providerId, addNotification]
  );

  const handleToggleRegionZones = useCallback(
    (region: SystemProviderRegion) => {
      if (expandedRegionId === region.id) {
        // Invalidate any in-flight load so a late response cannot repopulate a
        // collapsed row.
        zoneRequestRef.current += 1;
        setExpandedRegionId(null);
        setZones([]);
        setZonesTotal(0);
        return;
      }
      // Clear first: the previous region's zones must not show under this one
      // while the fetch is in flight.
      setZones([]);
      setExpandedRegionId(region.id);
      void loadZones(region.id);
    },
    [expandedRegionId, loadZones]
  );

  const handleDeleteZone = useCallback(
    async (regionId: string, zone: SystemProviderAvailabilityZone) => {
      if (!providerId) return;
      try {
        await systemApi.deleteProviderAvailabilityZone(providerId, regionId, zone.id);
        addNotification({
          type: 'success',
          message: `Availability zone "${zone.name}" deleted successfully`
        });
        await loadZones(regionId);
        await refreshData();
      } catch (error) {
        const errorMessage = error instanceof Error ? error.message : 'An error occurred';
        addNotification({
          type: 'error',
          message: `Failed to delete availability zone: ${errorMessage}`
        });
      }
    },
    [providerId, addNotification, loadZones, refreshData]
  );

  // Connection handlers
  const handleAddConnection = useCallback(() => {
    setEditConnection(null);
    setShowConnectionModal(true);
  }, []);

  const handleEditConnection = useCallback((connection: SystemProviderConnection) => {
    setEditConnection(connection);
    setShowConnectionModal(true);
  }, []);

  const handleDeleteConnection = useCallback(async () => {
    if (!connectionToDelete) return;

    setDeletingConnection(true);
    try {
      await systemApi.deleteProviderConnection(connectionToDelete.id);
      addNotification({
        type: 'success',
        message: `Connection "${connectionToDelete.name}" deleted successfully`
      });
      setConnectionToDelete(null);
      await refreshData();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: `Failed to delete connection: ${errorMessage}`
      });
    } finally {
      setDeletingConnection(false);
    }
  }, [connectionToDelete, addNotification, refreshData]);

  const handleTestConnection = useCallback(async (connection: SystemProviderConnection) => {
    setTestingConnection(connection.id);
    try {
      const result = await systemApi.testProviderConnection(connection.id);
      if (result.success) {
        addNotification({
          type: 'success',
          message: result.message || 'Connection test successful'
        });
      } else {
        addNotification({
          type: 'error',
          message: result.message || 'Connection test failed'
        });
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: `Connection test failed: ${errorMessage}`
      });
    } finally {
      setTestingConnection(null);
    }
  }, [addNotification]);

  const handleSyncCatalog = useCallback(async (connection: SystemProviderConnection) => {
    setSyncingCatalog(connection.id);
    try {
      const { catalog } = await systemApi.syncProviderConnectionCatalog(connection.id);
      addNotification({
        type: 'success',
        message: `Catalog synced for "${connection.name}": ${summariseCatalog(catalog)}`
      });
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: `Catalog sync failed: ${errorMessage}`
      });
    } finally {
      setSyncingCatalog(null);
    }
  }, [addNotification]);


  // `badge` renders whenever it is defined, where the inline strip it replaces
  // rendered a count only when it was above zero — hence `|| undefined`.
  const tabs: (Tab & { id: TabId })[] = [
    { id: 'info', label: 'Information', icon: <Cloud className="w-4 h-4" /> },
    { id: 'regions', label: 'Regions', icon: <MapPin className="w-4 h-4" />, badge: regions.length || undefined },
    { id: 'instance_types', label: 'Instance Types', icon: <Cpu className="w-4 h-4" /> },
    { id: 'connections', label: 'Connections', icon: <Server className="w-4 h-4" />, badge: connections.length || undefined },
    { id: 'config', label: 'Configuration', icon: <Settings className="w-4 h-4" /> }
  ];

  const renderInfoTab = () => {
    if (!provider) return null;

    return (
      <div className="space-y-6">
        {/* Basic Info */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-6">
          <div className="space-y-4">
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Name</label>
              <p className="text-theme-primary font-medium">{provider.name}</p>
            </div>
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Description</label>
              <p className="text-theme-primary">{provider.description || '—'}</p>
            </div>
          </div>
          <div className="space-y-4">
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Provider Type</label>
              <p className="text-theme-primary">
                {providerTypeLabels[provider.provider_type] || provider.provider_type}
              </p>
            </div>
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Resources</label>
              <div className="flex items-center gap-4 text-theme-primary">
                <span>{provider.region_count || 0} regions</span>
                <span>{provider.connection_count || 0} connections</span>
              </div>
            </div>
          </div>
        </div>

        {/* Status Badges */}
        <div className="flex flex-wrap gap-4 pt-4 border-t border-theme">
          <div className="flex items-center gap-2">
            {provider.enabled ? (
              <CheckCircle className="w-5 h-5 text-theme-success-fg" />
            ) : (
              <XCircle className="w-5 h-5 text-theme-error-fg" />
            )}
            <span className="text-theme-primary">
              {provider.enabled ? 'Enabled' : 'Disabled'}
            </span>
          </div>
          <div className="flex items-center gap-2">
            {provider.public ? (
              <Globe className="w-5 h-5 text-theme-info-fg" />
            ) : (
              <Lock className="w-5 h-5 text-theme-secondary" />
            )}
            <span className="text-theme-primary">
              {provider.public ? 'Public' : 'Private'}
            </span>
          </div>
        </div>

        {/* Timestamps */}
        <div className="grid grid-cols-2 gap-4 pt-4 border-t border-theme text-sm">
          <div>
            <span className="text-theme-secondary">Created:</span>
            <span className="ml-2 text-theme-primary">
              {new Date(provider.created_at).toLocaleString()}
            </span>
          </div>
          <div>
            <span className="text-theme-secondary">Updated:</span>
            <span className="ml-2 text-theme-primary">
              {new Date(provider.updated_at).toLocaleString()}
            </span>
          </div>
        </div>
      </div>
    );
  };

  const renderRegionsTab = () => {
    return (
      <div className="space-y-4">
        {/* Header with Add button */}
        {canManageRegions && (
          <div className="flex justify-end">
            <Button variant="primary" size="sm" onClick={handleAddRegion}>
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
                    onClick={() => handleToggleRegionZones(region)}
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
                      onClick={() => handleEditRegion(region)}
                      title="Edit region"
                    >
                      <Edit2 className="w-4 h-4" />
                    </Button>
                  )}
                  {canDeleteRegions && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => setRegionToDelete(region)}
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
                        onClick={() => {
                          setEditZone(null);
                          setZoneModalRegionId(region.id);
                        }}
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
                                onClick={() => {
                                  setEditZone(zone);
                                  setZoneModalRegionId(region.id);
                                }}
                                title="Edit availability zone"
                              >
                                <Edit2 className="w-4 h-4" />
                              </Button>
                            )}
                            {canDeleteRegions && (
                              <Button
                                variant="ghost"
                                size="sm"
                                onClick={() => handleDeleteZone(region.id, zone)}
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
  };

  const renderInstanceTypesTab = () => {
    return (
      <div className="space-y-4">
        {hasCloudConnection && (
          <p className="text-xs text-theme-warning-fg bg-theme-background rounded-lg p-3 border border-theme">
            This provider has a cloud connection, so instance types are normally
            populated by Sync catalog. Writes here are a manual override.
          </p>
        )}

        {canManageInstanceTypes && (
          <div className="flex justify-end">
            <Button
              variant="primary"
              size="sm"
              onClick={() => {
                setEditInstanceType(null);
                setShowInstanceTypeModal(true);
              }}
              title={
                hasCloudConnection
                  ? 'Add instance type (manual override)'
                  : 'Add instance type'
              }
            >
              <Plus className="w-4 h-4 mr-2" />
              Add Instance Type
            </Button>
          </div>
        )}

        {instanceTypesLoading ? (
          <div className="flex justify-center py-12">
            <LoadingSpinner size="lg" />
          </div>
        ) : instanceTypes.length === 0 ? (
          <div className="text-center py-12">
            <Cpu className="w-12 h-12 text-theme-tertiary mx-auto mb-4" />
            <p className="text-theme-secondary">No instance types configured</p>
            <p className="text-sm text-theme-tertiary mt-1">
              Declare the shapes this provider can hand out
            </p>
          </div>
        ) : (
          <>
          {instanceTypesTotal > instanceTypes.length && (
            <p className="text-xs text-theme-warning-fg">
              Showing {instanceTypes.length} of {instanceTypesTotal} instance types —
              narrow the catalog or use the API for the rest.
            </p>
          )}
          {instanceTypes.map(instanceType => (
            <div
              key={instanceType.id}
              className="bg-theme-background rounded-lg p-4 border border-theme"
              data-testid={`instance-type-${instanceType.id}`}
            >
              <div className="flex items-start justify-between">
                <div>
                  <h4 className="font-medium text-theme-primary">{instanceType.name}</h4>
                  <p className="text-xs text-theme-tertiary font-mono mt-1">
                    {instanceType.instance_type_code}
                  </p>
                  <p className="text-sm text-theme-secondary mt-1">
                    {instanceType.vcpus ?? '—'} vCPU • {instanceType.memory_mb ?? '—'} MB
                    {' • '}
                    {instanceType.storage_gb ?? '—'} GB
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <Badge variant={instanceType.enabled ? 'success' : 'secondary'} size="xs">
                    {instanceType.enabled ? 'Enabled' : 'Disabled'}
                  </Badge>
                  {canUpdateInstanceTypes && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => {
                        setEditInstanceType(instanceType);
                        setShowInstanceTypeModal(true);
                      }}
                      title="Edit instance type"
                    >
                      <Edit2 className="w-4 h-4" />
                    </Button>
                  )}
                  {canDeleteInstanceTypes && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => handleDeleteInstanceType(instanceType)}
                      title="Delete instance type"
                      className="text-theme-error-fg hover:text-theme-error-fg"
                    >
                      <Trash2 className="w-4 h-4" />
                    </Button>
                  )}
                </div>
              </div>
              {instanceType.description && (
                <p className="text-sm text-theme-secondary mt-2">{instanceType.description}</p>
              )}
            </div>
          ))}
          </>
        )}
      </div>
    );
  };

  const renderConnectionsTab = () => {
    return (
      <div className="space-y-4">
        {/* Header with Add button */}
        {canManageConnections && (
          <div className="flex justify-end">
            <Button variant="primary" size="sm" onClick={handleAddConnection}>
              <Plus className="w-4 h-4 mr-2" />
              Add Connection
            </Button>
          </div>
        )}

        {connections.length === 0 ? (
          <div className="text-center py-12">
            <Server className="w-12 h-12 text-theme-tertiary mx-auto mb-4" />
            <p className="text-theme-secondary">No connections configured</p>
            <p className="text-sm text-theme-tertiary mt-1">
              Add connections to authenticate with this provider
            </p>
          </div>
        ) : (
          connections.map(connection => (
            <div
              key={connection.id}
              className="bg-theme-background rounded-lg p-4 border border-theme"
            >
              <div className="flex items-start justify-between mb-2">
                <div>
                  <h4 className="font-medium text-theme-primary">{connection.name}</h4>
                  {connection.endpoint_url && (
                    <p className="text-xs text-theme-tertiary font-mono mt-1">
                      {connection.endpoint_url}
                    </p>
                  )}
                  {connection.provider_id && (
                    <p className="text-xs text-theme-secondary mt-1">
                      Provider:{' '}
                      <EntityLink
                        type="provider"
                        id={connection.provider_id}
                        label={connection.provider_name || connection.provider_id}
                        className="text-xs"
                      />
                    </p>
                  )}
                </div>
                <div className="flex items-center gap-2">
                  <Badge variant="success" size="xs">Active</Badge>
                  {canTestConnections && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => handleTestConnection(connection)}
                      disabled={testingConnection === connection.id}
                      title="Test connection"
                    >
                      {testingConnection === connection.id ? (
                        <RefreshCw className="w-4 h-4 animate-spin" />
                      ) : (
                        <RefreshCw className="w-4 h-4" />
                      )}
                    </Button>
                  )}
                  {canSyncCatalog && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => handleSyncCatalog(connection)}
                      disabled={syncingCatalog === connection.id}
                      title="Sync catalog"
                    >
                      <DownloadCloud
                        className={`w-4 h-4 ${syncingCatalog === connection.id ? 'animate-pulse' : ''}`}
                      />
                    </Button>
                  )}
                  {canManageConnections && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => handleEditConnection(connection)}
                      title="Edit connection"
                    >
                      <Edit2 className="w-4 h-4" />
                    </Button>
                  )}
                  {canDeleteConnections && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => setConnectionToDelete(connection)}
                      title="Delete connection"
                      className="text-theme-error-fg hover:text-theme-error-fg"
                    >
                      <Trash2 className="w-4 h-4" />
                    </Button>
                  )}
                </div>
              </div>
              {connection.description && (
                <p className="text-sm text-theme-secondary mt-2">{connection.description}</p>
              )}
            </div>
          ))
        )}
      </div>
    );
  };

  const renderConfigTab = () => {
    if (!provider) return null;

    const hasConfig = provider.config && Object.keys(provider.config).length > 0;
    const hasCapabilities = provider.capabilities && Object.keys(provider.capabilities).length > 0;

    return (
      <div className="space-y-6">
        {/* Config */}
        <div>
          <h4 className="font-medium text-theme-primary mb-2">Configuration</h4>
          {hasConfig ? (
            <pre className="bg-theme-background rounded-lg p-4 text-sm text-theme-primary overflow-x-auto border border-theme font-mono">
              {JSON.stringify(provider.config, null, 2)}
            </pre>
          ) : (
            <p className="text-theme-secondary text-sm">No configuration defined</p>
          )}
        </div>

        {/* Capabilities */}
        <div>
          <h4 className="font-medium text-theme-primary mb-2">Capabilities</h4>
          {hasCapabilities ? (
            <pre className="bg-theme-background rounded-lg p-4 text-sm text-theme-primary overflow-x-auto border border-theme font-mono">
              {JSON.stringify(provider.capabilities, null, 2)}
            </pre>
          ) : (
            <p className="text-theme-secondary text-sm">No capabilities defined</p>
          )}
        </div>
      </div>
    );
  };

  // Six dialogs can sit on top of this one: the region / instance-type /
  // availability-zone / connection forms and the two delete confirmations.
  // Each is a core Modal registering Escape on `document`, so this one stands
  // its own handler down while any of them is up.
  const nestedDialogOpen =
    showRegionModal ||
    showInstanceTypeModal ||
    showConnectionModal ||
    zoneModalRegionId !== null ||
    regionToDelete !== null ||
    connectionToDelete !== null;

  return (
    <>
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={loading ? 'Loading...' : provider?.name || 'Provider Details'}
      subtitle={
        provider
          ? providerTypeLabels[provider.provider_type] || provider.provider_type
          : undefined
      }
      icon={<Cloud className="w-6 h-6" />}
      maxWidth="3xl"
      closeOnEscape={!nestedDialogOpen}
      footer={
        <>
          {provider && onEdit && (
            <Button variant="outline" onClick={() => onEdit(provider)}>
              Edit
            </Button>
          )}
          <Button variant="outline" onClick={onClose}>
            Close
          </Button>
        </>
      }
    >
          {/* Tabs */}
          <TabContainer
            tabs={tabs}
            activeTab={activeTab}
            onTabChange={(id) => setActiveTab(id as TabId)}
            variant="underline"
            showContent={false}
          />

          {/* Content */}
          <div className="pt-4">
            {loading ? (
              <div className="flex items-center justify-center py-12">
                <LoadingSpinner size="lg" />
              </div>
            ) : provider ? (
              <>
                {activeTab === 'info' && renderInfoTab()}
                {activeTab === 'regions' && renderRegionsTab()}
                {activeTab === 'instance_types' && renderInstanceTypesTab()}
                {activeTab === 'connections' && renderConnectionsTab()}
                {activeTab === 'config' && renderConfigTab()}
              </>
            ) : (
              <div className="text-center py-12">
                <p className="text-theme-error-fg">Failed to load provider details</p>
              </div>
            )}
          </div>
    </Modal>

      {/* Region Form Modal */}
      {providerId && (
        <RegionFormModal
          providerId={providerId}
          region={editRegion}
          isOpen={showRegionModal}
          onClose={() => {
            setShowRegionModal(false);
            setEditRegion(null);
          }}
          onRegionSaved={refreshData}
        />
      )}

      {/* Instance Type Form Modal */}
      {providerId && (
        <InstanceTypeFormModal
          providerId={providerId}
          instanceType={editInstanceType}
          isOpen={showInstanceTypeModal}
          onClose={() => {
            setShowInstanceTypeModal(false);
            setEditInstanceType(null);
          }}
          onSaved={refreshInstanceTypes}
          manualOverride={hasCloudConnection}
        />
      )}

      {/* Availability Zone Form Modal */}
      {providerId && zoneModalRegionId && (
        <AvailabilityZoneFormModal
          providerId={providerId}
          regionId={zoneModalRegionId}
          zone={editZone}
          isOpen={true}
          onClose={() => {
            setZoneModalRegionId(null);
            setEditZone(null);
          }}
          onSaved={() => {
            // Reload the open region's zones and the region row's zone_count.
            void loadZones(zoneModalRegionId);
            void refreshData();
          }}
          manualOverride={hasCloudConnection}
        />
      )}

      {/* Connection Form Modal */}
      {providerId && (
        <ConnectionFormModal
          providerId={providerId}
          connection={editConnection}
          isOpen={showConnectionModal}
          onClose={() => {
            setShowConnectionModal(false);
            setEditConnection(null);
          }}
          onConnectionSaved={refreshData}
        />
      )}

      {/* Region Delete Confirmation */}
      {regionToDelete && (
        <Modal
          isOpen
          onClose={() => setRegionToDelete(null)}
          title="Delete Region"
          icon={<MapPin className="w-6 h-6" />}
          maxWidth="md"
          footer={
            <>
              <Button variant="outline" onClick={() => setRegionToDelete(null)}>
                Cancel
              </Button>
              <Button
                variant="danger"
                onClick={handleDeleteRegion}
                disabled={deletingRegion}
              >
                {deletingRegion ? 'Deleting...' : 'Delete Region'}
              </Button>
            </>
          }
        >
          <p className="text-theme-secondary">
            Are you sure you want to delete the region "{regionToDelete.name}"? This action cannot be undone.
          </p>
        </Modal>
      )}

      {/* Connection Delete Confirmation */}
      {connectionToDelete && (
        <Modal
          isOpen
          onClose={() => setConnectionToDelete(null)}
          title="Delete Connection"
          icon={<Server className="w-6 h-6" />}
          maxWidth="md"
          footer={
            <>
              <Button variant="outline" onClick={() => setConnectionToDelete(null)}>
                Cancel
              </Button>
              <Button
                variant="danger"
                onClick={handleDeleteConnection}
                disabled={deletingConnection}
              >
                {deletingConnection ? 'Deleting...' : 'Delete Connection'}
              </Button>
            </>
          }
        >
          <p className="text-theme-secondary">
            Are you sure you want to delete the connection "{connectionToDelete.name}"? This action cannot be undone.
          </p>
        </Modal>
      )}
    </>
  );
};

export default ProviderDetailModal;
