import React, { useCallback, useState } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { PuppetModuleList, PuppetModuleDetailModal, PuppetModuleFormModal } from '@system/features/system/components/puppet';
import { systemApi } from '@system/features/system/services/systemApi';
import { useCrudTab } from '@system/features/system/hooks/useCrudTab';
import type { SystemPuppetModule } from '@system/features/system/types/system.types';

interface PuppetModulesTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const PuppetModulesTab: React.FC<PuppetModulesTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const canCreate = hasPermission('system.puppet.create');
  const canDelete = hasPermission('system.puppet.delete');

  // Detail-modal state stays local: the hook owns the FORM, not the read view.
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [selectedModuleId, setSelectedModuleId] = useState<string | null>(null);

  const {
    showFormModal,
    editEntity: editModule,
    refreshKey,
    handleCreate,
    handleEdit,
    handleDeleteClick,
    handleSaved,
    closeForm,
    ConfirmationDialog,
  } = useCrudTab<SystemPuppetModule>({
    // Three casings of one noun, each pinned by a spec: the dialog is titled
    // "Delete Puppet Module", its button says "Delete Module", and the
    // notifications say "Puppet module". None may be derived from another.
    entityLabel: 'Puppet Module',
    confirmLabel: 'Delete Module',
    successLabel: 'Puppet module',
    errorLabel: 'Puppet module',
    deleteMessage:
      'Are you sure you want to delete this Puppet module? This action cannot be undone. All resources and node module assignments will also be removed.',
    deleteFn: (id) => systemApi.deletePuppetModule(id),
    onActionsReady,
  });

  const handleView = useCallback((m: SystemPuppetModule) => {
    setSelectedModuleId(m.id);
    setShowDetailModal(true);
  }, []);
  const handleEditFromDetail = useCallback(
    (m: SystemPuppetModule) => {
      setShowDetailModal(false);
      setSelectedModuleId(null);
      handleEdit(m);
    },
    [handleEdit],
  );

  return (
    <>
      <PuppetModuleList
        key={refreshKey}
        onView={handleView}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
      />

      <PuppetModuleDetailModal
        moduleId={selectedModuleId}
        isOpen={showDetailModal}
        onClose={() => { setShowDetailModal(false); setSelectedModuleId(null); }}
        onEdit={handleEditFromDetail}
      />

      <PuppetModuleFormModal
        isOpen={showFormModal}
        onClose={closeForm}
        onModuleSaved={handleSaved}
        editModule={editModule}
      />

      {ConfirmationDialog}
    </>
  );
};
