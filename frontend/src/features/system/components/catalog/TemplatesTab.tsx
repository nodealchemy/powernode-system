import React, { useState, useCallback, useEffect } from 'react';
import { Upload } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import {
  TemplateList,
  TemplateDetailModal,
  CreateTemplateModal,
  CloneTemplateModal,
  ImportTemplateModal
} from '@system/features/system/components/templates';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeTemplate } from '@system/features/system/types/system.types';

interface TemplatesTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const TemplatesTab: React.FC<TemplatesTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canCreate = hasPermission('system.templates.create');
  const canDelete = hasPermission('system.templates.delete');
  const { confirm, ConfirmationDialog } = useConfirmation();

  const [showCreateModal, setShowCreateModal] = useState(false);
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [selectedTemplateId, setSelectedTemplateId] = useState<string | null>(null);
  const [editTemplate, setEditTemplate] = useState<SystemNodeTemplate | null>(null);
  const [duplicateTemplate, setDuplicateTemplate] = useState<SystemNodeTemplate | null>(null);
  const [cloneTemplate, setCloneTemplate] = useState<SystemNodeTemplate | null>(null);
  const [showImportModal, setShowImportModal] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);

  const handleCreate = useCallback(() => {
    setEditTemplate(null);
    setDuplicateTemplate(null);
    setShowCreateModal(true);
  }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((t: SystemNodeTemplate) => { setSelectedTemplateId(t.id); setShowDetailModal(true); }, []);
  const handleEdit = useCallback((t: SystemNodeTemplate) => { setEditTemplate(t); setDuplicateTemplate(null); setShowCreateModal(true); }, []);
  const handleEditFromDetail = useCallback((t: SystemNodeTemplate) => {
    setShowDetailModal(false); setSelectedTemplateId(null); setEditTemplate(t); setDuplicateTemplate(null); setShowCreateModal(true);
  }, []);
  const handleDuplicate = useCallback((t: SystemNodeTemplate) => { setDuplicateTemplate(t); setEditTemplate(null); setShowCreateModal(true); }, []);
  const handleClone = useCallback((t: SystemNodeTemplate) => setCloneTemplate(t), []);
  const handleLifecycleComplete = useCallback(() => setRefreshKey((k) => k + 1), []);
  const handleDeleteClick = useCallback((id: string) => {
    confirm({
      title: 'Delete Template',
      message: 'Are you sure you want to delete this template? This action cannot be undone. Any nodes using this template will retain their current configuration.',
      confirmLabel: 'Delete Template',
      variant: 'danger',
      onConfirm: async () => {
        try {
          await systemApi.deleteTemplate(id);
          addNotification({ type: 'success', message: 'Template deleted successfully' });
          setRefreshKey((k) => k + 1);
        } catch (error) {
          addNotification({ type: 'error', message: `Failed to delete template: ${error instanceof Error ? error.message : 'An error occurred'}` });
        }
      }
    });
  }, [confirm, addNotification]);
  const handleTemplateCreated = useCallback(() => { setRefreshKey((k) => k + 1); setEditTemplate(null); setDuplicateTemplate(null); }, []);

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
        key={refreshKey}
        onView={handleView}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
        onDuplicate={canCreate ? handleDuplicate : undefined}
        onClone={canCreate ? handleClone : undefined}
      />

      <TemplateDetailModal
        templateId={selectedTemplateId}
        isOpen={showDetailModal}
        onClose={() => { setShowDetailModal(false); setSelectedTemplateId(null); }}
        onTemplateUpdated={() => setRefreshKey((k) => k + 1)}
        onEdit={handleEditFromDetail}
      />

      <CreateTemplateModal
        isOpen={showCreateModal}
        onClose={() => { setShowCreateModal(false); setEditTemplate(null); setDuplicateTemplate(null); }}
        onTemplateCreated={handleTemplateCreated}
        editTemplate={editTemplate}
        duplicateFrom={duplicateTemplate}
      />

      <CloneTemplateModal
        template={cloneTemplate}
        isOpen={!!cloneTemplate}
        onClose={() => setCloneTemplate(null)}
        onCloned={handleLifecycleComplete}
      />

      <ImportTemplateModal
        isOpen={showImportModal}
        onClose={() => setShowImportModal(false)}
        onImported={handleLifecycleComplete}
      />

      {ConfirmationDialog}
    </>
  );
};
