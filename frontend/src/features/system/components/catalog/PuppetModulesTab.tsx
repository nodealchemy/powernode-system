import React, { useState, useCallback, useEffect } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import { PuppetModuleList, PuppetModuleDetailModal, PuppetModuleFormModal } from '@system/features/system/components/puppet';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemPuppetModule } from '@system/features/system/types/system.types';

interface PuppetModulesTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const PuppetModulesTab: React.FC<PuppetModulesTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canCreate = hasPermission('system.puppet.create');
  const canDelete = hasPermission('system.puppet.delete');
  const { confirm, ConfirmationDialog } = useConfirmation();

  const [showFormModal, setShowFormModal] = useState(false);
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [selectedModuleId, setSelectedModuleId] = useState<string | null>(null);
  const [editModule, setEditModule] = useState<SystemPuppetModule | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const handleCreate = useCallback(() => { setEditModule(null); setShowFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((m: SystemPuppetModule) => { setSelectedModuleId(m.id); setShowDetailModal(true); }, []);
  const handleEdit = useCallback((m: SystemPuppetModule) => { setEditModule(m); setShowFormModal(true); }, []);
  const handleEditFromDetail = useCallback((m: SystemPuppetModule) => {
    setShowDetailModal(false); setSelectedModuleId(null); setEditModule(m); setShowFormModal(true);
  }, []);
  const handleDeleteClick = useCallback((id: string) => {
    confirm({
      title: 'Delete Puppet Module',
      message: 'Are you sure you want to delete this Puppet module? This action cannot be undone. All resources and node module assignments will also be removed.',
      confirmLabel: 'Delete Module',
      variant: 'danger',
      onConfirm: async () => {
        try {
          await systemApi.deletePuppetModule(id);
          addNotification({ type: 'success', message: 'Puppet module deleted successfully' });
          setRefreshKey((k) => k + 1);
        } catch (error) {
          addNotification({ type: 'error', message: `Failed to delete Puppet module: ${error instanceof Error ? error.message : 'An error occurred'}` });
        }
      }
    });
  }, [confirm, addNotification]);
  const handleModuleSaved = useCallback(() => { setRefreshKey((k) => k + 1); setEditModule(null); }, []);

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
        onClose={() => { setShowFormModal(false); setEditModule(null); }}
        onModuleSaved={handleModuleSaved}
        editModule={editModule}
      />

      {ConfirmationDialog}
    </>
  );
};
