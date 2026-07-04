import React, { useState, useCallback, useEffect } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import { ArchitectureList, ArchitectureFormModal } from '@system/features/system/components/architectures';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeArchitecture } from '@system/features/system/types/system.types';

interface ArchitecturesTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const ArchitecturesTab: React.FC<ArchitecturesTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canCreate = hasPermission('system.architectures.create');
  const canDelete = hasPermission('system.architectures.delete');
  const { confirm, ConfirmationDialog } = useConfirmation();

  const [showFormModal, setShowFormModal] = useState(false);
  const [editArchitecture, setEditArchitecture] = useState<SystemNodeArchitecture | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const handleCreate = useCallback(() => { setEditArchitecture(null); setShowFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((a: SystemNodeArchitecture) => { setEditArchitecture(a); setShowFormModal(true); }, []);
  const handleEdit = handleView;
  const handleDeleteClick = useCallback((id: string) => {
    confirm({
      title: 'Delete Architecture',
      message: 'Are you sure you want to delete this architecture? This action cannot be undone. Platforms using this architecture will need to be updated.',
      confirmLabel: 'Delete Architecture',
      variant: 'danger',
      onConfirm: async () => {
        try {
          await systemApi.deleteArchitecture(id);
          addNotification({ type: 'success', message: 'Architecture deleted successfully' });
          setRefreshKey((k) => k + 1);
        } catch (error) {
          addNotification({ type: 'error', message: `Failed to delete architecture: ${error instanceof Error ? error.message : 'An error occurred'}` });
        }
      }
    });
  }, [confirm, addNotification]);
  const handleArchitectureSaved = useCallback(() => { setRefreshKey((k) => k + 1); setEditArchitecture(null); }, []);

  return (
    <>
      <ArchitectureList
        key={refreshKey}
        onView={handleView}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
      />

      <ArchitectureFormModal
        isOpen={showFormModal}
        onClose={() => { setShowFormModal(false); setEditArchitecture(null); }}
        onArchitectureSaved={handleArchitectureSaved}
        editArchitecture={editArchitecture}
      />

      {ConfirmationDialog}
    </>
  );
};
