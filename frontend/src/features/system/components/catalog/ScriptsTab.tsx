import React, { useState, useCallback, useEffect } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import { ScriptList, ScriptFormModal } from '@system/features/system/components/scripts';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeScript } from '@system/features/system/types/system.types';

interface ScriptsTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const ScriptsTab: React.FC<ScriptsTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canCreate = hasPermission('system.scripts.create');
  const canDelete = hasPermission('system.scripts.delete');
  const { confirm, ConfirmationDialog } = useConfirmation();

  const [showFormModal, setShowFormModal] = useState(false);
  const [editScript, setEditScript] = useState<SystemNodeScript | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const handleCreate = useCallback(() => { setEditScript(null); setShowFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((s: SystemNodeScript) => { setEditScript(s); setShowFormModal(true); }, []);
  const handleEdit = handleView;
  const handleDeleteClick = useCallback((id: string) => {
    confirm({
      title: 'Delete Script',
      message: 'Are you sure you want to delete this script? This action cannot be undone. Platforms using this script will need to be updated.',
      confirmLabel: 'Delete Script',
      variant: 'danger',
      onConfirm: async () => {
        try {
          await systemApi.deleteScript(id);
          addNotification({ type: 'success', message: 'Script deleted successfully' });
          setRefreshKey((k) => k + 1);
        } catch (error) {
          addNotification({ type: 'error', message: `Failed to delete script: ${error instanceof Error ? error.message : 'An error occurred'}` });
        }
      }
    });
  }, [confirm, addNotification]);
  const handleScriptSaved = useCallback(() => { setRefreshKey((k) => k + 1); setEditScript(null); }, []);

  return (
    <>
      <ScriptList
        key={refreshKey}
        onView={handleView}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
      />

      <ScriptFormModal
        isOpen={showFormModal}
        onClose={() => { setShowFormModal(false); setEditScript(null); }}
        onScriptSaved={handleScriptSaved}
        editScript={editScript}
      />

      {ConfirmationDialog}
    </>
  );
};
