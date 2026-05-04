import React, { useState, useCallback, useEffect } from 'react';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { PlatformList, PlatformFormModal } from '@system/features/system/components/platforms';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodePlatform } from '@system/features/system/types/system.types';

interface PlatformsTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const PlatformsTab: React.FC<PlatformsTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canCreate = hasPermission('system.platforms.create');
  const canDelete = hasPermission('system.platforms.delete');

  const [showFormModal, setShowFormModal] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [editPlatform, setEditPlatform] = useState<SystemNodePlatform | null>(null);
  const [platformToDelete, setPlatformToDelete] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [deleting, setDeleting] = useState(false);

  const handleCreate = useCallback(() => { setEditPlatform(null); setShowFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((p: SystemNodePlatform) => { setEditPlatform(p); setShowFormModal(true); }, []);
  const handleEdit = handleView;
  const handleDeleteClick = useCallback((id: string) => { setPlatformToDelete(id); setShowDeleteConfirm(true); }, []);
  const handleDeleteConfirm = async () => {
    if (!platformToDelete) return;
    setDeleting(true);
    try {
      await systemApi.deletePlatform(platformToDelete);
      addNotification({ type: 'success', message: 'Platform deleted successfully' });
      setRefreshKey((k) => k + 1);
    } catch (error) {
      addNotification({ type: 'error', message: `Failed to delete platform: ${error instanceof Error ? error.message : 'An error occurred'}` });
    } finally {
      setDeleting(false); setShowDeleteConfirm(false); setPlatformToDelete(null);
    }
  };
  const handlePlatformSaved = useCallback(() => { setRefreshKey((k) => k + 1); setEditPlatform(null); }, []);

  return (
    <>
      <PlatformList
        key={refreshKey}
        onView={handleView}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
      />

      <PlatformFormModal
        isOpen={showFormModal}
        onClose={() => { setShowFormModal(false); setEditPlatform(null); }}
        onPlatformSaved={handlePlatformSaved}
        editPlatform={editPlatform}
      />

      {showDeleteConfirm && (
        <div className="fixed inset-0 z-50 overflow-y-auto">
          <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={() => setShowDeleteConfirm(false)} />
          <div className="flex min-h-full items-center justify-center p-4">
            <div className="relative w-full max-w-md bg-theme-surface rounded-lg shadow-xl">
              <div className="p-6">
                <h3 className="text-lg font-semibold text-theme-primary mb-2">Delete Platform</h3>
                <p className="text-theme-secondary mb-6">
                  Are you sure you want to delete this platform? This action cannot be undone.
                  Templates using this platform will need to be updated.
                </p>
                <div className="flex justify-end gap-3">
                  <Button variant="outline" onClick={() => { setShowDeleteConfirm(false); setPlatformToDelete(null); }}>Cancel</Button>
                  <Button variant="danger" onClick={handleDeleteConfirm} disabled={deleting}>
                    {deleting ? 'Deleting...' : 'Delete Platform'}
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
