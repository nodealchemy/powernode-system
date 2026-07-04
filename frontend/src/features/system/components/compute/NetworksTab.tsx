import React, { useState, useCallback, useEffect } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import { NetworkList, NetworkDetailModal, NetworkFormModal } from '@system/features/system/components/networks';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProviderNetwork } from '@system/features/system/types/system.types';

interface NetworksTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const NetworksTab: React.FC<NetworksTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canCreate = hasPermission('system.networks.create');
  const canDelete = hasPermission('system.networks.delete');
  const { confirm, ConfirmationDialog } = useConfirmation();

  const [showFormModal, setShowFormModal] = useState(false);
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [selectedNetworkId, setSelectedNetworkId] = useState<string | null>(null);
  const [editNetwork, setEditNetwork] = useState<SystemProviderNetwork | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const handleCreate = useCallback(() => { setEditNetwork(null); setShowFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((n: SystemProviderNetwork) => { setSelectedNetworkId(n.id); setShowDetailModal(true); }, []);
  const handleEdit = useCallback((n: SystemProviderNetwork) => { setEditNetwork(n); setShowFormModal(true); }, []);
  const handleDeleteClick = useCallback((id: string) => {
    confirm({
      title: 'Delete Network',
      message: 'Are you sure you want to delete this network? This action cannot be undone. All subnets and associated resources will also be removed.',
      confirmLabel: 'Delete Network',
      variant: 'danger',
      onConfirm: async () => {
        try {
          await systemApi.deleteNetwork(id);
          addNotification({ type: 'success', message: 'Network deleted successfully' });
          setRefreshKey((k) => k + 1);
        } catch (error) {
          addNotification({ type: 'error', message: `Failed to delete network: ${error instanceof Error ? error.message : 'An error occurred'}` });
        }
      }
    });
  }, [confirm, addNotification]);
  const handleNetworkSaved = useCallback(() => { setRefreshKey((k) => k + 1); setEditNetwork(null); }, []);
  const handleEditFromDetail = useCallback((n: SystemProviderNetwork) => {
    setShowDetailModal(false); setSelectedNetworkId(null); setEditNetwork(n); setShowFormModal(true);
  }, []);

  return (
    <>
      <NetworkList
        key={refreshKey}
        onView={handleView}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
      />

      <NetworkDetailModal
        networkId={selectedNetworkId}
        isOpen={showDetailModal}
        onClose={() => { setShowDetailModal(false); setSelectedNetworkId(null); }}
        onNetworkUpdated={() => setRefreshKey((k) => k + 1)}
        onEdit={handleEditFromDetail}
      />

      <NetworkFormModal
        network={editNetwork}
        isOpen={showFormModal}
        onClose={() => { setShowFormModal(false); setEditNetwork(null); }}
        onNetworkSaved={handleNetworkSaved}
      />

      {ConfirmationDialog}
    </>
  );
};
