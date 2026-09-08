import React from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { PlatformList, PlatformFormModal } from '@system/features/system/components/platforms';
import { systemApi } from '@system/features/system/services/systemApi';
import { useCrudTab } from '@system/features/system/hooks/useCrudTab';
import type { SystemNodePlatform } from '@system/features/system/types/system.types';

interface PlatformsTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const PlatformsTab: React.FC<PlatformsTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const canCreate = hasPermission('system.platforms.create');
  const canDelete = hasPermission('system.platforms.delete');

  const {
    showFormModal,
    editEntity: editPlatform,
    refreshKey,
    handleCreate,
    handleEdit,
    handleDeleteClick,
    handleSaved,
    closeForm,
    ConfirmationDialog,
  } = useCrudTab<SystemNodePlatform>({
    entityLabel: 'Platform',
    deleteMessage:
      'Are you sure you want to delete this platform? This action cannot be undone. Templates using this platform will need to be updated.',
    deleteFn: (id) => systemApi.deletePlatform(id),
    onActionsReady,
  });

  return (
    <>
      <PlatformList
        key={refreshKey}
        onView={handleEdit}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
      />

      <PlatformFormModal
        isOpen={showFormModal}
        onClose={closeForm}
        onPlatformSaved={handleSaved}
        editPlatform={editPlatform}
      />

      {ConfirmationDialog}
    </>
  );
};
