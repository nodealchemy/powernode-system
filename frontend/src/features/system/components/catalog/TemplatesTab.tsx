import React, { useCallback, useEffect, useState } from 'react';
import { Upload } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import {
  TemplateList,
  TemplateDetailModal,
  CreateTemplateModal,
  CloneTemplateModal,
  ImportTemplateModal
} from '@system/features/system/components/templates';
import { systemApi } from '@system/features/system/services/systemApi';
import { useCrudTab } from '@system/features/system/hooks/useCrudTab';
import type { SystemNodeTemplate } from '@system/features/system/types/system.types';

interface TemplatesTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const TemplatesTab: React.FC<TemplatesTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const canCreate = hasPermission('system.templates.create');
  const canDelete = hasPermission('system.templates.delete');

  const [showDetailModal, setShowDetailModal] = useState(false);
  const [selectedTemplateId, setSelectedTemplateId] = useState<string | null>(null);
  // The create modal is dual-purpose: it opens either editing a template or
  // duplicating one. `duplicateTemplate` is the second half of a state pair
  // whose first half the hook owns, so every handler that touches the form has
  // to clear it — including the one published through onActionsReady, which is
  // why this tab publishes its own handle rather than the hook's.
  const [duplicateTemplate, setDuplicateTemplate] = useState<SystemNodeTemplate | null>(null);
  const [cloneTemplate, setCloneTemplate] = useState<SystemNodeTemplate | null>(null);
  const [showImportModal, setShowImportModal] = useState(false);

  const crud = useCrudTab<SystemNodeTemplate>({
    entityLabel: 'Template',
    deleteMessage:
      'Are you sure you want to delete this template? This action cannot be undone. Any nodes using this template will retain their current configuration.',
    deleteFn: (id) => systemApi.deleteTemplate(id),
  });
  const { handleCreate: openBlankForm, handleEdit: openFormWith, closeForm, handleSaved } = crud;

  const handleCreate = useCallback(() => {
    setDuplicateTemplate(null);
    openBlankForm();
  }, [openBlankForm]);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((t: SystemNodeTemplate) => {
    setSelectedTemplateId(t.id);
    setShowDetailModal(true);
  }, []);
  const handleEdit = useCallback(
    (t: SystemNodeTemplate) => {
      setDuplicateTemplate(null);
      openFormWith(t);
    },
    [openFormWith],
  );
  const handleEditFromDetail = useCallback(
    (t: SystemNodeTemplate) => {
      setShowDetailModal(false);
      setSelectedTemplateId(null);
      handleEdit(t);
    },
    [handleEdit],
  );
  // Duplicate opens the same form with no entity under edit, seeded FROM one.
  const handleDuplicate = useCallback(
    (t: SystemNodeTemplate) => {
      setDuplicateTemplate(t);
      openBlankForm();
    },
    [openBlankForm],
  );
  const handleClone = useCallback((t: SystemNodeTemplate) => setCloneTemplate(t), []);
  const handleFormClose = useCallback(() => {
    setDuplicateTemplate(null);
    closeForm();
  }, [closeForm]);
  const handleTemplateCreated = useCallback(() => {
    setDuplicateTemplate(null);
    handleSaved();
  }, [handleSaved]);

  return (
    <>
      {canCreate && (
        <div className="flex justify-end mb-3">
          <Button variant="outline" size="sm" onClick={() => setShowImportModal(true)}>
            <Upload className="w-4 h-4 mr-2" />
            Import Template
          </Button>
        </div>
      )}

      <TemplateList
        key={crud.refreshKey}
        onView={handleView}
        onEdit={handleEdit}
        onDelete={canDelete ? crud.handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
        onDuplicate={canCreate ? handleDuplicate : undefined}
        onClone={canCreate ? handleClone : undefined}
      />

      <TemplateDetailModal
        templateId={selectedTemplateId}
        isOpen={showDetailModal}
        onClose={() => { setShowDetailModal(false); setSelectedTemplateId(null); }}
        onTemplateUpdated={crud.triggerRefresh}
        onEdit={handleEditFromDetail}
      />

      <CreateTemplateModal
        isOpen={crud.showFormModal}
        onClose={handleFormClose}
        onTemplateCreated={handleTemplateCreated}
        editTemplate={crud.editEntity}
        duplicateFrom={duplicateTemplate}
      />

      <CloneTemplateModal
        template={cloneTemplate}
        isOpen={!!cloneTemplate}
        onClose={() => setCloneTemplate(null)}
        onCloned={crud.triggerRefresh}
      />

      <ImportTemplateModal
        isOpen={showImportModal}
        onClose={() => setShowImportModal(false)}
        onImported={crud.triggerRefresh}
      />

      {crud.ConfirmationDialog}
    </>
  );
};
