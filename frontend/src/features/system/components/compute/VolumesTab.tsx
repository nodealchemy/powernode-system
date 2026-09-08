import React, { useCallback, useState } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { VolumeList, VolumeDetailModal, VolumeFormModal, VolumeAttachModal } from '@system/features/system/components/volumes';
import { systemApi } from '@system/features/system/services/systemApi';
import { useCrudTab } from '@system/features/system/hooks/useCrudTab';
import type { SystemProviderVolume } from '@system/features/system/types/system.types';

interface VolumesTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const VolumesTab: React.FC<VolumesTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canCreate = hasPermission('system.volumes.create');
  const canDelete = hasPermission('system.volumes.delete');

  const [showDetailModal, setShowDetailModal] = useState(false);
  const [showAttachModal, setShowAttachModal] = useState(false);
  const [selectedVolumeId, setSelectedVolumeId] = useState<string | null>(null);
  const [attachVolume, setAttachVolume] = useState<SystemProviderVolume | null>(null);
  const [, setDetaching] = useState(false);

  const {
    showFormModal,
    editEntity: editVolume,
    refreshKey,
    handleCreate,
    handleEdit,
    handleDeleteClick,
    handleSaved,
    closeForm,
    triggerRefresh,
    confirm,
    ConfirmationDialog,
  } = useCrudTab<SystemProviderVolume>({
    entityLabel: 'Volume',
    deleteMessage:
      'Are you sure you want to delete this volume? This action cannot be undone and all data on the volume will be permanently lost.',
    deleteFn: (id) => systemApi.deleteVolume(id),
    onActionsReady,
  });

  const handleView = useCallback((v: SystemProviderVolume) => {
    setSelectedVolumeId(v.id);
    setShowDetailModal(true);
  }, []);
  const handleEditFromDetail = useCallback(
    (v: SystemProviderVolume) => {
      setShowDetailModal(false);
      setSelectedVolumeId(null);
      handleEdit(v);
    },
    [handleEdit],
  );
  const handleAttach = useCallback((v: SystemProviderVolume) => {
    setAttachVolume(v);
    setShowAttachModal(true);
  }, []);
  // Confirm-gated like delete, but NOT a delete — it goes through the hook's
  // `confirm` so it reuses the one ConfirmationDialog. Detaching a mounted
  // volume pulls storage out from under whatever is running on the holding
  // instance, and the only undo is a re-attach.
  const handleDetach = useCallback(
    (v: SystemProviderVolume) => {
      confirm({
        title: 'Detach Volume',
        message: `Detach "${v.name}" from the instance holding it? Anything running against this volume loses access immediately, and the only way back is to re-attach it.`,
        confirmLabel: 'Detach Volume',
        cancelLabel: 'Keep Attached',
        variant: 'danger',
        onConfirm: async () => {
          setDetaching(true);
          try {
            await systemApi.detachVolume(v.id);
            addNotification({ type: 'success', message: 'Volume detached successfully' });
            triggerRefresh();
          } catch (error) {
            addNotification({ type: 'error', message: `Failed to detach volume: ${error instanceof Error ? error.message : 'An error occurred'}` });
          } finally {
            setDetaching(false);
          }
        }
      });
    },
    [confirm, addNotification, triggerRefresh],
  );
  const handleSnapshot = useCallback(async (v: SystemProviderVolume) => {
    try {
      await systemApi.createVolumeSnapshot(v.id, `${v.name}-snapshot`);
      addNotification({ type: 'success', message: 'Snapshot creation started' });
    } catch (error) {
      addNotification({ type: 'error', message: `Failed to create snapshot: ${error instanceof Error ? error.message : 'An error occurred'}` });
    }
  }, [addNotification]);

  return (
    <>
      <VolumeList
        key={refreshKey}
        onView={handleView}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
        onAttach={handleAttach}
        onDetach={handleDetach}
        onSnapshot={handleSnapshot}
      />

      <VolumeDetailModal
        volumeId={selectedVolumeId}
        isOpen={showDetailModal}
        onClose={() => { setShowDetailModal(false); setSelectedVolumeId(null); }}
        onVolumeUpdated={triggerRefresh}
        onEdit={handleEditFromDetail}
      />

      <VolumeFormModal
        volume={editVolume}
        isOpen={showFormModal}
        onClose={closeForm}
        onVolumeSaved={handleSaved}
      />

      <VolumeAttachModal
        volume={attachVolume}
        isOpen={showAttachModal}
        onClose={() => { setShowAttachModal(false); setAttachVolume(null); }}
        onVolumeAttached={triggerRefresh}
      />

      {ConfirmationDialog}
    </>
  );
};
