import React, { useState, useCallback } from 'react';
import { Network as NetworkIcon } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useNavigate } from 'react-router-dom';
import {
  NetworkList,
  NetworkCreateModal,
} from '@system/features/system/components/sdwan';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import type { SdwanNetwork } from '@system/features/system/types/sdwan.types';

/**
 * SdwanNetworksPage — top-level list of SDWAN overlay networks.
 *
 * Slice 3 of the SDWAN plan. Read+create here; per-network detail
 * (peers, firewall, topology) lives in SdwanNetworkDetailPage.
 */
const SdwanNetworksPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const navigate = useNavigate();

  const canManage = hasPermission('sdwan.networks.manage');

  const [showCreate, setShowCreate] = useState(false);
  const [deleteConfirm, setDeleteConfirm] = useState<SdwanNetwork | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);

  const triggerRefresh = useCallback(() => setRefreshKey((k) => k + 1), []);

  const handleView = useCallback((n: SdwanNetwork) => {
    navigate(`/app/system/sdwan/${n.id}`);
  }, [navigate]);

  const handleConfirmDelete = useCallback(async () => {
    if (!deleteConfirm) return;
    setDeleting(true);
    try {
      await sdwanApi.deleteNetwork(deleteConfirm.id);
      addNotification({ type: 'success', message: `Network "${deleteConfirm.name}" deleted` });
      setDeleteConfirm(null);
      triggerRefresh();
    } catch (err) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to delete network',
      });
    } finally {
      setDeleting(false);
    }
  }, [deleteConfirm, addNotification, triggerRefresh]);

  const actions = [
    canManage && {
      label: 'Create network',
      onClick: () => setShowCreate(true),
      variant: 'primary' as const,
      icon: NetworkIcon,
    },
  ].filter(Boolean) as { label: string; onClick: () => void; variant: 'primary'; icon: typeof NetworkIcon }[];

  return (
    <PageContainer
      title="SDWAN Networks"
      description="IPv6 overlay networks tied to your fleet. Each network owns a /64 prefix and a per-network nft policy."
      breadcrumbs={[{ label: 'System', href: '/app/system' }, { label: 'SDWAN' }]}
      actions={actions}
    >
      <NetworkList
        onView={handleView}
        onDelete={canManage ? setDeleteConfirm : undefined}
        refreshKey={refreshKey}
      />

      <NetworkCreateModal
        isOpen={showCreate}
        onClose={() => setShowCreate(false)}
        onCreated={triggerRefresh}
      />

      <Modal
        isOpen={deleteConfirm !== null}
        onClose={() => !deleting && setDeleteConfirm(null)}
        title="Delete SDWAN network"
      >
        {deleteConfirm && (
          <div className="space-y-4">
            <p className="text-theme-primary">
              Permanently delete <strong>{deleteConfirm.name}</strong>?
            </p>
            <p className="text-sm text-theme-secondary">
              This destroys all peers + firewall rules in this network. Agents will tear
              down their wg-sdwan-* interfaces on the next heartbeat tick.
            </p>
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setDeleteConfirm(null)} disabled={deleting}>
                Cancel
              </Button>
              <Button variant="danger" onClick={handleConfirmDelete} disabled={deleting}>
                {deleting ? 'Deleting…' : 'Delete'}
              </Button>
            </div>
          </div>
        )}
      </Modal>
    </PageContainer>
  );
};

export default SdwanNetworksPage;
