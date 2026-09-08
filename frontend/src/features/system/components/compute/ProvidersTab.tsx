import React, { useCallback, useState } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import {
  ProviderList,
  ProviderDetailModal,
  ProviderFormModal,
  ProviderCredentialsPanel,
} from '@system/features/system/components/providers';
import { systemApi } from '@system/features/system/services/systemApi';
import { useCrudTab } from '@system/features/system/hooks/useCrudTab';
import type { SystemProvider } from '@system/features/system/types/system.types';

interface ProvidersTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const ProvidersTab: React.FC<ProvidersTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const canCreate = hasPermission('system.providers.create');
  const canDelete = hasPermission('system.providers.delete');

  // Detail-modal state stays local: the hook owns the FORM, not the read view.
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [selectedProviderId, setSelectedProviderId] = useState<string | null>(null);

  const {
    showFormModal,
    editEntity: editProvider,
    refreshKey,
    handleCreate,
    handleEdit,
    handleDeleteClick,
    handleSaved,
    closeForm,
    triggerRefresh,
    ConfirmationDialog,
  } = useCrudTab<SystemProvider>({
    entityLabel: 'Provider',
    deleteMessage:
      'Are you sure you want to delete this provider? This action cannot be undone. All regions and connections associated with this provider will also be removed.',
    deleteFn: (id) => systemApi.deleteProvider(id),
    onActionsReady,
  });

  const handleView = useCallback((p: SystemProvider) => {
    setSelectedProviderId(p.id);
    setShowDetailModal(true);
  }, []);
  const handleEditFromDetail = useCallback(
    (p: SystemProvider) => {
      setShowDetailModal(false);
      setSelectedProviderId(null);
      handleEdit(p);
    },
    [handleEdit],
  );

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
        onClose={closeForm}
        onProviderSaved={handleSaved}
        onCredentialSaved={triggerRefresh}
        editProvider={editProvider}
      />

      {/* Storing a credential is a separate button on a separate tab of the
          same form, so it needs its own bump: onProviderSaved fires only when
          the PROVIDER is written, and an operator editing a provider purely to
          fix a credential never triggers it. */}
      <ProviderCredentialsPanel refreshKey={refreshKey} />

      {ConfirmationDialog}
    </>
  );
};
