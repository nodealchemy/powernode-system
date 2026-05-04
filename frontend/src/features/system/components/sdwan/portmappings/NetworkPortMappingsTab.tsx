import React, { useState, useCallback, useEffect } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type { SdwanPortMapping } from '../../../types/sdwan.types';
import { PortMappingList } from './PortMappingList';
import { PortMappingCreateModal } from './PortMappingCreateModal';

interface NetworkPortMappingsTabProps {
  networkId: string;
  // Slice 7b/d2 — page-owned action handle (matches "Actions ALL in
  // PageContainer" rule). Parent page wires the "New mapping" button
  // into its PageContainer.actions when this tab is active.
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const NetworkPortMappingsTab: React.FC<NetworkPortMappingsTabProps> = ({
  networkId,
  onActionsReady,
}) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canManage = hasPermission('sdwan.port_mappings.manage');

  const [refreshKey, setRefreshKey] = useState(0);
  const [editTarget, setEditTarget] = useState<SdwanPortMapping | null | undefined>(undefined);
  const [deleteTarget, setDeleteTarget] = useState<SdwanPortMapping | null>(null);

  const triggerRefresh = useCallback(() => setRefreshKey((k) => k + 1), []);

  useEffect(() => {
    onActionsReady?.({ openCreate: () => setEditTarget(null) });
    return () => onActionsReady?.(null);
  }, [onActionsReady]);

  const handleDelete = async () => {
    if (!deleteTarget) return;
    try {
      await sdwanApi.deletePortMapping(networkId, deleteTarget.id);
      addNotification?.({ type: 'success', message: `Port mapping '${deleteTarget.name}' deleted.` });
      setDeleteTarget(null);
      triggerRefresh();
    } catch (err) {
      addNotification?.({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to delete mapping',
      });
    }
  };

  const handleToggle = async (m: SdwanPortMapping) => {
    try {
      await sdwanApi.updatePortMapping(networkId, m.id, { enabled: !m.enabled });
      triggerRefresh();
    } catch (err) {
      addNotification?.({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to toggle mapping',
      });
    }
  };

  return (
    <div className="space-y-4">
      <p className="text-xs text-theme-secondary">
        Hub peers publish overlay services to v4-only clients via nft DNAT. Inbound packets to{' '}
        <code className="font-mono">hub:port</code> get redirected to the target peer's overlay address inside the
        SDWAN tunnel.
      </p>

      <PortMappingList
        networkId={networkId}
        refreshKey={refreshKey}
        onEdit={canManage ? (m) => setEditTarget(m) : undefined}
        onDelete={canManage ? (m) => setDeleteTarget(m) : undefined}
        onToggle={canManage ? handleToggle : undefined}
      />

      {editTarget !== undefined && (
        <PortMappingCreateModal
          networkId={networkId}
          mapping={editTarget}
          onClose={() => setEditTarget(undefined)}
          onSaved={() => {
            setEditTarget(undefined);
            triggerRefresh();
            addNotification?.({ type: 'success', message: 'Port mapping saved.' });
          }}
        />
      )}

      {deleteTarget && (
        <Modal isOpen onClose={() => setDeleteTarget(null)} title="Delete port mapping" size="md">
          <div className="space-y-3">
            <p className="text-sm text-theme-primary">
              Delete port mapping <strong>{deleteTarget.name}</strong> ({deleteTarget.protocol}/
              {deleteTarget.listen_port})? On the next agent reconcile the corresponding nft DNAT rule is removed
              and inbound packets to <code className="font-mono">{deleteTarget.protocol}/{deleteTarget.listen_port}</code>{' '}
              on the hub will no longer reach the target.
            </p>
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setDeleteTarget(null)}>Cancel</Button>
              <Button variant="danger" onClick={handleDelete}>Delete</Button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
};
