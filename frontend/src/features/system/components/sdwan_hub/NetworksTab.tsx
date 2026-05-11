import React, { useState, useCallback, useEffect } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import {
  NetworkList,
  NetworkCreateModal,
  NetworkDetailModal,
} from '@system/features/system/components/sdwan';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import type { SdwanNetwork } from '@system/features/system/types/sdwan.types';

interface NetworksTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const NetworksTab: React.FC<NetworksTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canManage = hasPermission('sdwan.networks.manage');

  const [showCreate, setShowCreate] = useState(false);
  const [deleteConfirm, setDeleteConfirm] = useState<SdwanNetwork | null>(null);
  const [detailNetwork, setDetailNetwork] = useState<SdwanNetwork | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);

  const triggerRefresh = useCallback(() => setRefreshKey((k) => k + 1), []);

  useEffect(() => {
    onActionsReady?.({ openCreate: () => setShowCreate(true) });
    return () => onActionsReady?.(null);
  }, [onActionsReady]);

  // Modal-first: the eye icon on a list row opens NetworkDetailModal,
  // which hosts the full management surface (7 tabs). No standalone
  // detail page exists.
  const handleOpenDetails = useCallback((n: SdwanNetwork) => {
    setDetailNetwork(n);
  }, []);

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

  return (
    <>
      <NetworkList
        onOpenDetails={handleOpenDetails}
        onDelete={canManage ? setDeleteConfirm : undefined}
        refreshKey={refreshKey}
      />

      <NetworkCreateModal
        isOpen={showCreate}
        onClose={() => setShowCreate(false)}
        onCreated={triggerRefresh}
      />

      <NetworkDetailModal
        network={detailNetwork}
        isOpen={detailNetwork !== null}
        onClose={() => setDetailNetwork(null)}
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
    </>
  );
};
