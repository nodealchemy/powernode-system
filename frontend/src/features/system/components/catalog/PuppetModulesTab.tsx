import React, { useState, useCallback, useEffect } from 'react';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
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

  const [showFormModal, setShowFormModal] = useState(false);
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [selectedModuleId, setSelectedModuleId] = useState<string | null>(null);
  const [editModule, setEditModule] = useState<SystemPuppetModule | null>(null);
  const [moduleToDelete, setModuleToDelete] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [deleting, setDeleting] = useState(false);

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
  const handleDeleteClick = useCallback((id: string) => { setModuleToDelete(id); setShowDeleteConfirm(true); }, []);
  const handleDeleteConfirm = async () => {
    if (!moduleToDelete) return;
    setDeleting(true);
    try {
      await systemApi.deletePuppetModule(moduleToDelete);
      addNotification({ type: 'success', message: 'Puppet module deleted successfully' });
      setRefreshKey((k) => k + 1);
    } catch (error) {
      addNotification({ type: 'error', message: `Failed to delete Puppet module: ${error instanceof Error ? error.message : 'An error occurred'}` });
    } finally {
      setDeleting(false); setShowDeleteConfirm(false); setModuleToDelete(null);
    }
  };
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

      {showDeleteConfirm && (
        <div className="fixed inset-0 z-50 overflow-y-auto">
          <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={() => setShowDeleteConfirm(false)} />
          <div className="flex min-h-full items-center justify-center p-4">
            <div className="relative w-full max-w-md bg-theme-surface rounded-lg shadow-xl">
              <div className="p-6">
                <h3 className="text-lg font-semibold text-theme-primary mb-2">Delete Puppet Module</h3>
                <p className="text-theme-secondary mb-6">
                  Are you sure you want to delete this Puppet module? This action cannot be undone.
                  All resources and node module assignments will also be removed.
                </p>
                <div className="flex justify-end gap-3">
                  <Button variant="outline" onClick={() => { setShowDeleteConfirm(false); setModuleToDelete(null); }}>Cancel</Button>
                  <Button variant="danger" onClick={handleDeleteConfirm} disabled={deleting}>
                    {deleting ? 'Deleting...' : 'Delete Module'}
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
