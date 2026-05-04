import React, { useState, useCallback, useEffect } from 'react';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { NetworkList, NetworkDetailModal, NetworkFormModal } from '@system/features/system/components/networks';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProviderNetwork } from '@system/features/system/types/system.types';

interface NetworksTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const NetworksTab: React.FC<NetworksTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canCreate = hasPermission('system.networks.create');
  const canDelete = hasPermission('system.networks.delete');

  const [showFormModal, setShowFormModal] = useState(false);
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [selectedNetworkId, setSelectedNetworkId] = useState<string | null>(null);
  const [editNetwork, setEditNetwork] = useState<SystemProviderNetwork | null>(null);
  const [networkToDelete, setNetworkToDelete] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [deleting, setDeleting] = useState(false);

  const handleCreate = useCallback(() => { setEditNetwork(null); setShowFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((n: SystemProviderNetwork) => { setSelectedNetworkId(n.id); setShowDetailModal(true); }, []);
  const handleEdit = useCallback((n: SystemProviderNetwork) => { setEditNetwork(n); setShowFormModal(true); }, []);
  const handleDeleteClick = useCallback((id: string) => { setNetworkToDelete(id); setShowDeleteConfirm(true); }, []);
  const handleDeleteConfirm = async () => {
    if (!networkToDelete) return;
    setDeleting(true);
    try {
      await systemApi.deleteNetwork(networkToDelete);
      addNotification({ type: 'success', message: 'Network deleted successfully' });
      setRefreshKey((k) => k + 1);
    } catch (error) {
      addNotification({ type: 'error', message: `Failed to delete network: ${error instanceof Error ? error.message : 'An error occurred'}` });
    } finally {
      setDeleting(false);
      setShowDeleteConfirm(false);
      setNetworkToDelete(null);
    }
  };
  const handleNetworkSaved = useCallback(() => { setRefreshKey((k) => k + 1); setEditNetwork(null); }, []);
  const handleEditFromDetail = useCallback((n: SystemProviderNetwork) => {
    setShowDetailModal(false); setSelectedNetworkId(null); setEditNetwork(n); setShowFormModal(true);
  }, []);

  return (
    <>
      <NetworkList
        key={refreshKey}
        onView={handleView}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
      />

      <NetworkDetailModal
        networkId={selectedNetworkId}
        isOpen={showDetailModal}
        onClose={() => { setShowDetailModal(false); setSelectedNetworkId(null); }}
        onNetworkUpdated={() => setRefreshKey((k) => k + 1)}
        onEdit={handleEditFromDetail}
      />

      <NetworkFormModal
        network={editNetwork}
        isOpen={showFormModal}
        onClose={() => { setShowFormModal(false); setEditNetwork(null); }}
        onNetworkSaved={handleNetworkSaved}
      />

      {showDeleteConfirm && (
        <div className="fixed inset-0 z-50 overflow-y-auto">
          <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={() => setShowDeleteConfirm(false)} />
          <div className="flex min-h-full items-center justify-center p-4">
            <div className="relative w-full max-w-md bg-theme-surface rounded-lg shadow-xl">
              <div className="p-6">
                <h3 className="text-lg font-semibold text-theme-primary mb-2">Delete Network</h3>
                <p className="text-theme-secondary mb-6">
                  Are you sure you want to delete this network? This action cannot be undone.
                  All subnets and associated resources will also be removed.
                </p>
                <div className="flex justify-end gap-3">
                  <Button variant="outline" onClick={() => { setShowDeleteConfirm(false); setNetworkToDelete(null); }}>
                    Cancel
                  </Button>
                  <Button variant="danger" onClick={handleDeleteConfirm} disabled={deleting}>
                    {deleting ? 'Deleting...' : 'Delete Network'}
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
