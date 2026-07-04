import React, { useState, useCallback, useEffect } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import { TemplateList, TemplateDetailModal, CreateTemplateModal } from '@system/features/system/components/templates';
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
      <TemplateList
        key={refreshKey}
        onView={handleView}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
        onDuplicate={canCreate ? handleDuplicate : undefined}
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

      {ConfirmationDialog}
    </>
  );
};
