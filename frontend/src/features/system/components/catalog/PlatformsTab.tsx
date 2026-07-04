import React, { useState, useCallback, useEffect } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
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
  const { confirm, ConfirmationDialog } = useConfirmation();

  const [showFormModal, setShowFormModal] = useState(false);
  const [editPlatform, setEditPlatform] = useState<SystemNodePlatform | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const handleCreate = useCallback(() => { setEditPlatform(null); setShowFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((p: SystemNodePlatform) => { setEditPlatform(p); setShowFormModal(true); }, []);
  const handleEdit = handleView;
  const handleDeleteClick = useCallback((id: string) => {
    confirm({
      title: 'Delete Platform',
      message: 'Are you sure you want to delete this platform? This action cannot be undone. Templates using this platform will need to be updated.',
      confirmLabel: 'Delete Platform',
      variant: 'danger',
      onConfirm: async () => {
        try {
          await systemApi.deletePlatform(id);
          addNotification({ type: 'success', message: 'Platform deleted successfully' });
          setRefreshKey((k) => k + 1);
        } catch (error) {
          addNotification({ type: 'error', message: `Failed to delete platform: ${error instanceof Error ? error.message : 'An error occurred'}` });
        }
      }
    });
  }, [confirm, addNotification]);
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

      {ConfirmationDialog}
    </>
  );
};
