import React, { useState, useCallback, useEffect } from 'react';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { ProviderList, ProviderDetailModal, ProviderFormModal } from '@system/features/system/components/providers';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProvider } from '@system/features/system/types/system.types';

interface ProvidersTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const ProvidersTab: React.FC<ProvidersTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canCreate = hasPermission('system.providers.create');
  const canDelete = hasPermission('system.providers.delete');

  const [showFormModal, setShowFormModal] = useState(false);
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [selectedProviderId, setSelectedProviderId] = useState<string | null>(null);
  const [editProvider, setEditProvider] = useState<SystemProvider | null>(null);
  const [providerToDelete, setProviderToDelete] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [deleting, setDeleting] = useState(false);

  const handleCreate = useCallback(() => { setEditProvider(null); setShowFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((p: SystemProvider) => { setSelectedProviderId(p.id); setShowDetailModal(true); }, []);
  const handleEdit = useCallback((p: SystemProvider) => { setEditProvider(p); setShowFormModal(true); }, []);
  const handleDeleteClick = useCallback((id: string) => { setProviderToDelete(id); setShowDeleteConfirm(true); }, []);
  const handleDeleteConfirm = async () => {
    if (!providerToDelete) return;
    setDeleting(true);
    try {
      await systemApi.deleteProvider(providerToDelete);
      addNotification({ type: 'success', message: 'Provider deleted successfully' });
      setRefreshKey((k) => k + 1);
    } catch (error) {
      addNotification({ type: 'error', message: `Failed to delete provider: ${error instanceof Error ? error.message : 'An error occurred'}` });
    } finally {
      setDeleting(false);
      setShowDeleteConfirm(false);
      setProviderToDelete(null);
    }
  };
  const handleProviderSaved = useCallback(() => { setRefreshKey((k) => k + 1); setEditProvider(null); }, []);
  const handleEditFromDetail = useCallback((p: SystemProvider) => {
    setShowDetailModal(false); setSelectedProviderId(null); setEditProvider(p); setShowFormModal(true);
  }, []);

  return (
    <>
      <ProviderList
        key={refreshKey}
        onView={handleView}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
      />

      <ProviderDetailModal
        providerId={selectedProviderId}
        isOpen={showDetailModal}
        onClose={() => { setShowDetailModal(false); setSelectedProviderId(null); }}
        onEdit={handleEditFromDetail}
      />

      <ProviderFormModal
        isOpen={showFormModal}
        onClose={() => { setShowFormModal(false); setEditProvider(null); }}
        onProviderSaved={handleProviderSaved}
        editProvider={editProvider}
      />

      {showDeleteConfirm && (
        <div className="fixed inset-0 z-50 overflow-y-auto">
          <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={() => setShowDeleteConfirm(false)} />
          <div className="flex min-h-full items-center justify-center p-4">
            <div className="relative w-full max-w-md bg-theme-surface rounded-lg shadow-xl">
              <div className="p-6">
                <h3 className="text-lg font-semibold text-theme-primary mb-2">Delete Provider</h3>
                <p className="text-theme-secondary mb-6">
                  Are you sure you want to delete this provider? This action cannot be undone.
                  All regions and connections associated with this provider will also be removed.
                </p>
                <div className="flex justify-end gap-3">
                  <Button variant="outline" onClick={() => { setShowDeleteConfirm(false); setProviderToDelete(null); }}>
                    Cancel
                  </Button>
                  <Button variant="danger" onClick={handleDeleteConfirm} disabled={deleting}>
                    {deleting ? 'Deleting...' : 'Delete Provider'}
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
