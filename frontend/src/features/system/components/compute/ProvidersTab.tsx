import React, { useState, useCallback, useEffect } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
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
  const { confirm, ConfirmationDialog } = useConfirmation();

  const [showFormModal, setShowFormModal] = useState(false);
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [selectedProviderId, setSelectedProviderId] = useState<string | null>(null);
  const [editProvider, setEditProvider] = useState<SystemProvider | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const handleCreate = useCallback(() => { setEditProvider(null); setShowFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  const handleView = useCallback((p: SystemProvider) => { setSelectedProviderId(p.id); setShowDetailModal(true); }, []);
  const handleEdit = useCallback((p: SystemProvider) => { setEditProvider(p); setShowFormModal(true); }, []);
  const handleDeleteClick = useCallback((id: string) => {
    confirm({
      title: 'Delete Provider',
      message: 'Are you sure you want to delete this provider? This action cannot be undone. All regions and connections associated with this provider will also be removed.',
      confirmLabel: 'Delete Provider',
      variant: 'danger',
      onConfirm: async () => {
        try {
          await systemApi.deleteProvider(id);
          addNotification({ type: 'success', message: 'Provider deleted successfully' });
          setRefreshKey((k) => k + 1);
        } catch (error) {
          addNotification({ type: 'error', message: `Failed to delete provider: ${error instanceof Error ? error.message : 'An error occurred'}` });
        }
      }
    });
  }, [confirm, addNotification]);
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

      {ConfirmationDialog}
    </>
  );
};
