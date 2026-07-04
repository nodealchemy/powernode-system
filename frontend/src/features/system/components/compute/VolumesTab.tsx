import React, { useState, useCallback, useEffect } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import { VolumeList, VolumeDetailModal, VolumeFormModal, VolumeAttachModal } from '@system/features/system/components/volumes';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProviderVolume } from '@system/features/system/types/system.types';

interface VolumesTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const VolumesTab: React.FC<VolumesTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canCreate = hasPermission('system.volumes.create');
  const canDelete = hasPermission('system.volumes.delete');
  const { confirm, ConfirmationDialog } = useConfirmation();

  const [showFormModal, setShowFormModal] = useState(false);
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [showAttachModal, setShowAttachModal] = useState(false);
  const [selectedVolumeId, setSelectedVolumeId] = useState<string | null>(null);
  const [editVolume, setEditVolume] = useState<SystemProviderVolume | null>(null);
  const [attachVolume, setAttachVolume] = useState<SystemProviderVolume | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [, setDetaching] = useState(false);

  const handleCreate = useCallback(() => { setEditVolume(null); setShowFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((v: SystemProviderVolume) => { setSelectedVolumeId(v.id); setShowDetailModal(true); }, []);
  const handleEdit = useCallback((v: SystemProviderVolume) => { setEditVolume(v); setShowFormModal(true); }, []);
  const handleDeleteClick = useCallback((id: string) => {
    confirm({
      title: 'Delete Volume',
      message: 'Are you sure you want to delete this volume? This action cannot be undone and all data on the volume will be permanently lost.',
      confirmLabel: 'Delete Volume',
      variant: 'danger',
      onConfirm: async () => {
        try {
          await systemApi.deleteVolume(id);
          addNotification({ type: 'success', message: 'Volume deleted successfully' });
          setRefreshKey((k) => k + 1);
        } catch (error) {
          addNotification({ type: 'error', message: `Failed to delete volume: ${error instanceof Error ? error.message : 'An error occurred'}` });
        }
      }
    });
  }, [confirm, addNotification]);
  const handleVolumeSaved = useCallback(() => { setRefreshKey((k) => k + 1); setEditVolume(null); }, []);
  const handleAttach = useCallback((v: SystemProviderVolume) => { setAttachVolume(v); setShowAttachModal(true); }, []);
  const handleDetach = useCallback(async (v: SystemProviderVolume) => {
    setDetaching(true);
    try {
      await systemApi.detachVolume(v.id);
      addNotification({ type: 'success', message: 'Volume detached successfully' });
      setRefreshKey((k) => k + 1);
    } catch (error) {
      addNotification({ type: 'error', message: `Failed to detach volume: ${error instanceof Error ? error.message : 'An error occurred'}` });
    } finally {
      setDetaching(false);
    }
  }, [addNotification]);
  const handleSnapshot = useCallback(async (v: SystemProviderVolume) => {
    try {
      await systemApi.createVolumeSnapshot(v.id, `${v.name}-snapshot`);
      addNotification({ type: 'success', message: 'Snapshot creation started' });
    } catch (error) {
      addNotification({ type: 'error', message: `Failed to create snapshot: ${error instanceof Error ? error.message : 'An error occurred'}` });
    }
  }, [addNotification]);
  const handleEditFromDetail = useCallback((v: SystemProviderVolume) => {
    setShowDetailModal(false); setSelectedVolumeId(null); setEditVolume(v); setShowFormModal(true);
  }, []);

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
        onVolumeUpdated={() => setRefreshKey((k) => k + 1)}
        onEdit={handleEditFromDetail}
      />

      <VolumeFormModal
        volume={editVolume}
        isOpen={showFormModal}
        onClose={() => { setShowFormModal(false); setEditVolume(null); }}
        onVolumeSaved={handleVolumeSaved}
      />

      <VolumeAttachModal
        volume={attachVolume}
        isOpen={showAttachModal}
        onClose={() => { setShowAttachModal(false); setAttachVolume(null); }}
        onVolumeAttached={() => setRefreshKey((k) => k + 1)}
      />

      {ConfirmationDialog}
    </>
  );
};
