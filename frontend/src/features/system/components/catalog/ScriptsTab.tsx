import React, { useState, useCallback, useEffect } from 'react';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
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

  const [showFormModal, setShowFormModal] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [editScript, setEditScript] = useState<SystemNodeScript | null>(null);
  const [scriptToDelete, setScriptToDelete] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [deleting, setDeleting] = useState(false);

  const handleCreate = useCallback(() => { setEditScript(null); setShowFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((s: SystemNodeScript) => { setEditScript(s); setShowFormModal(true); }, []);
  const handleEdit = handleView;
  const handleDeleteClick = useCallback((id: string) => { setScriptToDelete(id); setShowDeleteConfirm(true); }, []);
  const handleDeleteConfirm = async () => {
    if (!scriptToDelete) return;
    setDeleting(true);
    try {
      await systemApi.deleteScript(scriptToDelete);
      addNotification({ type: 'success', message: 'Script deleted successfully' });
      setRefreshKey((k) => k + 1);
    } catch (error) {
      addNotification({ type: 'error', message: `Failed to delete script: ${error instanceof Error ? error.message : 'An error occurred'}` });
    } finally {
      setDeleting(false); setShowDeleteConfirm(false); setScriptToDelete(null);
    }
  };
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

      {showDeleteConfirm && (
        <div className="fixed inset-0 z-50 overflow-y-auto">
          <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={() => setShowDeleteConfirm(false)} />
          <div className="flex min-h-full items-center justify-center p-4">
            <div className="relative w-full max-w-md bg-theme-surface rounded-lg shadow-xl">
              <div className="p-6">
                <h3 className="text-lg font-semibold text-theme-primary mb-2">Delete Script</h3>
                <p className="text-theme-secondary mb-6">
                  Are you sure you want to delete this script? This action cannot be undone.
                  Platforms using this script will need to be updated.
                </p>
                <div className="flex justify-end gap-3">
                  <Button variant="outline" onClick={() => { setShowDeleteConfirm(false); setScriptToDelete(null); }}>Cancel</Button>
                  <Button variant="danger" onClick={handleDeleteConfirm} disabled={deleting}>
                    {deleting ? 'Deleting...' : 'Delete Script'}
                  </Button>
                </div>
              </div>
            </div>
          </div>
        </div>
      )}
    </>
  );
};
