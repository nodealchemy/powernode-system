import React, { useState, useCallback, useEffect } from 'react';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
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

  const [showFormModal, setShowFormModal] = useState(false);
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [showAttachModal, setShowAttachModal] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [selectedVolumeId, setSelectedVolumeId] = useState<string | null>(null);
  const [editVolume, setEditVolume] = useState<SystemProviderVolume | null>(null);
  const [attachVolume, setAttachVolume] = useState<SystemProviderVolume | null>(null);
  const [volumeToDelete, setVolumeToDelete] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [deleting, setDeleting] = useState(false);
  const [, setDetaching] = useState(false);

  const handleCreate = useCallback(() => { setEditVolume(null); setShowFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((v: SystemProviderVolume) => { setSelectedVolumeId(v.id); setShowDetailModal(true); }, []);
  const handleEdit = useCallback((v: SystemProviderVolume) => { setEditVolume(v); setShowFormModal(true); }, []);
  const handleDeleteClick = useCallback((id: string) => { setVolumeToDelete(id); setShowDeleteConfirm(true); }, []);
  const handleDeleteConfirm = async () => {
    if (!volumeToDelete) return;
    setDeleting(true);
    try {
      await systemApi.deleteVolume(volumeToDelete);
      addNotification({ type: 'success', message: 'Volume deleted successfully' });
      setRefreshKey((k) => k + 1);
    } catch (error) {
      addNotification({ type: 'error', message: `Failed to delete volume: ${error instanceof Error ? error.message : 'An error occurred'}` });
    } finally {
      setDeleting(false);
      setShowDeleteConfirm(false);
      setVolumeToDelete(null);
    }
  };
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

      {showDeleteConfirm && (
        <div className="fixed inset-0 z-50 overflow-y-auto">
          <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={() => setShowDeleteConfirm(false)} />
          <div className="flex min-h-full items-center justify-center p-4">
            <div className="relative w-full max-w-md bg-theme-surface rounded-lg shadow-xl">
              <div className="p-6">
                <h3 className="text-lg font-semibold text-theme-primary mb-2">Delete Volume</h3>
                <p className="text-theme-secondary mb-6">
                  Are you sure you want to delete this volume? This action cannot be undone
                  and all data on the volume will be permanently lost.
                </p>
                <div className="flex justify-end gap-3">
                  <Button variant="outline" onClick={() => { setShowDeleteConfirm(false); setVolumeToDelete(null); }}>
                    Cancel
                  </Button>
                  <Button variant="danger" onClick={handleDeleteConfirm} disabled={deleting}>
                    {deleting ? 'Deleting...' : 'Delete Volume'}
                  </Button>
                </div>
              </div>
            </div>
          </div>
        </div>
      )}
    </>
  );
};
