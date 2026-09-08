import React from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { ScriptList, ScriptFormModal } from '@system/features/system/components/scripts';
import { systemApi } from '@system/features/system/services/systemApi';
import { useCrudTab } from '@system/features/system/hooks/useCrudTab';
import type { SystemNodeScript } from '@system/features/system/types/system.types';

interface ScriptsTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const ScriptsTab: React.FC<ScriptsTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const canCreate = hasPermission('system.scripts.create');
  const canDelete = hasPermission('system.scripts.delete');

  const {
    showFormModal,
    editEntity: editScript,
    refreshKey,
    handleCreate,
    handleEdit,
    handleDeleteClick,
    handleSaved,
    closeForm,
    ConfirmationDialog,
  } = useCrudTab<SystemNodeScript>({
    entityLabel: 'Script',
    deleteMessage:
      'Are you sure you want to delete this script? This action cannot be undone. Platforms using this script will need to be updated.',
    deleteFn: (id) => systemApi.deleteScript(id),
    onActionsReady,
  });

  return (
    <>
      <ScriptList
        key={refreshKey}
        onView={handleEdit}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
      />

      <ScriptFormModal
        isOpen={showFormModal}
        onClose={closeForm}
        onScriptSaved={handleSaved}
        editScript={editScript}
      />

      {ConfirmationDialog}
    </>
  );
};
