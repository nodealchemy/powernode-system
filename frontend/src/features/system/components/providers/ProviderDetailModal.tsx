import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Cloud, MapPin, Server, Settings, Cpu } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { TabContainer, type Tab } from '@/shared/components/layout/TabContainer';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
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
import { providerTypeLabels, summariseCatalog } from './providerDetailHelpers';
import { ProviderInfoTab } from './ProviderInfoTab';
import { ProviderRegionsTab } from './ProviderRegionsTab';
import { ProviderInstanceTypesTab } from './ProviderInstanceTypesTab';
import { ProviderConnectionsTab } from './ProviderConnectionsTab';
import { ProviderConfigTab } from './ProviderConfigTab';

interface ProviderDetailModalProps {
  providerId: string | null;
  isOpen: boolean;
  onClose: () => void;
  onEdit?: (provider: SystemProvider) => void;
}

type TabId = 'info' | 'regions' | 'instance_types' | 'connections' | 'config';

/**
 * ProviderDetailModal - Modal for viewing provider details with tabs
 *
 * C12 (component-status-plane campaign): the five tab bodies used to be
 * inline `render*Tab` functions in this file (1183 lines total). Split onto
 * section components — ProviderInfoTab, ProviderRegionsTab,
 * ProviderInstanceTypesTab, ProviderConnectionsTab, ProviderConfigTab —
 * each taking the state/handlers it needs as props; the pure
 * `providerTypeLabels` map and `summariseCatalog` helper moved to
 * providerDetailHelpers.ts. This file is now the orchestrator: data
 * fetching, mutation handlers, and composing TabContainer + the four
 * drill-down form modals + the two delete confirmations.
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

  const handleAddInstanceType = useCallback(() => {
    setEditInstanceType(null);
    setShowInstanceTypeModal(true);
  }, []);

  const handleEditInstanceType = useCallback((instanceType: SystemProviderInstanceType) => {
    setEditInstanceType(instanceType);
    setShowInstanceTypeModal(true);
  }, []);

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

  const handleAddZone = useCallback((regionId: string) => {
    setEditZone(null);
    setZoneModalRegionId(regionId);
  }, []);

  const handleEditZone = useCallback((regionId: string, zone: SystemProviderAvailabilityZone) => {
    setEditZone(zone);
    setZoneModalRegionId(regionId);
  }, []);

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


  // TabContainer renders a badge only when its count is above zero.
  const tabs: (Tab & { id: TabId })[] = [
    { id: 'info', label: 'Information', icon: <Cloud className="w-4 h-4" /> },
    { id: 'regions', label: 'Regions', icon: <MapPin className="w-4 h-4" />, badge: { count: regions.length } },
    { id: 'instance_types', label: 'Instance Types', icon: <Cpu className="w-4 h-4" /> },
    { id: 'connections', label: 'Connections', icon: <Server className="w-4 h-4" />, badge: { count: connections.length } },
    { id: 'config', label: 'Configuration', icon: <Settings className="w-4 h-4" /> }
  ];

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
          />

          {/* Content */}
          <div className="pt-4">
            {loading ? (
              <div className="flex items-center justify-center py-12">
                <LoadingSpinner size="lg" />
              </div>
            ) : provider ? (
              <>
                {activeTab === 'info' && <ProviderInfoTab provider={provider} />}
                {activeTab === 'regions' && (
                  <ProviderRegionsTab
                    regions={regions}
                    canManageRegions={canManageRegions}
                    canUpdateRegions={canUpdateRegions}
                    canDeleteRegions={canDeleteRegions}
                    hasCloudConnection={hasCloudConnection}
                    expandedRegionId={expandedRegionId}
                    zones={zones}
                    zonesLoading={zonesLoading}
                    zonesTotal={zonesTotal}
                    onAddRegion={handleAddRegion}
                    onEditRegion={handleEditRegion}
                    onDeleteRegionRequest={setRegionToDelete}
                    onToggleRegionZones={handleToggleRegionZones}
                    onAddZone={handleAddZone}
                    onEditZone={handleEditZone}
                    onDeleteZone={handleDeleteZone}
                  />
                )}
                {activeTab === 'instance_types' && (
                  <ProviderInstanceTypesTab
                    instanceTypes={instanceTypes}
                    instanceTypesLoading={instanceTypesLoading}
                    instanceTypesTotal={instanceTypesTotal}
                    hasCloudConnection={hasCloudConnection}
                    canManageInstanceTypes={canManageInstanceTypes}
                    canUpdateInstanceTypes={canUpdateInstanceTypes}
                    canDeleteInstanceTypes={canDeleteInstanceTypes}
                    onAddInstanceType={handleAddInstanceType}
                    onEditInstanceType={handleEditInstanceType}
                    onDeleteInstanceType={handleDeleteInstanceType}
                  />
                )}
                {activeTab === 'connections' && (
                  <ProviderConnectionsTab
                    connections={connections}
                    canManageConnections={canManageConnections}
                    canDeleteConnections={canDeleteConnections}
                    canTestConnections={canTestConnections}
                    canSyncCatalog={canSyncCatalog}
                    testingConnection={testingConnection}
                    syncingCatalog={syncingCatalog}
                    onAddConnection={handleAddConnection}
                    onEditConnection={handleEditConnection}
                    onDeleteRequest={setConnectionToDelete}
                    onTestConnection={handleTestConnection}
                    onSyncCatalog={handleSyncCatalog}
                  />
                )}
                {activeTab === 'config' && <ProviderConfigTab provider={provider} />}
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
