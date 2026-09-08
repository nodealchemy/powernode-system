import React from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { ArchitectureList, ArchitectureFormModal } from '@system/features/system/components/architectures';
import { systemApi } from '@system/features/system/services/systemApi';
import { useCrudTab } from '@system/features/system/hooks/useCrudTab';
import type { SystemNodeArchitecture } from '@system/features/system/types/system.types';

interface ArchitecturesTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const ArchitecturesTab: React.FC<ArchitecturesTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const canCreate = hasPermission('system.architectures.create');
  const canDelete = hasPermission('system.architectures.delete');

  const {
    showFormModal,
    editEntity: editArchitecture,
    refreshKey,
    handleCreate,
    handleEdit,
    handleDeleteClick,
    handleSaved,
    closeForm,
    ConfirmationDialog,
  } = useCrudTab<SystemNodeArchitecture>({
    entityLabel: 'Architecture',
    deleteMessage:
      'Are you sure you want to delete this architecture? This action cannot be undone. Platforms using this architecture will need to be updated.',
    deleteFn: (id) => systemApi.deleteArchitecture(id),
    onActionsReady,
  });

  return (
    <>
      <ArchitectureList
        key={refreshKey}
        onView={handleEdit}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
      />

      <ArchitectureFormModal
        isOpen={showFormModal}
        onClose={closeForm}
        onArchitectureSaved={handleSaved}
        editArchitecture={editArchitecture}
      />

      {ConfirmationDialog}
    </>
  );
};
