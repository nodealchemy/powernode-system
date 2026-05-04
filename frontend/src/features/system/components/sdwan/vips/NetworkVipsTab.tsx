import React, { useState, useCallback, useEffect } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type { SdwanVirtualIp } from '../../../types/sdwan.types';
import { VirtualIpList } from './VirtualIpList';
import { VirtualIpCreateModal } from './VirtualIpCreateModal';
import { VirtualIpFailoverModal } from './VirtualIpFailoverModal';

interface NetworkVipsTabProps {
  networkId: string;
  // Slice 9d/d2 — page-owned action handle. The parent page passes
  // a setter that the tab calls on mount with a callback bag, so the
  // page's PageContainer.actions can trigger modal opens (matches the
  // "Actions ALL in PageContainer" rule from frontend/CLAUDE.md).
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const NetworkVipsTab: React.FC<NetworkVipsTabProps> = ({ networkId, onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canManage = hasPermission('sdwan.vips.manage');

  const [refreshKey, setRefreshKey] = useState(0);
  const [showCreate, setShowCreate] = useState(false);
  const [vipToFailover, setVipToFailover] = useState<SdwanVirtualIp | null>(null);
  const [vipToDelete, setVipToDelete] = useState<SdwanVirtualIp | null>(null);

  const triggerRefresh = useCallback(() => setRefreshKey((k) => k + 1), []);

  // Publish the action handle to the parent on mount and clear on unmount,
  // so the page's tabActions array can wire its "New VIP" button into
  // PageContainer.actions when this tab is active.
  useEffect(() => {
    onActionsReady?.({ openCreate: () => setShowCreate(true) });
    return () => onActionsReady?.(null);
  }, [onActionsReady]);

  const handleDelete = async () => {
    if (!vipToDelete) return;
    try {
      await sdwanApi.deleteVirtualIp(networkId, vipToDelete.id);
      addNotification?.({ type: 'success', message: `VIP '${vipToDelete.name}' deleted.` });
      setVipToDelete(null);
      triggerRefresh();
    } catch (err) {
      addNotification?.({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to delete VIP',
      });
    }
  };

  return (
    <div className="space-y-4">
      <p className="text-xs text-theme-secondary">
        First-class addresses that one or more peers claim on their loopback. Routed via overlay AllowedIPs in
        static mode; advertised via iBGP in <code className="font-mono">routing_protocol=ibgp</code> networks.
      </p>

      <VirtualIpList
        networkId={networkId}
        refreshKey={refreshKey}
        onFailover={canManage ? (v) => setVipToFailover(v) : undefined}
        onDelete={canManage ? (v) => setVipToDelete(v) : undefined}
      />

      {showCreate && (
        <VirtualIpCreateModal
          networkId={networkId}
          onClose={() => setShowCreate(false)}
          onCreated={() => {
            setShowCreate(false);
            triggerRefresh();
            addNotification?.({ type: 'success', message: 'Virtual IP created.' });
          }}
        />
      )}

      {vipToFailover && (
        <VirtualIpFailoverModal
          networkId={networkId}
          vip={vipToFailover}
          onClose={() => setVipToFailover(null)}
          onFailedOver={() => {
            setVipToFailover(null);
            triggerRefresh();
            addNotification?.({ type: 'success', message: 'Failover triggered.' });
          }}
        />
      )}

      {vipToDelete && (
        <Modal isOpen onClose={() => setVipToDelete(null)} title="Delete Virtual IP" size="md">
          <div className="space-y-3">
            <p className="text-sm text-theme-primary">
              Delete VIP <strong>{vipToDelete.name}</strong> ({vipToDelete.cidr})? Holders will release the
              address from their loopback on the next reconcile.
            </p>
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setVipToDelete(null)}>Cancel</Button>
              <Button variant="danger" onClick={handleDelete}>Delete</Button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
};
