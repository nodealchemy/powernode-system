import React, { useCallback, useState } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { NetworkList, NetworkDetailModal, NetworkFormModal } from '@system/features/system/components/networks';
import { systemApi } from '@system/features/system/services/systemApi';
import { useCrudTab } from '@system/features/system/hooks/useCrudTab';
import type { SystemProviderNetwork } from '@system/features/system/types/system.types';

interface NetworksTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const NetworksTab: React.FC<NetworksTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const canCreate = hasPermission('system.networks.create');
  const canDelete = hasPermission('system.networks.delete');

  // Detail-modal state stays local: the hook owns the FORM, not the read view.
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [selectedNetworkId, setSelectedNetworkId] = useState<string | null>(null);

  const {
    showFormModal,
    editEntity: editNetwork,
    refreshKey,
    handleCreate,
    handleEdit,
    handleDeleteClick,
    handleSaved,
    closeForm,
    triggerRefresh,
    ConfirmationDialog,
  } = useCrudTab<SystemProviderNetwork>({
    entityLabel: 'Network',
    deleteMessage:
      'Are you sure you want to delete this network? This action cannot be undone. All subnets and associated resources will also be removed.',
    deleteFn: (id) => systemApi.deleteNetwork(id),
    onActionsReady,
  });

  const handleView = useCallback((n: SystemProviderNetwork) => {
    setSelectedNetworkId(n.id);
    setShowDetailModal(true);
  }, []);
  const handleEditFromDetail = useCallback(
    (n: SystemProviderNetwork) => {
      setShowDetailModal(false);
      setSelectedNetworkId(null);
      handleEdit(n);
    },
    [handleEdit],
  );

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
        onNetworkUpdated={triggerRefresh}
        onEdit={handleEditFromDetail}
      />

      <NetworkFormModal
        network={editNetwork}
        isOpen={showFormModal}
        onClose={closeForm}
        onNetworkSaved={handleSaved}
      />

      {ConfirmationDialog}
    </>
  );
};
